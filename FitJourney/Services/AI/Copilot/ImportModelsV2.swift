import Foundation

// Contratos compactos `contracts/program-import-v2.schema.json` e `nutrition-import-v2.schema.json` (saída da IA).
// O app expande para os modelos v1 (`ProgramImport`/`NutritionImport`), que continuam sendo o formato interno, o
// gravado nas importações pendentes e o usado pela entrevista. Os nomes das propriedades SÃO o contrato.
//
// Treino: séries iguais e seguidas viram um grupo (`count`); repetições em texto ("12", "8-12", "amrap"); campos
// raros em `extra`; sem `source` na série (nada no app lê). Dieta: item sem `source` (vale o da refeição) e valores
// nutricionais num objeto `macros` opcional.

// MARK: - Treino

struct ProgramImportV2: Codable, Sendable, Hashable {
    var name: String?
    var goal: ProgramGoal?
    var goalText: String?
    var scheduleMode: ScheduleMode?
    var durationWeeks: Int?
    var notes: String?
    var confidence: ImportConfidence
    var source: ImportSource?
    var routines: [RoutineV2]
    var ambiguities: [ImportAmbiguity]

    struct RoutineV2: Codable, Sendable, Hashable {
        var name: String?
        var symbol: String?
        var weekdays: [Weekday]
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var exercises: [ExerciseV2]
    }

    struct ExerciseV2: Codable, Sendable, Hashable {
        var asWritten: String
        var name: String?
        var catalogKey: String?
        var restSeconds: Int?
        var groupLabel: String?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var setGroups: [SetGroup]
    }

    struct SetGroup: Codable, Sendable, Hashable {
        var count: Int
        var kind: SetKind?
        /// "12", "8-12" ou "amrap".
        var reps: String?
        var load: ProgramDraft.LoadDraft?
        var loadAsWritten: String?
        var restSeconds: Int?
        var extra: Extra?
        var notes: String?
        var confidence: ImportConfidence
    }

    struct Extra: Codable, Sendable, Hashable {
        var holdSeconds: Int?
        var tempo: String?
        var rir: Int?
        var rpe: Double?
        var cardio: ProgramDraft.CardioDraft?
    }

    /// Regras do v2 que o schema não expressa (antes de expandir).
    func validationIssues() -> [String] {
        var issues: [String] = []
        for (r, routine) in routines.enumerated() {
            for (e, exercise) in routine.exercises.enumerated() {
                let path = "routines[\(r)].exercises[\(e)]"
                if exercise.setGroups.reduce(0, { $0 + $1.count }) > 12 { issues.append("\(path).setGroups: no máximo 12 séries") }
                for (g, group) in exercise.setGroups.enumerated() {
                    // Normalizado como em `repTarget` ("AMRAP", " 8 - 12 ").
                    guard let reps = group.reps?.lowercased().filter({ !$0.isWhitespace }), !reps.isEmpty else { continue }
                    let numbers = reps.split(separator: "-").compactMap { Int($0) }
                    if reps != "amrap", numbers.isEmpty || numbers.contains(where: { !(1...100).contains($0) }) {
                        issues.append("\(path).setGroups[\(g)].reps: use 1 a 100, faixa \"8-12\" ou \"amrap\"")
                    }
                }
            }
        }
        return issues
    }

    /// Modelo interno (v1): cada grupo vira `count` séries iguais.
    func expanded() -> ProgramImport {
        ProgramImport(name: name, goal: goal, goalText: goalText, scheduleMode: scheduleMode, durationWeeks: durationWeeks,
                      notes: notes, confidence: confidence, source: source,
                      routines: routines.map { routine in
                          ProgramImport.RoutineImport(name: routine.name, symbol: routine.symbol, weekdays: routine.weekdays,
                                                      notes: routine.notes, confidence: routine.confidence, source: routine.source,
                                                      exercises: routine.exercises.map(\.expanded))
                      },
                      ambiguities: ambiguities)
    }

