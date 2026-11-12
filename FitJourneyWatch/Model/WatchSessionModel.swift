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

/// Alerta de fim de descanso (DESIGN §9.4 "Descanso concluído"): tela cheia + laço háptico até o usuário interagir.
struct WatchRestAlert: Equatable, Sendable {
    /// Fim do descanso (a data do snapshot): a tela conta "+0:12" a partir daqui.
    var endedAt: Date
    /// O laço háptico ainda toca; para em qualquer interação ou no teto (`WatchRestAlertPattern.ceiling`).
    var isRinging: Bool
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
/// - Poda por `appliedCommandIDs` (v2): o snapshot lista os comandos que já contém; esses saem da fila mesmo
///   sem a resposta (resposta perdida não reaplica o comando por cima).
///
/// IDs (protocolo v2): o `start` otimista usa `WatchLinkIDs` — os mesmos IDs que o iPhone grava —, então os
/// comandos seguintes saem na hora, sem reter nem remapear. Pendentes que citam série/exercício que o snapshot
/// confirmado não tem são descartados com aviso (`pruneCommandsWithUnknownIDs`).
///
/// Coalescência da Coroa: `adjustLoad` fica `loadCoalesceInterval` sem enviar; outro `adjustLoad` da mesma série
/// nesse intervalo soma no mesmo comando (mesmo `commandID`, nunca enviado — seguro). Qualquer outro comando
/// envia antes o que estiver esperando (ordem preservada).
///
/// Quem grava o treino no Saúde (`WatchWorkoutStatus`): sessão iniciada aqui → o relógio grava; sessão iniciada
/// no iPhone → o relógio só controla, e oferece "gravar no relógio" (`canOfferWatchRecording`,
/// `startRecordingOnWatch()`, ou `recordingRequest` do iPhone). FC/energia vão ao iPhone (`.liveMetrics`).
///
/// Fim do descanso (`restAlert`): com o alerta insistente ligado (`SessionSnapshot.restAlertRepeat`, preferência
/// `fj.restAlertRepeat` do iPhone; ausente = ligado) o fim do descanso abre a tela "Descanso concluído" e toca
/// `WatchRestAlertPattern` em laço até `silenceRestAlert()` (qualquer toque/Coroa — não envia comando),
/// `startSetAfterRest()` ("Começar série": fecha a tela e dispensa o descanso vencido com `skipRest`) ou o teto
/// de 60 s contado do fim do descanso (o alerta fecha e a sessão volta com o aviso "Descanso concluído"). Sessão
/// esquecida (`staleSessionSince`) nunca abre nem mantém o alerta. O alerta some sozinho se o descanso dele deixar
/// de ser o da sessão (pulado/ajustado/nova série em outro aparelho, pausa, fim). Desligado: uma vibração e
/// "Descanso concluído" por 2 s (`restFinishedAt`). O laço roda enquanto o app roda: com o pulso abaixado isso
/// exige a `HKWorkoutSession` do relógio (sessão gravada aqui); sem ela o watchOS suspende o app e o laço só
/// continua (dentro do teto) quando a tela volta.
///
/// Pontos de injeção: `WatchTransport` (WatchConnectivity + canal da `HKWorkoutSession`) e
/// `WatchHealthProvider` (`HKWorkoutSession` do relógio); ver os protocolos.
@MainActor @Observable
final class WatchSessionModel {
    struct PendingCommand: Equatable, Identifiable, Sendable {
        var command: SessionCommand
        /// Revisão devolvida pelo iPhone quando aplicou; `nil` = sem resposta ainda.
        var ackedRevision: Int?
        var lastSentAt: Date?
        /// `adjustLoad` ainda não enviado, esperando outros da mesma série até esta data (coalescência).
        var holdUntil: Date?
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
    /// Quando o descanso acabou — só com o alerta insistente desligado ("Descanso concluído" por 2 s).
    var restFinishedAt: Date?
    /// Alerta insistente de fim de descanso em curso (`nil` = sem alerta).
    private(set) var restAlert: WatchRestAlert?
    var liveMetrics = WatchLiveMetrics.empty
    var healthAccess: WatchHealthAccess
    /// Sessão cujo treino o relógio está gravando no Saúde (`nil` = só controle).
    private(set) var recordingSessionID: UUID?

    // MARK: Dependências (injeção)

