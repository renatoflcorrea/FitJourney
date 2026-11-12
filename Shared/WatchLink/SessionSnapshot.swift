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

    // v2
    /// Exercício escolhido explicitamente (`focusExercise`); `nil` = regra automática.
    var focusedExerciseID: UUID? = nil
    /// Duração total do descanso em curso (com os ajustes ±15 s), para a barra de progresso. `nil` sem descanso.
    var restTotalSeconds: Double? = nil
    /// `commandID`s aplicados mais recentes (até `SessionSnapshot.appliedCommandWindow`, mais antigos
    /// primeiro): o relógio poda da fila o que o snapshot já contém, mesmo sem a resposta.
    var appliedCommandIDs: [UUID] = []
    /// Rodada do bi-set/tri-set/circuito do exercício atual (`nil` fora de grupo).
    var currentGroup: GroupRound? = nil
    /// Anotação da sessão (`nil`/vazio = sem).
    var notes: String? = nil
    /// Tipo do treino para o Saúde (`HealthWorkoutType.rawValue`, derivado da ficha no iPhone).
    var workoutType: String? = nil
    /// Preferência "Alerta insistente no fim do descanso" (`fj.restAlertRepeat`) do iPhone, para o relógio.
    /// Só vai `false` quando desligada; `nil` (ausente, versões antigas, sessão ainda sem snapshot) = ligada.
    var restAlertRepeat: Bool? = nil
    /// Idioma efetivo do app no iPhone (`AppLanguageCode`: "pt-BR" | "en"); ausente = sem mudança no relógio.
    var language: String? = nil

    /// Tamanho da janela de `appliedCommandIDs`.
    static let appliedCommandWindow = 64

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
        // v2
        var notes: String? = nil
        var painLocation: String? = nil
        /// Dor 0–10.
        var painScore: Int? = nil
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
        // v2 (cardio)
        /// Duração alvo (cardio), para o cronômetro.
        var targetDurationSeconds: Int? = nil
        var targetDistanceMeters: Double? = nil
        /// Nível/velocidade/inclinação realizados.
        var level: Int? = nil
        var speedKmh: Double? = nil
        var inclinePercent: Double? = nil
    }

    /// Posição do exercício atual na rodada do grupo.
    struct GroupRound: Codable, Sendable, Hashable {
        var groupID: UUID
        /// Rodada atual (1-based) e total (maior número de séries entre os exercícios do grupo).
        var round: Int
        var totalRounds: Int
        /// Concluir a série atual fecha a rodada (e começa o descanso); `false` = alterna para `nextExerciseID` sem descanso.
        var completesRound: Bool
        var nextExerciseID: UUID?
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

    /// Tempo ativo da sustentação/cronômetro de cardio em curso (as pausas não contam: o início é
    /// deslocado na retomada e, pausado, o tempo fica congelado na pausa).
    func holdElapsed(at now: Date) -> TimeInterval? {
        guard let holdStartedAt else { return nil }
        let reference = [endedAt, pausedAt].compactMap { $0 }.min() ?? now
        return max(0, reference.timeIntervalSince(holdStartedAt))
    }

    var currentExercise: Exercise? { exercises.first { $0.id == currentExerciseID } }

    /// Rodada do grupo do exercício `currentID` (mesma regra de `SessionFlow.isEndOfRound`).
    static func groupRound(exercises: [Exercise], currentID: UUID?) -> GroupRound? {
        guard let current = exercises.first(where: { $0.id == currentID }), let group = current.groupID else { return nil }
        let members = exercises.filter { $0.groupID == group && $0.status != .skipped }
        func done(_ e: Exercise) -> Int { e.sets.filter(\.isCompleted).count }
        func isOpen(_ e: Exercise) -> Bool {
            (e.status == .pending || e.status == .inProgress) && (e.sets.isEmpty || e.sets.contains { !$0.isCompleted })
        }
        let total = members.map(\.sets.count).max() ?? 0
        let after = done(current) + 1
        let others = members.filter { $0.id != current.id && isOpen($0) }
        let completes = others.allSatisfy { done($0) >= after }
        var next: UUID?
        if !completes, let index = members.firstIndex(where: { $0.id == current.id }) {
            let ordered = Array(members[(index + 1)...]) + Array(members[..<index])
            next = ordered.first { $0.id != current.id && isOpen($0) && done($0) < after }?.id
        }
        return GroupRound(groupID: group, round: min(max(1, after), max(1, total)), totalRounds: max(1, total),
                          completesRound: completes, nextExerciseID: next)
    }

    /// "Série 2 de 4" do exercício atual: (posição 1-based, total).
    var currentSetPosition: (index: Int, of: Int)? {
        guard let exercise = currentExercise, let setID = currentSetID,
              let index = exercise.sets.firstIndex(where: { $0.id == setID }) else { return nil }
        return (index + 1, exercise.sets.count)
    }
}
