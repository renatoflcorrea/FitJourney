import Foundation
import Observation

/// Estado da conexão com o iPhone, como o relógio o mostra (DESIGN §9.5).
enum WatchConnectionState: Equatable, Sendable {
    /// Nunca recebeu programa nem sessão: "Abra o FitJourney no iPhone para trazer seus treinos".
    case neverSynced
    /// iPhone alcançável e tudo confirmado.
    case connected
    /// iPhone alcançável, mas há comando sem confirmação ou pedido de snapshot em voo. Nunca tela de carregamento.
    case syncing
    /// iPhone fora de alcance: selo `iphone.slash`, tudo continua funcionando (comandos na fila).
    case phoneUnreachable

    static func resolve(hasReceivedData: Bool, reachable: Bool, awaitingSync: Bool) -> WatchConnectionState {
        guard hasReceivedData else { return .neverSynced }
        guard reachable else { return .phoneUnreachable }
        return awaitingSync ? .syncing : .connected
    }
}

/// Aviso curto de 2 s ("Atualizado pelo iPhone").
struct WatchNotice: Equatable, Identifiable, Sendable {
    let id = UUID()
    var text: String
}

/// Resumo da sessão encerrada (DESIGN §9.4, Finalizar → Resumo).
struct WatchSessionSummary: Equatable, Sendable {
    var sessionID: UUID
    var duration: TimeInterval
    var completedSets: Int
    var totalSets: Int
    var activeKilocalories: Double?
    var averageHeartRate: Int?
    /// Propostas de carga enviadas no `finish` (regra padrão SPEC §3.4) — "N cargas atualizadas".
    var loadsUpdated: Int
}

/// Modelo do app do relógio: renderiza o último `SessionSnapshot` + `ProgramDigest`, aplica
/// **otimisticamente** os próprios comandos e reconcilia com o snapshot do iPhone (fonte de verdade).
///
/// Reconciliação (revisões por sessão são monotônicas):
/// - `display` = último snapshot confirmado + comandos pendentes reaplicados em ordem (`SessionReducer`).
/// - Snapshot com revisão **menor** que a confirmada (mesma sessão) é descartado; igual ou maior substitui.
/// - Resposta `applied`/`duplicate`: o comando fica na fila até chegar um snapshot de revisão ≥ a da resposta
///   (antes disso o snapshot ainda não o contém, então continua reaplicado — sem "pulo" visual).
/// - Resposta `rejected`: o comando sai, o valor volta ao do iPhone e aparece "Atualizado pelo iPhone".
/// - Fora de alcance: nada se perde; ao reconectar, os pendentes sem resposta são reenviados (idempotentes).
///
/// Pontos de injeção (W2/W3b): `WatchTransport` (WatchConnectivity + canal da `HKWorkoutSession`) e
/// `WatchHealthProvider` (`HKWorkoutSession` do relógio); ver os protocolos.
@MainActor @Observable
final class WatchSessionModel {
    struct PendingCommand: Equatable, Identifiable, Sendable {
        var command: SessionCommand
        /// Revisão devolvida pelo iPhone quando aplicou; `nil` = sem resposta ainda.
        var ackedRevision: Int?
        var id: UUID { command.commandID }
    }

    // MARK: Estado observável

    private(set) var digest: ProgramDigest?
    private(set) var digestReceivedAt: Date?
    /// Último snapshot do iPhone (sem otimismo).
    private(set) var confirmed: SessionSnapshot?
    private(set) var pending: [PendingCommand] = []
    /// O que as telas renderizam: `confirmed` + pendentes.
    private(set) var display: SessionSnapshot?
    private(set) var isPhoneReachable: Bool
    private(set) var hasReceivedData = false
    private(set) var isAwaitingSnapshot = false
    private(set) var notice: WatchNotice?
    private(set) var summary: WatchSessionSummary?
    /// Aviso de versão incompatível ("atualize o app no iPhone"/"atualize o relógio").
    private(set) var incompatibility: WatchLinkCompatibility?
    /// Exercício que acabou de começar depois de outro concluído: a Série mostra "Próximo: …" + Começar.
    var introExerciseID: UUID?
    /// Duração total (s) do descanso em curso, para a barra de progresso.
    var restTotalSeconds: Double = 0
    /// Quando o descanso acabou (para "Descanso concluído" por 2 s).
    var restFinishedAt: Date?
    var liveMetrics = WatchLiveMetrics.empty
    var healthAccess: WatchHealthAccess

    // MARK: Dependências (injeção)