    static func repTarget(_ text: String?) -> ProgramDraft.RepTargetDraft? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        if text == "amrap" { return .init(kind: .amrap, reps: nil, min: nil, max: nil) }
        let numbers = text.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch numbers.count {
        case 1: return numbers[0].map { .init(kind: .fixed, reps: $0, min: nil, max: nil) }
        case 2: return .init(kind: .range, reps: nil, min: numbers[0], max: numbers[1])
        default: return nil
        }
    }

    static func repsText(_ target: ProgramDraft.RepTargetDraft?) -> String? {
        guard let target else { return nil }
        switch target.kind {
        case .amrap: return "amrap"
        case .fixed: return (target.reps ?? target.min).map(String.init)
        case .range:
            if let min = target.min, let max = target.max { return "\(min)-\(max)" }
            return (target.min ?? target.max ?? target.reps).map(String.init)
        }
    }
}

extension ProgramImportV2.ExerciseV2 {
    var expanded: ProgramImport.ExerciseImport {
        ProgramImport.ExerciseImport(asWritten: asWritten, name: name, catalogKey: catalogKey, restSeconds: restSeconds,
                                     groupLabel: groupLabel, notes: notes, confidence: confidence, source: source,
                                     sets: setGroups.flatMap { group in
                                         Array(repeating: group.expandedSet, count: max(0, min(12, group.count)))
                                     })
    }
}

extension ProgramImportV2.SetGroup {
    var expandedSet: ProgramImport.SetImport {
        ProgramImport.SetImport(kind: kind, repTarget: ProgramImportV2.repTarget(reps), holdSeconds: extra?.holdSeconds,
                                load: load, loadAsWritten: loadAsWritten, restSeconds: restSeconds, tempo: extra?.tempo,
                                rir: extra?.rir, rpe: extra?.rpe, cardio: extra?.cardio, notes: notes, confidence: confidence,
                                source: nil)
    }
}

extension ProgramImport {
    /// Forma compacta (v2): séries iguais e seguidas viram um grupo. Usada para mandar a extração atual à IA na
    /// revisão/reparo por remendo e para medir a saída. Inversa de `ProgramImportV2.expanded()` para dados canônicos
    /// (série sem `source`, alvo de repetições coerente).
    func compacted() -> ProgramImportV2 {
        ProgramImportV2(name: name, goal: goal, goalText: goalText, scheduleMode: scheduleMode, durationWeeks: durationWeeks,
                        notes: notes, confidence: confidence, source: source,
                        routines: routines.map { routine in
                            ProgramImportV2.RoutineV2(name: routine.name, symbol: routine.symbol, weekdays: routine.weekdays,
                                                      notes: routine.notes, confidence: routine.confidence, source: routine.source,
                                                      exercises: routine.exercises.map(\.compacted))
                        },
                        ambiguities: ambiguities)
    }
}

extension ProgramImport.ExerciseImport {
    var compacted: ProgramImportV2.ExerciseV2 {
        var groups: [ProgramImportV2.SetGroup] = []
        for set in sets {
            let group = set.compactedGroup
            if var last = groups.last, last.withCount(1) == group {
                last.count += 1
                groups[groups.count - 1] = last
            } else {
                groups.append(group)
            }
        }
        return ProgramImportV2.ExerciseV2(asWritten: asWritten, name: name, catalogKey: catalogKey, restSeconds: restSeconds,
                                          groupLabel: groupLabel, notes: notes, confidence: confidence, source: source,
                                          setGroups: groups)
    }
}

extension ProgramImport.SetImport {
    var compactedGroup: ProgramImportV2.SetGroup {
        let extra = ProgramImportV2.Extra(holdSeconds: holdSeconds, tempo: tempo, rir: rir, rpe: rpe, cardio: cardio)
        let isEmptyExtra = holdSeconds == nil && tempo == nil && rir == nil && rpe == nil && cardio == nil
        return ProgramImportV2.SetGroup(count: 1, kind: kind, reps: ProgramImportV2.repsText(repTarget), load: load,
                                        loadAsWritten: loadAsWritten, restSeconds: restSeconds,
                                        extra: isEmptyExtra ? nil : extra, notes: notes, confidence: confidence)
    }
}