    @ObservationIgnored let transport: any WatchTransport
    @ObservationIgnored let haptics: any WatchHaptics
    @ObservationIgnored let health: any WatchHealthProvider
    @ObservationIgnored private let clock: @MainActor () -> Date
    /// Espera por resposta antes de reenviar um comando; espera máxima por um snapshot pedido.
    @ObservationIgnored var resendInterval: TimeInterval = 5
    @ObservationIgnored var snapshotTimeout: TimeInterval = 10
    /// Janela de coalescência dos `adjustLoad` da Coroa (0 = envia cada um na hora).
    @ObservationIgnored var loadCoalesceInterval: TimeInterval = 0.35
    /// Intervalo mínimo entre envios de métricas ao iPhone.
    @ObservationIgnored var metricsInterval: TimeInterval = 2
    /// Intervalo entre os pulsos do alerta de fim de descanso e teto contado do fim do descanso.
    @ObservationIgnored var restAlertInterval: TimeInterval = WatchRestAlertPattern.interval
    @ObservationIgnored var restAlertCeiling: TimeInterval = WatchRestAlertPattern.ceiling

    @ObservationIgnored private var closedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var handledTerminalSessionIDs: Set<UUID> = []
    @ObservationIgnored private var seenActiveSessionIDs: Set<UUID> = []
    @ObservationIgnored private var staleAcknowledgedSessionID: UUID?
    @ObservationIgnored private var savingDismissedSessionID: UUID?
    /// Sessões iniciadas aqui ou com "gravar no relógio" pedido: o relógio grava o treino delas.
    @ObservationIgnored private var watchRecordedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var recordingPaused = false
    @ObservationIgnored private var lastMetricsSentAt: Date?
    @ObservationIgnored private var cardioStartElapsed: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var awaitingSince: Date?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var observedRest: (end: Date?, status: SessionSnapshot.Status?) = (nil, nil)
    @ObservationIgnored private let restAlertLoop = WatchHapticLoop()
    @ObservationIgnored private var restAlertPulses = 0
    /// Fim de descanso já avisado (um aviso por descanso, mesmo que o temporizador dispare de novo).
    @ObservationIgnored private var announcedRestEnd: Date?

    init(transport: any WatchTransport, haptics: any WatchHaptics, health: any WatchHealthProvider = UnavailableHealthProvider(),
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.transport = transport
        self.haptics = haptics
        self.health = health
        self.clock = clock
        self.isPhoneReachable = transport.isReachable
        self.healthAccess = health.access
        health.onMetrics = { [weak self] metrics in self?.receive(metrics: metrics) }
        health.onStatus = { [weak self] status in self?.receive(workoutStatus: status) }
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

    /// Alerta insistente no fim do descanso: preferência do iPhone no snapshot (ausente = ligado).
    var restAlertRepeats: Bool { display?.restAlertRepeat ?? true }

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

    /// Cardio: com cronômetro iniciado (`startHold`, aqui ou no iPhone) é o tempo ativo dele; senão, o tempo ativo
    /// desde que a série passou a ser a atual. As pausas não contam nos dois casos.
    func cardioElapsed(setID: UUID, at date: Date) -> TimeInterval {
        guard let display else { return 0 }
        if display.holdSetID == setID, let elapsed = display.holdElapsed(at: date) { return elapsed }
        guard let start = cardioStartElapsed[setID] else { return 0 }
        return max(0, display.elapsed(at: date) - start)
    }

    /// Há sessão em andamento que o relógio não grava e o Saúde não foi negado: dá para oferecer "gravar no relógio".
    var canOfferWatchRecording: Bool {
        guard let display, hasActiveSession, healthAccess != .denied else { return false }
        return recordingSessionID != display.sessionID
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
        clearRestAlert()
    }

    func requestSnapshot() {
        isAwaitingSnapshot = true
        awaitingSince = now
        transport.send(.snapshotRequest)
    }

    /// Reenvia comandos sem resposta há `resendInterval` (resposta perdida), envia `adjustLoad` coalescidos vencidos
    /// e abandona pedido de snapshot sem retorno.
    func retryStalePending() {
        // Alerta de descanso nunca fica por baixo da tela "Treino em aberto".
        if restAlert != nil, staleSessionSince != nil { clearRestAlert() }
        if pending.contains(where: { $0.lastSentAt == nil && ($0.holdUntil ?? .distantFuture) <= now }) { flushCoalescedCommands() }
        guard isPhoneReachable else { return }
        var resent = false
        for index in pending.indices where pending[index].ackedRevision == nil && pending[index].lastSentAt != nil {
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
                for index in pending.indices where pending[index].ackedRevision == nil { transmit(index) }
                requestSnapshot()
            }
        case .message(let message):
            handle(message)
        }
    }

