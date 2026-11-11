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

/// Resumo da sessão encerrada (DESIGN §9.4, Finalizar → Resumo); só nasce com o fim confirmado pelo iPhone.
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
/// - Resposta `rejected`: o comando sai, o valor volta ao do iPhone, pede-se novo snapshot e aparece "Atualizado pelo iPhone".
/// - Sem resposta (perdida) por `resendInterval`: reenvia o mesmo `commandID` (o iPhone responde `duplicate`) e pede snapshot.
/// - Fim da sessão (`finish`/`discard`): `summary`, `closedSessionIDs` e `workoutDidEnd` só quando o snapshot
///   **confirmado** for terminal; antes disso a tela mostra "Salvando…" e uma rejeição volta ao estado ativo.
///
/// IDs de uma sessão iniciada aqui (INTERINO, A1): o iPhone cria `SetLog`/`SessionExercise` com IDs novos, diferentes dos da
/// prescrição que o relógio usa para renderizar o `start` otimista. Enquanto o 1º snapshot dessa sessão não chega, comandos
/// não-`start` ficam **retidos** (`isHeld`, não enviados); ao chegar, são remapeados por posição (exercício, série) e os que
/// não casam são descartados com aviso. W2: com IDs determinísticos no `start`, o remapeamento vira identidade e este caminho
/// some (ponto único: `releaseHeldCommands`).
///
/// Pontos de injeção (W2/W3b): `WatchTransport` (WatchConnectivity + canal da `HKWorkoutSession`) e
/// `WatchHealthProvider` (`HKWorkoutSession` do relógio); ver os protocolos.
@MainActor @Observable
final class WatchSessionModel {
    struct PendingCommand: Equatable, Identifiable, Sendable {
        var command: SessionCommand
        /// Revisão devolvida pelo iPhone quando aplicou; `nil` = sem resposta ainda.
        var ackedRevision: Int?
        /// Retido: a sessão ainda não tem snapshot confirmado (ver A1 acima). Nunca enviado enquanto retido.
        var isHeld = false
        var lastSentAt: Date?
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
    /// Resumo da sessão encerrada; só existe depois que o iPhone confirmou o fim.
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
    /// Espera por resposta antes de reenviar um comando; espera máxima por um snapshot pedido.
    @ObservationIgnored var resendInterval: TimeInterval = 5
    @ObservationIgnored var snapshotTimeout: TimeInterval = 10

    @ObservationIgnored private var closedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var handledTerminalSessionIDs: Set<UUID> = []
    @ObservationIgnored private var seenActiveSessionIDs: Set<UUID> = []
    @ObservationIgnored private var staleAcknowledgedSessionID: UUID?
    @ObservationIgnored private var savingDismissedSessionID: UUID?
    @ObservationIgnored private var activeWorkoutSessionID: UUID?
    /// Snapshot otimista do `start` de cada sessão iniciada aqui (base do remapeamento de IDs).
    @ObservationIgnored private var startBaselines: [UUID: SessionSnapshot] = [:]
    @ObservationIgnored private var cardioStartElapsed: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var awaitingSince: Date?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
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

    /// Finalizado aqui, ainda sem confirmação do iPhone: a tela mostra "Salvando…".
    var isSavingSession: Bool {
        guard summary == nil, let display, display.status == .finished, savingDismissedSessionID != display.sessionID else { return false }
        return !(confirmed?.sessionID == display.sessionID && confirmed?.status == .finished)
    }

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

    /// Cardio: tempo ativo desde que a série passou a ser a atual (desconta pausas; sem comando de início no protocolo — W2).
    func cardioElapsed(setID: UUID, at date: Date) -> TimeInterval {
        guard let display, let start = cardioStartElapsed[setID] else { return 0 }
        return max(0, display.elapsed(at: date) - start)
    }

    // MARK: Ciclo de vida do canal

