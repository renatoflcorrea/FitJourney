import Foundation

// Contrato `contracts/program-draft-v1.schema.json`. Os nomes das propriedades SÃO o contrato
// (plugin do ChatGPT e HealthProject usarão o mesmo JSON) — não renomeie; crie uma v2.

struct ProgramDraft: Codable, Sendable, Hashable {
    var name: String
    var goal: ProgramGoal
    var goalText: String?
    var scheduleMode: ScheduleMode
    var durationWeeks: Int?
    var notes: String?
    var routines: [RoutineDraft]

    struct RoutineDraft: Codable, Sendable, Hashable {
        var name: String
        var symbol: String?
        var weekdays: [Weekday]
        var notes: String?
        var exercises: [ExerciseDraft]
    }

    struct ExerciseDraft: Codable, Sendable, Hashable {
        var name: String
        var catalogKey: String?
        var restSeconds: Int?
        var groupLabel: String?
        var notes: String?
        var sets: [SetDraft]
    }

    struct SetDraft: Codable, Sendable, Hashable {
        var kind: SetKind
        var repTarget: RepTargetDraft?
        var holdSeconds: Int?
        var load: LoadDraft?
        var restSeconds: Int?
        var tempo: String?
        var rir: Int?
        var rpe: Double?
        var cardio: CardioDraft?
        var notes: String?

        var effort: EffortTarget? {
            if let rir { return .rir(rir) }
            if let rpe { return .rpe(rpe) }
            return nil
        }
    }

    struct RepTargetDraft: Codable, Sendable, Hashable {
        enum Kind: String, Codable, Sendable, Hashable { case fixed, range, amrap }
        var kind: Kind
        var reps: Int?
        var min: Int?
        var max: Int?

        /// Alvo de domínio; `nil` se incoerente (ex.: `range` sem mínimo).
        var repTarget: RepTarget? {
            switch kind {
            case .fixed: (reps ?? min).map { .fixed(reps: $0) }
            case .range:
                if let min, let max, min <= max { min == max ? .fixed(reps: min) : .range(min: min, max: max) } else { nil }
            case .amrap: .amrap
            }
        }
    }

    struct LoadDraft: Codable, Sendable, Hashable {
        enum Kind: String, Codable, Sendable, Hashable { case weight, bodyweight }
        var kind: Kind
        var value: Double
        var unit: WeightUnit

        var load: Load {
            switch kind {
            case .weight: .weight(value: value, unit: unit)
            case .bodyweight: .bodyweight(delta: value, unit: unit)
            }
        }
    }

    struct CardioDraft: Codable, Sendable, Hashable {
        var durationSeconds: Int?
        var distanceMeters: Double?
        var level: Int?
        var speedKmh: Double?
        var inclinePercent: Double?
        var heartRateZone: Int?

        var target: CardioTarget {
            CardioTarget(durationSeconds: durationSeconds, distanceMeters: distanceMeters, level: level,
                         speedKmh: speedKmh, inclinePercent: inclinePercent, heartRateZone: heartRateZone)
        }
    }

    /// Regras que o JSON Schema não expressa. Vazio = válido.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("name: vazio") }
        if name.count > 80 { issues.append("name: mais de 80 caracteres") }
        if routines.isEmpty { issues.append("routines: ao menos uma ficha") }
        for (r, routine) in routines.enumerated() {
            let path = "routines[\(r)]"
            if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(path).name: vazio") }
            if scheduleMode == .weekly, routine.weekdays.isEmpty {
                issues.append("\(path).weekdays: obrigatório no modo weekly")
            }
            if Set(routine.weekdays).count != routine.weekdays.count { issues.append("\(path).weekdays: repetidos") }
            if routine.exercises.isEmpty { issues.append("\(path).exercises: ao menos um exercício") }
            for (e, exercise) in routine.exercises.enumerated() {
                let ePath = "\(path).exercises[\(e)]"
                if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(ePath).name: vazio") }
                if exercise.sets.isEmpty { issues.append("\(ePath).sets: ao menos uma série") }
                for (s, set) in exercise.sets.enumerated() {
                    let sPath = "\(ePath).sets[\(s)]"
                    if let target = set.repTarget, target.repTarget == nil {
                        issues.append("\(sPath).repTarget: \(target.kind == .range ? "range exige min ≤ max" : "fixed exige reps")")
                    }
                    if set.rir != nil, set.rpe != nil { issues.append("\(sPath): use rir ou rpe, não ambos") }
                    if let load = set.load, load.kind == .weight, load.value < 0 {
                        issues.append("\(sPath).load: carga absoluta negativa")
                    }
                }
            }
        }
        return issues
    }
}

extension ProgramDraft {
    /// Resumo curto para o resultado da ferramenta e o cartão da UI.
    var summary: String {
        let sets = routines.reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } }
        let exercises = routines.reduce(0) { $0 + $1.exercises.count }
        return "\(name): \(routines.count) fichas, \(exercises) exercícios, \(sets) séries"
    }
}
