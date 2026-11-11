import Foundation
import SwiftData

/// Resultado de uma ferramenta local: JSON compacto para o modelo e, nas ferramentas de
/// proposta, a proposta validada para a UI.
struct ToolOutcome: Sendable, Hashable {
    var content: String
    var isError: Bool = false
    var proposal: CoachProposal?
}

/// Ferramentas do Coach (SPEC §7) executadas sobre os dados locais.
///
/// - Só leitura: nenhuma ferramenta grava. `propose_*` só valida e devolve uma `CoachProposal`.
/// - Schemas estritos (todas as chaves obrigatórias, `null` para "sem valor").
/// - Limites: histórico de treino ≤ 90 dias / 50 sessões; registro alimentar ≤ 31 dias;
///   listas ≤ 50 itens. Pedidos acima do limite são cortados e o resultado diz `clamped`.
/// - Respeita `CoachProfile.sharing`: o que o usuário não compartilha nem aparece nas ferramentas.
@MainActor
final class FitnessToolbox {
    static let maxHistoryDays = 90
    static let maxHistorySessions = 50
    static let maxNutritionDays = 31
    static let maxListItems = 50
    static let maxNutritionEntries = 200
    static let maxProgressSessions = 20
    /// Janela de `get_exercise_progress` (dias) e teto de sessões lidas para calcular as marcas.
    static let progressWindowDays = 365
    static let progressScanLimit = 400

    enum Name: String, CaseIterable, Sendable {
        case getProfile = "get_profile"
        case listPrograms = "list_programs"
        case getProgram = "get_program"
        case getWorkoutHistory = "get_workout_history"
        case getExerciseProgress = "get_exercise_progress"
        case listExercises = "list_exercises"
        case listNutritionPlans = "list_nutrition_plans"
        case getNutritionLog = "get_nutrition_log"
        case getHealthSummary = "get_health_summary"
        case proposeProgram = "propose_program"
        case proposeNutritionPlan = "propose_nutrition_plan"
    }

    let context: ModelContext
    private let profile: @MainActor () -> CoachProfile
    let now: @MainActor () -> Date
    let calendar: Calendar
    /// Leitor do Saúde (`HealthQueries.live` no app; fake nos testes).
    let health: any HealthDataReading
    /// Estado da conexão com o Saúde, consultado a cada chamada de `get_health_summary`.
    let healthAccess: @MainActor () -> HealthToolAccess

    /// - Parameters:
    ///   - health: leitor do Saúde; `nil` = `HealthQueries.live`.
    ///   - healthAccess: conexão/aparelho; o padrão lê `HKHealthStore` e a preferência "Conectar ao Saúde".
    ///     No app, prefira `HealthToolAccess.from(_:)` com a `HealthAuthorization` compartilhada.
    init(context: ModelContext, profile: @escaping @MainActor () -> CoachProfile = { CoachProfileStore().load() },
         now: @escaping @MainActor () -> Date = { .now }, calendar: Calendar = .current,
         health: (any HealthDataReading)? = nil,
         healthAccess: @escaping @MainActor () -> HealthToolAccess = HealthToolAccess.system) {
        self.context = context
        self.profile = profile
        self.now = now
        self.calendar = calendar
        self.health = health ?? HealthQueries.live
        self.healthAccess = healthAccess
    }

    /// O usuário compartilha treinos (nomes de fichas podem aparecer no resumo de saúde).
    var sharesWorkouts: Bool { profile().sharing.workouts }

    // MARK: - Especificações

    /// Ferramentas oferecidas ao modelo, filtradas pelo que o usuário compartilha.
    var specs: [ToolSpec] {
        let sharing = profile().sharing
        return Name.allCases.filter { isShared($0, sharing) }.map(Self.spec)
    }

    private func isShared(_ name: Name, _ sharing: CoachProfile.Sharing) -> Bool {
        switch name {
        case .getProfile: sharing.profile
        case .listPrograms, .getProgram, .getWorkoutHistory, .getExerciseProgress: sharing.workouts
        case .listNutritionPlans, .getNutritionLog: sharing.nutrition
        case .getHealthSummary: sharing.health
        // Catálogo do app (não é dado pessoal) e propostas (só validam o que o modelo enviou).
        case .listExercises, .proposeProgram, .proposeNutritionPlan: true
        }
    }