private extension ProgramImportV2.SetGroup {
    func withCount(_ count: Int) -> Self { var copy = self; copy.count = count; return copy }
}

// MARK: - Dieta

struct NutritionImportV2: Codable, Sendable, Hashable {
    var name: String?
    var goal: String?
    var notes: String?
    var confidence: ImportConfidence
    var source: ImportSource?
    var targets: NutritionImport.TargetsImport
    var days: [DayV2]
    var ambiguities: [ImportAmbiguity]

    struct DayV2: Codable, Sendable, Hashable {
        var name: String?
        var weekdays: [Weekday]
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var meals: [MealV2]
    }

    struct MealV2: Codable, Sendable, Hashable {
        var name: String?
        var time: String?
        var notes: String?
        var confidence: ImportConfidence
        var source: ImportSource?
        var items: [ItemV2]
    }

    struct ItemV2: Codable, Sendable, Hashable {
        var asWritten: String
        var name: String
        var quantity: Double?
        var unit: FoodUnit?
        var macros: Macros?
        var notes: String?
        var confidence: ImportConfidence
        var substitutions: [SubstitutionV2]
    }

    struct SubstitutionV2: Codable, Sendable, Hashable {
        var name: String
        var quantity: Double?
        var unit: FoodUnit?
        var macros: SubstitutionMacros?
        var notes: String?
    }

    /// Valores de uma substituição (sem fibra: o app não guarda fibra nas trocas — contrato `substitutionMacros`).
    struct SubstitutionMacros: Codable, Sendable, Hashable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?

        var isEmpty: Bool { kcal == nil && protein == nil && carbs == nil && fat == nil }
    }

    struct Macros: Codable, Sendable, Hashable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?

        var isEmpty: Bool { kcal == nil && protein == nil && carbs == nil && fat == nil && fiber == nil }
    }

    func expanded() -> NutritionImport {
        NutritionImport(name: name, goal: goal, notes: notes, confidence: confidence, source: source, targets: targets,
                        days: days.map { day in
                            NutritionImport.DayImport(name: day.name, weekdays: day.weekdays, notes: day.notes,
                                                      confidence: day.confidence, source: day.source,
                                                      meals: day.meals.map(\.expanded))
                        },
                        ambiguities: ambiguities)
    }
}

extension NutritionImportV2.MealV2 {
    var expanded: NutritionImport.MealImport {
        NutritionImport.MealImport(name: name, time: time, notes: notes, confidence: confidence, source: source,
                                   items: items.map { item in
                                       NutritionImport.ItemImport(
                                           asWritten: item.asWritten, name: item.name, quantity: item.quantity, unit: item.unit,
                                           kcal: item.macros?.kcal, protein: item.macros?.protein, carbs: item.macros?.carbs,
                                           fat: item.macros?.fat, fiber: item.macros?.fiber, notes: item.notes,
                                           confidence: item.confidence, source: source,
                                           substitutions: item.substitutions.map { sub in
                                               NutritionImport.SubstitutionImport(
                                                   name: sub.name, quantity: sub.quantity, unit: sub.unit, kcal: sub.macros?.kcal,
                                                   protein: sub.macros?.protein, carbs: sub.macros?.carbs, fat: sub.macros?.fat,
                                                   notes: sub.notes)
                                           })
                                   })
    }
}

extension NutritionImport {
    /// Forma compacta (v2). Inversa de `NutritionImportV2.expanded()` quando o `source` do item é o da refeição.
    func compacted() -> NutritionImportV2 {
        NutritionImportV2(name: name, goal: goal, notes: notes, confidence: confidence, source: source, targets: targets,
                          days: days.map { day in
                              NutritionImportV2.DayV2(name: day.name, weekdays: day.weekdays, notes: day.notes,
                                                      confidence: day.confidence, source: day.source,
                                                      meals: day.meals.map(\.compacted))
                          },
                          ambiguities: ambiguities)
    }
}

