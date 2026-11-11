import Foundation

/// Transporte real relógio ↔ iPhone (W2) sobre `WatchLinkSession` (`WCSession`) e, durante a sessão espelhada,
/// o canal de dados da `HKWorkoutSession` (`WatchWorkoutDataChannel`).
///
/// Canais por mensagem (o modelo só chama `send`):
/// - `command`/`workoutStatus`: canal do treino espelhado (fila serial) → `sendMessageData` com resposta (iPhone
///   alcançável) → `transferUserInfo` (fila offline, entregue em ordem quando o iPhone acordar). Falha num canal cai
///   no seguinte. Reenvios são seguros (o iPhone deduplica por `commandID`).
/// - `snapshotRequest`: canal do treino → `sendMessageData` com resposta (o snapshot volta na resposta);
///   fora de alcance não vai (o modelo pede de novo ao reconectar).
/// - `liveMetrics`: canal do treino → `sendMessageData` sem resposta; fora de alcance descarta (é ao vivo).
///
/// Ativação: `transferUserInfo` antes de o `WCSession` ativar fica num buffer pequeno (`preActivationLimit`) e é
/// descarregado no `.activated`.
///
/// `.saved` durável: o último `workoutStatus(.saved)` fica guardado até ser entregue (resposta do iPhone, canal do
/// treino ou entregue ao `transferUserInfo` com a sessão ativa) e é reenviado ao ativar.
///
/// Recebe do iPhone: mensagens, respostas, `userInfo` e `applicationContext` (`ProgramDigest` + último snapshot +
/// carimbo). Guarda o último digest e o último snapshot em `UserDefaults`: o relógio abre a lista (e a sessão em
/// curso) sem o iPhone — cada fluxo novo começa com eles. Contexto com carimbo mais velho que o guardado é
/// ignorado; "sem sessão" vindo do contexto não apaga uma sessão ativa conhecida (o snapshot por mensagem decide).
/// Mensagem de versão não suportada num canal ativo (mensagem/resposta/canal do treino) → responde `.incompatible`.
///
/// Coalescência da Coroa: feita no `WatchSessionModel` antes de o comando ganhar canal (só ali é seguro somar
/// deltas sem reaproveitar um `commandID` já entregue).
@MainActor
final class WatchConnectivityTransport: WatchTransport {
    static let digestKey = "watchLink.lastProgramDigest"
    static let snapshotKey = "watchLink.lastSessionSnapshot"
    static let contextStampKey = "watchLink.contextStamp"
    static let savedStatusKey = "watchLink.pendingSavedStatus"
    static let preActivationLimit = 64

    private let session: any WatchLinkSession
    private let defaults: UserDefaults
    private weak var workoutChannel: (any WatchWorkoutDataChannel)?
    private var continuations: [UUID: AsyncStream<WatchTransportEvent>.Continuation] = [:]
    private var lastReachable: Bool
    private var preActivationQueue: [Data] = []
    private var channelChain: Task<Void, Never>?

    private enum Channel { case active, passive }

    init(session: any WatchLinkSession, defaults: UserDefaults = .standard, workoutChannel: (any WatchWorkoutDataChannel)? = nil) {
        self.session = session
        self.defaults = defaults
        self.lastReachable = false
        self.workoutChannel = workoutChannel
        session.onEvent = { [weak self] event in self?.handle(event) }
        attach(workoutChannel)
        lastReachable = isReachable
    }

    /// Liga o canal do treino espelhado (o provedor de saúde é criado junto, na composição).
    func attach(_ channel: (any WatchWorkoutDataChannel)?) {
        workoutChannel = channel
        channel?.onDataFromPhone = { [weak self] data in self?.receive(data, reply: nil, channel: .active) }
        channel?.onMirroringChange = { [weak self] _ in self?.publishReachability() }
    }

    func activate() {
        session.activate()
        if session.isActivated { didActivate() }
    }

    var isReachable: Bool { session.isReachable || workoutChannel?.isMirroring == true }