    @ObservationIgnored let transport: any WatchTransport
    @ObservationIgnored let haptics: any WatchHaptics
    @ObservationIgnored let health: any WatchHealthProvider
    @ObservationIgnored private let clock: @MainActor () -> Date

    @ObservationIgnored private var closedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var staleAcknowledgedSessionID: UUID?
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var observedRest: (end: Date?, status: SessionSnapshot.Status?) = (nil, nil)

    init(transport: any WatchTransport, haptics: any WatchHaptics, health: any WatchHealthProvider = UnavailableHealthProvider(),
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.transport = transport
        self.haptics = haptics
        self.health = health
        self.clock = clock
        self.isPhoneReachable = transport.isReachable
        self.healthAccess = health.access
        health.onMetrics = { [weak self] metrics in self?.liveMetrics = metrics }
    }

    var now: Date { clock() }

    // MARK: Derivados

    var connection: WatchConnectionState {
        .resolve(hasReceivedData: hasReceivedData, reachable: isPhoneReachable,
                 awaitingSync: isAwaitingSnapshot || pending.contains { $0.ackedRevision == nil })
    }

    var hasActiveSession: Bool { display?.status == .active || display?.status == .paused }
    var isPaused: Bool { display?.status == .paused }
    var currentExercise: SessionSnapshot.Exercise? { display?.currentExercise }
    var currentSet: SessionSnapshot.ExerciseSet? {
        guard let id = display?.currentSetID else { return nil }
        return currentExercise?.sets.first { $0.id == id }
    }
    var pendingCount: Int { pending.count }

    /// Sessão aberta há mais de 4 h sem atividade (DESIGN §9.5).
    var staleSessionSince: Date? {
        guard let display, hasActiveSession, staleAcknowledgedSessionID != display.sessionID else { return nil }
        let last = display.exercises.flatMap(\.sets).compactMap(\.completedAt).max() ?? display.startedAt
        return now.timeIntervalSince(last) > 4 * 3600 ? last : nil
    }

    /// Ficha sugerida/ordem para a lista de treinos.
    var suggestedRoutine: ProgramDigest.Routine? { digest?.suggestedRoutines.first }
    var otherRoutines: [ProgramDigest.Routine] {
        guard let digest else { return [] }
        let highlighted = suggestedRoutine?.id
        return digest.routines.filter { $0.id != highlighted }
    }

    func routine(id: UUID) -> ProgramDigest.Routine? { digest?.routines.first { $0.id == id } }

    // MARK: Ciclo de vida do canal

    /// Consome o fluxo do transporte até ele terminar. O app chama em `.task`.
    func run() async {
        isPhoneReachable = transport.isReachable
        requestSnapshot()
        for await event in transport.events { handle(event) }
    }

    func requestSnapshot() {
        isAwaitingSnapshot = true
        transport.send(.snapshotRequest)
    }

    func handle(_ event: WatchTransportEvent) {
        switch event {
        case .reachability(let reachable):
            let wasReachable = isPhoneReachable
            isPhoneReachable = reachable
            if reachable && !wasReachable {
                for item in pending where item.ackedRevision == nil { transport.send(.command(item.command)) }
                requestSnapshot()
            }
        case .message(let message):
            handle(message)
        }
    }

    func handle(_ message: WatchLinkMessage) {
        switch message {
        case .snapshot(let snapshot): receive(snapshot: snapshot)
        case .commandReply(let reply): receive(reply: reply)
        case .programDigest(let digest): receive(digest: digest)
        case .incompatible(let compatibility): incompatibility = compatibility
        case .command, .snapshotRequest: break // mensagens do relógio para o iPhone
        }
    }

    // MARK: Recepção

    func receive(digest: ProgramDigest?) {
        hasReceivedData = true
        isAwaitingSnapshot = false
        self.digest = digest
        digestReceivedAt = digest?.generatedAt ?? now
    }

    func receive(snapshot: SessionSnapshot?) {
        hasReceivedData = true
        isAwaitingSnapshot = false
        guard let snapshot else {
            // "Sem sessão": ignora enquanto um `start` nosso ainda não foi confirmado.
            if pending.contains(where: { $0.command.kind.isStart && $0.ackedRevision == nil }) { return }
            confirmed = nil
            pending.removeAll()
            recompute()
            return
        }
        if closedSessionIDs.contains(snapshot.sessionID), snapshot.status == .active || snapshot.status == .paused { return }
        if let current = confirmed, current.sessionID == snapshot.sessionID, snapshot.revision < current.revision { return }
        confirmed = snapshot
        pending.removeAll { $0.ackedRevision.map { $0 <= snapshot.revision } ?? false }
        pending.removeAll { $0.command.sessionID != snapshot.sessionID && !$0.command.kind.isStart }
        recompute()
    }

