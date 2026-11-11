import Foundation
import Observation
import SwiftData

/// Evento da sessão para hápticos, sons, notificações e Live Activity.
enum SessionEvent: Sendable, Hashable {
    case sessionStarted(sessionID: UUID)
    case setCompleted(setID: UUID, exerciseID: UUID, at: Date)
    case restStarted(endsAt: Date)
    case restAdjusted(endsAt: Date?)
    case restSkipped
    /// Descanso venceu (calculado pela data `restEndsAt`, emitido uma vez por descanso).
    case restFinished(at: Date)
    case holdStarted(setID: UUID, at: Date)
    case sessionPaused(at: Date)
    case sessionResumed(at: Date)
    case sessionFinished(sessionID: UUID, summary: SessionSummary)
    case sessionDiscarded(sessionID: UUID)
}

/// Resultado de `SessionEngine.apply(_:)`.
enum SessionApplyResult: Sendable, Hashable {
    case applied(revision: Int, events: [SessionEvent])
    /// `commandID` já aplicado: nada mudou.
    case duplicate(revision: Int)
    case rejected(SessionCommandRejection)

    var isApplied: Bool { if case .applied = self { true } else { false } }

    var events: [SessionEvent] { if case .applied(_, let events) = self { events } else { [] } }

    var rejection: SessionCommandRejection? { if case .rejected(let reason) = self { reason } else { nil } }

    /// Resposta para o emissor (relógio).
    func reply(to command: SessionCommand, currentRevision: Int) -> SessionCommandReply {
        switch self {
        case .applied(let revision, _):
            SessionCommandReply(commandID: command.commandID, sessionID: command.sessionID, outcome: .applied, revision: revision)
        case .duplicate(let revision):
            SessionCommandReply(commandID: command.commandID, sessionID: command.sessionID, outcome: .duplicate, revision: revision)
        case .rejected(let reason):
            SessionCommandReply(commandID: command.commandID, sessionID: command.sessionID,
                                outcome: .rejected(reason), revision: currentRevision)
        }
    }
}

/// Treino esquecido aberto (D4): pergunta exibida ao abrir o app.
struct StaleSessionPrompt: Sendable, Hashable, Identifiable {
    var sessionID: UUID
    var routineName: String
    var lastActivityAt: Date
    /// Horário sugerido para finalizar: a última série concluída (senão a última atividade).
    var suggestedEndAt: Date

    var id: UUID { sessionID }
}

enum StaleSessionResolution: Sendable, Hashable {
    /// Finaliza no horário da última série (`suggestedEndAt`).
    case finishAtLastSet(rpe: Int? = nil, applyLoadProposalIDs: [UUID] = [])
    /// Continua a sessão (a atividade passa a contar de agora).
    case keepGoing
    case discard
}

/// Motor da sessão de treino (P2.1): **única porta de escrita** da sessão em andamento para a UI
/// e para o relógio (SPEC §4, §6.4).
///
/// - Comandos idempotentes (`SessionCommand`): dedupe por `commandID` (persistido na sessão, os
///   últimos `appliedCommandLimit`, + memória recente para sessões descartadas).
/// - Cada comando aplicado incrementa `revision` (persistida) e publica um `SessionSnapshot`.
/// - Tempos sempre derivados de datas persistidas; `issuedAt` é o horário do fato (relógio offline).
/// - Lê pelo `SessionStore`; as telas podem continuar lendo a sessão com `@Query`, mas mutações
///   da sessão em andamento passam por aqui.
@MainActor
@Observable
final class SessionEngine {
    /// Quantos `commandID`s ficam gravados por sessão para deduplicação.
    static let appliedCommandLimit = 500
    private static let recentMemoryLimit = 256

    /// Estado atual da sessão em andamento (`nil` = nenhuma).
    private(set) var snapshot: SessionSnapshot?
    /// Treino esquecido aberto detectado no `restore()`.
    private(set) var staleSessionPrompt: StaleSessionPrompt?
    /// Último erro de persistência (para a UI avisar); `nil` depois de um comando bem-sucedido.
    private(set) var lastPersistenceError: String?

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let notifications: any RestNotificationScheduling
    /// Relógio injetável (testes).
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored private let autoRestTimer: Bool