    func handle(_ message: WatchLinkMessage) {
        if case .incompatible = message {} else { incompatibility = nil } // mensagem válida: versões se entendem
        switch message {
        case .snapshot(let snapshot): receive(snapshot: snapshot)
        case .commandReply(let reply): receive(reply: reply)
        case .programDigest(let digest): receive(digest: digest)
        case .incompatible(let compatibility): incompatibility = compatibility
        case .recordingRequest(let sessionID):
            if display?.sessionID == sessionID { startRecordingOnWatch() }
        case .command, .snapshotRequest, .liveMetrics, .workoutStatus: break // mensagens do relógio para o iPhone
        }
    }

    private func transmit(_ index: Int) {
        pending[index].lastSentAt = now
        pending[index].holdUntil = nil
        transport.send(.command(pending[index].command))
    }

    /// Envia já os `adjustLoad` que estavam esperando a coalescência (o `.task` de 1 s e os testes também chamam).
    func flushCoalescedCommands() {
        coalesceTask?.cancel()
        coalesceTask = nil
        for index in pending.indices where pending[index].lastSentAt == nil && pending[index].holdUntil != nil {
            transmit(index)
        }
    }

    private func scheduleCoalesceFlush() {
        coalesceTask?.cancel()
        let delay = loadCoalesceInterval
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushCoalescedCommands()
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
        pruneAppliedCommands(in: snapshot)
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
            show(notice: String(localized: "Atualizado pelo iPhone"))
            requestSnapshot()
        }
        recompute()
    }

    // MARK: Poda da fila

    /// IDs referenciados por um comando: (séries, exercícios).
    static func referencedIDs(_ kind: SessionCommand.Kind) -> (sets: [UUID], exercises: [UUID]) {
        switch kind {
        case .completeSet(let id, _, _, _, _), .uncompleteSet(let id), .updateSet(let id, _, _, _, _),
             .adjustLoad(let id, _), .startHold(let id), .endHold(let id), .updateHoldTarget(let id, _),
             .updateCardio(let id, _, _, _), .removeSet(let id), .changeSetKind(let id, _):
            return ([id], [])
        case .skipExercise(let id, _), .completeExercise(let id), .focusExercise(let id), .addSet(let id, _),
             .substituteExercise(let id, _), .reorderExercise(let id, _), .setExerciseNote(let id, _), .setPain(let id, _, _):
            return ([], [id])
        case .addExercise(_, let after):
            return ([], after.map { [$0] } ?? [])
        default:
            return ([], [])
        }
    }

    /// O snapshot já contém os comandos de `appliedCommandIDs`: saem da fila (mesmo sem resposta).
    private func pruneAppliedCommands(in snapshot: SessionSnapshot) {
        guard !snapshot.appliedCommandIDs.isEmpty else { return }
        let applied = Set(snapshot.appliedCommandIDs)
        pending.removeAll { $0.command.sessionID == snapshot.sessionID && applied.contains($0.id) }
    }

    /// Descarta pendentes que citam séries/exercícios que o snapshot da sessão não tem (o iPhone os recusaria).
    private func pruneCommandsWithUnknownIDs(in snapshot: SessionSnapshot) {
        guard snapshot.status == .active || snapshot.status == .paused else { return }
        var sets = Set(snapshot.exercises.flatMap(\.sets).map(\.id))
        var exercises = Set(snapshot.exercises.map(\.id))
        // IDs que `addSet`/`addExercise` ainda pendentes vão criar (mesma derivação do iPhone, `WatchLinkIDs`).
        for item in pending where item.command.sessionID == snapshot.sessionID {
            let created = Self.createdIDs(item.command)
            sets.formUnion(created.sets)
            exercises.formUnion(created.exercises)
        }
        let before = pending.count
        pending.removeAll { item in
            guard item.command.sessionID == snapshot.sessionID, item.ackedRevision == nil else { return false }
            let ids = Self.referencedIDs(item.command.kind)
            return !ids.sets.allSatisfy(sets.contains) || !ids.exercises.allSatisfy(exercises.contains)
        }
        if pending.count != before { show(notice: String(localized: "Atualizado pelo iPhone")) }
    }

