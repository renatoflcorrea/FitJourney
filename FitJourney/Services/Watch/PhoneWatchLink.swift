import Foundation
import Observation
import SwiftData

/// O que o transporte do relógio usa do `HealthWorkoutController` (espelhamento e vínculo do treino). Protocolo
/// para testar o `PhoneWatchLink` sem HealthKit.
@MainActor
protocol WatchHealthBridge: AnyObject {
    var hasRemoteSession: Bool { get }
    var onMirroredSessionDiscarded: ((UUID) -> Void)? { get set }
    var onRemoteSessionChange: ((Bool) -> Void)? { get set }
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

/// Procura no Saúde o treino gravado para uma sessão (`HKMetadataKeyExternalUUID` = ID da sessão).
typealias WatchWorkoutFinder = @MainActor (_ sessionID: UUID, _ interval: DateInterval) async -> UUID?

/// Transporte do iPhone com o relógio (W2, SPEC §6.4). O iPhone é a fonte de verdade: aplica os comandos do
/// relógio no `SessionEngine` e devolve resposta + snapshots.
///
/// **Canais** (relógio ↔ iPhone, sempre envelopes do `WatchLinkCodec`):
/// - Sessão espelhada conectada (`WatchHealthBridge.hasRemoteSession`): tudo pelo canal de dados da
///   `HKWorkoutSession` (`remoteData()`/`sendToRemote`), numa fila serial (a ordem dos envios é mantida).
///   Falhou → cai no WatchConnectivity.
/// - Relógio alcançável: `sendMessageData` (o relógio manda comandos com resposta: a resposta é o `commandReply`;
///   no `snapshotRequest`, a resposta é o snapshot).
/// - Fora de alcance: o `applicationContext` guarda o estado mais recente — `ProgramDigest` + último snapshot +
///   carimbo (`stamp`) — e chega quando o relógio acordar. Comandos do relógio offline chegam por
///   `transferUserInfo` (aplicados igual).
/// - Ativação: nada vai para o `applicationContext` antes de o `WCSession` ativar; em `.activated` o contexto
///   (digest + último snapshot) é sempre republicado.
///
/// **Snapshots:** assina `SessionEngine.snapshots()`, coalesce `snapshotCoalescing` (250 ms) e envia o mais
/// recente; terminal (`finished`/`discarded`) sai na hora. Comando duplicado/recusado reenvia o snapshot atual.
///
/// **Digest:** no `start()`, ao fim de cada sessão e quando o SwiftData grava programas/fichas/exercícios/séries
/// prescritas (`ModelContext.didSave` filtrado, espera `digestDebounce`), recalcula o `ProgramDigest`; se mudou
/// (ignorando `generatedAt`), atualiza o contexto e envia se alcançável.
///
/// **Saúde (quem grava):** `workoutStatus` do relógio →
/// - `.recording`: `adoptRemoteRecording` (o iPhone não grava);
/// - `.notRecording`: `unmarkMirrored` + `resumeIfNeeded` (o iPhone volta a gravar a sessão em andamento);
/// - `.saved(id)`: `linkWorkout`; enquanto a sessão não terminou aqui o vínculo fica pendente (persistido em
///   `UserDefaults`) e é repetido a cada comando, snapshot terminal e `handleForeground()`;
/// - `.failed`: `unmarkMirrored` + `reconcilePendingWorkouts()` — **sem** `resumeIfNeeded`: o relógio só falha no
///   fim (gravação do `HKWorkout`), com a sessão já encerrada; a reconciliação grava pelo gravador simples.
/// Sessão espelhada concluída sem vínculo há mais de `linkDeadline` (10 min): `reconcileMirroredSessions()`
/// (no `start()` e em `handleForeground()`) procura o treino no Saúde pelo `HKMetadataKeyExternalUUID`
/// (`workoutFinder`) e vincula; não achou → libera a sessão para a reconciliação do iPhone.
/// `liveMetrics` → `receiveRemoteMetrics`. Sessão espelhada descartada → o snapshot terminal sai na hora.
/// Espelho conectou/caiu (`onRemoteSessionChange`) → reavalia o alcance.
///
/// **Versão:** só mensagens de canal ativo (mensagem com/sem resposta ou canal espelhado) com versão não
/// suportada recebem `.incompatible`; `userInfo` antigo é ignorado. Aviso recebido do relógio fica em
/// `watchIncompatibility` e some na próxima mensagem válida.
@MainActor
@Observable
final class PhoneWatchLink {
    static let pendingLinksKey = "watchLink.pendingLinks"
    /// Entidades cuja gravação muda o digest.
    static let digestEntities: Set<String> = ["TrainingProgram", "Routine", "RoutineExercise", "SetPrescription", "Exercise"]

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
    @ObservationIgnored private let workoutFinder: WatchWorkoutFinder?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var snapshotCoalescing: Duration = .milliseconds(250)
    @ObservationIgnored var digestDebounce: Duration = .seconds(2)
    /// Prazo para uma sessão espelhada concluída receber o vínculo do relógio antes de procurar no Saúde.
    @ObservationIgnored var linkDeadline: TimeInterval = 600

