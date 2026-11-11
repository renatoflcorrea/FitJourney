import Foundation

/// Evento vindo do canal com o iPhone.
enum WatchTransportEvent: Sendable, Equatable {
    case message(WatchLinkMessage)
    /// O iPhone ficou alcançável (`true`) ou saiu de alcance (`false`).
    case reachability(Bool)
}

/// PONTO DE INJEÇÃO (W2/W3b): canal relógio ↔ iPhone.
///
/// - Implementação real (W2/W3b): `WCSession` (`applicationContext` ↔ `ProgramDigest`, `sendMessage` com
///   `WatchLinkCodec` para comandos com iPhone alcançável, `transferUserInfo` para a fila offline) e, durante
///   a sessão, o canal de dados da `HKWorkoutSession` espelhada (`sendToRemoteWorkoutSession`). Ela decide
///   sozinha qual canal usar em `send`; o modelo só conhece "enviar" e "o que chegou".
/// - Hoje: `MockWatchTransport` (previews, testes e harness de screenshots).
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

/// Transporte de lançamento até o W2: nunca alcança o iPhone e não entrega nada — o relógio mostra
/// "Abra o FitJourney no iPhone". PENDÊNCIA DE LANÇAMENTO: sem o `WatchConnectivityTransport` do W2 o app
/// do relógio não sincroniza; não publicar antes disso.
@MainActor
final class UnavailableWatchTransport: WatchTransport {
    let isReachable = false
    func makeEventStream() -> AsyncStream<WatchTransportEvent> { AsyncStream { _ in } }
    func send(_ message: WatchLinkMessage) {}
}
