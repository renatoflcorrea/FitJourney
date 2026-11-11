import Foundation
import Network

/// Listener HTTP de **uso único** em `localhost:1455`, que recebe o redirecionamento OAuth
/// (`/auth/callback?code=…&state=…`). `ASWebAuthenticationSession` não entrega um redirect `http://localhost`,
/// então é assim que o redirect registrado do cliente é atendido (porta de `ChatGPTLoopbackListener` do fireplaice).
///
/// Só na interface de loopback (loopback não pede permissão de rede local no iOS); responde uma página
/// curta e mais nada. O fireplaice não tem porta alternativa: se 1455 estiver ocupada, a UI cai no
/// fallback "colar a URL" (`ChatGPTOAuthClient.parseCallback`).
final class ChatGPTLoopbackListener: @unchecked Sendable {
    struct Callback: Sendable, Equatable {
        let code: String?
        let state: String?
        let error: String?
    }

    static let port: UInt16 = 1455
    static let path = "/auth/callback"

    // NWListener não tem API de concorrência estruturada: precisa de uma fila.
    private let queue = DispatchQueue(label: "br.com.renatocorrea.fitjourney.chatgpt-loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pending: CheckedContinuation<Callback, any Error>?
    private var delivered: Callback?
    private var stopped = false
    private let requestedPort: UInt16

    /// - Parameter port: `0` escolhe uma porta livre (testes); veja `boundPort`.
    init(port: UInt16 = ChatGPTLoopbackListener.port) {
        requestedPort = port
    }

    /// Porta efetiva depois de `start()`.
    var boundPort: UInt16? { lock.withLock { listener?.port?.rawValue } }

    /// Começa a escutar; lança se a porta estiver ocupada ou o listener falhar.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let nwPort = requestedPort == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        lock.withLock { self.listener = listener }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case let .failed(error): once.resume(.failure(error))
                case let .waiting(error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(AIError.cancelled))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Espera o redirecionamento. Cancelar a tarefa ou chamar `stop()` encerra a espera.
    func callback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, any Error>) in
                lock.lock()
                if let delivered {
                    lock.unlock()
                    continuation.resume(returning: delivered)
                } else if stopped {
                    lock.unlock()
                    continuation.resume(throwing: AIError.cancelled)
                } else {
                    pending = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            stop()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let listener = listener
        self.listener = nil
        let waiting = pending
        pending = nil
        lock.unlock()
        listener?.cancel()
        waiting?.resume(throwing: AIError.cancelled)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let parsed = Self.parse(requestLine: request)
            let body = parsed == nil ? Self.notFound : Self.success
            let status = parsed == nil ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let parsed { deliver(parsed) }
        }
    }

    /// Só o primeiro callback vale (uso único).
    private func deliver(_ callback: Callback) {
        lock.lock()
        guard delivered == nil else { lock.unlock(); return }
        delivered = callback
        let waiting = pending
        pending = nil
        lock.unlock()
        waiting?.resume(returning: callback)
    }

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

/// Validação do callback contra a tentativa (pura, testável).
enum ChatGPTLoginValidation {
    enum Failure: Error, Equatable {
        /// O ChatGPT negou ou o usuário cancelou na página.
        case denied
        /// `state` diferente: resposta de outra tentativa (ou forjada). Nunca troca o código.
        case stateMismatch
    }

    /// Devolve o código a trocar. Um código colado sozinho não traz `state`; qualquer `state` presente tem
    /// que bater. O listener sempre recebe `state` — por isso `requireState`.
    static func code(from callback: ChatGPTLoopbackListener.Callback, attempt: ChatGPTLoginAttempt,
                     requireState: Bool) throws(Failure) -> String {
        guard callback.error == nil, let code = callback.code, !code.isEmpty else { throw .denied }
        if let state = callback.state {
            guard state == attempt.state else { throw .stateMismatch }
        } else if requireState {
            throw .stateMismatch
        }
        return code
    }
}