    @ObservationIgnored private var lastDigest: ProgramDigest?
    @ObservationIgnored private var hasComputedDigest = false
    @ObservationIgnored private var hasPublishedDigest = false
    @ObservationIgnored private var pendingSnapshot: SessionSnapshot?
    @ObservationIgnored private var lastSentSnapshot: SessionSnapshot?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var digestTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotListener: Task<Void, Never>?
    @ObservationIgnored private var remoteListener: Task<Void, Never>?
    @ObservationIgnored private var remoteChain: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isReconciling = false

    /// - Parameters:
    ///   - health: o `HealthWorkoutController` do app (espelhamento/vínculo); `nil` = sem Saúde.
    ///   - digestProvider: padrão = `ProgramDigestBuilder.make(context: engine.context)`.
    ///   - workoutFinder: busca no Saúde por `HKMetadataKeyExternalUUID` (use `PhoneWatchLink.finder(reading:)`
    ///     com `HealthQueries`); `nil` = sessão sem vínculo no prazo vai direto para a reconciliação.
    ///   - defaults: onde ficam os vínculos pendentes.
    init(engine: SessionEngine, session: any WatchLinkSession = WCWatchLinkSession(), health: (any WatchHealthBridge)? = nil,
         digestProvider: (@MainActor () -> ProgramDigest?)? = nil, workoutFinder: WatchWorkoutFinder? = nil,
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.session = session
        self.health = health
        self.workoutFinder = workoutFinder
        self.defaults = defaults
        let context = engine.context
        self.digestProvider = digestProvider ?? { try? ProgramDigestBuilder.make(context: context) }
    }

    /// `workoutFinder` a partir das leituras do Saúde: treino deste app com `externalUUID` = ID da sessão.
    static func finder(reading: any HealthDataReading) -> WatchWorkoutFinder {
        { sessionID, interval in
            let window = DateInterval(start: interval.start.addingTimeInterval(-3_600), end: interval.end.addingTimeInterval(3_600))
            let records = (try? await reading.workouts(in: window))?.value ?? []
            return records.first { $0.externalUUID?.uppercased() == sessionID.uuidString }?.id
        }
    }

    // MARK: Ciclo de vida