    func receive(reply: SessionCommandReply) {
        guard let index = pending.firstIndex(where: { $0.id == reply.commandID }) else { return }
        switch reply.outcome {
        case .applied, .duplicate:
            if let confirmed, confirmed.sessionID == reply.sessionID, confirmed.revision >= reply.revision {
                pending.remove(at: index)
            } else {
                pending[index].ackedRevision = reply.revision
            }
        case .rejected:
            pending.remove(at: index)
            haptics.play(.failure)
            show(notice: "Atualizado pelo iPhone")
        }
        recompute()
    }

    // MARK: Comandos

    /// Emite um comando: aplica na hora (otimista), guarda na fila e envia. `nil` se não há sessão alvo.
    @discardableResult
    func send(_ kind: SessionCommand.Kind) -> SessionCommand? {
        let sessionID: UUID
        if kind.isStart {
            sessionID = UUID()
        } else if let id = display?.sessionID {
            sessionID = id
        } else {
            return nil
        }
        let command = SessionCommand(sessionID: sessionID, issuedAt: now, origin: .watch, kind: kind)
        pending.append(PendingCommand(command: command))
        recompute()
        transport.send(.command(command))
        return command
    }

    func startSession(routineID: UUID) {
        guard !hasActiveSession else { return }
        summary = nil
        send(.start(routineID: routineID))
    }

    /// Conclui a série atual com a carga exibida. Isométrico/cardio podem passar a duração medida.
    func completeCurrentSet(durationSeconds: Double? = nil) {
        guard let set = currentSet, !set.isCompleted else { return }
        send(.completeSet(setID: set.id, reps: nil, load: nil, durationSeconds: durationSeconds, distanceMeters: nil))
        haptics.play(.setCompleted)
    }

    /// Registra reps realizadas na série atual (botão "+ reps"): mantém a carga exibida. Reps são opcionais (D2).
    func updateReps(setID: UUID, reps: Int?) {
        guard let set = display?.exercises.flatMap(\.sets).first(where: { $0.id == setID }) else { return }
        send(.updateSet(setID: setID, reps: reps, load: set.load, durationSeconds: set.durationSeconds, distanceMeters: set.distanceMeters))
    }

    /// Soma `delta` (múltiplo do passo) à carga da série; respeita os limites.
    func adjustLoad(setID: UUID, by delta: Double) {
        guard delta != 0, let set = display?.exercises.flatMap(\.sets).first(where: { $0.id == setID }) else { return }
        let base = set.load ?? set.plannedLoad ?? WatchLoad(value: 0)
        let target = WatchLoadStepping.clamp(base.value + delta, for: base)
        let effective = target - base.value
        guard abs(effective) >= WatchLoadStepping.step / 2 else { return }
        send(.adjustLoad(setID: setID, delta: effective))
    }

    /// Valor absoluto vindo da Coroa: converte em `adjustLoad`.
    func setLoad(setID: UUID, to value: Double) {
        guard let set = display?.exercises.flatMap(\.sets).first(where: { $0.id == setID }) else { return }
        let base = set.load ?? set.plannedLoad ?? WatchLoad(value: 0)
        adjustLoad(setID: setID, by: value - base.value)
    }

    func skipRest() { send(.skipRest) }
    func extendRest(by seconds: Int = 15) { send(.adjustRest(seconds: seconds)) }

    func startHold() {
        guard let set = currentSet else { return }
        send(.startHold(setID: set.id))
    }

    func endHold() {
        guard let id = display?.holdSetID else { return }
        send(.endHold(setID: id))
        haptics.play(.stopped)
    }

    func pause() {
        guard display?.status == .active else { return }
        send(.pause)
        health.workoutDidPause()
        haptics.play(.stopped)
    }

    func resume() {
        guard display?.status == .paused else { return }
        send(.resume)
        health.workoutDidResume()
        haptics.play(.resumed)
    }

    func focus(exerciseID: UUID) {
        introExerciseID = nil
        send(.focusExercise(exerciseID: exerciseID))
    }

    func complete(exerciseID: UUID) { send(.completeExercise(exerciseID: exerciseID)) }
    func skip(exerciseID: UUID, reason: WatchSkipReason? = nil) { send(.skipExercise(exerciseID: exerciseID, reason: reason)) }

