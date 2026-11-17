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
/// - Comandos idempotentes (`SessionCommand`), deduplicados por `commandID`.
///   **Janela de dedupe:** os últimos `appliedCommandLimit` (200) IDs ficam gravados na sessão; um
///   reenvio mais antigo que isso seria reaplicado — o que, para comandos de série, vira no-op pela
///   ordem por `issuedAt` (`SetLog.lastCommandAt`). Sessões descartadas ficam em `SessionTombstones`
///   (as 5 mais recentes, em UserDefaults).
/// - Atomicidade: cada comando valida tudo **antes** de mutar e grava a mutação junto com o registro
///   (`commandID`, `revision`) num único `save`. O `rollback()` do SwiftData não desfaz valores em
///   memória dos modelos, então, se o `save` falha, mutação e registro ficam juntos em memória como
///   commit pendente (nunca divergem): o próximo comando — ou o reenvio do mesmo — tenta gravar de
///   novo antes de qualquer coisa; o reenvio recebe então o resultado original (`.applied`).
/// - Cada comando aplicado incrementa `revision` (persistida) e publica um `SessionSnapshot`.
/// - Tempos sempre derivados de datas persistidas; `issuedAt` é o horário do fato (relógio offline).
/// - IDs determinísticos (protocolo v2, `WatchLinkIDs`): `start` cria exercícios/séries com IDs derivados
///   do `sessionID` + prescrição; `addSet`/`addExercise` derivam do `commandID`. O relógio calcula os mesmos.
/// - Sustentação (isométrico) e cronômetro de cardio usam `startHold`/`endHold`: a pausa da sessão não
///   conta (o início é deslocado na retomada; `endHold` durante a pausa conta até o início da pausa).
/// - `skipRest` também dispensa um descanso já vencido (limpa `restEndsAt`); o evento `restSkipped` só
///   sai se o descanso ainda corria.
/// - Anotações (exercício/sessão), dor (local + 0–10), humor (1–5) e nota no `finish`, remover série,
///   tipo da série, alvo da sustentação/duração do cardio e nível/velocidade/inclinação do cardio.
///
/// **Ciclo de vida na UI:** chamar `restore()` ao abrir o app e `handleForeground()` sempre que a
/// cena voltar ao primeiro plano (`scenePhase == .active`) — reavalia descanso vencido e treino
/// esquecido. As telas podem ler a sessão com `@Query`, mas toda mutação da sessão em andamento
/// passa por aqui.
@MainActor
@Observable
final class SessionEngine {
    /// Quantos `commandID`s ficam gravados por sessão para deduplicação.
    static let appliedCommandLimit = 200
    /// `restFinished` vencido há mais que isso (app suspenso, por exemplo) não é anunciado.
    static let restFinishedTolerance: TimeInterval = 30
    /// Limite de descanso e de ajuste de descanso, em segundos.
    static let maxRestSeconds = 3_600
    /// Limite de um ajuste de carga num comando.
    static let maxLoadDelta = 500.0
    /// Limite do alvo de sustentação/duração do cardio, em segundos.
    static let maxHoldSeconds = 3_600
    /// Limite de caracteres de uma anotação.
    static let maxTextLength = 2_000

    /// Estado atual da sessão em andamento (`nil` = nenhuma).
    private(set) var snapshot: SessionSnapshot?
    /// Treino esquecido aberto detectado no `restore()`/`handleForeground()`.
    private(set) var staleSessionPrompt: StaleSessionPrompt?
    /// Último erro de persistência (para a UI avisar); `nil` depois de um comando bem-sucedido.
    private(set) var lastPersistenceError: String?

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let notifications: any RestNotificationScheduling
    /// Preferências de Ajustes (descanso padrão).
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let tombstones: SessionTombstones
    /// Relógio injetável (testes).
    @ObservationIgnored var now: () -> Date
    /// Ponto de falha injetável antes do `save` (testes de atomicidade).
    @ObservationIgnored var beforeSave: (() throws -> Void)?
    @ObservationIgnored private let autoRestTimer: Bool

