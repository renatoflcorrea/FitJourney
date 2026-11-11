import Foundation

// Tipos de valor da prescrição (SPEC §3.4). Codable sintetizado com casos rotulados:
// os rótulos fazem parte do formato persistido — não renomeie.

enum WeightUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case kg, lb

    static let poundsPerKilogram = 2.204_622_621_8

    func toKilograms(_ value: Double) -> Double {
        self == .kg ? value : value / Self.poundsPerKilogram
    }

    func fromKilograms(_ kilograms: Double) -> Double {
        self == .kg ? kilograms : kilograms * Self.poundsPerKilogram
    }
}

/// Alvo de repetições: fixo, faixa (mín = "piso", SPEC R1) ou AMRAP.
enum RepTarget: Codable, Sendable, Hashable {
    case fixed(reps: Int)
    case range(min: Int, max: Int)
    case amrap

    /// Valor pré-preenchido ao registrar a série: fixo → n; faixa → piso; AMRAP → nil.
    var defaultReps: Int? {
        switch self {
        case .fixed(let reps): reps
        case .range(let min, _): min
        case .amrap: nil
        }
    }

    /// Topo da meta (fixo → n; faixa → máx; AMRAP → nil). Usado pela progressão.
    var topReps: Int? {
        switch self {
        case .fixed(let reps): reps
        case .range(_, let max): max
        case .amrap: nil
        }
    }

    /// "10", "8–12", "AMRAP".
    var displayText: String {
        switch self {
        case .fixed(let reps): "\(reps)"
        case .range(let min, let max): "\(min)–\(max)"
        case .amrap: "AMRAP"
        }
    }
}

/// Carga: valor absoluto ou peso corporal com delta (lastro +, assistência −).
enum Load: Codable, Sendable, Hashable {
    case weight(value: Double, unit: WeightUnit)
    case bodyweight(delta: Double, unit: WeightUnit)

    static func kg(_ value: Double) -> Load { .weight(value: value, unit: .kg) }

    var unit: WeightUnit {
        switch self {
        case .weight(_, let unit), .bodyweight(_, let unit): unit
        }
    }

    /// Carga externa em kg: valor absoluto, ou o delta (pode ser negativo) do peso corporal.
    var externalKilograms: Double {
        switch self {
        case .weight(let value, let unit): unit.toKilograms(value)
        case .bodyweight(let delta, let unit): unit.toKilograms(delta)
        }
    }

    /// Carga que entra no volume/1RM, em kg. Peso corporal conta só o lastro positivo,
    /// porque o app não conhece a massa corporal no momento da série (assistência conta 0).
    var volumeKilograms: Double { max(0, externalKilograms) }

    var isBodyweight: Bool {
        if case .bodyweight = self { true } else { false }
    }

    /// Peso absoluto zero: em exercício de carga equivale a "sem carga definida" (P2.8). Peso corporal com
    /// delta 0 é uma carga válida ("só o peso do corpo").
    var isUnsetWeight: Bool {
        if case .weight(let value, _) = self { abs(value) < 0.000_1 } else { false }
    }

    /// A carga, se for uma carga definida (`nil` ou peso 0 = sem carga). Nunca inventa zero.
    static func defined(_ load: Load?) -> Load? {
        guard let load, !load.isUnsetWeight else { return nil }
        return load
    }

    /// Mesmo tipo e mesma carga (comparada em kg, tolerância de 10 g).
    func isEquivalent(to other: Load) -> Bool {
        isBodyweight == other.isBodyweight && abs(externalKilograms - other.externalKilograms) < 0.01
    }

    /// Soma um incremento (na unidade desta carga).
    func adding(_ increment: Double) -> Load {
        switch self {
        case .weight(let value, let unit): .weight(value: value + increment, unit: unit)
        case .bodyweight(let delta, let unit): .bodyweight(delta: delta + increment, unit: unit)
        }
    }
}

/// Esforço alvo: RIR (0–5) ou RPE (1–10).
enum EffortTarget: Codable, Sendable, Hashable {
    case rir(Int)
    case rpe(Double)
}

/// Alvo de cardio (SPEC §3.4). Tudo opcional.
struct CardioTarget: Codable, Sendable, Hashable {
    var durationSeconds: Int?
    var distanceMeters: Double?
    var level: Int?
    var speedKmh: Double?
    var inclinePercent: Double?
    /// Zona de FC alvo (1–5).
    var heartRateZone: Int?

    init(durationSeconds: Int? = nil, distanceMeters: Double? = nil, level: Int? = nil,
         speedKmh: Double? = nil, inclinePercent: Double? = nil, heartRateZone: Int? = nil) {
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.level = level
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.heartRateZone = heartRateZone
    }
}

/// Duração estimada de uma ficha (SPEC §3.2): Σ (execução + descanso) por série.
enum RoutineEstimate {
    /// Tempo de troca entre membros de um bi-set/circuito (sem descanso).
    static let groupTransitionSeconds = 15

    /// - Parameters:
    ///   - restSeconds: descanso efetivo de cada série prescrita.
    ///   - workSecondsPerSet: tempo médio de execução de uma série (padrão 40 s).
    static func durationSeconds(restSeconds: [Int], workSecondsPerSet: Int = 40) -> Int {
        restSeconds.reduce(0) { $0 + workSecondsPerSet + max(0, $1) }
    }
}