    nonisolated static func spec(_ name: Name) -> ToolSpec {
        switch name {
        case .getProfile:
            ToolSpec(name: name.rawValue, description: "Perfil do usuário (idade, sexo, altura, peso, nível, objetivo, restrições/lesões, equipamentos, dias e tempo por semana, preferências alimentares) e a data de hoje. Campos null = não informado.",
                     parametersSchema: emptySchema)
        case .listPrograms:
            ToolSpec(name: name.rawValue, description: "Lista os programas de treino (ativo primeiro), até 50.",
                     parametersSchema: objectSchema(["include_archived": #"{"type":"boolean","description":"Incluir arquivados."}"#]))
        case .getProgram:
            ToolSpec(name: name.rawValue, description: "Detalhe de um programa: fichas, exercícios e séries prescritas (planejado, não realizado).",
                     parametersSchema: objectSchema(["id": #"{"type":"string","description":"id de list_programs."}"#]))
        case .getWorkoutHistory:
            ToolSpec(name: name.rawValue, description: "Sessões de treino concluídas (realizado) no período, mais recentes primeiro. Máximo 90 dias e 50 sessões. Séries como \"reps×carga\"; reps \"alvo\" = feita dentro do alvo sem reps anotadas.",
                     parametersSchema: objectSchema([
                         "from": dateProperty("Início (inclusive)."), "to": dateProperty("Fim (inclusive)."),
                         "exercise": #"{"type":["string","null"],"description":"Filtra por nome de exercício."}"#,
                     ]))
        case .getExerciseProgress:
            ToolSpec(name: name.rawValue, description: "Evolução de um exercício no último ano: até 20 sessões recentes (séries, volume, 1RM estimado Epley) e melhores marcas, em kg.",
                     parametersSchema: objectSchema(["exercise": #"{"type":"string","description":"Nome do exercício."}"#]))
        case .listExercises:
            ToolSpec(name: name.rawValue, description: "Catálogo de exercícios do app (até 50) com catalogKey para usar em propose_program.",
                     parametersSchema: objectSchema(["query": #"{"type":["string","null"],"description":"Trecho do nome (pt-BR ou en); null = todos."}"#]))
        case .listNutritionPlans:
            ToolSpec(name: name.rawValue, description: "Planos alimentares (até 20), com metas; o ativo inclui dias e refeições planejadas (planejado, não consumido).",
                     parametersSchema: emptySchema)
        case .getNutritionLog:
            ToolSpec(name: name.rawValue, description: "O que foi comido (realizado) por dia no período, com totais, água e metas do plano ativo. Máximo 31 dias.",
                     parametersSchema: objectSchema(["from": dateProperty("Início (inclusive)."), "to": dateProperty("Fim (inclusive).")]))
        case .getHealthSummary:
            ToolSpec(name: name.rawValue, description: "Resumo agregado do app Saúde por dia (treinos sem duplicar os vinculados, minutos por tipo, energia ativa, FC em repouso, passos) e médias/tendência do período. Máximo 31 dias; padrão: últimos 7. null = sem dado (ver status: no_data/unavailable), nunca zero. Contexto, não diagnóstico.",
                     parametersSchema: objectSchema(["from": nullableDateProperty("Início (inclusive); null = 6 dias antes de to."),
                                                     "to": nullableDateProperty("Fim (inclusive); null = hoje.")]))
        case .proposeProgram:
            ToolSpec(name: name.rawValue, description: "Propõe um programa de treino como RASCUNHO. O app valida e mostra um cartão para o usuário revisar e salvar; nada é gravado. Use catalogKey de list_exercises quando houver.",
                     parametersSchema: DraftValidation.toolParameters(fromContract: DraftSchemas.programDraftV1))
        case .proposeNutritionPlan:
            ToolSpec(name: name.rawValue, description: "Propõe um plano alimentar como RASCUNHO (valores são estimativas). O app valida e mostra um cartão para revisar e salvar; nada é gravado.",
                     parametersSchema: DraftValidation.toolParameters(fromContract: DraftSchemas.nutritionPlanDraftV1))
        }
    }

    private nonisolated static let emptySchema = #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#

    private nonisolated static func dateProperty(_ description: String) -> String {
        #"{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$","description":"AAAA-MM-DD. "# + description + #""}"#
    }

    private nonisolated static func nullableDateProperty(_ description: String) -> String {
        #"{"type":["string","null"],"pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$","description":"AAAA-MM-DD. "# + description + #""}"#
    }

    private nonisolated static func objectSchema(_ properties: [String: String]) -> String {
        let keys = properties.keys.sorted()
        let body = keys.map { "\"\($0)\":\(properties[$0]!)" }.joined(separator: ",")
        let required = keys.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"# + body + #"},"required":["# + required + #"],"additionalProperties":false}"#
    }

    // MARK: - Execução

    /// Executa uma ferramenta. Assíncrona só por causa do Saúde (as demais leem o SwiftData na hora).
    func execute(_ call: ToolCall) async -> ToolOutcome {
        guard let name = Name(rawValue: call.name) else {
            return error("unknown_tool", "Ferramenta desconhecida: \(call.name)")
        }
        guard isShared(name, profile().sharing) else {
            return error("not_shared", "O usuário não compartilha estes dados com o Coach.")
        }
        // Propostas validam o JSON bruto (schema + Codable); as demais leem argumentos simples.
        switch name {
        case .proposeProgram: return proposeProgram(call)
        case .proposeNutritionPlan: return proposeNutritionPlan(call)
        default: break
        }
        guard let args = (try? JSONValue.parse(call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON))?.objectValue else {
            return error("invalid_arguments", "Argumentos não são um objeto JSON.")
        }
        do {
            switch name {
            case .getProfile: return ok(profileJSON())
            case .listPrograms: return ok(try listPrograms(includeArchived: args["include_archived"] == .bool(true)))
            case .getProgram: return try getProgram(id: args["id"]?.stringValue)
            case .getWorkoutHistory:
                return try workoutHistory(from: args["from"]?.stringValue, to: args["to"]?.stringValue,
                                          exercise: args["exercise"]?.stringValue)
            case .getExerciseProgress: return try exerciseProgress(args["exercise"]?.stringValue)
            case .listExercises: return ok(try listExercises(query: args["query"]?.stringValue))
            case .listNutritionPlans: return ok(try listNutritionPlans())
            case .getNutritionLog: return try nutritionLog(from: args["from"]?.stringValue, to: args["to"]?.stringValue)
            case .getHealthSummary:
                return try await healthSummary(from: args["from"]?.stringValue, to: args["to"]?.stringValue)
            case .proposeProgram, .proposeNutritionPlan: return error("internal", "unreachable")
            }
        } catch is CancellationError {
            return self.error("cancelled", "Leitura cancelada.")
        } catch {
            return self.error("internal", "Falha ao ler os dados locais.")
        }
    }

    // MARK: - Ferramentas

    private func profileJSON() -> JSONValue {
        let p = profile()
        var object: [String: JSONValue] = ["today": .string(Self.dayString(now(), calendar)),
                                           "weekday": .string(Weekday(date: now(), calendar: calendar).rawValue)]
        guard !p.isEmpty else {
            object["available"] = .bool(false)
            return .object(object)
        }
        object["available"] = .bool(true)
        object["age"] = p.age.map { .number(Double($0)) } ?? .null
        object["sex"] = p.sex.map { .string($0.rawValue) } ?? .null
        object["heightCm"] = p.heightCm.map(JSONValue.number) ?? .null
        object["weightKg"] = p.weightKg.map(JSONValue.number) ?? .null
        object["level"] = p.level.map { .string($0.rawValue) } ?? .null
        object["goal"] = Self.text(p.goal)
        object["restrictions"] = Self.text(p.restrictions)
        object["equipment"] = Self.text(p.equipment)
        object["daysPerWeek"] = p.daysPerWeek.map { .number(Double($0)) } ?? .null
        object["minutesPerSession"] = p.minutesPerSession.map { .number(Double($0)) } ?? .null
        object["foodPreferences"] = Self.text(p.foodPreferences)
        return .object(object)
    }

    private func listPrograms(includeArchived: Bool) throws -> JSONValue {
        let all = try context.fetch(FetchDescriptor<TrainingProgram>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        let filtered = all.filter { includeArchived || !$0.isArchived }
            .sorted { ($0.isActive ? 0 : 1, $1.updatedAt) < ($1.isActive ? 0 : 1, $0.updatedAt) }
        let items = filtered.prefix(Self.maxListItems).map { p -> JSONValue in
            .object([
                "id": .string(p.id.uuidString), "name": .string(p.name), "goal": .string(p.goal.rawValue),
                "scheduleMode": .string(p.scheduleMode.rawValue), "isActive": .bool(p.isActive),
                "isArchived": .bool(p.isArchived), "origin": .string(p.origin.rawValue),
                "routines": .number(Double((p.routines ?? []).count)),
                "startDate": .string(Self.dayString(p.startDate, calendar)),
                "endDate": p.endDate.map { .string(Self.dayString($0, calendar)) } ?? .null,
            ])
        }
        return .object(["programs": .array(Array(items)), "total": .number(Double(filtered.count))])
    }

    private func getProgram(id: String?) throws -> ToolOutcome {
        guard let id, let uuid = UUID(uuidString: id) else { return error("invalid_arguments", "id inválido.") }
        var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let program = try context.fetch(descriptor).first else { return error("not_found", "Programa não encontrado.") }
        let routines = program.sortedRoutines.map { routine -> JSONValue in
            .object([
                "name": .string(routine.name), "symbol": .string(routine.symbol),
                "weekdays": .array(routine.weekdays.sorted().map { .string($0.rawValue) }),
                "notes": Self.text(routine.notes),
                "exercises": .array(routine.sortedExercises.map { item in
                    .object([
                        "name": .string(item.displayName),
                        "catalogKey": item.exercise?.catalogKey.map(JSONValue.string) ?? .null,
                        "grouped": .bool(item.groupID != nil),
                        "notes": Self.text(item.notes),
                        "sets": .array(item.sortedSets.map { Self.prescriptionJSON($0, exercise: item) }),
                    ])
                }),
            ])
        }
        return ok(.object([
            "id": .string(program.id.uuidString), "name": .string(program.name),
            "goal": .string(program.goal.rawValue), "goalText": Self.text(program.goalText),
            "scheduleMode": .string(program.scheduleMode.rawValue), "isActive": .bool(program.isActive),
            "notes": Self.text(program.notes), "routines": .array(routines),
        ]))
    }

    private func workoutHistory(from: String?, to: String?, exercise: String?) throws -> ToolOutcome {
        guard let range = dateRange(from: from, to: to, maxDays: Self.maxHistoryDays) else {
            return error("invalid_arguments", "Use from/to no formato AAAA-MM-DD com from ≤ to.")
        }
        let completed = SessionStatus.completed.rawValue
        let start = range.start, end = range.end
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        let filter = exercise.map(ExerciseMatcher.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let matching = sessions.filter { session in
            guard let filter else { return true }
            return session.sortedExercises.contains { ExerciseMatcher.normalize($0.name).contains(filter) }
        }
        let items = matching.prefix(Self.maxHistorySessions).map { session -> JSONValue in
            let exercises = session.sortedExercises.filter { filter == nil || ExerciseMatcher.normalize($0.name).contains(filter!) }
            let duration = session.endedAt.map { max(0, $0.timeIntervalSince(session.startedAt) - session.accumulatedPauseSeconds) }
            return .object([
                "date": .string(Self.dayString(session.startedAt, calendar)),
                "routine": .string(session.routineName),
                "durationMin": duration.map { .number(($0 / 60).rounded()) } ?? .null,
                "sessionRPE": session.sessionRPE.map { .number(Double($0)) } ?? .null,
                "volumeKg": .number(Self.round(exercises.reduce(0) { $0 + WorkoutMetrics.volumeKg($1.performedSets) })),
                "exercises": .array(exercises.map { item in
                    let done = item.sortedSets.filter(\.isCompleted)
                    var object: [String: JSONValue] = [
                        "name": .string(item.name), "status": .string(item.status.rawValue),
                        "sets": .string(done.map(Self.setText).joined(separator: ", ")),
                        "planned": .number(Double(item.sortedSets.count)),
                    ]
                    if item.status == .skipped, let reason = item.skipReason { object["skipReason"] = .string(reason.rawValue) }
                    return .object(object)
                }),
            ])
        }
        var result: [String: JSONValue] = [
            "from": .string(Self.dayString(range.start, calendar)),
            "to": .string(Self.dayString(range.lastDay, calendar)),
            "sessions": .array(Array(items)),
            "totalInRange": .number(Double(matching.count)),
        ]
        if range.clamped { result["clamped"] = .string("Período limitado a \(Self.maxHistoryDays) dias.") }
        if matching.count > Self.maxHistorySessions { result["truncated"] = .string("Mostrando as \(Self.maxHistorySessions) mais recentes.") }
        return ok(.object(result))
    }

    private func exerciseProgress(_ name: String?) throws -> ToolOutcome {
        let target = ExerciseMatcher.normalize(name ?? "")
        guard !target.isEmpty else { return error("invalid_arguments", "Informe o nome do exercício.") }
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let matched = ExerciseMatcher.match(name: name ?? "", catalogKey: nil, in: catalog)
        let completed = SessionStatus.completed.rawValue
        let since = calendar.date(byAdding: .day, value: -Self.progressWindowDays, to: calendar.startOfDay(for: now())) ?? .distantPast
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.startedAt >= since },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = Self.progressScanLimit
        let sessions = try context.fetch(descriptor)
        var rows: [JSONValue] = []
        var history: [[PerformedSet]] = []
        for session in sessions {
            let items = session.sortedExercises.filter { item in
                if let id = matched?.id, item.exerciseID == id { return true }
                return ExerciseMatcher.normalize(item.name) == target
            }
            guard !items.isEmpty else { continue }
            let sets = items.flatMap(\.performedSets)
            history.append(sets)
            if rows.count < Self.maxProgressSessions {
                let bests = WorkoutMetrics.bests(of: sets)
                rows.append(.object([
                    "date": .string(Self.dayString(session.startedAt, calendar)),
                    "sets": .string(items.flatMap { $0.sortedSets.filter(\.isCompleted) }.map(Self.setText).joined(separator: ", ")),
                    "volumeKg": .number(Self.round(bests.bestSessionVolumeKg)),
                    "best1RMKg": .number(Self.round(bests.bestEstimated1RMKg)),
                    "heaviestKg": .number(Self.round(bests.heaviestLoadKg)),
                ]))
            }
        }
        guard !history.isEmpty else {
            return ok(.object(["exercise": .string(matched?.name ?? name ?? ""), "sessions": .array([]),
                               "note": .string("Sem sessões concluídas com este exercício.")]))
        }
        let bests = WorkoutMetrics.bests(history: history)
        return ok(.object([
            "exercise": .string(matched?.name ?? name ?? ""),
            "sessions": .array(rows),
            "totalSessions": .number(Double(history.count)),
            "window": .string("Últimos \(Self.progressWindowDays) dias."),
            "bests": .object([
                "heaviestKg": .number(Self.round(bests.heaviestLoadKg)),
                "bestSessionVolumeKg": .number(Self.round(bests.bestSessionVolumeKg)),
                "best1RMKg": .number(Self.round(bests.bestEstimated1RMKg)),
            ]),
        ]))
    }

    private func listExercises(query: String?) throws -> JSONValue {
        let all = try context.fetch(FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.name)]))
        let q = ExerciseMatcher.normalize(query ?? "")
        let filtered = all.filter { exercise in
            guard !q.isEmpty else { return true }
            if ExerciseMatcher.normalize(exercise.name).contains(q) { return true }
            if let key = exercise.catalogKey, let entry = ExerciseCatalog.entry(forKey: key) {
                return ExerciseMatcher.normalize(entry.nameEN).contains(q) || key.contains(q.replacingOccurrences(of: " ", with: "-"))
            }
            return false
        }
        let items = filtered.prefix(Self.maxListItems).map { e -> JSONValue in
            .object([
                "name": .string(e.name),
                "catalogKey": e.catalogKey.map(JSONValue.string) ?? .null,
                "equipment": .string(e.equipment.rawValue),
                "muscles": .array(e.primaryMuscles.map { .string($0.rawValue) }),
                "kind": .string(e.measurementKind.rawValue),
            ])
        }
        return .object(["exercises": .array(Array(items)), "total": .number(Double(filtered.count))])
    }

    private func listNutritionPlans() throws -> JSONValue {
        let plans = try context.fetch(FetchDescriptor<NutritionPlan>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
        let items = plans.prefix(20).map { plan -> JSONValue in
            var object: [String: JSONValue] = [
                "id": .string(plan.id.uuidString), "name": .string(plan.name), "goal": Self.text(plan.goal),
                "isActive": .bool(plan.isActive), "isArchived": .bool(plan.isArchived), "author": .string(plan.author.rawValue),
                "targets": Self.targetsJSON(plan.targets),
            ]
            if plan.isActive {
                object["days"] = .array(plan.sortedDays.map { day in
                    .object([
                        "name": .string(day.name),
                        "weekdays": .array(day.weekdays.sorted().map { .string($0.rawValue) }),
                        "meals": .array(day.sortedMeals.map { meal in
                            .object([
                                "name": .string(meal.name), "time": .string(Self.timeString(minutes: meal.minutesFromMidnight)),
                                "items": .string(meal.sortedItems.map { "\(Self.round($0.quantity)) \($0.unit.rawValue) \($0.name)" }.joined(separator: "; ")),
                                "plannedKcal": meal.plannedValues.kcal.map { .number(Self.round($0)) } ?? .null,
                            ])
                        }),
                    ])
                })
            }
            return .object(object)
        }
        return .object(["plans": .array(Array(items)), "total": .number(Double(plans.count))])
    }

    private func nutritionLog(from: String?, to: String?) throws -> ToolOutcome {
        guard let range = dateRange(from: from, to: to, maxDays: Self.maxNutritionDays) else {
            return error("invalid_arguments", "Use from/to no formato AAAA-MM-DD com from ≤ to.")
        }
        let start = range.start, end = range.end
        let entries = try context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end }, sortBy: [SortDescriptor(\.date)]))
        let water = try context.fetch(FetchDescriptor<WaterLog>(predicate: #Predicate { $0.date >= start && $0.date < end }))
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        let waterByDay = Dictionary(grouping: water) { calendar.startOfDay(for: $0.date) }
        var emitted = 0
        var days: [JSONValue] = []
        for day in Set(byDay.keys).union(waterByDay.keys).sorted() {
            let dayEntries = byDay[day] ?? []
            let totals = NutritionTotals.totals(dayEntries.map(\.totalsEntry))
            let remaining = max(0, Self.maxNutritionEntries - emitted)
            let shown = dayEntries.prefix(remaining)
            emitted += shown.count
            days.append(.object([
                "date": .string(Self.dayString(day, calendar)),
                "totals": .object([
                    "kcal": .number(Self.round(totals.kcal)), "protein": .number(Self.round(totals.protein)),
                    "carbs": .number(Self.round(totals.carbs)), "fat": .number(Self.round(totals.fat)),
                    "fiber": .number(Self.round(totals.fiber)), "entries": .number(Double(totals.entryCount)),
                    "itemsWithoutKcal": .number(Double(totals.itemsWithoutKcal)),
                ]),
                "waterMl": .number(Self.round((waterByDay[day] ?? []).reduce(0) { $0 + $1.milliliters })),
                "entries": .array(shown.map { entry in
                    .object([
                        "time": .string(Self.timeString(entry.date, calendar)),
                        "name": .string(entry.name),
                        "quantity": .string("\(Self.round(entry.quantity)) \(entry.unit.rawValue)"),
                        "kcal": entry.kcal.map { .number(Self.round($0)) } ?? .null,
                        "meal": entry.mealName.map(JSONValue.string) ?? .string("fora do plano"),
                        "status": entry.mealStatus.map { .string($0.rawValue) } ?? .null,
                        "estimation": .string(entry.estimation.rawValue),
                    ])
                }),
            ]))
        }
        var result: [String: JSONValue] = [
            "from": .string(Self.dayString(range.start, calendar)),
            "to": .string(Self.dayString(range.lastDay, calendar)),
            "days": .array(days),
            "note": .string("Só registros feitos pelo usuário contam como consumido; dias ausentes não têm registro."),
        ]
        if let plan = try NutritionStore(context: context, calendar: calendar).activePlan() {
            result["activePlanTargets"] = Self.targetsJSON(plan.targets)
        }
        if range.clamped { result["clamped"] = .string("Período limitado a \(Self.maxNutritionDays) dias.") }
        if entries.count > emitted { result["truncated"] = .string("Mostrando \(emitted) de \(entries.count) registros.") }
        return ok(.object(result))
    }

    private func proposeProgram(_ call: ToolCall) -> ToolOutcome {
        switch DraftValidation.program(call.argumentsJSON) {
        case let .valid(draft):
            return proposed(CoachProposal(id: call.id, content: .program(draft), createdAt: now()), tool: call.name)
        case let .invalid(issues):
            return invalid(issues, tool: call.name)
        }
    }

    private func proposeNutritionPlan(_ call: ToolCall) -> ToolOutcome {
        switch DraftValidation.nutritionPlan(call.argumentsJSON) {
        case let .valid(draft):
            return proposed(CoachProposal(id: call.id, content: .nutritionPlan(draft), createdAt: now()), tool: call.name)
        case let .invalid(issues):
            return invalid(issues, tool: call.name)
        }
    }

    private func proposed(_ proposal: CoachProposal, tool: String) -> ToolOutcome {
        ToolOutcome(content: JSONValue.object([
            "status": .string("proposed"),
            "proposalId": .string(proposal.id),
            "summary": .string(proposal.summary),
            "note": .string("O usuário verá um cartão para revisar e salvar. Nada foi salvo; não diga que foi."),
        ]).jsonString(), proposal: proposal)
    }

    private func invalid(_ issues: [String], tool: String) -> ToolOutcome {
        ToolOutcome(content: JSONValue.object([
            "status": .string("invalid"),
            "issues": .array(issues.prefix(20).map(JSONValue.string)),
            "hint": .string("Corrija os campos e chame \(tool) de novo com o objeto completo."),
        ]).jsonString(), isError: true)
    }

    // MARK: - Utilitários

    func ok(_ value: JSONValue) -> ToolOutcome { ToolOutcome(content: value.jsonString()) }

    func error(_ code: String, _ message: String) -> ToolOutcome {
        ToolOutcome(content: JSONValue.object(["error": .string(code), "message": .string(message)]).jsonString(), isError: true)
    }

    struct DateRange {
        var start: Date
        /// Exclusivo (meia-noite do dia seguinte a `lastDay`).
        var end: Date
        var lastDay: Date
        var clamped: Bool
    }

    /// Intervalo de dias inteiros [from, to], cortado para `maxDays` terminando em `to`.
    func dateRange(from: String?, to: String?, maxDays: Int) -> DateRange? {
        guard let from = from.flatMap({ Self.parseDay($0, calendar) }), let to = to.flatMap({ Self.parseDay($0, calendar) }),
              from <= to, let end = calendar.date(byAdding: .day, value: 1, to: to) else { return nil }
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        if days + 1 > maxDays, let clampedStart = calendar.date(byAdding: .day, value: -(maxDays - 1), to: to) {
            return DateRange(start: clampedStart, end: end, lastDay: to, clamped: true)
        }
        return DateRange(start: from, end: end, lastDay: to, clamped: false)
    }

    static func parseDay(_ text: String, _ calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1 ... 12).contains(parts[1]), (1 ... 31).contains(parts[2]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func dayString(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func timeString(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func timeString(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func text(_ value: String?) -> JSONValue {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return .null }
        return .string(String(value.prefix(500)))
    }

    /// Na unidade preferida de Ajustes, sempre com o símbolo ("80kg", "176.4lb").
    static func loadText(_ load: Load?, displayUnit: WeightUnit = WeightUnitPreference.current) -> String {
        guard let original = load else { return "" }
        let shown = LoadDisplay.load(original, in: displayUnit)
        let unit = shown.unit.rawValue
        switch shown {
        case let .weight(value, _): return "\(format(value))\(unit)"
        case let .bodyweight(delta, _):
            return delta == 0 ? "PC" : "PC\(delta > 0 ? "+" : "")\(format(delta))\(unit)"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "10×30kg", "alvo×30kg" (concluída sem reps), "aq 15×20kg", "45s", "20min 3000m".
    static func setText(_ log: SetLog) -> String {
        let prefix = log.kind == .working ? "" : (log.kind.isWorking ? "\(log.kind.rawValue) " : "aq ")
        if log.durationSeconds != nil || log.distanceMeters != nil {
            var parts: [String] = []
            if let seconds = log.durationSeconds { parts.append(seconds >= 120 ? "\(Int(seconds / 60))min" : "\(Int(seconds))s") }
            if let meters = log.distanceMeters { parts.append("\(Int(meters))m") }
            if let load = log.load { parts.append(loadText(load)) }
            return prefix + parts.joined(separator: " ")
        }
        let reps = log.reps.map(String.init) ?? "alvo(\(log.repTarget?.displayText ?? "?"))"
        let load = loadText(log.load ?? log.plannedLoad)
        return prefix + (load.isEmpty ? reps : "\(reps)×\(load)")
    }

    private static func prescriptionJSON(_ set: SetPrescription, exercise: RoutineExercise) -> JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string(set.kind.rawValue),
            "reps": set.repTarget.map { .string($0.displayText) } ?? .null,
            "load": set.effectiveLoad.map { .string(loadText($0)) } ?? .null,
            "restSeconds": (set.restSeconds ?? exercise.restSeconds).map { .number(Double($0)) } ?? .null,
        ]
        if let hold = set.holdSeconds { object["holdSeconds"] = .number(Double(hold)) }
        switch set.effort {
        case let .rir(value)?: object["rir"] = .number(Double(value))
        case let .rpe(value)?: object["rpe"] = .number(value)
        case nil: break
        }
        if let tempo = set.tempo, !tempo.isEmpty { object["tempo"] = .string(tempo) }
        if let cardio = set.cardio {
            object["cardio"] = .string([
                cardio.durationSeconds.map { "\($0 / 60)min" }, cardio.distanceMeters.map { "\(Int($0))m" },
                cardio.level.map { "nível \($0)" }, cardio.heartRateZone.map { "zona \($0)" },
            ].compactMap { $0 }.joined(separator: " "))
        }
        if !set.notes.isEmpty { object["notes"] = .string(set.notes) }
        return .object(object)
    }

    private static func targetsJSON(_ t: NutritionTargets) -> JSONValue {
        .object([
            "kcal": t.kcal.map(JSONValue.number) ?? .null, "protein": t.protein.map(JSONValue.number) ?? .null,
            "carbs": t.carbs.map(JSONValue.number) ?? .null, "fat": t.fat.map(JSONValue.number) ?? .null,
            "fiber": t.fiber.map(JSONValue.number) ?? .null,
            "waterMilliliters": t.waterMilliliters.map(JSONValue.number) ?? .null,
        ])
    }
}