extension NutritionImport.MealImport {
    var compacted: NutritionImportV2.MealV2 {
        NutritionImportV2.MealV2(name: name, time: time, notes: notes, confidence: confidence, source: source,
                                 items: items.map { item in
                                     let macros = NutritionImportV2.Macros(kcal: item.kcal, protein: item.protein, carbs: item.carbs,
                                                                           fat: item.fat, fiber: item.fiber)
                                     return NutritionImportV2.ItemV2(
                                         asWritten: item.asWritten, name: item.name, quantity: item.quantity, unit: item.unit,
                                         macros: macros.isEmpty ? nil : macros, notes: item.notes, confidence: item.confidence,
                                         substitutions: item.substitutions.map { sub in
                                             let macros = NutritionImportV2.SubstitutionMacros(kcal: sub.kcal, protein: sub.protein,
                                                                                               carbs: sub.carbs, fat: sub.fat)
                                             return NutritionImportV2.SubstitutionV2(name: sub.name, quantity: sub.quantity,
                                                                                     unit: sub.unit,
                                                                                     macros: macros.isEmpty ? nil : macros,
                                                                                     notes: sub.notes)
                                         })
                                 })
    }
}

// MARK: - Validação (v2 ou v1)

/// Resultado detalhado da validação de uma extração: separa "decodificou mas quebra regra" (dá para consertar no
/// aparelho ou por remendo) de "nem decodificou".
enum ImportOutcome<Value: Sendable>: Sendable {
    case valid(Value)
    /// Passou no schema e decodificou, mas quebra regras.
    case ruleIssues(Value, [String])
    case invalid([String])
}

extension ImportValidation {
    /// Aceita o v2 (saída atual da IA) e o v1 (respostas antigas). Devolve sempre o modelo interno (v1).
    static func programDetailed(_ json: String) -> ImportOutcome<ProgramImport> {
        let v2 = detailed(json, schema: ImportSchemas.programImportV2, as: ProgramImportV2.self,
                          semantic: { $0.validationIssues() }, expand: { $0.expanded() }, rules: { $0.validationIssues() })
        if case .valid = v2 { return v2 }
        let v1 = detailed(json, schema: ImportSchemas.programImportV1, as: ProgramImport.self,
                          semantic: { _ in [] }, expand: { $0 }, rules: { $0.validationIssues() })
        if case .invalid = v1 { return ImportWireVersion.detect(json, kind: .program) == .v1 ? v1 : v2 }
        return v1
    }

    static func nutritionDetailed(_ json: String) -> ImportOutcome<NutritionImport> {
        let v2 = detailed(json, schema: ImportSchemas.nutritionImportV2, as: NutritionImportV2.self,
                          semantic: { _ in [] }, expand: { $0.expanded() }, rules: { $0.validationIssues() })
        if case .valid = v2 { return v2 }
        let v1 = detailed(json, schema: ImportSchemas.nutritionImportV1, as: NutritionImport.self,
                          semantic: { _ in [] }, expand: { $0 }, rules: { $0.validationIssues() })
        if case .invalid = v1 { return ImportWireVersion.detect(json, kind: .nutrition) == .v1 ? v1 : v2 }
        return v1
    }

    /// Decodifica sem schema (para o reparo por remendo de um JSON que quase passou). `nil` = nem isso.
    static func lenientProgram(_ json: String) -> ProgramImport? {
        guard let object = StructuredDecoder.extractJSONObject(from: json) else { return nil }
        let data = Data(object.utf8)
        if let v2 = try? JSONDecoder().decode(ProgramImportV2.self, from: data) { return v2.expanded() }
        return try? JSONDecoder().decode(ProgramImport.self, from: data)
    }