    func makeEventStream() -> AsyncStream<WatchTransportEvent> {
        let id = UUID()
        let cached = cachedMessages()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            for message in cached { continuation.yield(.message(message)) }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        }
    }

    func send(_ message: WatchLinkMessage) {
        guard let data = try? WatchLinkCodec.encode(message) else { return }
        switch message {
        case .workoutStatus(let status):
            let durable = if case .saved = status.state { true } else { false }
            if durable { defaults.set(data, forKey: Self.savedStatusKey) }
            deliver(data, expectsReply: true, queueOffline: true, durable: durable)
        case .command:
            deliver(data, expectsReply: true, queueOffline: true)
        case .snapshotRequest:
            deliver(data, expectsReply: true, queueOffline: false)
        case .liveMetrics, .incompatible:
            deliver(data, expectsReply: false, queueOffline: false)
        case .commandReply, .snapshot, .programDigest, .recordingRequest:
            break // mensagens do iPhone
        }
    }

    // MARK: Envio

    private func deliver(_ data: Data, expectsReply: Bool, queueOffline: Bool, durable: Bool = false) {
        if let channel = workoutChannel, channel.isMirroring {
            let previous = channelChain
            channelChain = Task { [weak self] in
                await previous?.value
                do {
                    try await channel.sendToPhone(data)
                    if durable { self?.delivered(data) }
                } catch {
                    self?.deliverByConnectivity(data, expectsReply: expectsReply, queueOffline: queueOffline, durable: durable)
                }
            }
            return
        }
        deliverByConnectivity(data, expectsReply: expectsReply, queueOffline: queueOffline, durable: durable)
    }

    private func deliverByConnectivity(_ data: Data, expectsReply: Bool, queueOffline: Bool, durable: Bool) {
        guard session.isReachable else {
            if queueOffline { enqueueOffline(data, durable: durable) }
            return
        }
        var reply: (@MainActor @Sendable (Data) -> Void)?
        if expectsReply {
            reply = { [weak self] response in
                if durable { self?.delivered(data) }
                self?.receive(response, reply: nil, channel: .active)
            }
        }
        session.sendMessage(data, reply: reply) { [weak self] in
            if queueOffline { self?.enqueueOffline(data, durable: durable) }
        }
    }

    /// `transferUserInfo` com a sessão ativa (o sistema guarda e entrega); antes da ativação, buffer.
    private func enqueueOffline(_ data: Data, durable: Bool) {
        guard session.isActivated else {
            if preActivationQueue.count >= Self.preActivationLimit { preActivationQueue.removeFirst() }
            preActivationQueue.append(data)
            return
        }
        session.transferUserInfo(data)
        if durable { delivered(data) }
    }

    private func delivered(_ data: Data) {
        if defaults.data(forKey: Self.savedStatusKey) == data { defaults.removeObject(forKey: Self.savedStatusKey) }
    }

    private func didActivate() {
        let queued = preActivationQueue
        preActivationQueue = []
        for data in queued { session.transferUserInfo(data) }
        if let saved = defaults.data(forKey: Self.savedStatusKey), !queued.contains(saved) {
            deliver(saved, expectsReply: true, queueOffline: true, durable: true)
        } else if let saved = defaults.data(forKey: Self.savedStatusKey) {
            delivered(saved)
        }
        let context = session.receivedContext
        if !context.isEmpty { receive(context: context) }
        publishReachability()
    }

    // MARK: Recepção

    private func handle(_ event: WatchLinkSessionEvent) {
        switch event {
        case .activated:
            didActivate()
        case .reachability:
            publishReachability()
        case .message(let data, let reply):
            receive(data, reply: reply, channel: .active)
        case .userInfo(let data):
            receive(data, reply: nil, channel: .passive)
        case .context(let context):
            receive(context: context)
        }
    }

    private func receive(context: [String: Data]) {
        let stamp = WatchLinkSessionKey.decodeStamp(context[WatchLinkSessionKey.stamp])
        if let stamp {
            let cached = defaults.object(forKey: Self.contextStampKey) as? Date
            if let cached, stamp < cached { return } // contexto velho (entregue fora de ordem)
            defaults.set(stamp, forKey: Self.contextStampKey)
        }
        if let data = context[WatchLinkSessionKey.digest] { receive(data, reply: nil, channel: .passive) }
        if let data = context[WatchLinkSessionKey.snapshot] {
            if case .snapshot(nil)? = try? WatchLinkCodec.decode(data), hasActiveCachedSession { return }
            receive(data, reply: nil, channel: .passive)
        }
    }

    private var hasActiveCachedSession: Bool {
        guard let data = defaults.data(forKey: Self.snapshotKey),
              case .snapshot(let snapshot?)? = try? WatchLinkCodec.decode(data) else { return false }
        return snapshot.status == .active || snapshot.status == .paused
    }

    /// Decodifica e entrega. Resposta vazia vem de quem não tinha o que dizer (ignorada).
    private func receive(_ data: Data, reply: WatchLinkReply?, channel: Channel) {
        defer { reply?(Data()) }
        guard !data.isEmpty else { return }
        let message: WatchLinkMessage
        do {
            message = try WatchLinkCodec.decode(data)
        } catch WatchLinkCodecError.unsupportedVersion {
            guard channel == .active, let notice = try? WatchLinkCodec.incompatibilityNotice() else { return }
            if let reply { reply(notice) } else { deliver(notice, expectsReply: false, queueOffline: false) }
            return
        } catch {
            return
        }
        cache(message)
        yield(.message(message))
    }

    private func publishReachability() {
        let reachable = isReachable
        guard reachable != lastReachable else { return }
        lastReachable = reachable
        yield(.reachability(reachable))
    }

    private func yield(_ event: WatchTransportEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: Cache local

    private func cache(_ message: WatchLinkMessage) {
        switch message {
        case .programDigest:
            defaults.set(try? WatchLinkCodec.encode(message), forKey: Self.digestKey)
        case .snapshot:
            defaults.set(try? WatchLinkCodec.encode(message), forKey: Self.snapshotKey)
        default:
            break
        }
    }

    /// Último digest e último snapshot guardados (na ordem em que o modelo deve recebê-los).
    private func cachedMessages() -> [WatchLinkMessage] {
        [Self.digestKey, Self.snapshotKey].compactMap { key in
            defaults.data(forKey: key).flatMap { try? WatchLinkCodec.decode($0) }
        }
    }
}
