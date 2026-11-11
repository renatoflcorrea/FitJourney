import Foundation

/// Invólucro fino de `URLSession` (porta do fireplaice): timeouts explícitos, cancelamento e
/// mapeamento de status em `AIError`.
///
/// **Nunca loga cabeçalhos nem corpos.** Corpos de erro são limpos das credenciais exatas do
/// pedido (Authorization, x-api-key e os cabeçalhos marcados como sensíveis) e do `Redactor`
/// antes de virarem mensagem.
struct HTTPClient: Sendable {
    struct Timeouts: Sendable, Hashable {
        var chat: TimeInterval
        static let standard = Timeouts(chat: 120)
    }

    private let session: URLSession
    private let sensitiveHeaderNames: Set<String>

    init(session: URLSession = .shared, sensitiveHeaderNames: Set<String> = []) {
        self.session = session
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
    }

    func addingSensitiveHeaders(_ names: some Sequence<String>) -> HTTPClient {
        HTTPClient(session: session, sensitiveHeaderNames: sensitiveHeaderNames.union(names.map { $0.lowercased() }))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(
                for: request, delegate: RedirectCredentialDelegate(sensitiveHeaderNames: sensitiveHeaderNames))
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network(code: URLError.badServerResponse.rawValue, retryable: false)
            }
            try Self.validate(http, data: data, request: request, sensitiveHeaders: sensitiveHeaderNames)
            return (data, http)
        } catch {
            throw Self.normalize(error)
        }
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(
                for: request, delegate: RedirectCredentialDelegate(sensitiveHeaderNames: sensitiveHeaderNames))
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network(code: URLError.badServerResponse.rawValue, retryable: false)
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 64_000 { break }
                }
                try Self.validate(http, data: body, request: request, sensitiveHeaders: sensitiveHeaderNames)
                throw AIError.network(code: URLError.badServerResponse.rawValue, retryable: false)
            }
            return (bytes, http)
        } catch {
            throw Self.normalize(error)
        }
    }

    // MARK: - Mapeamento de erros

    static func normalize(_ error: any Error) -> any Error {
        switch error {
        case let error as AIError: error
        case is CancellationError: AIError.cancelled
        case let error as URLError: map(error)
        default: error
        }
    }

    static func validate(_ response: HTTPURLResponse, data: Data, request: URLRequest? = nil,
                         sensitiveHeaders: Set<String> = []) throws {
        let status = response.statusCode
        guard !(200 ..< 300).contains(status) else { return }

        // Provedores podem ecoar credenciais: remove os valores exatos antes de truncar/regex.
        var safeBody = String(decoding: data, as: UTF8.self)
        for (header, value) in request?.allHTTPHeaderFields ?? [:] {
            let name = header.lowercased()
            guard name == "authorization" || name == "x-api-key" || name == "api-key" || sensitiveHeaders.contains(name)
            else { continue }
            let credential = name == "authorization" && value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
            if !credential.isEmpty { safeBody = safeBody.replacingOccurrences(of: credential, with: "<redacted>") }
        }
        let message = errorMessage(from: Data(safeBody.utf8))
        switch status {
        case 401, 403:
            throw AIError.unauthorized(message: message)
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            throw AIError.rateLimited(retryAfter: header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 400 ..< 500:
            throw AIError.badRequest(status: status, message: message)
        default:
            throw AIError.server(status: status, message: message)
        }
    }

    /// `error.message` (OpenAI/Anthropic), `message` ou `error` string; senão o começo do corpo.
    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Redactor.redact(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return Redactor.redact(message)
        }
        if let message = object["message"] as? String { return Redactor.redact(message) }
        if let error = object["error"] as? String { return Redactor.redact(error) }
        return Redactor.redact(String(decoding: data.prefix(300), as: UTF8.self))
    }

    static func map(_ error: URLError) -> AIError {
        if error.code == .cancelled { return .cancelled }
        let retryable: Set<URLError.Code> = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
        ]
        return .network(code: error.code.rawValue, retryable: retryable.contains(error.code))
    }
}

/// Sem isto a URLSession repassa cabeçalhos de credencial em redirecionamentos para outra origem.
private final class RedirectCredentialDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let sensitiveHeaderNames: Set<String>

    init(sensitiveHeaderNames: Set<String>) {
        self.sensitiveHeaderNames = sensitiveHeaderNames
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let source = response.url, let destination = request.url else { return request }
        var redirected = request
        if Self.origin(source) != Self.origin(destination) {
            let credentials: Set = ["authorization", "proxy-authorization", "cookie", "x-api-key", "api-key"]
            for header in (redirected.allHTTPHeaderFields ?? [:]).keys {
                let normalized = header.lowercased()
                if credentials.contains(normalized) || sensitiveHeaderNames.contains(normalized) {
                    redirected.setValue(nil, forHTTPHeaderField: header)
                }
            }
        }
        return redirected
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
    }
}
