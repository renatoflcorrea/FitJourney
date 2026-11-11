import Foundation

/// Progressão automática (SPEC §3.4): **opcional, desligada por padrão**; só sugere.
///
/// Regra: se todas as séries válidas foram concluídas e cada uma atingiu o topo da meta
/// (faixa → máx; fixo → n), sugere `carga atual + incremento`. AMRAP e séries sem carga não sugerem.
struct ProgressionSuggestion: Sendable, Hashable {
    struct Settings: Sendable, Hashable, Codable {
        var isEnabled: Bool = false
        var incrementKg: Double = 2.5
        var incrementLb: Double = 5

        static let `default` = Settings()

        func increment(for unit: WeightUnit) -> Double { unit == .kg ? incrementKg : incrementLb }
    }

    var current: Load
    var suggested: Load

    static func evaluate(target: RepTarget, sets: [PerformedSet], currentLoad: Load?,
                         settings: Settings = .default) -> ProgressionSuggestion? {
        guard settings.isEnabled, let top = target.topReps, let currentLoad else { return nil }
        let working = sets.filter { $0.kind.isWorking }
        guard !working.isEmpty,
              working.allSatisfy({ $0.isCompleted && ($0.reps ?? 0) >= top }) else { return nil }
        let suggested = currentLoad.adding(settings.increment(for: currentLoad.unit))
        return ProgressionSuggestion(current: currentLoad, suggested: suggested)
    }
}
