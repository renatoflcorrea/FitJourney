import Foundation

/// Grande categoria do treino para a aba Saúde (SPEC §6.3: força x aeróbico).
enum HealthWorkoutCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case strength
    case aerobic
    /// Treino misto (ex.: cross training): nem só força nem só aeróbico.
    case mixed
    /// Flexibilidade, mobilidade, ioga, pilates.
    case mobility
    case other

    var localizedName: String {
        switch self {
        case .strength: String(localized: "Força")
        case .aerobic: String(localized: "Aeróbico")
        case .mixed: String(localized: "Misto")
        case .mobility: String(localized: "Mobilidade")
        case .other: String(localized: "Outro")
        }
    }
}

/// Tipo do treino gravado no Saúde, derivado da ficha (SPEC §6.2). O mapeamento para
/// `HKWorkoutActivityType` fica em `Services/Health/HealthKitMapping.swift`.
/// NUNCA renomeie um rawValue (pode ser gravado).
enum HealthWorkoutType: String, Sendable, Hashable, CaseIterable, Codable {
    case traditionalStrength, functionalStrength, hiit, core, flexibility
    case running, cycling, elliptical, rowing, stairClimbing, walking, mixedCardio

    var category: HealthWorkoutCategory {
        switch self {
        case .traditionalStrength, .functionalStrength, .core: .strength
        case .hiit, .running, .cycling, .elliptical, .rowing, .stairClimbing, .walking, .mixedCardio: .aerobic
        case .flexibility: .mobility
        }
    }

    var isCardio: Bool {
        switch self {
        case .running, .cycling, .elliptical, .rowing, .stairClimbing, .walking, .mixedCardio: true
        default: false
        }
    }

    var localizedName: String {
        switch self {
        case .traditionalStrength: String(localized: "Força tradicional")
        case .functionalStrength: String(localized: "Força funcional")
        case .hiit: String(localized: "HIIT")
        case .core: String(localized: "Core")
        case .flexibility: String(localized: "Flexibilidade")
        case .running: String(localized: "Corrida")
        case .cycling: String(localized: "Bicicleta")
        case .elliptical: String(localized: "Elíptico")
        case .rowing: String(localized: "Remo")
        case .stairClimbing: String(localized: "Escada")
        case .walking: String(localized: "Caminhada")
        case .mixedCardio: String(localized: "Cardio")
        }
    }
}

/// O que importa de cada exercício para escolher o tipo do treino.
struct HealthWorkoutTypeInput: Sendable, Hashable {
    var measurementKind: MeasurementKind
    var primaryMuscles: [MuscleGroup] = []
    var equipment: Equipment?
    var name: String = ""
}

extension HealthWorkoutType {
    private static let coreMuscles: Set<MuscleGroup> = [.abs, .obliques, .lowerBack]

    /// Heurística (documentada para a UI permitir trocar depois):
    /// 1. Sem exercícios → força tradicional.
    /// 2. Todos `timeOrDistance` → cardio; o aparelho vem do nome (corrida/esteira, bicicleta, elíptico,
    ///    remo, escada, caminhada), senão cardio misto.
    /// 3. Maioria (≥ 2/3) de alongamento/mobilidade pelo nome → flexibilidade.
    /// 4. Cardio ≥ 1/3 misturado com força → HIIT (circuito/intervalado).
    /// 5. Maioria (≥ 2/3) com músculos só de core → core.
    /// 6. Maioria (> 1/2) peso corporal/kettlebell/elástico → força funcional.
    /// 7. Senão → força tradicional.
    static func derive(from exercises: [HealthWorkoutTypeInput]) -> HealthWorkoutType {
        guard !exercises.isEmpty else { return .traditionalStrength }
        let total = Double(exercises.count)
        let cardio = exercises.filter { $0.measurementKind == .timeOrDistance }
        if cardio.count == exercises.count { return cardioType(for: cardio) }

        let mobility = exercises.filter { matches($0.name, mobilityKeywords) }
        if Double(mobility.count) / total >= 2.0 / 3.0 { return .flexibility }

        if Double(cardio.count) / total >= 1.0 / 3.0 { return .hiit }

        let core = exercises.filter { exercise in
            let muscles = Set(exercise.primaryMuscles)
            return !muscles.isEmpty && muscles.isSubset(of: coreMuscles)
        }
        if Double(core.count) / total >= 2.0 / 3.0 { return .core }

        let functional = exercises.filter { exercise in
            if exercise.measurementKind == .repsOnly { return true }
            switch exercise.equipment {
            case .bodyweight?, .kettlebell?, .band?: return true
            default: return false
            }
        }
        if Double(functional.count) / total > 0.5 { return .functionalStrength }
        return .traditionalStrength
    }

    private static let cardioKeywords: [(HealthWorkoutType, [String])] = [
        (.running, ["corrida", "correr", "esteira", "run", "treadmill", "jog"]),
        (.cycling, ["bicicleta", "bike", "ciclismo", "spinning", "cycl", "pedal"]),
        (.elliptical, ["eliptic", "elliptical", "transport"]),
        (.rowing, ["remo", "rowing", "rower", "row "]),
        (.stairClimbing, ["escada", "stair", "step"]),
        (.walking, ["caminhada", "caminhar", "walk"]),
    ]

    private static let mobilityKeywords = ["alongamento", "mobilidade", "flexibilidade", "stretch", "mobility",
                                           "yoga", "ioga", "liberação", "foam roll"]

    private static func cardioType(for exercises: [HealthWorkoutTypeInput]) -> HealthWorkoutType {
        var found: Set<HealthWorkoutType> = []
        for exercise in exercises {
            if let type = cardioKeywords.first(where: { matches(exercise.name, $0.1) })?.0 { found.insert(type) } else {
                return .mixedCardio
            }
        }
        return found.count == 1 ? found.first! : .mixedCardio
    }

    private static func matches(_ name: String, _ keywords: [String]) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) + " "
        return keywords.contains { folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }
}
