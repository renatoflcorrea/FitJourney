import Foundation

/// Modelos que a conta ChatGPT logada pode usar, do backend não oficial
/// (`GET /backend-api/codex/models?client_version=`) — porta simplificada de `ChatGPTModelLister` do fireplaice
/// (cache por conta). **Nunca lança**: qualquer falha devolve o último cache e depois a lista estática.
actor ChatGPTModelLister {
    /// O backend esconde modelos cujo `minimal_client_version` passa da versão enviada.
    static let defaultClientVersion = "0.155.0"

    /// Offline, deslogado ou se o endpoint mudar. Primeiro = padrão (confirmado no fireplaice); depois por prioridade.
    static let fallbackModels = [
        "gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5",
    ]

    private let baseURL: URL
    private let session: ChatGPTAuthSession
    private let client: HTTPClient
    private let originator: String
    private let userAgent: String
    private let clientVersion: String
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let modelCache: ModelCache
    private var cache: (accountID: String, models: [String], fetchedAt: Date)?

    init(baseURL: URL = ChatGPTResponsesGateway.defaultBaseURL, session: ChatGPTAuthSession,
         client: HTTPClient = HTTPClient(), originator: String = ChatGPTOAuthConfiguration.default.originator,
         version: String = ChatGPTResponsesGateway.appVersion,
         clientVersion: String = ChatGPTModelLister.defaultClientVersion, ttl: TimeInterval = ModelCache.ttl,
         defaults: UserDefaults = .standard,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.session = session
        self.client = client.addingSensitiveHeaders(ChatGPTResponsesGateway.sensitiveHeaders).withRetryPolicy(.none)
        self.originator = originator
        userAgent = "FitJourney/\(version)"
        self.clientVersion = clientVersion
        self.ttl = ttl
        self.modelCache = ModelCache(defaults: defaults)
        self.clock = clock
    }

    /// Cache fresco, depois a rede, depois cache vencido, depois a lista estática. Nunca vazia.
    func models(refresh: Bool = false) async -> [String] {
        guard let credentials = try? await session.credentials() else { return Self.fallbackModels }
        let accountHash = ModelCache.fingerprint(credentials.accountID)
        let persisted = modelCache.load(.chatGPT)
        if let persisted, persisted.credentialHash != accountHash { modelCache.clear(.chatGPT) }
        let generation = modelCache.activate(.chatGPT, identity: accountHash)
        let matching = persisted?.credentialHash == accountHash && persisted?.models.isEmpty == false ? persisted : nil
        let cached = cache?.accountID == credentials.accountID ? cache : matching.map {
            (accountID: credentials.accountID, models: $0.models, fetchedAt: $0.fetchedAt)
        }
        if !refresh, let cached, case let age = clock().timeIntervalSince(cached.fetchedAt), age >= 0, age < ttl {
            return cached.models
        }
        do {
            var listed = Self.parse(try await fetch(credentials))
            guard modelCache.isCurrent(generation, provider: .chatGPT) else { return Self.fallbackModels }
            if let preferred = ModelDefaults.preferred(in: listed, provider: .chatGPT),
               let index = listed.firstIndex(of: preferred) { listed.remove(at: index); listed.insert(preferred, at: 0) }
            guard !listed.isEmpty else { return cached?.models ?? Self.fallbackModels }
            cache = (credentials.accountID, listed, clock())
            modelCache.save(.init(models: listed, fetchedAt: clock(), credentialHash: accountHash, baseURL: nil), provider: .chatGPT)
            return listed
        } catch {
            guard modelCache.isCurrent(generation, provider: .chatGPT) else { return Self.fallbackModels }
            return cached?.models ?? Self.fallbackModels
        }
    }

    private func fetch(_ credentials: ChatGPTCredentials) async throws -> Data {
        do {
            return try await client.data(for: makeRequest(credentials)).0
        } catch AIError.unauthorized {
            let renewed = try await session.credentialsAfterRejection(of: credentials.accessToken)
            return try await client.data(for: makeRequest(renewed)).0
        }
    }

    func makeRequest(_ credentials: ChatGPTCredentials) throws -> URLRequest {
        guard var parts = URLComponents(url: baseURL.appending(path: "models"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        parts.queryItems = [URLQueryItem(name: "client_version", value: clientVersion)]
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Mantém `visibility == "list"`, descarta duplicados e ordena por `priority` (ausente por último, estável).
    static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let models = root["models"]?.arrayValue else { return [] }
        var seen = Set<String>()
        var items: [(slug: String, priority: Double, offset: Int)] = []
        for (offset, model) in models.enumerated() {
            guard let slug = model["slug"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty,
                  model["visibility"]?.stringValue == "list", seen.insert(slug).inserted else { continue }
            var priority = Double.greatestFiniteMagnitude
            if case let .number(value)? = model["priority"] { priority = value }
            items.append((slug, priority, offset))
        }
        return items.sorted { ($0.priority, $0.offset) < ($1.priority, $1.offset) }.map(\.slug)
    }
}
