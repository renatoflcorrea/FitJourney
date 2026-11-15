import Foundation

// Contratos `contracts/program-import-v1.schema.json` e `nutrition-import-v1.schema.json`. Os nomes das
// propriedades SÃO o contrato — não renomeie; crie uma v2. `nil` = não estava no arquivo (nunca zero).

enum ImportConfidence: String, Codable, Sendable, Hashable, CaseIterable {
    case high, medium, low
}

struct ImportSource: Codable, Sendable, Hashable {
    var file: String
    var page: Int?
}

/// Dúvida levantada pela IA que só o usuário resolve.
struct ImportAmbiguity: Codable, Sendable, Hashable {
    var path: String
    var question: String
    var options: [String]
}

// MARK: - Treino

struct ProgramImport: Codable, Sendable, Hashable {
    var name: String?
    var goal: ProgramGoal?
    var goalText: String?
    var scheduleMode: ScheduleMode?
    var durationWeeks: Int?
    var notes: String?
    var confidence: ImportConfidence
    var source: ImportSource?
    var routines: [RoutineImport]
    var ambiguities: [ImportAmbiguity]

    struct RoutineImport: Codable, Sendable, Hashable {
        var name: String?
        var symbol: String?
        var weekdays: [Weekday]
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var exercises: [ExerciseImport]
    }

    struct ExerciseImport: Codable, Sendable, Hashable {
        var asWritten: String
        var name: String?
        var catalogKey: String?
        var restSeconds: Int?
        var groupLabel: String?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var sets: [SetImport]

        /// Nome usado para casar com o catálogo e exibir.
        var displayName: String {
            let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? asWritten.trimmingCharacters(in: .whitespacesAndNewlines) : normalized
        }
    }

    struct SetImport: Codable, Sendable, Hashable {
        var kind: SetKind?
        var repTarget: ProgramDraft.RepTargetDraft?
        var holdSeconds: Int?
        var load: ProgramDraft.LoadDraft?
        var loadAsWritten: String?
        var restSeconds: Int?
        var tempo: String?
        var rir: Int?
        var rpe: Double?
        var cardio: ProgramDraft.CardioDraft?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?

        /// Precisa de alvo de repetições (não é isométrico nem cardio).
        var needsReps: Bool { repTarget?.repTarget == nil && holdSeconds == nil && cardio == nil }
    }

    /// Regras que o schema não expressa. Vazio = válido.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if routines.isEmpty { issues.append("routines: nenhuma ficha detectada") }
        for (r, routine) in routines.enumerated() {
            if Set(routine.weekdays).count != routine.weekdays.count { issues.append("routines[\(r)].weekdays: repetidos") }
            for (e, exercise) in routine.exercises.enumerated() {
                let path = "routines[\(r)].exercises[\(e)]"
                if exercise.asWritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (exercise.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(path).asWritten: vazio")
                }
                for (s, set) in exercise.sets.enumerated() {
                    if set.rir != nil, set.rpe != nil { issues.append("\(path).sets[\(s)]: use rir ou rpe, não ambos") }
                    if let target = set.repTarget, target.kind != .amrap, target.repTarget == nil {
                        issues.append("\(path).sets[\(s)].repTarget: \(target.kind == .range ? "range exige min ≤ max" : "fixed exige reps")")
                    }
                }
            }
        }
        return issues
    }

    var exerciseCount: Int { routines.reduce(0) { $0 + $1.exercises.count } }
}

// MARK: - Dieta

struct NutritionImport: Codable, Sendable, Hashable {
    var name: String?
    var goal: String?
    var notes: String?
    var confidence: ImportConfidence
    var source: ImportSource?
    var targets: TargetsImport
    var days: [DayImport]
    var ambiguities: [ImportAmbiguity]

    struct TargetsImport: Codable, Sendable, Hashable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var waterMilliliters: Double?
        var confidence: ImportConfidence
        var source: ImportSource?
    }

    struct DayImport: Codable, Sendable, Hashable {
        var name: String?
        var weekdays: [Weekday]
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var meals: [MealImport]
    }

    struct MealImport: Codable, Sendable, Hashable {
        var name: String?
        var time: String?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var items: [ItemImport]

        var minutesFromMidnight: Int? { time.flatMap(NutritionPlanDraft.MealDraft.minutes(from:)) }
    }

    struct ItemImport: Codable, Sendable, Hashable {
        var asWritten: String
        var name: String
        var quantity: Double?
        var unit: FoodUnit?
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var substitutions: [SubstitutionImport]
    }

    struct SubstitutionImport: Codable, Sendable, Hashable {
        var name: String
        var quantity: Double?
        var unit: FoodUnit?
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var notes: String?
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        if days.isEmpty || days.allSatisfy({ $0.meals.isEmpty }) { issues.append("days: nenhuma refeição detectada") }
        for (d, day) in days.enumerated() {
            if Set(day.weekdays).count != day.weekdays.count { issues.append("days[\(d)].weekdays: repetidos") }
            for (m, meal) in day.meals.enumerated() {
                for (i, item) in meal.items.enumerated()
                where item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && item.asWritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("days[\(d)].meals[\(m)].items[\(i)].name: vazio")
                }
            }
        }
        return issues
    }
}