    /// Começa a escutar o transporte e a reenviar o que ficou sem resposta. Idempotente (guarda); o app chama no `.task`.
    func start() {
        guard loopTask == nil else { return }
        isPhoneReachable = transport.isReachable
        let stream = transport.makeEventStream() // antes do pedido, para não perder a resposta
        requestSnapshot()
        loopTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
            self?.loopTask = nil // transporte terminou: `start()` pode reassinar
        }
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.retryStalePending()
            }
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        tickTask?.cancel(); tickTask = nil
    }

    func requestSnapshot() {
        isAwaitingSnapshot = true
        awaitingSince = now
        transport.send(.snapshotRequest)
    }

    /// Reenvia comandos sem resposta há `resendInterval` (resposta perdida) e abandona pedido de snapshot sem retorno.
    func retryStalePending() {
        guard isPhoneReachable else { return }
        var resent = false
        for index in pending.indices where !pending[index].isHeld && pending[index].ackedRevision == nil {
            if now.timeIntervalSince(pending[index].lastSentAt ?? .distantPast) >= resendInterval {
                transmit(index)
                resent = true
            }
        }
        if resent { requestSnapshot() }
        if isAwaitingSnapshot, let since = awaitingSince, now.timeIntervalSince(since) >= snapshotTimeout {
            isAwaitingSnapshot = false
        }
    }

    func handle(_ event: WatchTransportEvent) {
        switch event {
        case .reachability(let reachable):
            let wasReachable = isPhoneReachable
            isPhoneReachable = reachable
            if reachable && !wasReachable {
                for index in pending.indices where !pending[index].isHeld && pending[index].ackedRevision == nil { transmit(index) }
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

    private func transmit(_ index: Int) {
        pending[index].lastSentAt = now
        transport.send(.command(pending[index].command))
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
            // "Sem sessão" atrasado em relação a um `start` nosso (qualquer estado de resposta): ignora.
            if pending.contains(where: { $0.command.kind.isStart }) { return }
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
        releaseHeldCommands(for: snapshot)
        pruneCommandsWithUnknownIDs(in: snapshot)
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
            let rejected = pending.remove(at: index)
            if rejected.command.kind.isStart {
                // Sessão não nasceu: tudo o que dependia dela cai junto.
                pending.removeAll { $0.command.sessionID == rejected.command.sessionID }
                closedSessionIDs.insert(rejected.command.sessionID)
            }
            haptics.play(.failure)
            show(notice: "Atualizado pelo iPhone")
            requestSnapshot()
        }
        recompute()
    }

    // MARK: IDs de sessão iniciada aqui (interino, A1)

    /// IDs referenciados por um comando: (séries, exercícios).
    static func referencedIDs(_ kind: SessionCommand.Kind) -> (sets: [UUID], exercises: [UUID]) {
        switch kind {
        case .completeSet(let id, _, _, _, _), .uncompleteSet(let id), .updateSet(let id, _, _, _, _),
             .adjustLoad(let id, _), .startHold(let id), .endHold(let id):
            return ([id], [])
        case .skipExercise(let id, _), .completeExercise(let id), .focusExercise(let id), .addSet(let id, _),
             .substituteExercise(let id, _), .reorderExercise(let id, _):
            return ([], [id])
        case .addExercise(_, let after):
            return ([], after.map { [$0] } ?? [])
        default:
            return ([], [])
        }
    }

    /// Troca os IDs de série/exercício de um comando; `nil` se algum não tem correspondente.
    static func remap(_ kind: SessionCommand.Kind, sets: [UUID: UUID], exercises: [UUID: UUID]) -> SessionCommand.Kind? {
        switch kind {
        case .completeSet(let id, let r, let l, let d, let m):
            return sets[id].map { .completeSet(setID: $0, reps: r, load: l, durationSeconds: d, distanceMeters: m) }
        case .uncompleteSet(let id): return sets[id].map { .uncompleteSet(setID: $0) }
        case .updateSet(let id, let r, let l, let d, let m):
            return sets[id].map { .updateSet(setID: $0, reps: r, load: l, durationSeconds: d, distanceMeters: m) }
        case .adjustLoad(let id, let delta): return sets[id].map { .adjustLoad(setID: $0, delta: delta) }
        case .startHold(let id): return sets[id].map { .startHold(setID: $0) }
        case .endHold(let id): return sets[id].map { .endHold(setID: $0) }
        case .skipExercise(let id, let reason): return exercises[id].map { .skipExercise(exerciseID: $0, reason: reason) }
        case .completeExercise(let id): return exercises[id].map { .completeExercise(exerciseID: $0) }
        case .focusExercise(let id): return exercises[id].map { .focusExercise(exerciseID: $0) }
        case .addSet(let id, let kind): return exercises[id].map { .addSet(exerciseID: $0, kind: kind) }
        case .substituteExercise(let id, let with):
            return exercises[id].map { .substituteExercise(exerciseID: $0, withCatalogExerciseID: with) }
        case .reorderExercise(let id, let to): return exercises[id].map { .reorderExercise(exerciseID: $0, toIndex: to) }
        case .addExercise(let catalog, let after):
            guard let after else { return kind }
            return exercises[after].map { .addExercise(catalogExerciseID: catalog, afterExerciseID: $0) }
        default: return kind
        }
    }

    /// Chegou o 1º snapshot de uma sessão iniciada aqui: remapeia (por posição) e envia o que estava retido.
    private func releaseHeldCommands(for snapshot: SessionSnapshot) {
        let heldIndices = pending.indices.filter { pending[$0].isHeld && pending[$0].command.sessionID == snapshot.sessionID }
        guard !heldIndices.isEmpty else { return }
        var setMap: [UUID: UUID] = [:], exerciseMap: [UUID: UUID] = [:]
        for exercise in snapshot.exercises {
            exerciseMap[exercise.id] = exercise.id
            for set in exercise.sets { setMap[set.id] = set.id }
        }
        if let baseline = startBaselines[snapshot.sessionID] {
            for (ei, local) in baseline.exercises.enumerated() where snapshot.exercises.indices.contains(ei) {
                let real = snapshot.exercises[ei]
                if exerciseMap[local.id] == nil { exerciseMap[local.id] = real.id }
                for (si, localSet) in local.sets.enumerated() where real.sets.indices.contains(si) {
                    if setMap[localSet.id] == nil { setMap[localSet.id] = real.sets[si].id }
                }
            }
        }
        var dropped: [UUID] = []
        for index in heldIndices {
            if let kind = Self.remap(pending[index].command.kind, sets: setMap, exercises: exerciseMap) {
                pending[index].command.kind = kind
                pending[index].isHeld = false
                transmit(index)
            } else {
                dropped.append(pending[index].id)
            }
        }
        pending.removeAll { dropped.contains($0.id) }
        startBaselines[snapshot.sessionID] = nil
        if !dropped.isEmpty { show(notice: "Atualizado pelo iPhone") }
    }

    /// Descarta pendentes que citam séries/exercícios que o snapshot da sessão não tem (o iPhone os recusaria).
    private func pruneCommandsWithUnknownIDs(in snapshot: SessionSnapshot) {
        guard snapshot.status == .active || snapshot.status == .paused else { return }
        let sets = Set(snapshot.exercises.flatMap(\.sets).map(\.id))
        let exercises = Set(snapshot.exercises.map(\.id))
        let before = pending.count
        pending.removeAll { item in
            guard item.command.sessionID == snapshot.sessionID, item.ackedRevision == nil else { return false }
            let ids = Self.referencedIDs(item.command.kind)
            return !ids.sets.allSatisfy(sets.contains) || !ids.exercises.allSatisfy(exercises.contains)
        }
        if pending.count != before { show(notice: "Atualizado pelo iPhone") }
    }

    // MARK: Comandos

    /// Emite um comando: aplica na hora (otimista), guarda na fila e envia (ou retém, ver A1). `nil` se não há sessão alvo.
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
        let held = !kind.isStart && confirmed?.sessionID != sessionID
        pending.append(PendingCommand(command: command, isHeld: held))
        if kind.isStart, let baseline = SessionReducer.apply(command, to: nil, digest: digest) { startBaselines[sessionID] = baseline }
        recompute()
        if !held, let index = pending.firstIndex(where: { $0.id == command.commandID }) { transmit(index) }
        return command
    }

    func startSession(routineID: UUID) {
        guard !hasActiveSession, !pending.contains(where: { $0.command.kind.isStart }) else { return }
        summary = nil
        send(.start(routineID: routineID))
    }

    /// Conclui a série atual com a carga exibida. Isométrico/cardio podem passar a duração medida.
    func completeCurrentSet(durationSeconds: Double? = nil) {
        guard let set = currentSet, !set.isCompleted else { return }
        var duration = durationSeconds
        if duration == nil, currentExercise?.measurementKind == .timeOrDistance {
            duration = cardioElapsed(setID: set.id, at: now)
        }
        send(.completeSet(setID: set.id, reps: nil, load: nil, durationSeconds: duration, distanceMeters: nil))
        haptics.play(.setCompleted)
    }

    /// Registra reps realizadas (botão "+ reps"): mantém a carga exibida. Reps são opcionais (D2).
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

    /// Começa a sustentação da série `setID` — só se ela ainda é a atual e a sessão está ativa (contagem cancelável).
    func startHold(setID: UUID) {
        guard display?.status == .active, currentSet?.id == setID else { return }
        send(.startHold(setID: setID))
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

    /// "Salvando…" sem iPhone: volta à lista; o `finish` continua na fila.
    func dismissSaving() { savingDismissedSessionID = display?.sessionID }

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
        handleConfirmedTerminal()
    }

    private func didChangeDisplay(from old: SessionSnapshot?, to new: SessionSnapshot?) {
        let wasActive = old.map { $0.status == .active || $0.status == .paused } ?? false
        let isActive = new.map { $0.status == .active || $0.status == .paused } ?? false

        if let new, isActive {
            seenActiveSessionIDs.insert(new.sessionID)
            if activeWorkoutSessionID != new.sessionID {
                if activeWorkoutSessionID != nil { health.workoutDidEnd() }
                activeWorkoutSessionID = new.sessionID
                health.workoutDidBegin(sessionID: new.sessionID, startedAt: new.startedAt)
                introExerciseID = nil
            }
        }
        // Saiu da sessão sem ser por fim otimista (start rejeitado, snapshot nil, outra sessão): encerra o treino do Saúde.
        // Fim otimista (`finish`/`discard` pendente) espera a confirmação (`handleConfirmedTerminal`).
        if wasActive, !isActive, new?.status != .finished, new?.status != .discarded { endWorkout() }

        // Próximo exercício começou porque o anterior fechou (não por escolha do usuário).
        if let old, let new, isActive, old.sessionID == new.sessionID,
           let previousID = old.currentExerciseID, let nextID = new.currentExerciseID, previousID != nextID,
           let previous = new.exercises.first(where: { $0.id == previousID }),
           [.completed, .partial, .skipped].contains(previous.status),
           old.exercises.first(where: { $0.id == previousID })?.status != previous.status {
            introExerciseID = nextID
        }
        if !isActive { introExerciseID = nil }

        if let new, isActive, let exercise = new.currentExercise, exercise.measurementKind == .timeOrDistance,
           let set = exercise.sets.first(where: { $0.id == new.currentSetID }), !set.isCompleted,
           cardioStartElapsed[set.id] == nil {
            cardioStartElapsed[set.id] = new.elapsed(at: now)
        }

        observeRest(old: old, new: new)
    }

    /// Fim da sessão só vale quando o snapshot **confirmado** é terminal (A2).
    private func handleConfirmedTerminal() {
        guard let confirmed, confirmed.status == .finished || confirmed.status == .discarded,
              handledTerminalSessionIDs.insert(confirmed.sessionID).inserted else { return }
        closedSessionIDs.insert(confirmed.sessionID)
        if activeWorkoutSessionID == confirmed.sessionID { endWorkout() }
        if confirmed.status == .finished, seenActiveSessionIDs.contains(confirmed.sessionID), summary == nil {
            summary = makeSummary(confirmed)
        }
    }

    private func endWorkout() {
        guard activeWorkoutSessionID != nil else { return }
        activeWorkoutSessionID = nil
        health.workoutDidEnd()
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
