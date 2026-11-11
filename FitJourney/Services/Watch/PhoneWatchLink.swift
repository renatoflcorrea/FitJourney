import Foundation
import Observation
import SwiftData

/// O que o transporte do relógio usa do `HealthWorkoutController` (espelhamento e vínculo do treino). Protocolo
/// para testar o `PhoneWatchLink` sem HealthKit.
@MainActor
protocol WatchHealthBridge: AnyObject {
    var hasRemoteSession: Bool { get }
    var onMirroredSessionDiscarded: ((UUID) -> Void)? { get set }
    func remoteData() -> AsyncStream<Data>
    func sendToRemote(_ data: Data) async throws
    func receiveRemoteMetrics(_ updates: [HealthLiveUpdate])
    func markMirrored(_ sessionID: UUID)
    func unmarkMirrored(_ sessionID: UUID)
    func isMirrored(_ sessionID: UUID) -> Bool
    func adoptRemoteRecording(_ sessionID: UUID)
    @discardableResult func linkWorkout(_ workoutID: UUID?, to sessionID: UUID) -> Bool
    func resumeIfNeeded(sessionID: UUID) async
    func reconcilePendingWorkouts() async
}

extension HealthWorkoutController: WatchHealthBridge {}

/// Transporte do iPhone com o relógio (W2, SPEC §6.4). O iPhone é a fonte de verdade: aplica os comandos do
/// relógio no `SessionEngine` e devolve resposta + snapshots.
///
/// **Canais** (relógio ↔ iPhone, sempre envelopes do `WatchLinkCodec`):
/// - Sessão espelhada conectada (`WatchHealthBridge.hasRemoteSession`): tudo pelo canal de dados da
///   `HKWorkoutSession` (`remoteData()`/`sendToRemote`). Falhou → cai no WatchConnectivity.
/// - Relógio alcançável: `sendMessageData` (o relógio manda comandos com resposta: a resposta é o `commandReply`;
///   no `snapshotRequest`, a resposta é o snapshot).
/// - Fora de alcance: o `applicationContext` guarda o estado mais recente — `ProgramDigest` + último snapshot —
///   e chega quando o relógio acordar. Comandos do relógio offline chegam por `transferUserInfo` (aplicados igual).
///
/// **Snapshots:** assina `SessionEngine.snapshots()`, coalesce `snapshotCoalescing` (250 ms) e envia o mais
/// recente; terminal (`finished`/`discarded`) sai na hora. Comando duplicado/recusado reenvia o snapshot atual.
///
/// **Digest:** no `start()` e a cada gravação do SwiftData (`ModelContext.didSave`, com espera de 1 s) recalcula o
/// `ProgramDigest`; se mudou (ignorando `generatedAt`), atualiza o `applicationContext` e envia se alcançável.
///
/// **Saúde:** `workoutStatus` do relógio → `.recording`: `adoptRemoteRecording` (o iPhone não grava);
/// `.notRecording`: `unmarkMirrored` + volta a gravar no iPhone; `.saved(id)`: `linkWorkout` (repetido até a
/// sessão estar encerrada aqui); `.failed`: `unmarkMirrored` + reconciliação (gravador simples). `liveMetrics` →
/// `receiveRemoteMetrics`. Sessão espelhada descartada (`onMirroredSessionDiscarded`) → o snapshot terminal sai
/// na hora (o relógio encerra a `HKWorkoutSession`).
///
/// **Versão:** mensagem de versão não suportada → responde `.incompatible` (formato estável); aviso recebido do
/// relógio fica em `watchIncompatibility` (a UI pede para atualizar o app do relógio).
@MainActor
@Observable
final class PhoneWatchLink {
    /// Relógio alcançável (WatchConnectivity) ou sessão espelhada conectada.
    private(set) var isWatchReachable = false
    /// Relógio pareado com o app do FitJourney instalado.
    private(set) var isWatchAppInstalled = false
    /// O relógio avisou que não entende nossa versão (ou nós a dele).
    private(set) var watchIncompatibility: WatchLinkCompatibility?
    /// Sessão em andamento cujo treino o relógio está gravando (FC do relógio).
    private(set) var watchRecordingSessionID: UUID?

