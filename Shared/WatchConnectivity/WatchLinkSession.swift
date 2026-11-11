import Foundation
import WatchConnectivity

// Ponte fina sobre `WCSession`, compilada nos alvos iOS e watchOS. Os transportes
// (`PhoneWatchLink` no iPhone, `WatchConnectivityTransport` no relógio) falam com o protocolo
// `WatchLinkSession`, então os testes usam fakes sem WatchConnectivity.
//
// Formato no fio: cada mensagem é um envelope do `WatchLinkCodec` (`Data`).
// - `sendMessageData` (com resposta quando quem envia espera uma);
// - `transferUserInfo` = `[WatchLinkSessionKey.payload: Data]` (fila offline, entregue em ordem);
// - `applicationContext` = estado mais recente: `[digest: Data, snapshot: Data, stamp: Data]` (só o último vale;
//   `stamp` = quando o iPhone montou o contexto, para o relógio ignorar contexto mais velho que o guardado).
//
// Os transportes só usam `transferUserInfo`/`updateContext` com a sessão ativada: antes disso guardam e
// descarregam no `.activated` (o `WCSession` descarta chamadas feitas antes da ativação).

enum WatchLinkSessionKey {
    static let payload = "p"
    static let digest = "digest"
    static let snapshot = "snapshot"
    static let stamp = "stamp"

    static func encodeStamp(_ date: Date) -> Data { Data(String(date.timeIntervalSinceReferenceDate).utf8) }
    static func decodeStamp(_ data: Data?) -> Date? {
        guard let data, let value = Double(String(decoding: data, as: UTF8.self)) else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }
}

/// Resposta única (thread-safe) de `didReceiveMessageData` — o bloco do sistema não é anotado `Sendable`.
final class WatchLinkReply: @unchecked Sendable {
    private let block: (Data) -> Void
    private let lock = NSLock()
    private var called = false

    init(_ block: @escaping (Data) -> Void) { self.block = block }

    func callAsFunction(_ data: Data) {
        lock.lock()
        let first = !called
        called = true
        lock.unlock()
        if first { block(data) }
    }
}

enum WatchLinkSessionEvent {
    case activated
    case reachability(Bool)
    /// Mensagem; `reply` presente quando o outro lado espera resposta (responder sempre, nem que vazio).
    case message(Data, reply: WatchLinkReply?)
    case userInfo(Data)
    case context([String: Data])
}

/// Abstração de `WCSession` (testável).
@MainActor
protocol WatchLinkSession: AnyObject {
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    /// iPhone: relógio pareado com o app instalado. Relógio: app do iPhone instalado.
    var isCounterpartInstalled: Bool { get }
    /// Último `applicationContext` recebido.
    var receivedContext: [String: Data] { get }
    var onEvent: (@MainActor (WatchLinkSessionEvent) -> Void)? { get set }
    func activate()
    /// `reply` = espera resposta (`nil` = sem resposta). `failure` quando não entregou (fora de alcance/erro).
    func sendMessage(_ data: Data, reply: (@MainActor @Sendable (Data) -> Void)?, failure: @escaping @MainActor @Sendable () -> Void)
    func transferUserInfo(_ data: Data)
    func updateContext(_ context: [String: Data]) throws
}

/// `WCSession.default`. Os callbacks do delegate chegam numa fila do sistema: só extraem valores e pulam
/// para o MainActor; o `WCSession` em si nunca atravessa atores.
@MainActor
final class WCWatchLinkSession: NSObject, WatchLinkSession, WCSessionDelegate {
    var onEvent: (@MainActor (WatchLinkSessionEvent) -> Void)?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    var isActivated: Bool { session?.activationState == .activated }
    var isReachable: Bool { isActivated && session?.isReachable == true }
    var isCounterpartInstalled: Bool {
        guard let session else { return false }
        #if os(iOS)
        return session.isPaired && session.isWatchAppInstalled
        #else
        return session.isCompanionAppInstalled
        #endif
    }
    var receivedContext: [String: Data] {
        (session?.receivedApplicationContext ?? [:]).compactMapValues { $0 as? Data }
    }

    func activate() {
        guard let session, session.delegate !== self || session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    func sendMessage(_ data: Data, reply: (@MainActor @Sendable (Data) -> Void)?, failure: @escaping @MainActor @Sendable () -> Void) {
        guard let session, isReachable else {
            failure()
            return
        }
        Self.sendMessage(session, data, reply: reply, failure: failure)
    }

    /// Montado fora do ator: os handlers rodam na fila do WatchConnectivity; um closure formado num método
    /// `@MainActor` herdaria o isolamento e travaria em tempo de execução.
    nonisolated private static func sendMessage(_ session: WCSession, _ data: Data, reply: (@MainActor @Sendable (Data) -> Void)?,
                                                failure: @escaping @MainActor @Sendable () -> Void) {
        let replyHandler: ((Data) -> Void)? = reply.map { reply in
            { data in Task { @MainActor in reply(data) } }
        }
        session.sendMessageData(data, replyHandler: replyHandler) { _ in
            Task { @MainActor in failure() }
        }
    }

    func transferUserInfo(_ data: Data) {
        guard let session, isActivated else { return }
        session.transferUserInfo([WatchLinkSessionKey.payload: data])
    }

    func updateContext(_ context: [String: Data]) throws {
        guard let session, isActivated else { return }
        try session.updateApplicationContext(context)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        let reachable = activationState == .activated && session.isReachable
        let context = session.receivedApplicationContext.compactMapValues { $0 as? Data }
        Task { @MainActor [weak self] in
            self?.onEvent?(.activated)
            self?.onEvent?(.reachability(reachable))
            if !context.isEmpty { self?.onEvent?(.context(context)) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.activationState == .activated && session.isReachable
        Task { @MainActor [weak self] in self?.onEvent?(.reachability(reachable)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in self?.onEvent?(.message(messageData, reply: nil)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        let reply = WatchLinkReply(replyHandler)
        Task { @MainActor [weak self] in
            guard let self, let onEvent = self.onEvent else { reply(Data()); return }
            onEvent(.message(messageData, reply: reply))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchLinkSessionKey.payload] as? Data else { return }
        Task { @MainActor [weak self] in self?.onEvent?(.userInfo(data)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = applicationContext.compactMapValues { $0 as? Data }
        Task { @MainActor [weak self] in self?.onEvent?(.context(context)) }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.onEvent?(.reachability(false)) }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Troca de relógio: reativa para o novo.
        Task { @MainActor in WCSession.default.activate() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let reachable = session.activationState == .activated && session.isReachable
        Task { @MainActor [weak self] in self?.onEvent?(.reachability(reachable)) }
    }
    #endif
}