    /// Séries/exercícios que um comando cria (IDs determinísticos). `addExercise` cria até
    /// `addedExerciseSetCount` séries (o padrão do iPhone).
    static func createdIDs(_ command: SessionCommand) -> (sets: [UUID], exercises: [UUID]) {
        switch command.kind {
        case .addSet:
            return ([WatchLinkIDs.extraSetID(sessionID: command.sessionID, commandID: command.commandID)], [])
        case .addExercise:
            let sets = (0..<addedExerciseSetCount).map {
                WatchLinkIDs.addedSetID(sessionID: command.sessionID, commandID: command.commandID, index: $0)
            }
            return (sets, [WatchLinkIDs.addedExerciseID(sessionID: command.sessionID, commandID: command.commandID)])
        default:
            return ([], [])
        }
    }

    /// Séries que o `SessionStore.addExercise` cria por padrão.
    static let addedExerciseSetCount = 3

    // MARK: Comandos

    /// Emite um comando: aplica na hora (otimista), guarda na fila e envia (`adjustLoad` espera a coalescência).
    /// `nil` se não há sessão alvo.
    @discardableResult
    func send(_ kind: SessionCommand.Kind) -> SessionCommand? { send(kind, sessionID: nil) }

    @discardableResult
    private func send(_ kind: SessionCommand.Kind, sessionID startID: UUID?) -> SessionCommand? {
        let sessionID: UUID
        if kind.isStart {
            sessionID = startID ?? UUID()
        } else if let id = display?.sessionID {
            sessionID = id
        } else {
            return nil
        }
        let coalesces = loadCoalesceInterval > 0
        if case .adjustLoad(let setID, let delta) = kind, coalesces, let last = pending.indices.last,
           pending[last].lastSentAt == nil, pending[last].command.sessionID == sessionID,
           case .adjustLoad(let lastSetID, let lastDelta) = pending[last].command.kind, lastSetID == setID {
            // Mesmo comando (nunca enviado): soma o delta.
            let total = lastDelta + delta
            pending[last].command.kind = .adjustLoad(setID: setID, delta: total)
            pending[last].command.issuedAt = now
            pending[last].holdUntil = now.addingTimeInterval(loadCoalesceInterval)
            let merged = pending[last].command
            if abs(total) < WatchLoadStepping.step / 2 { pending.remove(at: last) }
            recompute()
            scheduleCoalesceFlush()
            return merged
        }
        flushCoalescedCommands() // o que esperava sai antes (ordem)
        let command = SessionCommand(sessionID: sessionID, issuedAt: now, origin: .watch, kind: kind)
        var item = PendingCommand(command: command)
        if case .adjustLoad = kind, coalesces { item.holdUntil = now.addingTimeInterval(loadCoalesceInterval) }
        pending.append(item)
        recompute()
        if item.holdUntil != nil {
            scheduleCoalesceFlush()
        } else if let index = pending.firstIndex(where: { $0.id == command.commandID }) {
            transmit(index)
        }
        return command
    }

    func startSession(routineID: UUID) {
        guard !hasActiveSession, !pending.contains(where: { $0.command.kind.isStart }) else { return }
        summary = nil
        // Iniciada aqui → o relógio grava o treino (se o Saúde não foi negado). Marcada antes do envio para o
        // `workoutStatus(.recording)` sair antes do `start` (o iPhone nem liga a gravação dele).
        let sessionID = UUID()
        watchRecordedSessionIDs.insert(sessionID)
        send(.start(routineID: routineID), sessionID: sessionID)
    }

    /// "Gravar no relógio" a sessão em andamento (iniciada no iPhone): FC/energia do relógio; o iPhone descarta a dele.
    func startRecordingOnWatch() {
        guard canOfferWatchRecording, let display else { return }
        watchRecordedSessionIDs.insert(display.sessionID)
        beginRecordingIfNeeded(display)
    }

    /// Cardio: inicia o cronômetro da série atual (o iPhone vê o mesmo; a pausa não conta).
    func startCardio() {
        guard display?.status == .active, let set = currentSet, !set.isCompleted,
              currentExercise?.measurementKind == .timeOrDistance, display?.holdSetID == nil else { return }
        send(.startHold(setID: set.id))
    }

