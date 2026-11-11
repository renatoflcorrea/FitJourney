import Foundation
import SwiftData

// Execução (SPEC §4). A sessão guarda um snapshot da prescrição: editar a ficha depois
// não altera sessões passadas. Referências à ficha são IDs + nomes copiados.

@Model
final class WorkoutSession {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Ficha de origem (nullify: apagar a ficha mantém a sessão). `nil` também em "Treino livre".
    var routine: Routine?
    var routineID: UUID?
    var programID: UUID?
    /// Snapshot do nome da ficha.
    var routineName: String = ""

    var startedAt: Date = Date()
    var endedAt: Date?
    var statusRaw: String = SessionStatus.inProgress.rawValue
    /// RPE da sessão 1–10 (Borg CR-10).
    var sessionRPE: Int?
    /// Humor/energia 1–5.
    var mood: Int?
    var notes: String = ""
    var healthKitWorkoutID: UUID?

    // Relógio (SPEC §4.1): só datas persistidas.
    var pausedAt: Date?
    var accumulatedPauseSeconds: Double = 0
    var restEndsAt: Date?

    // Motor da sessão (P2.1, SPEC §6.4).
    /// Revisão monotônica do estado: sobe a cada comando aplicado (base do snapshot versionado).
    var revision: Int = 0
    /// IDs dos comandos já aplicados (JSON `[UUID]`, só os mais recentes) — deduplicação.
    var appliedCommandIDsData: Data?
    /// Exercício escolhido explicitamente como atual (`focusExercise`); `nil` = regra automática.
    var focusedExerciseID: UUID?
    /// Momento da última atividade (comando aplicado) — detecta treino esquecido aberto (D4).
    var lastActivityAt: Date?
    /// Sustentação isométrica em curso: série e início (relógio por datas).
    var holdSetID: UUID?
    var holdStartedAt: Date?
    /// Duração total do descanso em curso (com ajustes ±15 s), para a barra de progresso (P2.6).
    var restTotalSeconds: Double?

    @Relationship(deleteRule: .cascade, inverse: \SessionExercise.session)
    var exercises: [SessionExercise]? = []