// MARK: - Validação

enum ImportValidation {
    /// Extração no contrato v2 (atual) ou v1 (compatibilidade), já no modelo interno.
    static func program(_ json: String) -> DraftValidation.Outcome<ProgramImport> {
        switch programDetailed(json) {
        case let .valid(value): .valid(value)
        case let .ruleIssues(_, issues), let .invalid(issues): .invalid(issues)
        }
    }

    static func nutrition(_ json: String) -> DraftValidation.Outcome<NutritionImport> {
        switch nutritionDetailed(json) {
        case let .valid(value): .valid(value)
        case let .ruleIssues(_, issues), let .invalid(issues): .invalid(issues)
        }
    }
}

// MARK: - Conversão para os rascunhos existentes

extension ProgramImport {
    /// Rascunho do programa com as fichas escolhidas (`selected` = índices; `nil` = todas). Lacunas não
    /// respondidas recebem o padrão mais seguro (nome genérico, série válida, sem carga); `ProgramDraft`
    /// valida o resultado e `DraftApplier` casa os exercícios com o catálogo.
    func makeDraft(selected: Set<Int>? = nil) -> ProgramDraft {
        let chosen = routines.enumerated().filter { selected?.contains($0.offset) ?? true }.map(\.element)
        let mode = scheduleMode ?? (chosen.contains { !$0.weekdays.isEmpty } ? .weekly : .sequential)
        let letters = Array("ABCDEFGHIJKL")
        // Sem cortes: o schema de importação já limita (12 fichas, 20 exercícios, 12 séries) e o `DraftApplier`
        // grava qualquer quantidade — nada lido do arquivo é descartado em silêncio.
        let draftRoutines = chosen.enumerated().map { index, routine in
            ProgramDraft.RoutineDraft(
                name: routine.name.nonEmpty ?? String(localized: "Ficha \(String(letters[index]))"),
                symbol: routine.symbol.nonEmpty.map { String($0.prefix(2)) },
                weekdays: mode == .weekly ? Self.unique(routine.weekdays) : [],
                notes: routine.notes.nonEmpty,
                exercises: routine.exercises.map(Self.exerciseDraft))
        }
        return ProgramDraft(
            name: name.nonEmpty ?? String(localized: "Programa importado"),
            goal: goal ?? .other,
            goalText: goalText.nonEmpty,
            scheduleMode: mode,
            durationWeeks: durationWeeks.map { min(52, max(1, $0)) },
            notes: notes.nonEmpty,
            routines: draftRoutines)
    }

    private static func exerciseDraft(_ exercise: ExerciseImport) -> ProgramDraft.ExerciseDraft {
        var sets = exercise.sets.map { set in
            ProgramDraft.SetDraft(kind: set.kind ?? .working, repTarget: set.repTarget?.repTarget == nil ? nil : set.repTarget,
                                  holdSeconds: set.holdSeconds, load: set.load, restSeconds: set.restSeconds,
                                  tempo: set.tempo.nonEmpty, rir: set.rir, rpe: set.rir == nil ? set.rpe : nil,
                                  cardio: set.cardio, notes: [set.notes.nonEmpty, set.load == nil ? set.loadAsWritten.nonEmpty.map { "Carga escrita: \($0)" } : nil]
                                      .compactMap { $0 }.joined(separator: " · ").nonEmpty)
        }
        if sets.isEmpty {
            sets = [ProgramDraft.SetDraft(kind: .working, repTarget: nil, holdSeconds: nil, load: nil, restSeconds: nil,
                                          tempo: nil, rir: nil, rpe: nil, cardio: nil, notes: nil)]
        }
        let asWritten = exercise.asWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteParts = [exercise.notes.nonEmpty,
                         asWritten.isEmpty || asWritten == exercise.displayName ? nil : "No arquivo: \(asWritten)"]
        return ProgramDraft.ExerciseDraft(name: exercise.displayName, catalogKey: exercise.catalogKey.nonEmpty,
                                          restSeconds: exercise.restSeconds, groupLabel: exercise.groupLabel.nonEmpty,
                                          notes: noteParts.compactMap { $0 }.joined(separator: " · ").nonEmpty,
                                          sets: sets)
    }