    @ObservationIgnored private var session: WorkoutSession?
    /// Quem iniciou a última sessão criada por este motor (só memória): o início automático do relógio (P2.8)
    /// só vale para sessões iniciadas no iPhone.
    @ObservationIgnored private var lastStart: (sessionID: UUID, origin: WatchCommandOrigin)?
    @ObservationIgnored private var appliedCache: (sessionID: UUID, ids: [UUID], set: Set<UUID>)?
    @ObservationIgnored private var announcedRestEnd: Date?
    @ObservationIgnored private var scheduledRest: ScheduledRest?
    @ObservationIgnored private var restTimer: Task<Void, Never>?
    @ObservationIgnored private var pending: PendingCommit?
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    @ObservationIgnored private var snapshotContinuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    /// Comando aplicado em memória cujo `save` falhou.
    private struct PendingCommit {
        var commandID: UUID?
        var result: SessionApplyResult
        var finalize: () -> Void
    }

    private struct ScheduledRest: Equatable {
        var endsAt: Date
        var nextExerciseName: String?
    }

    /// Store sem `save` interno: o motor grava uma vez por comando.
    private var store: SessionStore {
        var store = SessionStore(context: context, autosave: false)
        store.fallbackRestSeconds = RestPreference.defaultSeconds(preferences)
        return store
    }

    /// - Parameters:
    ///   - tombstoneDefaults: onde guardar as sessões descartadas (`nil` = só memória).
    ///   - autoRestTimer: agenda internamente um `refresh()` no fim de cada descanso para emitir
    ///     `restFinished` (o estado continua vindo das datas). Testes passam `false` e chamam `refresh()`.
    init(context: ModelContext, notifications: any RestNotificationScheduling = NoopRestNotificationScheduler(),
         tombstoneDefaults: UserDefaults? = .standard, autoRestTimer: Bool = true,
         now: @escaping () -> Date = { Date() }, preferences: UserDefaults = .standard) {
        self.context = context
        self.preferences = preferences
        self.notifications = notifications
        self.tombstones = SessionTombstones(defaults: tombstoneDefaults)
        self.autoRestTimer = autoRestTimer
        self.now = now
    }

    // MARK: Leitura

    /// Sessão em andamento (para telas que leem o modelo diretamente).
    var activeSession: WorkoutSession? { session }

    var activeSessionID: UUID? { snapshot?.sessionID }

    /// Origem do comando `start` que criou a sessão, se foi criada por este motor desde a abertura do app.
    func startOrigin(of sessionID: UUID) -> WatchCommandOrigin? {
        lastStart?.sessionID == sessionID ? lastStart?.origin : nil
    }

    /// Resumo da sessão em andamento como se terminasse agora.
    func currentSummary() throws -> SessionSummary? {
        guard let session else { return nil }
        return try store.summary(for: session, at: now())
    }

