import Foundation
import Network

/// Listener HTTP de **uso único** em `localhost:1455`, que recebe o redirecionamento OAuth
/// (`/auth/callback?code=…&state=…`). `ASWebAuthenticationSession` não entrega um redirect `http://localhost`,
/// então é assim que o redirect registrado do cliente é atendido (porta de `ChatGPTLoopbackListener` do fireplaice).
///
/// Defesas:
/// - só interface de loopback, e cada conexão tem que vir de 127.0.0.0/8 ou ::1 (o resto é cancelado);
/// - só entrega (e consome o uso único) o callback cujo `state` bate com o esperado, comparado em tempo
///   constante; qualquer outro pedido recebe 404 e a espera continua;
/// - espera total limitada (`timeout`, padrão 5 min), cada conexão com 5 s e no máximo 8 simultâneas;
/// - falha ou cancelamento do listener depois de pronto encerra a espera e libera a porta.
///
/// O fireplaice não tem porta alternativa: se 1455 estiver ocupada, a UI cai no fallback "colar a URL".
final class ChatGPTLoopbackListener: @unchecked Sendable {
    struct Callback: Sendable, Equatable {
        let code: String?
        let state: String?
        let error: String?
    }

    static let port: UInt16 = 1455
    static let path = "/auth/callback"
    static let maxRequestBytes = 8192
    static let maxConnections = 8

    // NWListener não tem API de concorrência estruturada: precisa de uma fila.
    private let queue = DispatchQueue(label: "br.com.renatocorrea.fitjourney.chatgpt-loopback")
    private let lock = NSLock()
    private let expectedState: String
    private let requestedPort: UInt16
    private let timeout: TimeInterval
    private let connectionTimeout: TimeInterval
    // Protegidos por `lock`:
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pending: CheckedContinuation<Callback, any Error>?
    private var outcome: Result<Callback, any Error>?
    private var timeoutItem: DispatchWorkItem?

    /// - Parameters:
    ///   - expectedState: o `state` da tentativa; só um callback com ele é entregue.
    ///   - port: `0` escolhe uma porta livre (testes); veja `boundPort`.
    init(expectedState: String, port: UInt16 = ChatGPTLoopbackListener.port, timeout: TimeInterval = 300,
         connectionTimeout: TimeInterval = 5) {
        self.expectedState = expectedState
        requestedPort = port
        self.timeout = timeout
        self.connectionTimeout = connectionTimeout
    }

    /// Porta efetiva depois de `start()`.
    var boundPort: UInt16? { lock.withLock { listener?.port?.rawValue } }

    /// Conexões abertas agora (testes).
    var openConnectionCount: Int { lock.withLock { connections.count } }

    /// Começa a escutar; lança se a porta estiver ocupada ou o listener falhar.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // Necessário: o listener fecha ativamente cada conexão (`Connection: close`), que fica em TIME_WAIT na
        // porta 1455; sem reuso, um novo login logo depois falharia com EADDRINUSE.
        parameters.allowLocalEndpointReuse = true
        let nwPort = requestedPort == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.withLock { self.listener = listener }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case let .failed(error), let .waiting(error):
                    once.resume(.failure(error))
                    self?.finish(.failure(AIError.network(code: URLError.cannotConnectToHost.rawValue, retryable: true)))
                case .cancelled:
                    once.resume(.failure(AIError.cancelled))
                    self?.finish(.failure(AIError.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AIError.network(code: URLError.timedOut.rawValue, retryable: false)))
        }
        lock.withLock { timeoutItem = item }
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Espera o redirecionamento com o `state` certo. Cancelar a tarefa, `stop()`, o timeout ou uma falha do
    /// listener encerram a espera.
    func callback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, any Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    pending = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// Encerra tudo: listener, conexões pendentes e a espera (com `AIError.cancelled`, se ainda não terminou).
    func stop() {
        finish(.failure(AIError.cancelled))
    }

    /// Primeiro resultado vence; libera a porta e as conexões.
    private func finish(_ result: Result<Callback, any Error>) {
        lock.lock()
        if outcome == nil { outcome = result }
        let final = outcome
        let waiting = pending
        pending = nil
        let listener = listener
        self.listener = nil
        let open = Array(connections.values)
        connections = [:]
        let item = timeoutItem
        timeoutItem = nil
        lock.unlock()
        item?.cancel()
        listener?.cancel()
        for connection in open { connection.cancel() }
        if let waiting, let final { waiting.resume(with: final) }
    }

    // MARK: - Conexões

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admitted: Bool = lock.withLock {
            guard outcome == nil, connections.count < Self.maxConnections, Self.isLoopback(connection.endpoint)
            else { return false }
            connections[id] = connection
            return true
        }
        guard admitted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.withLock { _ = connections.removeValue(forKey: id) }
    }

    /// Lê até o fim da linha de pedido (`\r\n`) ou 8 KB.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let hasLine = buffer.range(of: Data("\r\n".utf8)) != nil
            if hasLine || buffer.count >= Self.maxRequestBytes || isComplete || error != nil {
                respond(on: connection, request: String(decoding: buffer.prefix(Self.maxRequestBytes), as: UTF8.self))
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, request: String) {
        let parsed = Self.parse(requestLine: request)
        let accepted = parsed.map { Self.constantTimeEquals($0.state ?? "", expectedState) } ?? false
        let body = accepted ? Self.success : Self.notFound
        let status = accepted ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if accepted, let parsed { self?.finish(.success(parsed)) }
        })
    }

    // MARK: - Puros (testáveis)

    /// `GET /auth/callback?code=…&state=… HTTP/1.1` → parâmetros. Qualquer outro pedido é ignorado.
    static func parse(requestLine request: String) -> Callback? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first
        else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost" + parts[1]),
              components.path == path else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return Callback(code: value("code"), state: value("state"), error: value("error"))
    }

    /// Comparação sem atalho no primeiro byte diferente (o tamanho do `state` não é segredo).
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0 ..< max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0 && a.count == b.count
    }

    /// Só 127.0.0.0/8, ::1 e ::ffff:127.x.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return address.rawValue.first == 127
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
            return bytes[0 ..< 10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
        case .name: return false
        @unknown default: return false
        }
    }

    private static let success = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\
    <title>FitJourney</title><body style="font-family:-apple-system,sans-serif;text-align:center;padding:3em">\
    <h2>Login recebido.</h2><p>Pode voltar ao FitJourney.</p></body>
    """
    private static let notFound = "<!doctype html><title>Not found</title>"
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

    func resume(_ result: Result<Void, any Error>) {
        let taken = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(with: result)
    }
}

/// Validação do callback contra a tentativa (pura, testável). Usada no fallback de colar a URL; o listener já
/// filtra pelo `state`, e aqui ele é checado de novo.
enum ChatGPTLoginValidation {
    enum Failure: Error, Equatable {
        /// O ChatGPT negou ou o usuário cancelou na página.
        case denied
        /// `state` ausente ou diferente: resposta de outra tentativa (ou forjada). Nunca troca o código.
        case stateMismatch
    }

    static func code(from callback: ChatGPTLoopbackListener.Callback,
                     attempt: ChatGPTLoginAttempt) throws(Failure) -> String {
        guard let state = callback.state, ChatGPTLoopbackListener.constantTimeEquals(state, attempt.state) else {
            throw .stateMismatch
        }
        guard callback.error == nil, let code = callback.code, !code.isEmpty else { throw .denied }
        return code
    }
}