    static func unique(_ weekdays: [Weekday]) -> [Weekday] {
        var seen: Set<Weekday> = []
        return weekdays.filter { seen.insert($0).inserted }
    }
}

extension NutritionImport {
    /// Rascunho do plano com os dias escolhidos. Dia da semana repetido fica só no primeiro dia que o usa;
    /// horário ausente vira o horário típico da posição; quantidade ou unidade ausente vira 1 porção (com nota —
    /// a entrevista pergunta antes, é só o padrão de quem pulou).
    func makeDraft(selected: Set<Int>? = nil) -> NutritionPlanDraft {
        let chosen = days.enumerated().filter { selected?.contains($0.offset) ?? true }.map(\.element)
        var used: Set<Weekday> = []
        let draftDays = chosen.enumerated().map { index, day in
            let weekdays = ProgramImport.unique(day.weekdays).filter { !used.contains($0) }
            used.formUnion(weekdays)
            return NutritionPlanDraft.DayDraft(
                name: day.name.nonEmpty ?? (chosen.count == 1 ? String(localized: "Todos os dias") : String(localized: "Dia \(index + 1)")),
                weekdays: weekdays,
                meals: day.meals.enumerated().map { m, meal in
                    NutritionPlanDraft.MealDraft(
                        name: meal.name.nonEmpty ?? String(localized: "Refeição \(m + 1)"),
                        time: meal.minutesFromMidnight.map { clockString(minutes: $0) }
                            ?? clockString(minutes: Self.fallbackMinutes(index: m, count: day.meals.count)),
                        notes: meal.notes.nonEmpty,
                        items: meal.items.map(Self.itemDraft))
                })
        }
        return NutritionPlanDraft(
            name: name.nonEmpty ?? String(localized: "Dieta importada"),
            goal: goal.nonEmpty,
            notes: notes.nonEmpty,
            targets: NutritionPlanDraft.TargetsDraft(kcal: targets.kcal, protein: targets.protein, carbs: targets.carbs,
                                                     fat: targets.fat, fiber: targets.fiber,
                                                     waterMilliliters: targets.waterMilliliters),
            days: draftDays)
    }

    private static func itemDraft(_ item: ItemImport) -> NutritionPlanDraft.ItemDraft {
        let name = item.name.nonEmpty ?? item.asWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        let guessed = item.quantity == nil || item.unit == nil
        let note = guessed ? String(localized: "Quantidade/unidade não informada; no arquivo: \(item.asWritten)") : nil
        return NutritionPlanDraft.ItemDraft(
            name: name, quantity: item.quantity ?? 1, unit: item.unit ?? .serving,
            kcal: item.kcal, protein: item.protein, carbs: item.carbs, fat: item.fat, fiber: item.fiber,
            notes: [item.notes.nonEmpty, note].compactMap { $0 }.joined(separator: " · ").nonEmpty,
            substitutions: item.substitutions.map { sub in
                let guessed = sub.quantity == nil || sub.unit == nil
                return NutritionPlanDraft.SubstitutionDraft(name: sub.name, quantity: sub.quantity ?? 1,
                                                     unit: sub.unit ?? .serving,
                                                     kcal: sub.kcal, protein: sub.protein, carbs: sub.carbs, fat: sub.fat,
                                                     notes: [sub.notes.nonEmpty, guessed ? String(localized: "Quantidade/unidade não informada") : nil]
                                                         .compactMap { $0 }.joined(separator: " · ").nonEmpty)
            })
    }

    /// 07:00 → 21:00 distribuído pela quantidade de refeições.
    static func fallbackMinutes(index: Int, count: Int) -> Int {
        guard count > 1 else { return 12 * 60 }
        let start = 7 * 60, end = 21 * 60
        let step = (end - start) / (count - 1)
        return min(end, start + index * step) / 30 * 30
    }
}

/// "HH:MM" de minutos desde a meia-noite.
func clockString(minutes: Int) -> String {
    String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
}

extension Optional where Wrapped == String {
    /// Texto sem espaços nas pontas; `nil` se vazio.
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension String {
    var nonEmpty: String? { Optional(self).nonEmpty }
}
