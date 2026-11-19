import Foundation

/// Invólucro fino de `URLSession` (porta do fireplaice): timeouts explícitos, cancelamento e
/// mapeamento de status em `AIError`.
///
/// **Nunca loga cabeçalhos nem corpos.** Corpos de erro são limpos das credenciais exatas do
/// pedido (Authorization, x-api-key e os cabeçalhos marcados como sensíveis) e do `Redactor`
/// antes de virarem mensagem.
struct HTTPClient: Sendable {
    enum ErrorDialect: Sendable, Hashable { case standard, openCode, openRouter }
    struct Timeouts: Sendable, Hashable {
        var chat: TimeInterval
        static let standard = Timeouts(chat: 120)
    }

    /// Repetição antes do stream começar: 429, 529/503 e `overloaded`, honrando `Retry-After`.
    struct RetryPolicy: Sendable, Hashable {
        var maxRetries: Int = 2
        var baseDelay: TimeInterval = 1
        /// Atraso máximo aceito; um `Retry-After` maior desiste e devolve o erro.
        var maxDelay: TimeInterval = 20

        static let standard = RetryPolicy()
        static let none = RetryPolicy(maxRetries: 0)

        /// Atraso para a tentativa `attempt` (0, 1…), ou `nil` se não deve repetir.
        func delay(for error: any Error, attempt: Int) -> TimeInterval? {
            guard attempt < maxRetries, let error = error as? AIError else { return nil }
            let backoff = baseDelay * pow(2, Double(attempt))
            switch error {
            case let .rateLimited(retryAfter):
                let wait = retryAfter ?? backoff
                return wait <= maxDelay ? wait : nil
            case let .server(status, message):
                let overloaded = status == 529 || status == 503 || message.lowercased().contains("overloaded")
                return overloaded ? min(backoff, maxDelay) : nil
            default:
                return nil
            }
        }
    }

    /// Sessão efêmera própria (sem cache em disco nem cookies); redirecionamentos são recusados.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private let sensitiveHeaderNames: Set<String>
    let retryPolicy: RetryPolicy
    /// 403 vira `badRequest(status: 403)` em vez de `unauthorized` (o ChatGPT distingue token vencido de bloqueio).
    private let forbiddenKeepsStatus: Bool
    private let errorDialect: ErrorDialect

    init(session: URLSession = HTTPClient.sharedSession, sensitiveHeaderNames: Set<String> = [],
         retryPolicy: RetryPolicy = .standard, forbiddenKeepsStatus: Bool = false, errorDialect: ErrorDialect = .standard) {
        self.session = session
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.retryPolicy = retryPolicy
        self.forbiddenKeepsStatus = forbiddenKeepsStatus
        self.errorDialect = errorDialect
    }

    func addingSensitiveHeaders(_ names: some Sequence<String>) -> HTTPClient {
        HTTPClient(session: session, sensitiveHeaderNames: sensitiveHeaderNames.union(names.map { $0.lowercased() }),
                   retryPolicy: retryPolicy, forbiddenKeepsStatus: forbiddenKeepsStatus, errorDialect: errorDialect)
    }

    func withRetryPolicy(_ policy: RetryPolicy) -> HTTPClient {
        HTTPClient(session: session, sensitiveHeaderNames: sensitiveHeaderNames, retryPolicy: policy,
                   forbiddenKeepsStatus: forbiddenKeepsStatus, errorDialect: errorDialect)
    }

    func keepingForbiddenStatus() -> HTTPClient {
        HTTPClient(session: session, sensitiveHeaderNames: sensitiveHeaderNames, retryPolicy: retryPolicy,
                   forbiddenKeepsStatus: true, errorDialect: errorDialect)
    }

    func withErrorDialect(_ dialect: ErrorDialect) -> HTTPClient {
        HTTPClient(session: session, sensitiveHeaderNames: sensitiveHeaderNames, retryPolicy: retryPolicy,
                   forbiddenKeepsStatus: forbiddenKeepsStatus, errorDialect: dialect)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetry { try await dataOnce(for: request) }
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await withRetry { try await bytesOnce(for: request) }
    }

    private func withRetry<Value>(_ operation: () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard let delay = retryPolicy.delay(for: error, attempt: attempt) else { throw error }
                attempt += 1
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw AIError.cancelled
                }
            }
        }
    }

    /// Como `data(for:)`, mas devolve 4xx/5xx para quem chama decidir (OAuth distingue 400 `invalid_grant`,
    /// 401 e 403). Redirecionamentos continuam recusados; sem repetição automática.
    func dataAllowingErrorStatus(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await dataOnce(for: request, validateStatus: false)
    }

    private func dataOnce(for request: URLRequest, validateStatus: Bool = true) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectRefusingDelegate())
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network(code: URLError.badServerResponse.rawValue, retryable: false)
            }
            if validateStatus || (300 ..< 400).contains(http.statusCode) {
                try Self.validate(http, data: data, request: request, sensitiveHeaders: sensitiveHeaderNames,
                                  forbiddenKeepsStatus: forbiddenKeepsStatus, errorDialect: errorDialect)
            }
            return (data, http)
        } catch {
            throw Self.normalize(error)
        }
    }

    private func bytesOnce(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusingDelegate())
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network(code: URLError.badServerResponse.rawValue, retryable: false)
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 64_000 { break }
                }
                try Self.validate(http, data: body, request: request, sensitiveHeaders: sensitiveHeaderNames,
                                  forbiddenKeepsStatus: forbiddenKeepsStatus, errorDialect: errorDialect)
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

    static func isOpenRouterNoHost(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no endpoints found") || lower.contains("no available providers")
    }

    static var openRouterNoHostMessage: String {
        String(localized: "Nenhum serviço que executa este modelo atende à exigência de não guardar seus dados. Escolha outro modelo.")
    }

    static func validate(_ response: HTTPURLResponse, data: Data, request: URLRequest? = nil,
                         sensitiveHeaders: Set<String> = [], forbiddenKeepsStatus: Bool = false, errorDialect: ErrorDialect = .standard) throws {
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
        if errorDialect == .openRouter, isOpenRouterNoHost(safeBody) {
            throw AIError.badRequest(status: status, message: openRouterNoHostMessage)
        }
        if errorDialect == .openCode {
            let lower = safeBody.lowercased()
            if status == 403 && (lower.contains("free tier") || lower.contains("within opencode")) {
                throw AIError.notConfigured(reason: String(localized: "modelos “-free” só funcionam dentro do OpenCode; escolha outro modelo"))
            }
            if status == 402 {
                throw AIError.notConfigured(reason: String(localized: "a assinatura do OpenCode Go não está ativa; confira em opencode.ai"))
            }
            if status == 429 {
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                if let wait, wait.isFinite, wait >= 0, wait <= 20 { throw AIError.rateLimited(retryAfter: wait) }
                throw AIError.usageLimitReached(retryAfter: wait.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            }
        }
        switch status {
        case 300 ..< 400:
            throw AIError.badRequest(status: status, message: "redirecionamento recusado")
        case 403 where forbiddenKeepsStatus:
            throw AIError.badRequest(status: 403, message: message)
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

/// Recusa qualquer redirecionamento: a API de um provedor não deveria redirecionar, e seguir um
/// redirecionamento poderia levar a credencial (Authorization/x-api-key) para outra origem.
/// O 3xx vira erro de status no `validate`.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