    /// Conclui a série atual com a carga exibida. Isométrico/cardio podem passar a duração medida.
    func completeCurrentSet(durationSeconds: Double? = nil) {
        guard let set = currentSet, !set.isCompleted else { return }
        if durationSeconds == nil, display?.holdSetID == set.id {
            // Cronômetro/sustentação em curso: o fim vale como medição (sem as pausas).
            send(.endHold(setID: set.id))
            haptics.play(.setCompleted)
            return
        }
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
        haptics.play(.stopped)
    }

    func resume() {
        guard display?.status == .paused else { return }
        send(.resume)
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

    // MARK: Saúde (gravação no relógio)

    private func receive(metrics: WatchLiveMetrics) {
        liveMetrics = metrics
        guard let sessionID = recordingSessionID else { return }
        if let last = lastMetricsSentAt, now.timeIntervalSince(last) < metricsInterval { return }
        lastMetricsSentAt = now
        transport.send(.liveMetrics(WatchLiveMetricsPayload(sessionID: sessionID, date: now,
                                                            heartRate: metrics.heartRate.map(Double.init),
                                                            activeKilocalories: metrics.activeKilocalories)))
    }

    private func receive(workoutStatus status: WatchWorkoutStatus) {
        switch status.state {
        case .notRecording, .failed:
            // Não grava (sem permissão/falhou): o iPhone grava; o relógio volta a oferecer.
            if recordingSessionID == status.sessionID {
                recordingSessionID = nil
                watchRecordedSessionIDs.remove(status.sessionID)
            }
        case .saved:
            // Gravado (inclusive fim externo do treino com a sessão ainda aberta): não reinicia outra gravação.
            if recordingSessionID == status.sessionID { recordingSessionID = nil }
            watchRecordedSessionIDs.remove(status.sessionID)
        case .recording:
            break
        }
        transport.send(.workoutStatus(status))
    }

    /// Começa a gravar a sessão exibida se ela é das que o relógio grava e ainda não grava.
    private func beginRecordingIfNeeded(_ snapshot: SessionSnapshot?) {
        guard let snapshot, snapshot.status == .active || snapshot.status == .paused,
              watchRecordedSessionIDs.contains(snapshot.sessionID) || health.activeWorkoutSessionID == snapshot.sessionID,
              recordingSessionID != snapshot.sessionID, healthAccess != .denied else { return }
        if recordingSessionID != nil { endWorkout(final: nil) }
        recordingSessionID = snapshot.sessionID
        recordingPaused = snapshot.status == .paused
        lastMetricsSentAt = nil
        health.workoutDidBegin(WatchWorkoutContext(sessionID: snapshot.sessionID, startedAt: snapshot.startedAt,
                                                   routineName: snapshot.routineName, workoutType: snapshot.workoutType,
                                                   pausedAt: snapshot.pausedAt))
    }

    /// Reavalia a gravação da sessão exibida (ex.: o provedor recuperou um treino depois de o app ser encerrado).
    func reevaluateRecording() {
        beginRecordingIfNeeded(display)
        syncRecordingPause(display)
    }

    /// Pausa/retomada da gravação seguem a sessão exibida (pausas feitas no iPhone também).
    private func syncRecordingPause(_ snapshot: SessionSnapshot?) {
        guard let snapshot, snapshot.sessionID == recordingSessionID else { return }
        if snapshot.status == .paused, !recordingPaused {
            recordingPaused = true
            health.workoutDidPause(at: snapshot.pausedAt ?? now)
        } else if snapshot.status == .active, recordingPaused {
            recordingPaused = false
            health.workoutDidResume(at: now)
        }
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
            if seenActiveSessionIDs.insert(new.sessionID).inserted { introExerciseID = nil }
            // Outra sessão ativa: a gravação anterior acaba sem gravar.
            if let recording = recordingSessionID, recording != new.sessionID { endWorkout(final: nil) }
            beginRecordingIfNeeded(new)
            syncRecordingPause(new)
        }
        // Saiu da sessão sem ser por fim otimista (start rejeitado, snapshot nil, outra sessão): encerra o treino do Saúde.
        // Fim otimista (`finish`/`discard` pendente) espera a confirmação (`handleConfirmedTerminal`).
        if wasActive, !isActive, new?.status != .finished, new?.status != .discarded { endWorkout(final: nil) }

        // Próximo exercício começou porque o anterior fechou (não por escolha do usuário).
        if let old, let new, isActive, old.sessionID == new.sessionID,
           let previousID = old.currentExerciseID, let nextID = new.currentExerciseID, previousID != nextID,
           let previous = new.exercises.first(where: { $0.id == previousID }),
           [.completed, .partial, .skipped].contains(previous.status),
           old.exercises.first(where: { $0.id == previousID })?.status != previous.status {
            introExerciseID = nextID
        }
        if !isActive { introExerciseID = nil }
        reconcileRestAlert(with: new)

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
        if recordingSessionID == confirmed.sessionID { endWorkout(final: confirmed) }
        if confirmed.status == .finished, seenActiveSessionIDs.contains(confirmed.sessionID), summary == nil {
            summary = makeSummary(confirmed)
        }
    }