    init(routineName: String, startedAt: Date = .now) {
        self.routineName = routineName
        self.startedAt = startedAt
        self.createdAt = startedAt
        self.updatedAt = startedAt
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    var sortedExercises: [SessionExercise] { (exercises ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Relógio derivado das datas. Atribuir grava as datas de volta.
    var clock: SessionClock {
        get {
            SessionClock(startedAt: startedAt, endedAt: endedAt, pausedAt: pausedAt,
                         accumulatedPauseSeconds: accumulatedPauseSeconds, restEndsAt: restEndsAt)
        }
        set {
            startedAt = newValue.startedAt
            endedAt = newValue.endedAt
            pausedAt = newValue.pausedAt
            accumulatedPauseSeconds = newValue.accumulatedPauseSeconds
            restEndsAt = newValue.restEndsAt
        }
    }

    /// IDs de comandos aplicados (mais antigos primeiro).
    var appliedCommandIDs: [UUID] {
        get { StorageCoding.decode([UUID].self, from: appliedCommandIDsData) ?? [] }
        set { appliedCommandIDsData = StorageCoding.encode(newValue) }
    }

    /// Última atividade conhecida: a gravada, senão a última série concluída, senão o início.
    var effectiveLastActivityAt: Date {
        let lastSet = (exercises ?? []).flatMap { $0.sets ?? [] }.compactMap(\.completedAt).max()
        return [lastActivityAt, lastSet, startedAt].compactMap { $0 }.max() ?? startedAt
    }

    /// (concluídos ou pulados, total) para o cabeçalho.
    var exerciseProgress: (done: Int, total: Int) {
        let all = exercises ?? []
        return (all.filter { [.completed, .partial, .skipped].contains($0.status) }.count, all.count)
    }
}

@Model
final class SessionExercise {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Snapshot
    var exerciseID: UUID?
    var routineExerciseID: UUID?
    var name: String = ""
    var measurementKindRaw: String = MeasurementKind.repsAndLoad.rawValue
    var lateralityRaw: String = Laterality.bilateral.rawValue
    var sortIndex: Int = 0
    var groupID: UUID?
    var restSeconds: Int?

    var statusRaw: String = SessionExerciseStatus.pending.rawValue
    var skipReasonRaw: String?
    var skipReasonText: String?
    /// Exercício original quando este foi trocado na hora.
    var substitutedFromExerciseID: UUID?
    var substitutedFromName: String?
    var notes: String = ""
    /// Dor/desconforto opcional (local + 0–10), sem interpretação.
    var painLocation: String?
    var painLevel: Int?

    var session: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \SetLog.sessionExercise)
    var sets: [SetLog]? = []

    init(name: String, measurementKind: MeasurementKind = .repsAndLoad, sortIndex: Int = 0) {
        self.name = name
        self.measurementKindRaw = measurementKind.rawValue
        self.sortIndex = sortIndex
    }

    var measurementKind: MeasurementKind {
        get { MeasurementKind(rawValue: measurementKindRaw) ?? .repsAndLoad }
        set { measurementKindRaw = newValue.rawValue }
    }

    var laterality: Laterality {
        get { Laterality(rawValue: lateralityRaw) ?? .bilateral }
        set { lateralityRaw = newValue.rawValue }
    }

    var status: SessionExerciseStatus {
        get { SessionExerciseStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var skipReason: SkipReason? {
        get { skipReasonRaw.flatMap(SkipReason.init(rawValue:)) }
        set { skipReasonRaw = newValue?.rawValue }
    }

    var sortedSets: [SetLog] { (sets ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Início/fim do exercício (1ª e última série concluída) — base das faixas de FC (SPEC §6.3).
    var completedInterval: DateInterval? {
        let dates = (sets ?? []).compactMap(\.completedAt).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return DateInterval(start: first, end: last)
    }

    var performedSets: [PerformedSet] { sortedSets.map(\.performed) }
}

@Model
final class SetLog {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var sortIndex: Int = 0
    /// Série prescrita de origem (para atualizar a carga atual). `nil` = série extra.
    var prescriptionID: UUID?

    // Snapshot da prescrição
    var kindRaw: String = SetKind.working.rawValue
    var repTargetData: Data?
    var plannedLoadData: Data?
    var targetHoldSeconds: Int?
    var restSeconds: Int?
    var cardioTargetData: Data?

    // Realizado
    var reps: Int?
    var loadData: Data?
    var durationSeconds: Double?
    var distanceMeters: Double?
    /// Cardio realizado (P2.6): nível do aparelho, velocidade (km/h) e inclinação (%).
    var level: Int?
    var speedKmh: Double?
    var inclinePercent: Double?
    var isCompleted: Bool = false
    var completedAt: Date?
    /// Corrigida depois de a sessão terminar (SPEC §4.4).
    var edited: Bool = false
    /// `issuedAt` do último comando que mexeu nesta série (motor da sessão): comandos mais antigos
    /// que chegam depois (relógio offline) são ignorados.
    var lastCommandAt: Date?

    var sessionExercise: SessionExercise?

    init(sortIndex: Int = 0, kind: SetKind = .working, repTarget: RepTarget? = nil,
         plannedLoad: Load? = nil, prescriptionID: UUID? = nil) {
        self.sortIndex = sortIndex
        self.kindRaw = kind.rawValue
        self.repTargetData = StorageCoding.encode(repTarget)
        self.plannedLoadData = StorageCoding.encode(plannedLoad)
        self.prescriptionID = prescriptionID
    }

    var kind: SetKind {
        get { SetKind(rawValue: kindRaw) ?? .working }
        set { kindRaw = newValue.rawValue }
    }

    var repTarget: RepTarget? {
        get { StorageCoding.decode(RepTarget.self, from: repTargetData) }
        set { repTargetData = StorageCoding.encode(newValue) }
    }

    var plannedLoad: Load? {
        get { StorageCoding.decode(Load.self, from: plannedLoadData) }
        set { plannedLoadData = StorageCoding.encode(newValue) }
    }

    var load: Load? {
        get { StorageCoding.decode(Load.self, from: loadData) }
        set { loadData = StorageCoding.encode(newValue) }
    }

    var cardioTarget: CardioTarget? {
        get { StorageCoding.decode(CardioTarget.self, from: cardioTargetData) }
        set { cardioTargetData = StorageCoding.encode(newValue) }
    }

    /// Para métricas: reps realizadas (opcionais, D2) + piso do alvo para estimar volume.
    var performed: PerformedSet {
        PerformedSet(kind: kind, reps: reps, load: load, isCompleted: isCompleted,
                     targetFloorReps: repTarget?.defaultReps)
    }
}
