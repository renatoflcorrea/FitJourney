import Foundation

// Protocolo relógio ↔ iPhone (SPEC §6.4). Só Foundation: compila nos alvos iOS e watchOS.
// O formato de fio é o Codable sintetizado em JSON (`WatchLinkCodec`). Qualquer mudança de formato
// (caso, campo obrigatório ou nome) exige subir `WatchLinkProtocol.schemaVersion`.
// Os IDs são sempre os da sessão/ficha no iPhone (fonte de verdade): `SessionExercise.id`,
// `SetLog.id`, `Routine.id`, `SetPrescription.id`. Desde a v2 os IDs de exercício/série de uma sessão
// são determinísticos (`WatchLinkIDs`): relógio e iPhone chegam aos mesmos sem troca de mensagens.
//
// Histórico:
// - v1: IDs da sessão criados no iPhone (o relógio retinha e remapeava comandos até o 1º snapshot).
// - v2: IDs determinísticos; comandos de nota/dor/série/cardio; `finish` com humor/nota; snapshot com
//   `appliedCommandIDs`, `restTotalSeconds`, `focusedExerciseID`, rodada do grupo, alvos de cardio;
//   mensagens `liveMetrics`, `workoutStatus` e `recordingRequest`. v1 recebe `.incompatible`.
//   17/11: `SessionSnapshot.repTargetProposals` (opcional — versões anteriores ignoram/omitem; sem subir a versão).

enum WatchLinkProtocol {
    static let schemaVersion = 2
    static let minimumSupportedVersion = 2
}

/// Enum de fio tolerante: valor bruto desconhecido (gravado por versão mais nova) vira `.unknown`
/// em vez de derrubar a mensagem inteira.
protocol UnknownCaseDecodable: RawRepresentable, Decodable where RawValue == String {
    static var unknown: Self { get }
}

extension UnknownCaseDecodable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
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

enum WatchMeasurementKind: String, Codable, Sendable, Hashable, UnknownCaseDecodable {
    case repsAndLoad, repsOnly, isometric, timeOrDistance
    /// Valor de versão futura.
    case unknown
}

enum WatchSetKind: String, Codable, Sendable, Hashable, UnknownCaseDecodable {
    case warmup, feeder, working, dropSet, restPause, toFailure, backOff
    /// Valor de versão futura.
    case unknown
}

enum WatchExerciseStatus: String, Codable, Sendable, Hashable, UnknownCaseDecodable {
    case pending, inProgress, completed, partial, skipped
    /// Valor de versão futura.
    case unknown
}

enum WatchSkipReason: String, Codable, Sendable, Hashable, UnknownCaseDecodable {
    case equipmentBusy, pain, time, other
    /// Valor de versão futura.
    case unknown
}

enum WatchCommandOrigin: String, Codable, Sendable, Hashable {
    case phone, watch
}

/// FC/energia ao vivo medidas pelo relógio (`nil` = sem leitura; nunca zero).
struct WatchLiveMetricsPayload: Codable, Sendable, Hashable {
    var sessionID: UUID
    var date: Date
    var heartRate: Double?
    /// Energia ativa acumulada no treino (kcal).
    var activeKilocalories: Double?
}

/// Estado da gravação do treino no relógio, para o iPhone decidir se grava (SPEC §6.2/§6.4).
///
/// Regra de quem grava: sessão iniciada no relógio → o relógio grava (se o Saúde estiver autorizado lá);
/// sessão iniciada no iPhone → o iPhone grava e o relógio só controla, a menos que o usuário escolha
/// "gravar no relógio" (`recordingRequest` ou ação no relógio) — aí o relógio grava e o iPhone descarta a dele.
struct WatchWorkoutStatus: Codable, Sendable, Hashable {
    enum State: Codable, Sendable, Hashable {
        /// O relógio está gravando: o iPhone não grava outro treino para a sessão.
        case recording
        /// O relógio não vai gravar (sem permissão/falhou ao iniciar): o iPhone grava.
        case notRecording
        /// Treino gravado no Saúde pelo relógio (`HKWorkout.uuid`, com `HKMetadataKeyExternalUUID` = sessão).
        case saved(workoutID: UUID)
        /// Falhou ao gravar no fim: o iPhone grava pelo gravador simples.
        case failed
    }

    var sessionID: UUID
    var state: State
}