    @ObservationIgnored let engine: SessionEngine
    @ObservationIgnored private let session: any WatchLinkSession
    @ObservationIgnored private weak var health: (any WatchHealthBridge)?
    @ObservationIgnored private let digestProvider: @MainActor () -> ProgramDigest?
    @ObservationIgnored var snapshotCoalescing: Duration = .milliseconds(250)
    @ObservationIgnored var digestDebounce: Duration = .seconds(1)

    @ObservationIgnored private var lastDigest: ProgramDigest?
    @ObservationIgnored private var hasPublishedDigest = false
    @ObservationIgnored private var pendingSnapshot: SessionSnapshot?
    @ObservationIgnored private var lastSentSnapshot: SessionSnapshot?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var digestTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotListener: Task<Void, Never>?
    @ObservationIgnored private var remoteListener: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?
    /// Treinos do relógio aguardando a sessão encerrar aqui para o vínculo.
    @ObservationIgnored private var pendingLinks: [UUID: UUID] = [:]

    /// - Parameters:
    ///   - health: o `HealthWorkoutController` do app (espelhamento/vínculo); `nil` = sem Saúde.
    ///   - digestProvider: padrão = `ProgramDigestBuilder.make(context: engine.context)`.
    init(engine: SessionEngine, session: any WatchLinkSession = WCWatchLinkSession(), health: (any WatchHealthBridge)? = nil,
         digestProvider: (@MainActor () -> ProgramDigest?)? = nil) {
        self.engine = engine
        self.session = session
        self.health = health
        let context = engine.context
        self.digestProvider = digestProvider ?? { try? ProgramDigestBuilder.make(context: context) }
    }

    // MARK: Ciclo de vida