    static func lenientNutrition(_ json: String) -> NutritionImport? {
        guard let object = StructuredDecoder.extractJSONObject(from: json) else { return nil }
        let data = Data(object.utf8)
        if let v2 = try? JSONDecoder().decode(NutritionImportV2.self, from: data) { return v2.expanded() }
        return try? JSONDecoder().decode(NutritionImport.self, from: data)
    }

    private static func detailed<Wire: Decodable & Sendable, Value: Sendable>(
        _ json: String, schema: String, as type: Wire.Type, semantic: @escaping (Wire) -> [String],
        expand: @escaping (Wire) -> Value, rules: @escaping (Value) -> [String]) -> ImportOutcome<Value> {
        var decoded: Wire?
        let outcome = DraftValidation.validate(json, schema: schema, as: Wire.self) { wire in
            decoded = wire
            return []
        }
        guard case .valid = outcome, let wire = decoded else {
            if case let .invalid(issues) = outcome { return .invalid(issues) }
            return .invalid(["$: JSON inválido"])
        }
        let wireIssues = semantic(wire)
        let value = expand(wire)
        let issues = wireIssues + rules(value)
        return issues.isEmpty ? .valid(value) : .ruleIssues(value, issues)
    }
}

/// Versão do contrato de uma resposta que não passou em nenhum dos dois, pela estrutura do JSON decodificado (não
/// por texto solto): treino v2 tem `setGroups` nos exercícios, v1 tem `sets`; dieta v2 tem `macros` nos itens, v1 tem
/// `kcal`/`protein`… direto no item. Sem sinal, v2 (a saída atual).
enum ImportWireVersion: Equatable {
    case v1, v2

    static func detect(_ json: String, kind: ImportSession.Kind) -> ImportWireVersion {
        guard let object = StructuredDecoder.extractJSONObject(from: json), let root = try? JSONValue.parse(object) else { return .v2 }
        var v1Votes = 0, v2Votes = 0
        switch kind {
        case .program:
            for routine in root["routines"]?.arrayValue ?? [] {
                for exercise in routine["exercises"]?.arrayValue ?? [] {
                    if exercise["setGroups"] != nil { v2Votes += 1 } else if exercise["sets"] != nil { v1Votes += 1 }
                }
            }
        case .nutrition:
            let v1Keys = ["kcal", "protein", "carbs", "fat", "fiber"]
            for day in root["days"]?.arrayValue ?? [] {
                for meal in day["meals"]?.arrayValue ?? [] {
                    for item in meal["items"]?.arrayValue ?? [] {
                        if item["macros"] != nil { v2Votes += 1 } else if v1Keys.contains(where: { item[$0] != nil }) { v1Votes += 1 }
                    }
                }
            }
        }
        return v1Votes > v2Votes ? .v1 : .v2
    }
}

// MARK: - Conserto local do trivial

enum ImportLocalRepair {
    /// Conserta no aparelho o que não precisa da IA: dias repetidos, RIR e RPE juntos (fica o RIR), faixa invertida.
    static func fix(_ value: ProgramImport) -> ProgramImport {
        var copy = value
        for r in copy.routines.indices {
            copy.routines[r].weekdays = ProgramImport.unique(copy.routines[r].weekdays)
            for e in copy.routines[r].exercises.indices {
                for s in copy.routines[r].exercises[e].sets.indices {
                    var set = copy.routines[r].exercises[e].sets[s]
                    if set.rir != nil, set.rpe != nil { set.rpe = nil }
                    if var target = set.repTarget, target.kind == .range, let min = target.min, let max = target.max, min > max {
                        (target.min, target.max) = (max, min)
                        set.repTarget = target
                    }
                    copy.routines[r].exercises[e].sets[s] = set
                }
            }
        }
        return copy
    }

    static func fix(_ value: NutritionImport) -> NutritionImport {
        var copy = value
        for d in copy.days.indices { copy.days[d].weekdays = ProgramImport.unique(copy.days[d].weekdays) }
        return copy
    }
}