    /// "Próximo" dos Controles: foca o próximo exercício aberto depois do atual.
    func focusNextExercise() {
        guard let display, let current = display.currentExerciseID,
              let index = display.exercises.firstIndex(where: { $0.id == current }) else { return }
        let open: (SessionSnapshot.Exercise) -> Bool = { $0.status != .skipped && $0.status != .completed && $0.sets.contains { !$0.isCompleted } }
        let ordered = Array(display.exercises[(index + 1)...]) + Array(display.exercises[..<index])
        if let next = ordered.first(where: open) { focus(exerciseID: next.id) }
    }

    func startIntroExercise() { introExerciseID = nil }

    func finish(rpe: Int?) {
        guard let display else { return }
        send(.finish(rpe: rpe, applyLoadProposalIDs: display.loadProposals.map(\.prescriptionID)))
        haptics.play(.saved)
    }

    func discard() { send(.discard) }

    func dismissSummary() {
        summary = nil
        introExerciseID = nil
    }

    func keepStaleSessionGoing() { staleAcknowledgedSessionID = display?.sessionID }

    func requestHealthAccess() async {
        healthAccess = await health.requestAccess()
    }

    // MARK: Reconciliação

    private func recompute() {
        let old = display
        var snapshot = confirmed
        for item in pending { snapshot = SessionReducer.apply(item.command, to: snapshot, digest: digest) }
        display = snapshot
        didChangeDisplay(from: old, to: snapshot)
    }

    private func didChangeDisplay(from old: SessionSnapshot?, to new: SessionSnapshot?) {
        let wasActive = old.map { $0.status == .active || $0.status == .paused } ?? false
        let isActive = new.map { $0.status == .active || $0.status == .paused } ?? false

        if let new, isActive, !wasActive || old?.sessionID != new.sessionID {
            health.workoutDidBegin(sessionID: new.sessionID, startedAt: new.startedAt)
            introExerciseID = nil
        }
        if let new, new.status == .finished || new.status == .discarded {
            closedSessionIDs.insert(new.sessionID)
            if wasActive, old?.sessionID == new.sessionID {
                health.workoutDidEnd()
                if new.status == .finished, summary == nil { summary = makeSummary(new) }
            }
        }
        // Próximo exercício começou porque o anterior fechou (não por escolha do usuário).
        if let old, let new, isActive, old.sessionID == new.sessionID,
           let previousID = old.currentExerciseID, let nextID = new.currentExerciseID, previousID != nextID,
           let previous = new.exercises.first(where: { $0.id == previousID }),
           [.completed, .partial, .skipped].contains(previous.status),
           old.exercises.first(where: { $0.id == previousID })?.status != previous.status {
            introExerciseID = nextID
        }
        if !isActive { introExerciseID = nil }

        observeRest(old: old, new: new)
    }

    private func makeSummary(_ s: SessionSnapshot) -> WatchSessionSummary {
        WatchSessionSummary(sessionID: s.sessionID, duration: s.elapsed(at: s.endedAt ?? now),
                            completedSets: s.metrics.completedSets, totalSets: s.metrics.totalSets,
                            activeKilocalories: liveMetrics.activeKilocalories, averageHeartRate: liveMetrics.averageHeartRate,
                            loadsUpdated: s.loadProposals.count)
    }

    // MARK: Descanso

    private func observeRest(old: SessionSnapshot?, new: SessionSnapshot?) {
        let end = new?.restEndsAt
        let status = new?.status
        defer { observedRest = (end, status) }
        guard end != observedRest.end || status != observedRest.status else { return }
        restTask?.cancel()
        restTask = nil
        guard let new, let end, new.status == .active, end > now else {
            if end == nil { restTotalSeconds = 0 }
            return
        }
        let oldEnd = observedRest.end
        if let oldEnd, oldEnd > now {
            restTotalSeconds = max(1, restTotalSeconds + end.timeIntervalSince(oldEnd))
        } else {
            restTotalSeconds = max(1, end.timeIntervalSince(now).rounded())
        }
        restFinishedAt = nil
        let delay = end.timeIntervalSince(now)
        restTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.restDidEnd(at: end)
        }
    }

    /// O descanso vencido dispara o háptico forte (o pulso abaixado também sente) uma única vez.
    func restDidEnd(at end: Date) {
        guard let display, display.status == .active, display.restEndsAt == end else { return }
        restFinishedAt = now
        haptics.play(.restEnded)
    }

    private func show(notice text: String) {
        let notice = WatchNotice(text: text)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.notice?.id == notice.id else { return }
            self?.notice = nil
        }
    }
}

extension SessionCommand.Kind {
    var isStart: Bool {
        if case .start = self { return true }
        return false
    }
}