    /// Ativa o `WCSession`, publica o digest (depois da ativação) e passa a acompanhar snapshots, o canal espelhado
    /// e as gravações. Idempotente. Chamar no lançamento, depois do `engine.restore()`.
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
                    self.receive(packet, reply: nil, channel: .remote)
                }
            }
            health.onMirroredSessionDiscarded = { [weak self] _ in self?.flushSnapshot() }
            health.onRemoteSessionChange = { [weak self] _ in self?.refreshConnection() }
        }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let names = Self.entityNames(in: note)
            MainActor.assumeIsolated {
                guard !names.isDisjoint(with: Self.digestEntities) else { return }
                self?.scheduleDigestRefresh()
            }
        }
        refreshDigest()
        retryPendingLinks()
        Task { await reconcileMirroredSessions() }
    }

    func stop() {
        snapshotListener?.cancel(); snapshotListener = nil
        remoteListener?.cancel(); remoteListener = nil
        flushTask?.cancel(); flushTask = nil
        digestTask?.cancel(); digestTask = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        session.onEvent = nil
        health?.onRemoteSessionChange = nil
    }

    /// Volta ao primeiro plano: reavalia o alcance, repete vínculos pendentes e procura treinos sem vínculo.
    func handleForeground() {
        refreshConnection()
        retryPendingLinks()
        Task { await reconcileMirroredSessions() }
    }

    /// Recalcula o digest agora e publica se mudou (o app pode chamar depois de editar programas).
    func refreshDigest() {
        digestTask?.cancel()
        digestTask = nil
        let digest = digestProvider()
        let changed = !hasComputedDigest || !Self.sameContent(digest, lastDigest)
        hasComputedDigest = true
        lastDigest = digest
        // Antes da ativação só guarda; o `.activated` publica.
        guard session.isActivated, changed || !hasPublishedDigest else { return }
        hasPublishedDigest = true
        publishContext()
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

    private enum Channel { case message, userInfo, remote }

    private func handle(_ event: WatchLinkSessionEvent) {
        switch event {
        case .activated:
            refreshConnection()
            // Sempre republica o estado (contexto feito antes da ativação se perdeu).
            if !hasComputedDigest { lastDigest = digestProvider(); hasComputedDigest = true }
            hasPublishedDigest = true
            publishContext()
        case .reachability:
            refreshConnection()
        case .message(let data, let reply):
            receive(data, reply: reply, channel: .message)
        case .userInfo(let data):
            receive(data, reply: nil, channel: .userInfo)
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
    private func receive(_ data: Data, reply: WatchLinkReply?, channel: Channel) {
        let viaRemote = channel == .remote
        let message: WatchLinkMessage
        do {
            message = try WatchLinkCodec.decode(data)
        } catch WatchLinkCodecError.unsupportedVersion {
            // Só canal ativo responde (fila offline antiga não merece aviso).
            if channel != .userInfo, let notice = try? WatchLinkCodec.incompatibilityNotice() {
                respond(raw: notice, reply: reply, viaRemote: viaRemote)
            } else {
                reply?(Data())
            }
            return
        } catch {
            reply?(Data())
            return
        }
        if case .incompatible = message {} else { watchIncompatibility = nil }
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
            var links = pendingLinks
            links[sessionID] = workoutID
            pendingLinks = links
            retryPendingLinks()
        case .failed:
            // Sem `resumeIfNeeded`: a falha é na gravação do fim, com a sessão já encerrada (ver doc da classe).
            if watchRecordingSessionID == sessionID { watchRecordingSessionID = nil }
            guard let health else { return }
            health.unmarkMirrored(sessionID)
            Task { await health.reconcilePendingWorkouts() }
        }
    }

    // MARK: Vínculo do treino do relógio

    /// Vínculos recebidos do relógio aguardando a sessão encerrar aqui (persistidos).
    var pendingLinks: [UUID: UUID] {
        get {
            let raw = defaults.dictionary(forKey: Self.pendingLinksKey) as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                guard let session = UUID(uuidString: key), let workout = UUID(uuidString: value) else { return nil }
                return (session, workout)
            })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value.uuidString) })
            defaults.set(raw, forKey: Self.pendingLinksKey)
        }
    }

    /// `linkWorkout` só vale com a sessão encerrada aqui (o `finish` pode chegar depois do treino gravado).
    private func retryPendingLinks() {
        guard let health else { return }
        var links = pendingLinks
        guard !links.isEmpty else { return }
        for (sessionID, workoutID) in links where health.linkWorkout(workoutID, to: sessionID) {
            links[sessionID] = nil
        }
        pendingLinks = links
    }

    /// Sessões espelhadas concluídas há mais de `linkDeadline` sem treino vinculado: procura no Saúde e vincula;
    /// sem resultado, libera para a reconciliação do iPhone (gravador simples).
    func reconcileMirroredSessions() async {
        guard let health, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        retryPendingLinks()
        let now = engine.now()
        let since = now.addingTimeInterval(-HealthWorkoutController.reconcileWindow)
        let deadline = now.addingTimeInterval(-linkDeadline)
        let completed = SessionStatus.completed.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.healthKitWorkoutID == nil && $0.startedAt > since })
        let sessions = ((try? engine.context.fetch(descriptor)) ?? []).filter {
            guard let ended = $0.endedAt else { return false }
            return ended <= deadline && health.isMirrored($0.id)
        }
        let candidates = sessions.map { ($0.id, DateInterval(start: $0.startedAt, end: max($0.startedAt, $0.endedAt ?? $0.startedAt))) }
        var released = false
        for (sessionID, interval) in candidates where pendingLinks[sessionID] == nil {
            if let finder = workoutFinder, let workoutID = await finder(sessionID, interval) {
                health.linkWorkout(workoutID, to: sessionID)
            } else {
                health.unmarkMirrored(sessionID)
                released = true
            }
        }
        if released { await health.reconcilePendingWorkouts() }
    }

    // MARK: Snapshots

    private func enqueue(_ snapshot: SessionSnapshot, force: Bool = false) {
        pendingSnapshot = snapshot
        if snapshot.status == .finished || snapshot.status == .discarded || force {
            flushSnapshot()
            if snapshot.status == .finished {
                retryPendingLinks()
                scheduleDigestRefresh() // última execução/cargas atuais mudaram
            }
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
        publishContext()
        send(.snapshot(snapshot))
    }

    // MARK: Envio

    /// Melhor canal disponível: espelhado (fila serial) → mensagem (se alcançável). Fora de alcance o
    /// `applicationContext` já carrega o estado; o relógio reenvia comandos sem resposta.
    private func send(_ message: WatchLinkMessage) {
        guard let data = try? WatchLinkCodec.encode(message) else { return }
        if let health, health.hasRemoteSession {
            sendRemote(data, health: health)
            return
        }
        sendByConnectivity(data)
    }

    private func sendRemote(_ data: Data, health: any WatchHealthBridge) {
        let previous = remoteChain
        remoteChain = Task { [weak self] in
            await previous?.value
            do {
                try await health.sendToRemote(data)
            } catch {
                self?.sendByConnectivity(data)
            }
        }
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
            sendRemote(data, health: health)
        } else {
            sendByConnectivity(data)
        }
    }

    /// `applicationContext` = digest + último snapshot + carimbo. Antes da ativação só marca para o `.activated`.
    private func publishContext() {
        guard session.isActivated else { return }
        var context: [String: Data] = [WatchLinkSessionKey.stamp: WatchLinkSessionKey.encodeStamp(engine.now())]
        if let digest = try? WatchLinkCodec.encode(.programDigest(lastDigest)) { context[WatchLinkSessionKey.digest] = digest }
        if let data = try? WatchLinkCodec.encode(.snapshot(lastSentSnapshot)) { context[WatchLinkSessionKey.snapshot] = data }
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

    /// Nomes das entidades inseridas/alteradas/apagadas numa gravação do SwiftData.
    nonisolated static func entityNames(in note: Notification) -> Set<String> {
        let keys = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        var names = Set<String>()
        for key in keys {
            for id in note.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? [] { names.insert(id.entityName) }
        }
        return names
    }

    static func sameContent(_ a: ProgramDigest?, _ b: ProgramDigest?) -> Bool {
        guard var a, var b else { return a == nil && b == nil }
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }
}
