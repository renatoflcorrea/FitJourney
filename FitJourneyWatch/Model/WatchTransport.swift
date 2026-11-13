import Foundation

/// Evento vindo do canal com o iPhone.
enum WatchTransportEvent: Sendable, Equatable {
    case message(WatchLinkMessage)
    /// O iPhone ficou alcançável (`true`) ou saiu de alcance (`false`).
    case reachability(Bool)
}

/// Canal relógio ↔ iPhone.
///
/// - Real: `WatchConnectivityTransport` (`applicationContext` ↔ `ProgramDigest`/snapshot, `sendMessageData` com
///   resposta quando alcançável, `transferUserInfo` como fila offline) e, durante a sessão espelhada, o canal
///   de dados da `HKWorkoutSession` (`WatchWorkoutDataChannel`). Ele decide sozinho qual canal usar em `send`;
///   o modelo só conhece "enviar" e "o que chegou".
/// - Previews/testes/harness: `MockWatchTransport` (DEBUG).
///
/// Contrato: `send` nunca lança nem bloqueia (pode enfileirar); reenviar o mesmo `commandID` é seguro
/// (o iPhone é idempotente), então o modelo reenvia os pendentes sempre que a alcançabilidade volta.
@MainActor
protocol WatchTransport: AnyObject {
    /// Novo fluxo de mensagens recebidas e mudanças de alcançabilidade. Cada chamada devolve um fluxo
    /// independente (suporta re-assinatura: o modelo pode reiniciar a escuta sem perder o transporte).
    func makeEventStream() -> AsyncStream<WatchTransportEvent>
    /// Alcançabilidade atual (valor inicial, antes de qualquer `.reachability`).
    var isReachable: Bool { get }
    func send(_ message: WatchLinkMessage)
}

/// Canal de dados da `HKWorkoutSession` espelhada no iPhone (`sendToRemoteWorkoutSession`). Implementado
/// pelo `WatchWorkoutProvider`; o `WatchConnectivityTransport` prefere este canal enquanto ele existe.
@MainActor
protocol WatchWorkoutDataChannel: AnyObject {
    /// A sessão do relógio está espelhada no iPhone (o canal entrega dados).
    var isMirroring: Bool { get }
    func sendToPhone(_ data: Data) async throws
    /// Dados recebidos do iPhone pelo canal (envelopes do `WatchLinkCodec`).
    var onDataFromPhone: (@MainActor (Data) -> Void)? { get set }
    /// O espelhamento ligou/desligou.
    var onMirroringChange: (@MainActor (Bool) -> Void)? { get set }
}

/// Nunca alcança o iPhone e não entrega nada — o relógio mostra "Abra o FitRoute no iPhone". Só para
/// ambientes sem `WCSession` (não suportado); o app usa o `WatchConnectivityTransport`.
@MainActor
final class UnavailableWatchTransport: WatchTransport {
    let isReachable = false
    func makeEventStream() -> AsyncStream<WatchTransportEvent> { AsyncStream { _ in } }
    func send(_ message: WatchLinkMessage) {}
}