    /// Ativa o `WCSession`, publica o digest e passa a acompanhar snapshots, o canal espelhado e as gravações.
    /// Idempotente. Chamar no lançamento, depois do `engine.restore()`.
    func start() {
        guard snapshotListener == nil else { return }
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.activate()
        refreshConnection()
        let snapshots = engine.snapshots()
        snapshotListener = Task { [weak self] in
            for await snapshot in snapshots {
                guard let self, !Task.isCancelled else { return }
                self.enqueue(snapshot)
            }
        }
        if let health {
            let data = health.remoteData()
            remoteListener = Task { [weak self] in
                for await packet in data {
                    guard let self, !Task.isCancelled else { return }
                    self.receive(packet, reply: nil, viaRemote: true)
                }
            }
            health.onMirroredSessionDiscarded = { [weak self] _ in self?.flushSnapshot() }
        }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDigestRefresh() }
        }
        refreshDigest()
    }

    func stop() {
        snapshotListener?.cancel(); snapshotListener = nil
        remoteListener?.cancel(); remoteListener = nil
        flushTask?.cancel(); flushTask = nil
        digestTask?.cancel(); digestTask = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        session.onEvent = nil
    }

    /// Recalcula o digest agora e publica se mudou (o app pode chamar depois de editar programas).
    func refreshDigest() {
        digestTask?.cancel()
        digestTask = nil
        let digest = digestProvider()
        guard !hasPublishedDigest || !Self.sameContent(digest, lastDigest) else { return }
        hasPublishedDigest = true
        lastDigest = digest
        updateContext()
        if session.isReachable { sendByConnectivity(.programDigest(digest)) }
    }

    /// "Gravar no relógio" a sessão em andamento (iniciada no iPhone): pede ao relógio para iniciar a
    /// `HKWorkoutSession` dele (FC do relógio). O relógio confirma com `workoutStatus(.recording)`.
    @discardableResult
    func requestWatchRecording() -> Bool {
        guard let sessionID = engine.activeSessionID, isWatchReachable else { return false }
        send(.recordingRequest(sessionID: sessionID))
        return true
    }

    /// Dá para oferecer "gravar no relógio": sessão em andamento que o relógio não grava, com o relógio alcançável.
    var canRequestWatchRecording: Bool {
        guard let sessionID = engine.activeSessionID else { return false }
        return isWatchReachable && watchRecordingSessionID != sessionID
    }

    // MARK: Recepção

    private func handle(_ event: WatchLinkSessionEvent) {
        switch event {
        case .activated, .reachability:
            refreshConnection()
        case .message(let data, let reply):
            receive(data, reply: reply, viaRemote: false)
        case .userInfo(let data):
            receive(data, reply: nil, viaRemote: false)
        case .context:
            break // o relógio não publica contexto
        }
    }

    private func refreshConnection() {
        let reachable = session.isReachable || health?.hasRemoteSession == true
        let wasReachable = isWatchReachable
        isWatchReachable = reachable
        isWatchAppInstalled = session.isCounterpartInstalled
        // Voltou ao alcance: o estado atual vai na hora (o relógio também pede, mas não custa).
        if reachable, !wasReachable, let snapshot = engine.snapshot, snapshot != lastSentSnapshot { enqueue(snapshot) }
    }

    /// Mensagem do relógio (WatchConnectivity ou canal espelhado). `reply` = o relógio espera resposta.
    func receive(_ data: Data, reply: WatchLinkReply?, viaRemote: Bool) {
        let message: WatchLinkMessage
        do {
            message = try WatchLinkCodec.decode(data)
        } catch WatchLinkCodecError.unsupportedVersion {
            if let notice = try? WatchLinkCodec.incompatibilityNotice() { respond(raw: notice, reply: reply, viaRemote: viaRemote) }
            return
        } catch {
            reply?(Data())
            return
        }
        switch message {
        case .command(let command):
            handle(command, reply: reply, viaRemote: viaRemote)
        case .snapshotRequest:
            respond(.snapshot(engine.snapshot), reply: reply, viaRemote: viaRemote)
            if engine.snapshot != nil { lastSentSnapshot = engine.snapshot }
            send(.programDigest(lastDigest ?? digestProvider()))
        case .liveMetrics(let payload):
            reply?(Data())
            receive(metrics: payload)
        case .workoutStatus(let status):
            reply?(Data())
            receive(workoutStatus: status)
        case .incompatible(let compatibility):
            reply?(Data())
            watchIncompatibility = compatibility
        case .commandReply, .snapshot, .programDigest, .recordingRequest:
            reply?(Data()) // mensagens do iPhone para o relógio
        }
    }

    private func handle(_ command: SessionCommand, reply: WatchLinkReply?, viaRemote: Bool) {
        let result = engine.apply(command)
        let answer = result.reply(to: command, currentRevision: engine.snapshot?.revision ?? 0)
        respond(.commandReply(answer), reply: reply, viaRemote: viaRemote)
        if !result.isApplied {
            // Duplicado/recusado: o relógio reconcilia com o estado atual.
            if let snapshot = engine.snapshot { enqueue(snapshot, force: true) }
            else if case .rejected = result { send(.snapshot(nil)) }
        }
        retryPendingLinks()
    }

    private func receive(metrics payload: WatchLiveMetricsPayload) {
        guard let health, payload.sessionID == engine.activeSessionID else { return }
        var updates: [HealthLiveUpdate] = []
        if let bpm = payload.heartRate, bpm > 0 { updates.append(.heartRate(HeartRateSample(date: payload.date, bpm: bpm))) }
        if let kcal = payload.activeKilocalories { updates.append(.activeEnergy(kilocalories: kcal)) }
        if !updates.isEmpty { health.receiveRemoteMetrics(updates) }
    }

    private func receive(workoutStatus status: WatchWorkoutStatus) {
        let sessionID = status.sessionID
        switch status.state {
        case .recording:
            watchRecordingSessionID = sessionID
            health?.adoptRemoteRecording(sessionID)
        case .notRecording:
            if watchRecordingSessionID == sessionID { watchRecordingSessionID = nil }
            guard let health, health.isMirrored(sessionID), !health.hasRemoteSession else { return }
            health.unmarkMirrored(sessionID)
            Task { await health.resumeIfNeeded(sessionID: sessionID) }
        case .saved(let workoutID):
            if watchRecordingSessionID == sessionID { watchRecordingSessionID = nil }
            pendingLinks[sessionID] = workoutID
            retryPendingLinks()
        case .failed:
            if watchRecordingSessionID == sessionID { watchRecordingSessionID = nil }
            guard let health else { return }
            health.unmarkMirrored(sessionID)
            Task { await health.reconcilePendingWorkouts() }
        }
    }

    /// `linkWorkout` só vale com a sessão encerrada aqui (o `finish` pode chegar depois do treino gravado).
    private func retryPendingLinks() {
        guard let health, !pendingLinks.isEmpty else { return }
        for (sessionID, workoutID) in pendingLinks where health.linkWorkout(workoutID, to: sessionID) {
            pendingLinks[sessionID] = nil
        }
    }

    // MARK: Snapshots

    private func enqueue(_ snapshot: SessionSnapshot, force: Bool = false) {
        pendingSnapshot = snapshot
        if snapshot.status == .finished || snapshot.status == .discarded || force {
            flushSnapshot()
            if snapshot.status == .finished { retryPendingLinks() }
            return
        }
        guard flushTask == nil else { return }
        let delay = snapshotCoalescing
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushSnapshot()
        }
    }

    /// Envia já o snapshot mais recente (ou o terminal recém-publicado).
    func flushSnapshot() {
        flushTask?.cancel()
        flushTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        lastSentSnapshot = snapshot
        updateContext(snapshot: snapshot)
        send(.snapshot(snapshot))
    }

    // MARK: Envio

    /// Melhor canal disponível: espelhado → mensagem (se alcançável). Fora de alcance o `applicationContext` já
    /// carrega o estado; o relógio reenvia comandos sem resposta.
    private func send(_ message: WatchLinkMessage) {
        guard let data = try? WatchLinkCodec.encode(message) else { return }
        if let health, health.hasRemoteSession {
            Task { [weak self] in
                do {
                    try await health.sendToRemote(data)
                } catch {
                    self?.sendByConnectivity(data)
                }
            }
            return
        }
        sendByConnectivity(data)
    }

    private func sendByConnectivity(_ message: WatchLinkMessage) {
        guard let data = try? WatchLinkCodec.encode(message) else { return }
        sendByConnectivity(data)
    }

    private func sendByConnectivity(_ data: Data) {
        guard session.isReachable else { return }
        session.sendMessage(data, reply: nil) {}
    }

    private func respond(_ message: WatchLinkMessage, reply: WatchLinkReply?, viaRemote: Bool) {
        guard let data = try? WatchLinkCodec.encode(message) else {
            reply?(Data())
            return
        }
        respond(raw: data, reply: reply, viaRemote: viaRemote)
    }

    private func respond(raw data: Data, reply: WatchLinkReply?, viaRemote: Bool) {
        if let reply {
            reply(data)
        } else if viaRemote, let health {
            Task { [weak self] in
                do { try await health.sendToRemote(data) } catch { self?.sendByConnectivity(data) }
            }
        } else {
            sendByConnectivity(data)
        }
    }

    /// `applicationContext` = digest + último snapshot (estado mais recente para o relógio fora de alcance).
    private func updateContext(snapshot: SessionSnapshot? = nil) {
        var context: [String: Data] = [:]
        if let digest = try? WatchLinkCodec.encode(.programDigest(lastDigest)) { context[WatchLinkSessionKey.digest] = digest }
        let current = snapshot ?? lastSentSnapshot
        if let data = try? WatchLinkCodec.encode(.snapshot(current)) { context[WatchLinkSessionKey.snapshot] = data }
        try? session.updateContext(context)
    }

    private func scheduleDigestRefresh() {
        guard digestTask == nil else { return }
        let delay = digestDebounce
        digestTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.digestTask = nil
            self?.refreshDigest()
        }
    }

    static func sameContent(_ a: ProgramDigest?, _ b: ProgramDigest?) -> Bool {
        guard var a, var b else { return a == nil && b == nil }
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }
}