    @ObservationIgnored private var session: WorkoutSession?
    @ObservationIgnored private var recentCommandIDs: [UUID] = []
    @ObservationIgnored private var announcedRestEnd: Date?
    @ObservationIgnored private var scheduledRestEnd: Date?
    @ObservationIgnored private var restTimer: Task<Void, Never>?
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    @ObservationIgnored private var snapshotContinuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    private var store: SessionStore { SessionStore(context: context) }

    /// - Parameters:
    ///   - autoRestTimer: agenda internamente um `refresh()` no fim de cada descanso para emitir
    ///     `restFinished` (o estado continua vindo das datas). Testes passam `false` e chamam `refresh()`.
    init(context: ModelContext, notifications: any RestNotificationScheduling = NoopRestNotificationScheduler(),
         autoRestTimer: Bool = true, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.notifications = notifications
        self.autoRestTimer = autoRestTimer
        self.now = now
    }

    // MARK: Leitura

    /// Sessão em andamento (para telas que leem o modelo diretamente).
    var activeSession: WorkoutSession? { session }

    var activeSessionID: UUID? { snapshot?.sessionID }

    /// Resumo da sessão em andamento como se terminasse agora.
    func currentSummary() throws -> SessionSummary? {
        guard let session else { return nil }
        return try store.summary(for: session, at: now())
    }

