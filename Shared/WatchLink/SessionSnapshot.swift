import Foundation

/// Estado compacto e completo da sessão para renderizar no relógio, no acessório flutuante e na
/// Live Activity (SPEC §6.4). Gerado pelo iPhone (fonte de verdade) a cada comando aplicado.
/// `revision` é monotônica por sessão: o receptor descarta snapshots com revisão menor que a que tem.
/// Tempos são datas (relógio derivado de timestamps, nunca de contadores).
struct SessionSnapshot: Codable, Sendable, Hashable {
    enum Status: String, Codable, Sendable, Hashable, UnknownCaseDecodable {
        case active, paused, finished, discarded
        /// Valor de versão futura.
        case unknown
    }

    var sessionID: UUID
    var revision: Int
    var status: Status
    var routineID: UUID?
    var routineName: String
    var startedAt: Date
    var endedAt: Date?
    var pausedAt: Date?
    var accumulatedPauseSeconds: Double
    /// Fim do descanso em curso (`nil` = sem descanso). Já vencido = descanso acabou.
    var restEndsAt: Date?
    /// Sustentação isométrica em curso.
    var holdSetID: UUID?
    var holdStartedAt: Date?
    /// Exercício atual (regra automática ou escolhido) e a próxima série pendente dele.
    var currentExerciseID: UUID?
    var currentSetID: UUID?
    var exercises: [Exercise]
    var metrics: Metrics
    /// Propostas de atualização de carga (R-T2) se a sessão terminasse agora — para confirmar no `finish`.
    var loadProposals: [LoadProposal]

    struct Exercise: Codable, Sendable, Hashable, Identifiable {
        /// `SessionExercise.id`.
        var id: UUID
        /// Exercício do catálogo.
        var exerciseID: UUID?
        var name: String
        var measurementKind: WatchMeasurementKind
        var status: WatchExerciseStatus
        /// Mesmo `groupID` = bi-set/tri-set/circuito.
        var groupID: UUID?
        var restSeconds: Int?
        var sets: [ExerciseSet]
    }

    struct ExerciseSet: Codable, Sendable, Hashable, Identifiable {
        /// `SetLog.id`.
        var id: UUID
        var kind: WatchSetKind
        /// Alvo exibível como prescrito: "8–12", "10", "AMRAP", "45 s", "20 min".
        var targetText: String
        var repTarget: WatchRepTarget?
        var effort: WatchEffort?
        var plannedLoad: WatchLoad?
        /// Carga exibida/realizada (ajustada antes de concluir ou registrada).
        var load: WatchLoad?
        /// Reps realizadas — opcionais (D2).
        var reps: Int?
        var targetHoldSeconds: Int?
        var durationSeconds: Double?
        var distanceMeters: Double?
        var restSeconds: Int?
        var isCompleted: Bool
        var completedAt: Date?
    }

    struct Metrics: Codable, Sendable, Hashable {
        var completedSets: Int
        var totalSets: Int
        /// Exercícios concluídos/parciais/pulados.
        var exercisesDone: Int
        var exercisesTotal: Int
        var volumeKg: Double
        /// Volume inclui séries sem reps estimadas pelo piso do alvo (D2).
        var hasEstimatedVolume: Bool
    }

    struct LoadProposal: Codable, Sendable, Hashable, Identifiable {
        var prescriptionID: UUID
        var exerciseName: String
        var from: WatchLoad?
        var to: WatchLoad

        var id: UUID { prescriptionID }
    }

    // MARK: Relógio (mesma regra do `SessionClock` do app)

    /// Tempo ativo da sessão.
    func elapsed(at now: Date) -> TimeInterval {
        let reference = [endedAt, pausedAt].compactMap { $0 }.min() ?? now
        return max(0, reference.timeIntervalSince(startedAt) - accumulatedPauseSeconds)
    }

    /// Descanso restante; `nil` sem descanso ou vencido. Congelado durante a pausa.
    func restRemaining(at now: Date) -> TimeInterval? {
        guard let restEndsAt, endedAt == nil else { return nil }
        let remaining = restEndsAt.timeIntervalSince(pausedAt ?? now)
        return remaining > 0 ? remaining : nil
    }

    var currentExercise: Exercise? { exercises.first { $0.id == currentExerciseID } }

    /// "Série 2 de 4" do exercício atual: (posição 1-based, total).
    var currentSetPosition: (index: Int, of: Int)? {
        guard let exercise = currentExercise, let setID = currentSetID,
              let index = exercise.sets.firstIndex(where: { $0.id == setID }) else { return nil }
        return (index + 1, exercise.sets.count)
    }
}
