import Foundation

/// Transporte real relógio ↔ iPhone (W2) sobre `WatchLinkSession` (`WCSession`) e, durante a sessão espelhada,
/// o canal de dados da `HKWorkoutSession` (`WatchWorkoutDataChannel`).
///
/// Canais por mensagem (o modelo só chama `send`):
/// - `command`/`workoutStatus`: canal do treino espelhado → `sendMessageData` com resposta (iPhone alcançável) →
///   `transferUserInfo` (fila offline, entregue em ordem quando o iPhone acordar). Falha num canal cai no seguinte.
///   Reenvios são seguros (o iPhone deduplica por `commandID`).
/// - `snapshotRequest`: canal do treino → `sendMessageData` com resposta (o snapshot volta na resposta);
///   fora de alcance não vai (o modelo pede de novo ao reconectar).
/// - `liveMetrics`: canal do treino → `sendMessageData` sem resposta; fora de alcance descarta (é ao vivo).
///
/// Recebe do iPhone: mensagens, respostas, `userInfo` e `applicationContext` (`ProgramDigest` + último snapshot).
/// Guarda o último digest e o último snapshot em `UserDefaults`: o relógio abre a lista (e a sessão em curso)
/// sem o iPhone — cada fluxo novo começa com eles. Mensagem de versão não suportada → responde `.incompatible`.
///
/// Coalescência da Coroa: feita no `WatchSessionModel` antes de o comando ganhar canal (só ali é seguro somar
/// deltas sem reaproveitar um `commandID` já entregue).
@MainActor
final class WatchConnectivityTransport: WatchTransport {
    static let digestKey = "watchLink.lastProgramDigest"
    static let snapshotKey = "watchLink.lastSessionSnapshot"

    private let session: any WatchLinkSession
    private let defaults: UserDefaults
    private weak var workoutChannel: (any WatchWorkoutDataChannel)?
    private var continuations: [UUID: AsyncStream<WatchTransportEvent>.Continuation] = [:]
    private var lastReachable: Bool

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
        channel?.onDataFromPhone = { [weak self] data in self?.receive(data, reply: nil) }
        channel?.onMirroringChange = { [weak self] _ in self?.publishReachability() }
    }

    func activate() {
        session.activate()
        let context = session.receivedContext
        if !context.isEmpty { receive(context: context) }
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
        case .command, .workoutStatus:
            deliver(data, expectsReply: true, queueOffline: true)
        case .snapshotRequest:
            deliver(data, expectsReply: true, queueOffline: false)
        case .liveMetrics:
            deliver(data, expectsReply: false, queueOffline: false)
        case .incompatible:
            deliver(data, expectsReply: false, queueOffline: false)
        case .commandReply, .snapshot, .programDigest, .recordingRequest:
            break // mensagens do iPhone
        }
    }

    // MARK: Envio

    private func deliver(_ data: Data, expectsReply: Bool, queueOffline: Bool) {
        if let channel = workoutChannel, channel.isMirroring {
            Task { [weak self] in
                do {
                    try await channel.sendToPhone(data)
                } catch {
                    self?.deliverByConnectivity(data, expectsReply: expectsReply, queueOffline: queueOffline)
                }
            }
            return
        }
        deliverByConnectivity(data, expectsReply: expectsReply, queueOffline: queueOffline)
    }

    private func deliverByConnectivity(_ data: Data, expectsReply: Bool, queueOffline: Bool) {
        guard session.isReachable else {
            if queueOffline { session.transferUserInfo(data) }
            return
        }
        var reply: (@MainActor @Sendable (Data) -> Void)?
        if expectsReply {
            reply = { [weak self] response in self?.receive(response, reply: nil) }
        }
        session.sendMessage(data, reply: reply) { [weak self] in
            if queueOffline { self?.session.transferUserInfo(data) }
        }
    }

    // MARK: Recepção

    private func handle(_ event: WatchLinkSessionEvent) {
        switch event {
        case .activated, .reachability:
            publishReachability()
        case .message(let data, let reply):
            receive(data, reply: reply)
        case .userInfo(let data):
            receive(data, reply: nil)
        case .context(let context):
            receive(context: context)
        }
    }

    private func receive(context: [String: Data]) {
        for key in [WatchLinkSessionKey.digest, WatchLinkSessionKey.snapshot] {
            if let data = context[key] { receive(data, reply: nil) }
        }
    }

    /// Decodifica e entrega. Resposta vazia vem de quem não tinha o que dizer (ignorada).
    private func receive(_ data: Data, reply: WatchLinkReply?) {
        defer { reply?(Data()) }
        guard !data.isEmpty else { return }
        let message: WatchLinkMessage
        do {
            message = try WatchLinkCodec.decode(data)
        } catch WatchLinkCodecError.unsupportedVersion {
            if let notice = try? WatchLinkCodec.incompatibilityNotice() {
                if let reply { reply(notice) } else { deliver(notice, expectsReply: false, queueOffline: false) }
            }
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