    /// Fluxo de eventos (um por assinante).
    func events() -> AsyncStream<SessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.eventContinuations[id] = nil }
            }
        }
    }

    /// Fluxo de snapshots para o transporte do relógio/Live Activity: o atual (se houver) e cada
    /// novo, incluindo o terminal (`finished`/`discarded`).
    func snapshots() -> AsyncStream<SessionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            if let snapshot { continuation.yield(snapshot) }
            snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.snapshotContinuations[id] = nil }
            }
        }
    }

    // MARK: Retomada

    /// Ao abrir o app: carrega a sessão em andamento, recalcula o estado pelas datas e detecta
    /// treino esquecido aberto (> 4 h sem atividade, D4).
    func restore() {
        do {
            session = try store.inProgressSession()
        } catch {
            lastPersistenceError = String(describing: error)
            session = nil
        }
        guard let session else {
            staleSessionPrompt = nil
            snapshot = nil
            syncRest()
            return
        }
        let current = now()
        // Descanso que venceu com o app fechado não gera `restFinished` atrasado.
        if let end = session.restEndsAt, end <= current { announcedRestEnd = end }
        let lastActivity = session.effectiveLastActivityAt
        if SessionFlow.isStale(lastActivity: lastActivity, now: current) {
            let lastSet = (session.exercises ?? []).flatMap { $0.sets ?? [] }.compactMap(\.completedAt).max()
            staleSessionPrompt = StaleSessionPrompt(sessionID: session.id, routineName: session.routineName,
                                                    lastActivityAt: lastActivity,
                                                    suggestedEndAt: lastSet ?? lastActivity)
        } else {
            staleSessionPrompt = nil
        }
        publish(session)
        syncRest()
    }

    func resolveStaleSession(_ resolution: StaleSessionResolution) {
        guard let prompt = staleSessionPrompt else { return }
        staleSessionPrompt = nil
        switch resolution {
        case .finishAtLastSet(let rpe, let ids):
            apply(SessionCommand(sessionID: prompt.sessionID, issuedAt: prompt.suggestedEndAt, origin: .phone,
                                 kind: .finish(rpe: rpe, applyLoadProposalIDs: ids)))
        case .keepGoing:
            guard let session, session.id == prompt.sessionID else { return }
            session.lastActivityAt = now()
            try? context.save()
        case .discard:
            apply(SessionCommand(sessionID: prompt.sessionID, issuedAt: now(), origin: .phone, kind: .discard))
        }
    }

    // MARK: Permissão de notificação (contextual)

    func notificationAuthorization() async -> RestNotificationAuthorization {
        await notifications.authorization()
    }

    /// A UI chama no contexto (ex.: no primeiro descanso). Se autorizar, agenda o descanso em curso.
    @discardableResult
    func requestNotificationPermission() async -> Bool {
        let granted = await notifications.requestAuthorization()
        if granted {
            scheduledRestEnd = nil
            syncRest()
        }
        return granted
    }

    // MARK: Comandos

    /// Atalho da UI do iPhone: monta o comando (origem `phone`, agora) para a sessão em andamento.
    @discardableResult
    func send(_ kind: SessionCommand.Kind, issuedAt: Date? = nil) -> SessionApplyResult {
        let sessionID: UUID
        if case .start = kind { sessionID = UUID() } else { sessionID = session?.id ?? UUID() }
        return apply(SessionCommand(sessionID: sessionID, issuedAt: issuedAt ?? now(), origin: .phone, kind: kind))
    }

    /// Aplica um comando (do iPhone ou do relógio). Idempotente por `commandID`.
    @discardableResult
    func apply(_ command: SessionCommand) -> SessionApplyResult {
        let target: WorkoutSession?
        do {
            target = try fetchSession(id: command.sessionID)
        } catch {
            return fail(error)
        }
        if recentCommandIDs.contains(command.commandID) || target?.appliedCommandIDs.contains(command.commandID) == true {
            return .duplicate(revision: target?.revision ?? 0)
        }

        if case .start(let routineID) = command.kind {
            return applyStart(command, routineID: routineID, existing: target)
        }
        guard let session = target else { return .rejected(.unknownSession) }
        guard session.status == .inProgress else { return .rejected(.sessionNotInProgress) }

        let current = now()
        let at = min(max(command.issuedAt, session.startedAt), current)
        var events: [SessionEvent] = []
        do {
            switch command.kind {
            case .start:
                return .rejected(.invalidState) // tratado acima

            case .finish(let rpe, let ids):
                return try applyFinish(command, session: session, at: at, rpe: rpe, proposalIDs: ids)

            case .discard:
                return try applyDiscard(command, session: session)

            default:
                try perform(command.kind, on: session, at: at, now: current, events: &events)
            }
        } catch let rejection as SessionCommandRejection {
            context.rollback()
            return .rejected(rejection)
        } catch {
            context.rollback()
            return fail(error)
        }

        do {
            try record(command, in: session, at: at)
        } catch {
            return fail(error)
        }
        self.session = session
        lastPersistenceError = nil
        publish(session)
        events += restEvents(for: session, now: current, alreadyEmitted: events)
        syncRest()
        emit(events)
        return .applied(revision: session.revision, events: events)
    }

    /// Verifica o fim do descanso pelas datas e emite `restFinished` uma vez.
    func refresh() {
        guard let session, session.status == .inProgress, session.pausedAt == nil,
              let end = session.restEndsAt, end <= now(), announcedRestEnd != end else { return }
        announcedRestEnd = end
        emit([.restFinished(at: end)])
    }

    // MARK: Início / fim

    private func applyStart(_ command: SessionCommand, routineID: UUID?, existing: WorkoutSession?) -> SessionApplyResult {
        if let existing {
            // Outro `start` para a mesma sessão (reenvio com ID novo) é inofensivo.
            return existing.status == .inProgress ? .duplicate(revision: existing.revision) : .rejected(.sessionNotInProgress)
        }
        do {
            if try store.inProgressSession() != nil { return .rejected(.anotherSessionInProgress) }
            var routine: Routine?
            if let routineID {
                var descriptor = FetchDescriptor<Routine>(predicate: #Predicate { $0.id == routineID })
                descriptor.fetchLimit = 1
                guard let found = try context.fetch(descriptor).first else { return .rejected(.unknownRoutine) }
                routine = found
            }
            let at = min(command.issuedAt, now())
            let session = try store.start(routine: routine, at: at, id: command.sessionID)
            try record(command, in: session, at: at)
            self.session = session
            staleSessionPrompt = nil
            announcedRestEnd = nil
            lastPersistenceError = nil
            publish(session)
            syncRest()
            let events: [SessionEvent] = [.sessionStarted(sessionID: session.id)]
            emit(events)
            return .applied(revision: session.revision, events: events)
        } catch {
            context.rollback()
            return fail(error)
        }
    }

    private func applyFinish(_ command: SessionCommand, session: WorkoutSession, at: Date, rpe: Int?,
                             proposalIDs: [UUID]) throws -> SessionApplyResult {
        if let rpe, !(1...10).contains(rpe) { throw SessionCommandRejection.invalidValue }
        let store = store
        let ids = Set(proposalIDs)
        let proposals = try store.loadProposals(for: session).filter { ids.contains($0.prescriptionID) }
        session.holdSetID = nil
        session.holdStartedAt = nil
        try store.finish(session, at: at, sessionRPE: rpe, applying: proposals)
        try record(command, in: session, at: at)
        let summary = try store.summary(for: session, at: at)
        let terminal = SessionSnapshotBuilder.make(session: session, store: store)
        clearActiveSession()
        broadcast(terminal)
        let events: [SessionEvent] = [.sessionFinished(sessionID: session.id, summary: summary)]
        emit(events)
        return .applied(revision: session.revision, events: events)
    }

    private func applyDiscard(_ command: SessionCommand, session: WorkoutSession) throws -> SessionApplyResult {
        let revision = session.revision + 1
        let terminal = SessionSnapshotBuilder.make(session: session, store: store, status: .discarded, revision: revision)
        let sessionID = session.id
        try store.discard(session)
        remember(command.commandID)
        clearActiveSession()
        broadcast(terminal)
        let events: [SessionEvent] = [.sessionDiscarded(sessionID: sessionID)]
        emit(events)
        return .applied(revision: revision, events: events)
    }

    private func clearActiveSession() {
        session = nil
        snapshot = nil
        staleSessionPrompt = nil
        lastPersistenceError = nil
        syncRest()
    }

    // MARK: Comandos durante a sessão

    private func perform(_ kind: SessionCommand.Kind, on session: WorkoutSession, at: Date, now current: Date,
                         events: inout [SessionEvent]) throws {
        let store = store
        switch kind {
        case .start, .finish, .discard:
            throw SessionCommandRejection.invalidState

        case let .completeSet(setID, reps, load, duration, distance):
            try validate(reps: reps, duration: duration, distance: distance)
            let log = try setLog(setID, in: session)
            try complete(log, in: session, reps: reps, load: load?.load, duration: duration, distance: distance,
                         at: at, events: &events)

        case .uncompleteSet(let setID):
            let log = try setLog(setID, in: session)
            try store.uncompleteSet(log, at: at)

        case let .updateSet(setID, reps, load, duration, distance):
            try validate(reps: reps, duration: duration, distance: distance)
            let log = try setLog(setID, in: session)
            try store.updateSet(log, reps: reps, load: load?.load, durationSeconds: duration, distanceMeters: distance, at: at)

        case let .adjustLoad(setID, delta):
            guard delta.isFinite else { throw SessionCommandRejection.invalidValue }
            try store.adjustLoad(try setLog(setID, in: session), by: delta, at: at)

        case .startRest(let seconds):
            if let seconds, seconds < 0 { throw SessionCommandRejection.invalidValue }
            try store.startRest(session, seconds: seconds ?? defaultRestSeconds(for: session), at: at)

        case .adjustRest(let seconds):
            // Ajuste emitido antes da última série concluída se referia a um descanso já substituído.
            guard !isSuperseded(at, in: session) else { return }
            try store.adjustRest(session, by: seconds, at: current)
            events.append(.restAdjusted(endsAt: session.restEndsAt))

        case .skipRest:
            guard !isSuperseded(at, in: session) else { return }
            if session.restEndsAt != nil {
                try store.skipRest(session)
                events.append(.restSkipped)
            }

        case .startHold(let setID):
            let log = try setLog(setID, in: session)
            guard !log.isCompleted else { throw SessionCommandRejection.invalidState }
            try resumeIfPaused(session, at: at, events: &events)
            var clock = session.clock
            clock.skipRest()
            session.clock = clock
            session.holdSetID = log.id
            session.holdStartedAt = at
            try context.save()
            events.append(.holdStarted(setID: log.id, at: at))

        case .endHold(let setID):
            let log = try setLog(setID, in: session)
            guard session.holdSetID == setID, let started = session.holdStartedAt else {
                throw SessionCommandRejection.invalidState
            }
            let duration = max(0, at.timeIntervalSince(started))
            try complete(log, in: session, reps: nil, load: nil, duration: duration, distance: nil, at: at, events: &events)

        case let .skipExercise(exerciseID, reason):
            let exercise = try sessionExercise(exerciseID, in: session)
            try store.skipExercise(exercise, reason: reason?.skipReason, at: at)
            if session.focusedExerciseID == exerciseID { session.focusedExerciseID = nil }

        case .completeExercise(let exerciseID):
            let exercise = try sessionExercise(exerciseID, in: session)
            try store.completeExercise(exercise, at: at)
            if session.focusedExerciseID == exerciseID { session.focusedExerciseID = nil }

        case .focusExercise(let exerciseID):
            let exercise = try sessionExercise(exerciseID, in: session)
            // Escolher um exercício pulado o retoma.
            if exercise.status == .skipped { try store.unskipExercise(exercise) }
            session.focusedExerciseID = exerciseID

        case let .addSet(exerciseID, kind):
            let exercise = try sessionExercise(exerciseID, in: session)
            try store.addSet(to: exercise, kind: kind?.setKind ?? .working, at: at)

        case .pause:
            guard session.pausedAt == nil else { return }
            try store.pause(session, at: at)
            events.append(.sessionPaused(at: at))

        case .resume:
            try resumeIfPaused(session, at: at, events: &events)
        }
    }

    /// Conclui a série (ou, se já concluída, só atualiza os valores informados).
    private func complete(_ log: SetLog, in session: WorkoutSession, reps: Int?, load: Load?, duration: Double?,
                          distance: Double?, at: Date, events: inout [SessionEvent]) throws {
        if session.holdSetID == log.id {
            session.holdSetID = nil
            session.holdStartedAt = nil
        }
        if log.isCompleted {
            try store.updateSet(log, reps: reps ?? log.reps, load: load ?? log.load,
                                durationSeconds: duration ?? log.durationSeconds,
                                distanceMeters: distance ?? log.distanceMeters, at: at)
            return
        }
        try resumeIfPaused(session, at: at, events: &events)
        // Fora de ordem (relógio offline): só a conclusão mais recente mexe no descanso.
        let latestOther = (session.exercises ?? []).flatMap { $0.sets ?? [] }
            .filter { $0.id != log.id }.compactMap(\.completedAt).max()
        let isLatest = latestOther.map { at >= $0 } ?? true
        try store.completeSet(log, reps: reps, load: load, durationSeconds: duration, distanceMeters: distance,
                              at: at, startRest: isLatest)
        // No grupo, a escolha manual cede à alternância por rodada.
        if let exercise = log.sessionExercise, let groupID = exercise.groupID,
           let focused = session.focusedExerciseID,
           session.sortedExercises.contains(where: { $0.id == focused && $0.groupID == groupID }) {
            session.focusedExerciseID = nil
        }
        if let exercise = log.sessionExercise {
            events.append(.setCompleted(setID: log.id, exerciseID: exercise.id, at: at))
        }
    }

    private func resumeIfPaused(_ session: WorkoutSession, at: Date, events: inout [SessionEvent]) throws {
        guard let pausedAt = session.pausedAt else { return }
        try store.resume(session, at: max(at, pausedAt))
        events.append(.sessionResumed(at: max(at, pausedAt)))
    }

    // MARK: Apoio

    private func record(_ command: SessionCommand, in session: WorkoutSession, at: Date) throws {
        var ids = session.appliedCommandIDs
        ids.append(command.commandID)
        if ids.count > Self.appliedCommandLimit { ids.removeFirst(ids.count - Self.appliedCommandLimit) }
        session.appliedCommandIDs = ids
        session.revision += 1
        session.lastActivityAt = max(session.lastActivityAt ?? at, at)
        remember(command.commandID)
        try context.save()
    }

    private func remember(_ id: UUID) {
        recentCommandIDs.append(id)
        if recentCommandIDs.count > Self.recentMemoryLimit {
            recentCommandIDs.removeFirst(recentCommandIDs.count - Self.recentMemoryLimit)
        }
    }

    private func fetchSession(id: UUID) throws -> WorkoutSession? {
        if let session, session.id == id { return session }
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func setLog(_ id: UUID, in session: WorkoutSession) throws -> SetLog {
        for exercise in session.exercises ?? [] {
            if let log = exercise.sets?.first(where: { $0.id == id }) { return log }
        }
        throw SessionCommandRejection.unknownSet
    }

    private func sessionExercise(_ id: UUID, in session: WorkoutSession) throws -> SessionExercise {
        guard let exercise = session.exercises?.first(where: { $0.id == id }) else {
            throw SessionCommandRejection.unknownExercise
        }
        return exercise
    }

    private func validate(reps: Int?, duration: Double?, distance: Double?) throws {
        if let reps, reps < 0 { throw SessionCommandRejection.invalidValue }
        if let duration, !(duration.isFinite && duration >= 0) { throw SessionCommandRejection.invalidValue }
        if let distance, !(distance.isFinite && distance >= 0) { throw SessionCommandRejection.invalidValue }
    }

    /// Descanso padrão: o da última série concluída, senão o do exercício atual.
    private func defaultRestSeconds(for session: WorkoutSession) -> Int {
        let sets = (session.exercises ?? []).flatMap { $0.sets ?? [] }
        if let last = sets.filter({ $0.completedAt != nil }).max(by: { $0.completedAt! < $1.completedAt! }),
           let rest = last.restSeconds ?? last.sessionExercise?.restSeconds {
            return rest
        }
        let currentID = SessionFlow.currentExerciseID(session.flowStates, focused: session.focusedExerciseID)
        let current = session.exercises?.first { $0.id == currentID }
        return current?.sortedSets.first { !$0.isCompleted }?.restSeconds ?? current?.restSeconds ?? 0
    }

    /// Comando emitido antes da série concluída mais recente (fila offline) — refere-se a um estado velho.
    private func isSuperseded(_ issuedAt: Date, in session: WorkoutSession) -> Bool {
        guard let latest = (session.exercises ?? []).flatMap({ $0.sets ?? [] }).compactMap(\.completedAt).max() else {
            return false
        }
        return issuedAt < latest
    }

    private func fail(_ error: Error) -> SessionApplyResult {
        lastPersistenceError = String(describing: error)
        if let storeError = error as? SessionStoreError {
            switch storeError {
            case .sessionAlreadyInProgress: return .rejected(.anotherSessionInProgress)
            case .sessionNotInProgress: return .rejected(.sessionNotInProgress)
            }
        }
        return .rejected(.persistenceFailed)
    }

    // MARK: Publicação

    private func publish(_ session: WorkoutSession) {
        let snapshot = SessionSnapshotBuilder.make(session: session, store: store)
        self.snapshot = snapshot
        broadcast(snapshot)
    }

    private func broadcast(_ snapshot: SessionSnapshot) {
        for continuation in snapshotContinuations.values { continuation.yield(snapshot) }
    }

    private func emit(_ events: [SessionEvent]) {
        guard !events.isEmpty else { return }
        for continuation in eventContinuations.values {
            for event in events { continuation.yield(event) }
        }
    }

    /// `restStarted` quando o comando abriu um descanso novo ainda em curso.
    private func restEvents(for session: WorkoutSession, now current: Date, alreadyEmitted: [SessionEvent]) -> [SessionEvent] {
        guard let end = session.restEndsAt, end != scheduledRestEnd,
              !alreadyEmitted.contains(where: { if case .restAdjusted = $0 { true } else { false } }) else { return [] }
        if end <= current {
            announcedRestEnd = end // descanso de comando atrasado que já venceu: sem aviso
            return []
        }
        return [.restStarted(endsAt: end)]
    }

    /// Sincroniza notificação e temporizador de fim de descanso com o estado persistido.
    private func syncRest() {
        let current = now()
        var target: Date?
        if let session, session.status == .inProgress, session.pausedAt == nil,
           let end = session.restEndsAt, end > current {
            target = end
        }
        guard target != scheduledRestEnd else { return }
        scheduledRestEnd = target
        restTimer?.cancel()
        restTimer = nil
        guard let target else {
            notifications.cancelRestEnd()
            return
        }
        let currentID = session.flatMap { SessionFlow.currentExerciseID($0.flowStates, focused: $0.focusedExerciseID) }
        let name = session?.exercises?.first { $0.id == currentID }?.name
        notifications.scheduleRestEnd(at: target, nextExerciseName: name)
        guard autoRestTimer else { return }
        let delay = target.timeIntervalSince(current)
        restTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