    /// Fluxo de eventos (um por assinante; guarda até 64 não lidos).
    func events() -> AsyncStream<SessionEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.eventContinuations[id] = nil }
            }
        }
    }

    /// Fluxo de snapshots para o transporte do relógio/Live Activity: o atual (se houver) e cada
    /// novo, incluindo o terminal (`finished`/`discarded`). Guarda só o mais recente não lido.
    func snapshots() -> AsyncStream<SessionSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            if let snapshot { continuation.yield(snapshot) }
            snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.snapshotContinuations[id] = nil }
            }
        }
    }

    /// Encerra os fluxos e o temporizador (ao descartar o motor). Os fluxos atravessam sessões de
    /// propósito (o transporte do relógio assina uma vez); o fim de uma sessão não os encerra.
    func invalidate() {
        restTimer?.cancel()
        restTimer = nil
        for continuation in eventContinuations.values { continuation.finish() }
        for continuation in snapshotContinuations.values { continuation.finish() }
        eventContinuations = [:]
        snapshotContinuations = [:]
    }

    // MARK: Retomada

    /// Ao abrir o app: carrega a sessão em andamento, recalcula o estado pelas datas e detecta
    /// treino esquecido aberto (> 4 h sem atividade, D4).
    func restore() {
        appliedCache = nil
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
        // Descanso que venceu com o app fechado não gera `restFinished` atrasado.
        if let end = session.restEndsAt, end <= now() { announcedRestEnd = end }
        evaluateStale(session)
        publish(session)
        syncRest()
    }

    /// Volta ao primeiro plano (`scenePhase == .active`): anuncia descanso recém-vencido (dentro da
    /// tolerância), reavalia treino esquecido e ressincroniza notificação/temporizador.
    func handleForeground() {
        guard let session else {
            restore()
            return
        }
        refresh()
        evaluateStale(session)
        syncRest()
    }

    private func evaluateStale(_ session: WorkoutSession) {
        let lastActivity = session.effectiveLastActivityAt
        guard SessionFlow.isStale(lastActivity: lastActivity, now: now()) else {
            staleSessionPrompt = nil
            return
        }
        let lastSet = (session.exercises ?? []).flatMap { $0.sets ?? [] }.compactMap(\.completedAt).max()
        staleSessionPrompt = StaleSessionPrompt(sessionID: session.id, routineName: session.routineName,
                                                lastActivityAt: lastActivity, suggestedEndAt: lastSet ?? lastActivity)
    }

    /// Resolve o treino esquecido. O prompt só some depois de a ação dar certo.
    @discardableResult
    func resolveStaleSession(_ resolution: StaleSessionResolution) -> Bool {
        guard let prompt = staleSessionPrompt else { return false }
        let succeeded: Bool
        switch resolution {
        case .finishAtLastSet(let rpe, let ids):
            succeeded = apply(SessionCommand(sessionID: prompt.sessionID, issuedAt: prompt.suggestedEndAt, origin: .phone,
                                             kind: .finish(rpe: rpe, applyLoadProposalIDs: ids))).isApplied
        case .keepGoing:
            guard let session, session.id == prompt.sessionID else { return false }
            guard flushPending() else { return false }
            session.lastActivityAt = now()
            session.revision += 1
            succeeded = commitOrHold(nil, result: .applied(revision: session.revision, events: [])) { [weak self] in
                self?.publish(session)
            }.isApplied
        case .discard:
            succeeded = apply(SessionCommand(sessionID: prompt.sessionID, issuedAt: now(), origin: .phone,
                                             kind: .discard)).isApplied
        }
        if succeeded { staleSessionPrompt = nil }
        return succeeded
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
            scheduledRest = nil
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
        // Commit pendente (save anterior falhou): grava antes de qualquer coisa.
        if let held = pending {
            guard flushPending() else { return .rejected(.persistenceFailed) }
            if held.commandID == command.commandID { return held.result }
        }
        if let tombstone = tombstones.tombstone(for: command.sessionID) {
            if case .start = command.kind, !tombstone.commandIDs.contains(command.commandID) {
                return .rejected(.sessionDiscarded)
            }
            return .duplicate(revision: tombstone.lastRevision)
        }
        let target: WorkoutSession?
        do {
            target = try fetchSession(id: command.sessionID)
        } catch {
            return fail(error)
        }
        if let target, appliedIDs(of: target).set.contains(command.commandID) {
            return .duplicate(revision: target.revision)
        }
        if case .start(let routineID) = command.kind {
            return applyStart(command, routineID: routineID, existing: target)
        }
        guard let session = target else { return .rejected(.unknownSession) }
        guard session.status == .inProgress else { return .rejected(.sessionNotInProgress) }

        let current = now()
        let at = min(max(command.issuedAt, session.startedAt), current)
        switch command.kind {
        case let .finish(rpe, ids, mood, notes):
            return applyFinish(command, session: session, at: at, rpe: rpe, proposalIDs: ids, mood: mood, notes: notes)
        case .discard:
            return applyDiscard(command, session: session)
        default:
            break
        }

        var events: [SessionEvent] = []
        do {
            try perform(command, on: session, at: at, now: current, events: &events)
            try record(command, in: session, at: at)
        } catch {
            return reject(error)
        }
        let emitted = events
        return commitOrHold(command.commandID, result: .applied(revision: session.revision, events: events)) { [weak self] in
            guard let self else { return }
            self.session = session
            self.publish(session)
            self.syncRest()
            self.emit(emitted)
        }
    }

    /// Verifica o fim do descanso pelas datas e emite `restFinished` uma vez — só se venceu há no
    /// máximo `restFinishedTolerance` (senão marca como anunciado sem avisar).
    func refresh() {
        let current = now()
        guard let session, session.status == .inProgress, session.pausedAt == nil,
              let end = session.restEndsAt, end <= current, announcedRestEnd != end else { return }
        announcedRestEnd = end
        guard current.timeIntervalSince(end) <= Self.restFinishedTolerance else { return }
        emit([.restFinished(at: end)])
    }

    // MARK: Início / fim

    private func applyStart(_ command: SessionCommand, routineID: UUID?, existing: WorkoutSession?) -> SessionApplyResult {
        if let existing {
            // Outro `start` para a mesma sessão (reenvio com ID novo) é inofensivo.
            return existing.status == .inProgress ? .duplicate(revision: existing.revision) : .rejected(.sessionNotInProgress)
        }
        let session: WorkoutSession
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
            session = try store.start(routine: routine, at: at, id: command.sessionID)
            try record(command, in: session, at: at)
        } catch {
            return reject(error)
        }
        let events: [SessionEvent] = [.sessionStarted(sessionID: session.id)]
        return commitOrHold(command.commandID, result: .applied(revision: session.revision, events: events)) { [weak self] in
            guard let self else { return }
            self.session = session
            self.lastStart = (session.id, command.origin)
            self.staleSessionPrompt = nil
            self.announcedRestEnd = nil
            self.publish(session)
            self.syncRest()
            self.emit(events)
        }
    }

    /// Tudo que pode falhar (validação, propostas, resumo) vem antes da mutação; o snapshot terminal
    /// é montado em memória antes do único `save`. Um comando aplicado nunca é respondido como recusado.
    private func applyFinish(_ command: SessionCommand, session: WorkoutSession, at: Date, rpe: Int?,
                             proposalIDs: [UUID], mood: Int?, notes: String?) -> SessionApplyResult {
        let summary: SessionSummary
        let terminal: SessionSnapshot
        do {
            if let rpe, !(1...10).contains(rpe) { throw SessionCommandRejection.invalidValue }
            if let mood, !(1...5).contains(mood) { throw SessionCommandRejection.invalidValue }
            if let notes { try validate(text: notes) }
            let store = store
            let ids = Set(proposalIDs)
            // Confirmadas + primeiras definições (ficha sem carga: aplicadas sempre, P2.8) — vale para o iPhone,
            // o relógio e o "finalizar na última série" do treino esquecido.
            let proposals = try store.loadProposals(for: session).filter {
                ids.contains($0.prescriptionID) || $0.isFirstDefinition
            }
            // Alvos de reps (17/11): os mesmos `prescriptionID`s confirmados (o relógio manda todos = padrão).
            let repProposals = try store.repTargetProposals(for: session).filter { ids.contains($0.prescriptionID) }
            // Mesmo resultado antes ou depois de `finish` (duração por datas; histórico exclui a sessão).
            summary = try store.summary(for: session, at: at)
            session.holdSetID = nil
            session.holdStartedAt = nil
            session.restTotalSeconds = nil
            try store.finish(session, at: at, sessionRPE: rpe, mood: mood, notes: notes, applying: proposals,
                             applyingRepTargets: repProposals)
            try record(command, in: session, at: at)
            terminal = SessionSnapshotBuilder.make(session: session, store: store, restAlertRepeat: RestPreference.alertRepeatEnabled(preferences))
        } catch {
            return reject(error)
        }
        let events: [SessionEvent] = [.sessionFinished(sessionID: session.id, summary: summary)]
        return commitOrHold(command.commandID, result: .applied(revision: terminal.revision, events: events)) { [weak self] in
            guard let self else { return }
            self.clearActiveSession()
            self.broadcast(terminal)
            self.emit(events)
        }
    }

    private func applyDiscard(_ command: SessionCommand, session: WorkoutSession) -> SessionApplyResult {
        let revision = session.revision + 1
        let sessionID = session.id
        let commandIDs = appliedIDs(of: session).ids + [command.commandID]
        let terminal = SessionSnapshotBuilder.make(session: session, store: store, status: .discarded, revision: revision,
                                                   restAlertRepeat: RestPreference.alertRepeatEnabled(preferences))
        do {
            try store.discard(session)
        } catch {
            return reject(error)
        }
        let tombstone = SessionTombstone(sessionID: sessionID, lastRevision: revision, commandIDs: commandIDs,
                                         discardedAt: now())
        let events: [SessionEvent] = [.sessionDiscarded(sessionID: sessionID)]
        return commitOrHold(command.commandID, result: .applied(revision: revision, events: events)) { [weak self] in
            guard let self else { return }
            self.tombstones.add(tombstone)
            self.clearActiveSession()
            self.broadcast(terminal)
            self.emit(events)
        }
    }

    private func clearActiveSession() {
        session = nil
        snapshot = nil
        appliedCache = nil
        staleSessionPrompt = nil
        lastPersistenceError = nil
        syncRest()
    }

    // MARK: Comandos durante a sessão

    private func perform(_ command: SessionCommand, on session: WorkoutSession, at: Date, now current: Date,
                         events: inout [SessionEvent]) throws {
        let store = store
        switch command.kind {
        case .start, .finish, .discard:
            throw SessionCommandRejection.invalidState

        case let .completeSet(setID, reps, load, duration, distance):
            try validate(reps: reps, load: load, duration: duration, distance: distance)
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try complete(log, in: session, reps: reps, load: load?.load, duration: duration, distance: distance,
                         at: at, now: current, events: &events)

        case .uncompleteSet(let setID):
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.uncompleteSet(log, at: at)

        case let .updateSet(setID, reps, load, duration, distance):
            try validate(reps: reps, load: load, duration: duration, distance: distance)
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.updateSet(log, reps: reps, load: load?.load, durationSeconds: duration, distanceMeters: distance, at: at)

        case let .adjustLoad(setID, delta):
            guard delta.isFinite, abs(delta) <= Self.maxLoadDelta else { throw SessionCommandRejection.invalidValue }
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.adjustLoad(log, by: delta, at: at)

        case .startRest(let seconds):
            if let seconds, !(0...Self.maxRestSeconds).contains(seconds) { throw SessionCommandRejection.invalidValue }
            guard !isSuperseded(at, in: session) else { return }
            let before = session.restEndsAt
            try store.startRest(session, seconds: seconds ?? defaultRestSeconds(for: session), at: at)
            session.restTotalSeconds = session.restEndsAt.map { $0.timeIntervalSince(session.pausedAt ?? at) }
            restStartedEvent(session, before: before, now: current, into: &events)

        case .adjustRest(let seconds):
            guard abs(seconds) <= Self.maxRestSeconds else { throw SessionCommandRejection.invalidValue }
            // Ajuste emitido antes da última série concluída se referia a um descanso já substituído.
            guard !isSuperseded(at, in: session) else { return }
            let previousTotal = session.restTotalSeconds
            try store.adjustRest(session, by: seconds, at: current)
            if let end = session.restEndsAt {
                let remaining = end.timeIntervalSince(session.pausedAt ?? current)
                session.restTotalSeconds = max(remaining, (previousTotal ?? remaining - Double(seconds)) + Double(seconds))
            } else {
                session.restTotalSeconds = nil
            }
            events.append(.restAdjusted(endsAt: session.restEndsAt))

        case .skipRest:
            guard !isSuperseded(at, in: session) else { return }
            if session.restEndsAt != nil {
                // Também dispensa o descanso já vencido (a UI não precisa de "dispensar local").
                let wasResting = session.clock.isResting(at: current)
                try store.skipRest(session)
                session.restTotalSeconds = nil
                if wasResting { events.append(.restSkipped) }
            }

        case .startHold(let setID):
            let log = try setLog(setID, in: session)
            guard !log.isCompleted else { throw SessionCommandRejection.invalidState }
            guard touch(log, at: at) else { return }
            try resumeIfPaused(session, at: at, events: &events)
            if session.clock.isResting(at: current) { events.append(.restSkipped) }
            var clock = session.clock
            clock.skipRest()
            session.clock = clock
            session.restTotalSeconds = nil
            session.holdSetID = log.id
            session.holdStartedAt = at
            events.append(.holdStarted(setID: log.id, at: at))

        case .endHold(let setID):
            let log = try setLog(setID, in: session)
            guard session.holdSetID == setID, let started = session.holdStartedAt else {
                throw SessionCommandRejection.invalidState
            }
            guard touch(log, at: at) else { return }
            // Pausada: conta só até o início da pausa (o início já foi deslocado pelas pausas anteriores).
            let end = session.pausedAt.map { min($0, at) } ?? at
            let duration = max(0, end.timeIntervalSince(started))
            try complete(log, in: session, reps: nil, load: nil, duration: duration, distance: nil,
                         at: at, now: current, events: &events)

        case let .updateHoldTarget(setID, seconds):
            guard (1...Self.maxHoldSeconds).contains(seconds) else { throw SessionCommandRejection.invalidValue }
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.updateHoldTarget(log, seconds: seconds, at: at)

        case let .updateCardio(setID, level, speed, incline):
            if let level, !(0...1_000).contains(level) { throw SessionCommandRejection.invalidValue }
            if let speed, !(speed.isFinite && (0...1_000).contains(speed)) { throw SessionCommandRejection.invalidValue }
            if let incline, !(incline.isFinite && abs(incline) <= 100) { throw SessionCommandRejection.invalidValue }
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.updateCardio(log, level: level, speedKmh: speed, inclinePercent: incline, at: at)

        case .removeSet(let setID):
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            if session.holdSetID == setID {
                session.holdSetID = nil
                session.holdStartedAt = nil
            }
            try store.removeSet(log, at: at)

        case let .changeSetKind(setID, kind):
            guard kind != .unknown else { throw SessionCommandRejection.invalidValue }
            let log = try setLog(setID, in: session)
            guard touch(log, at: at) else { return }
            try store.changeKind(log, to: kind.setKind, at: at)

        case let .setExerciseNote(exerciseID, text):
            try validate(text: text)
            let exercise = try sessionExercise(exerciseID, in: session)
            guard Self.isNewer(at, than: exercise.notesUpdatedAt) else { return }
            exercise.notesUpdatedAt = at
            try store.setNote(exercise, text: text, at: at)

        case let .setPain(exerciseID, location, score):
            if let score, !(0...10).contains(score) { throw SessionCommandRejection.invalidValue }
            if let location { try validate(text: location) }
            let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines)
            let exercise = try sessionExercise(exerciseID, in: session)
            guard Self.isNewer(at, than: exercise.painUpdatedAt) else { return }
            exercise.painUpdatedAt = at
            try store.setPain(exercise, location: trimmed?.isEmpty == false ? trimmed : nil, level: score, at: at)

        case .setSessionNote(let text):
            try validate(text: text)
            guard Self.isNewer(at, than: session.notesUpdatedAt) else { return }
            session.notesUpdatedAt = at
            session.notes = text
            session.updatedAt = at

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
            try store.addSet(to: exercise, kind: kind?.setKind ?? .working, at: at,
                             id: WatchLinkIDs.extraSetID(sessionID: session.id, commandID: command.commandID))

        case let .addExercise(catalogID, afterID):
            let catalog = try catalogExercise(catalogID)
            let after = try afterID.map { try sessionExercise($0, in: session) }
            try store.addExercise(catalog, to: session, after: after, commandID: command.commandID)

        case let .substituteExercise(exerciseID, catalogID):
            let exercise = try sessionExercise(exerciseID, in: session)
            try store.substitute(exercise, with: try catalogExercise(catalogID), at: at)

        case let .reorderExercise(exerciseID, index):
            guard index >= 0 else { throw SessionCommandRejection.invalidValue }
            try store.moveExercise(try sessionExercise(exerciseID, in: session), toIndex: index, at: at)

        case .pause:
            guard session.pausedAt == nil else { return }
            try store.pause(session, at: at)
            events.append(.sessionPaused(at: at))

        case .resume:
            let wasPaused = session.pausedAt != nil
            try resumeIfPaused(session, at: at, events: &events)
            if wasPaused, session.pausedAt == nil, session.clock.isResting(at: current) {
                events.append(.restAdjusted(endsAt: session.restEndsAt))
            }
        }
    }

    /// Conclui a série (ou, se já concluída, só atualiza os valores informados).
    private func complete(_ log: SetLog, in session: WorkoutSession, reps: Int?, load: Load?, duration: Double?,
                          distance: Double?, at: Date, now current: Date, events: inout [SessionEvent]) throws {
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
        let before = session.restEndsAt
        try store.completeSet(log, reps: reps, load: load, durationSeconds: duration, distanceMeters: distance,
                              at: at, startRest: isLatest)
        if session.restEndsAt != before {
            session.restTotalSeconds = session.restEndsAt.map { $0.timeIntervalSince(at) }
        }
        // No grupo, a escolha manual cede à alternância por rodada.
        if let exercise = log.sessionExercise, let groupID = exercise.groupID,
           let focused = session.focusedExerciseID,
           session.sortedExercises.contains(where: { $0.id == focused && $0.groupID == groupID }) {
            session.focusedExerciseID = nil
        }
        if let exercise = log.sessionExercise {
            events.append(.setCompleted(setID: log.id, exerciseID: exercise.id, at: at))
        }
        restStartedEvent(session, before: before, now: current, into: &events)
    }

    /// Retoma só se o comando é posterior ao início da pausa; anterior → registra sem retomar.
    /// A sustentação/cronômetro em curso é deslocada pela duração da pausa (a pausa não conta).
    private func resumeIfPaused(_ session: WorkoutSession, at: Date, events: inout [SessionEvent]) throws {
        guard let pausedAt = session.pausedAt, at > pausedAt else { return }
        try store.resume(session, at: at)
        // Só o trecho realmente pausado da sustentação: começou durante a pausa (comando fora de ordem) → conta da retomada.
        if let started = session.holdStartedAt {
            session.holdStartedAt = started.addingTimeInterval(max(0, at.timeIntervalSince(max(pausedAt, started))))
        }
        events.append(.sessionResumed(at: at))
    }

    /// `restStarted` quando o comando abriu um descanso novo ainda em curso; descanso de comando
    /// atrasado que já venceu é marcado como anunciado, sem aviso.
    private func restStartedEvent(_ session: WorkoutSession, before: Date?, now current: Date,
                                  into events: inout [SessionEvent]) {
        guard let end = session.restEndsAt, end != before else { return }
        if session.clock.isResting(at: current) {
            events.append(.restStarted(endsAt: end))
        } else {
            announcedRestEnd = end
        }
    }

    // MARK: Apoio

    /// Ordem por `issuedAt` por série: `false` = comando mais antigo que o último aplicado (no-op).
    private func touch(_ log: SetLog, at: Date) -> Bool {
        if let last = log.lastCommandAt, at < last { return false }
        log.lastCommandAt = at
        return true
    }

    private func appliedIDs(of session: WorkoutSession) -> (ids: [UUID], set: Set<UUID>) {
        if let cache = appliedCache, cache.sessionID == session.id { return (cache.ids, cache.set) }
        let ids = session.appliedCommandIDs
        let set = Set(ids)
        appliedCache = (session.id, ids, set)
        return (ids, set)
    }

    private func record(_ command: SessionCommand, in session: WorkoutSession, at: Date) throws {
        var ids = appliedIDs(of: session).ids
        ids.append(command.commandID)
        if ids.count > Self.appliedCommandLimit { ids.removeFirst(ids.count - Self.appliedCommandLimit) }
        session.appliedCommandIDs = ids
        appliedCache = (session.id, ids, Set(ids))
        session.revision += 1
        session.lastActivityAt = max(session.lastActivityAt ?? at, at)
    }

    private func commit() throws {
        try beforeSave?()
        try context.save()
    }

    /// Grava; em sucesso finaliza (publica/emite) e devolve `result`. Em falha guarda como pendente.
    private func commitOrHold(_ commandID: UUID?, result: SessionApplyResult,
                              finalize: @escaping () -> Void) -> SessionApplyResult {
        do {
            try commit()
        } catch {
            lastPersistenceError = String(describing: error)
            pending = PendingCommit(commandID: commandID, result: result, finalize: finalize)
            return .rejected(.persistenceFailed)
        }
        lastPersistenceError = nil
        finalize()
        return result
    }

    /// Tenta gravar o commit pendente. `false` = continua falhando.
    private func flushPending() -> Bool {
        guard let held = pending else { return true }
        do {
            try commit()
        } catch {
            lastPersistenceError = String(describing: error)
            return false
        }
        pending = nil
        lastPersistenceError = nil
        held.finalize()
        return true
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

    private func catalogExercise(_ id: UUID) throws -> Exercise {
        var descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let exercise = try context.fetch(descriptor).first else {
            throw SessionCommandRejection.unknownCatalogExercise
        }
        return exercise
    }

    /// Ordem por `issuedAt` de campos sem série (anotações/dor): `false` = comando mais antigo que o último aplicado.
    private static func isNewer(_ at: Date, than last: Date?) -> Bool {
        last.map { at >= $0 } ?? true
    }

    private func validate(text: String) throws {
        if text.count > Self.maxTextLength { throw SessionCommandRejection.invalidValue }
    }

    private func validate(reps: Int?, load: WatchLoad?, duration: Double?, distance: Double?) throws {
        if let reps, reps < 0 { throw SessionCommandRejection.invalidValue }
        if let load, !load.value.isFinite { throw SessionCommandRejection.invalidValue }
        if let load, !load.isBodyweight, load.value < 0 { throw SessionCommandRejection.invalidValue }
        if let duration, !(duration.isFinite && duration >= 0) { throw SessionCommandRejection.invalidValue }
        if let distance, !(distance.isFinite && distance >= 0) { throw SessionCommandRejection.invalidValue }
    }

    /// Descanso padrão: o da última série concluída, senão o do exercício atual, senão o de Ajustes.
    private func defaultRestSeconds(for session: WorkoutSession) -> Int {
        let sets = (session.exercises ?? []).flatMap { $0.sets ?? [] }
        if let last = sets.filter({ $0.completedAt != nil }).max(by: { $0.completedAt! < $1.completedAt! }),
           let rest = last.restSeconds ?? last.sessionExercise?.restSeconds {
            return rest
        }
        let current = currentExercise(of: session)
        return RestPolicy.effective(set: current?.sortedSets.first { !$0.isCompleted }?.restSeconds,
                                    routineExercise: current?.restSeconds, exercise: nil,
                                    fallback: RestPreference.defaultSeconds(preferences))
    }

    private func currentExercise(of session: WorkoutSession) -> SessionExercise? {
        let currentID = SessionFlow.currentExerciseID(session.flowStates, focused: session.focusedExerciseID)
        return session.exercises?.first { $0.id == currentID }
    }

    /// Comando emitido antes da série concluída mais recente (fila offline) — refere-se a um estado velho.
    private func isSuperseded(_ issuedAt: Date, in session: WorkoutSession) -> Bool {
        guard let latest = (session.exercises ?? []).flatMap({ $0.sets ?? [] }).compactMap(\.completedAt).max() else {
            return false
        }
        return issuedAt < latest
    }

    private func reject(_ error: Error) -> SessionApplyResult {
        if let rejection = error as? SessionCommandRejection { return .rejected(rejection) }
        return fail(error)
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
        let snapshot = SessionSnapshotBuilder.make(session: session, store: store,
                                                   restAlertRepeat: RestPreference.alertRepeatEnabled(preferences))
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

    /// Sincroniza notificação (fim + nome do próximo exercício) e temporizador com o estado persistido.
    private func syncRest() {
        var target: ScheduledRest?
        if let session, session.status == .inProgress, session.pausedAt == nil,
           let end = session.restEndsAt, end > now() {
            target = ScheduledRest(endsAt: end, nextExerciseName: currentExercise(of: session)?.name)
        }
        guard target != scheduledRest else { return }
        let endChanged = target?.endsAt != scheduledRest?.endsAt
        scheduledRest = target
        guard let target else {
            restTimer?.cancel()
            restTimer = nil
            notifications.cancelRestEnd()
            return
        }
        notifications.scheduleRestEnd(at: target.endsAt, nextExerciseName: target.nextExerciseName)
        if endChanged { armRestTimer(target.endsAt) }
    }

    /// Acorda no fim do descanso; se acordar cedo, rearma.
    private func armRestTimer(_ end: Date) {
        restTimer?.cancel()
        restTimer = nil
        guard autoRestTimer else { return }
        let delay = max(0, end.timeIntervalSince(now()))
        restTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if end > self.now() {
                self.armRestTimer(end)
            } else {
                self.refresh()
            }
        }
    }
}
