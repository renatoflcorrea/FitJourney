import Foundation

// Protocolo relógio ↔ iPhone (SPEC §6.4). Só Foundation: compila nos alvos iOS e watchOS.
// O formato de fio é o Codable sintetizado em JSON (`WatchLinkCodec`). Qualquer mudança de formato
// (caso, campo obrigatório ou nome) exige subir `WatchLinkProtocol.schemaVersion`.
// Os IDs são sempre os da sessão/ficha no iPhone (fonte de verdade): `SessionExercise.id`,
// `SetLog.id`, `Routine.id`, `SetPrescription.id`.

enum WatchLinkProtocol {
    static let schemaVersion = 1
    static let minimumSupportedVersion = 1
}

enum WatchWeightUnit: String, Codable, Sendable, Hashable {
    case kg, lb
}

/// Carga no fio: valor absoluto, ou peso corporal com delta (lastro +, assistência −).
struct WatchLoad: Codable, Sendable, Hashable {
    var value: Double
    var unit: WatchWeightUnit
    var isBodyweight: Bool

    init(value: Double, unit: WatchWeightUnit = .kg, isBodyweight: Bool = false) {
        self.value = value
        self.unit = unit
        self.isBodyweight = isBodyweight
    }
}

/// Alvo de repetições como prescrito (SPEC D2: sempre exibido; reps realizadas são opcionais).
enum WatchRepTarget: Codable, Sendable, Hashable {
    case fixed(reps: Int)
    case range(min: Int, max: Int)
    case amrap
}

/// Esforço alvo da série prescrita.
enum WatchEffort: Codable, Sendable, Hashable {
    case rir(Int)
    case rpe(Double)
}

enum WatchMeasurementKind: String, Codable, Sendable, Hashable {
    case repsAndLoad, repsOnly, isometric, timeOrDistance
}

enum WatchSetKind: String, Codable, Sendable, Hashable {
    case warmup, feeder, working, dropSet, restPause, toFailure, backOff
}

enum WatchExerciseStatus: String, Codable, Sendable, Hashable {
    case pending, inProgress, completed, partial, skipped
}

enum WatchSkipReason: String, Codable, Sendable, Hashable {
    case equipmentBusy, pain, time, other
}

enum WatchCommandOrigin: String, Codable, Sendable, Hashable {
    case phone, watch
}