    private func endWorkout(final: SessionSnapshot?) {
        guard recordingSessionID != nil else { return }
        recordingSessionID = nil
        recordingPaused = false
        health.workoutDidEnd(final: final)
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
        if let total = new.restTotalSeconds {
            restTotalSeconds = max(1, total) // v2: o iPhone/redutor informa o total (com ajustes)
        } else if let oldEnd, oldEnd > now {
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

    /// Fim do descanso (uma vez por descanso). Alerta insistente ligado: tela "Descanso concluído" + laço háptico
    /// até uma interação ou o teto; desligado: um háptico forte e o aviso de 2 s.
    func restDidEnd(at end: Date) {
        guard let display, display.status == .active, display.restEndsAt == end, announcedRestEnd != end else { return }
        announcedRestEnd = end
        guard restAlertRepeats else {
            restFinishedAt = now
            haptics.play(.restEnded)
            return
        }
        restFinishedAt = nil
        restAlertPulses = 0
        // Treino esquecido (a tela "Treino em aberto" tem prioridade e não daria como parar o laço) ou
        // temporizador atrasado além do teto (app suspenso com o pulso abaixado): avisa uma vez, sem tela nem laço.
        guard staleSessionSince == nil, now.timeIntervalSince(end) < restAlertCeiling else {
            playRestAlertPulse()
            show(notice: String(localized: "Descanso concluído"))
            return
        }
        restAlert = WatchRestAlert(endedAt: end, isRinging: true)
        playRestAlertPulse()
        restAlertLoop.start(every: restAlertInterval) { [weak self] in self?.restAlertTick() }
    }

    /// Um passo do laço (o temporizador chama a cada `restAlertInterval`; os testes chamam direto): toca o
    /// próximo pulso; no teto (ou se a sessão virou "treino em aberto") fecha o alerta e volta à sessão com um
    /// aviso discreto.
    func restAlertTick() {
        guard let alert = restAlert, alert.isRinging else {
            restAlertLoop.cancel()
            return
        }
        guard staleSessionSince == nil else {
            clearRestAlert()
            return
        }
        guard now.timeIntervalSince(alert.endedAt) < restAlertCeiling else {
            clearRestAlert()
            show(notice: String(localized: "Descanso concluído"))
            return
        }
        playRestAlertPulse()
    }

    private func playRestAlertPulse() {
        haptics.play(WatchRestAlertPattern.event(forPulse: restAlertPulses))
        restAlertPulses += 1
    }

    /// Qualquer interação (toque na tela, Coroa, ação do VoiceOver): o laço para e a tela fica.
    /// Não envia comando.
    func silenceRestAlert() {
        restAlertLoop.cancel()
        guard restAlert?.isRinging == true else { return }
        restAlert?.isRinging = false
        haptics.cancelPending()
    }

    /// "Começar série": para o laço, fecha a tela e volta à Série (sem a introdução do exercício). O descanso
    /// vencido é dispensado no iPhone (`skipRest`), o que também encerra o alerta de lá.
    func startSetAfterRest() {
        let expired = display.flatMap { $0.status == .active ? $0.restEndsAt : nil }.map { $0 <= now } ?? false
        clearRestAlert()
        restFinishedAt = nil
        introExerciseID = nil
        if expired { send(.skipRest) }
    }

    private func clearRestAlert() {
        restAlertLoop.cancel()
        guard let alert = restAlert else { return }
        if alert.isRinging { haptics.cancelPending() }
        restAlert = nil
    }

    /// O alerta só vale enquanto o descanso dele é o da sessão ativa: pulado, ajustado, série nova (outro
    /// descanso), pausa ou fim — aqui ou no iPhone — encerram o alerta.
    private func reconcileRestAlert(with snapshot: SessionSnapshot?) {
        guard let alert = restAlert else { return }
        if snapshot?.status != .active || snapshot?.restEndsAt != alert.endedAt { clearRestAlert() }
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
