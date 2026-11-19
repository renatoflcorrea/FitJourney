import Foundation

actor ModelDiscovery {
    private let client: HTTPClient
    private let cache: ModelCache
    private let clock: @Sendable () -> Date
    init(client: HTTPClient = HTTPClient(), defaults: UserDefaults = .standard,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client.withRetryPolicy(.none)
        self.cache = ModelCache(defaults: defaults)
        self.clock = clock
    }

    func models(for provider: AIProviderID, apiKey: String?, baseURL: URL? = nil, refresh: Bool = false)
        async -> (models: [String], fromCache: Bool, fetchedAt: Date?) {
        let fingerprint = ModelCache.fingerprint(apiKey ?? "")
        let urlIdentity = provider == .custom ? baseURL?.absoluteString : nil
        var cached = cache.load(provider)
        if let existing = cached, existing.credentialHash != fingerprint || existing.baseURL != urlIdentity {
            cache.clear(provider)
            cached = nil
        }
        let fallback = ProviderCatalog.descriptor(for: provider).suggestedModels
        if !refresh, let cached, !cached.models.isEmpty {
            let age = clock().timeIntervalSince(cached.fetchedAt)
            if age >= 0 && age < ModelCache.ttl { return (cached.models, true, cached.fetchedAt) }
        }
        guard let url = Self.url(provider: provider, baseURL: baseURL) else {
            return (cached?.models ?? fallback, cached != nil, cached?.fetchedAt)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            if provider == .anthropic { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            else { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }
        if provider == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        do {
            let data = try await client.data(for: request).0
            let models = Self.parse(data, provider: provider)
            guard !models.isEmpty else { return (cached?.models ?? fallback, cached != nil, cached?.fetchedAt) }
            let now = clock()
            cache.save(.init(models: models, fetchedAt: now, credentialHash: fingerprint, baseURL: urlIdentity), provider: provider)
            return (models, false, now)
        } catch { return (cached?.models ?? fallback, cached != nil, cached?.fetchedAt) }
    }

    static func url(provider: AIProviderID, baseURL: URL?) -> URL? {
        switch provider {
        case .openAI: return URL(string: "https://api.openai.com/v1/models")
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models?limit=1000")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/models")
        case .custom:
            guard let baseURL, ProviderReadiness.isAcceptable(baseURL) else { return nil }
            return baseURL.appending(path: "models")
        default: return nil
        }
    }

    static func parse(_ data: Data, provider: AIProviderID) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            guard let raw = item["id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = id.lowercased()
            guard !id.isEmpty else { continue }
            switch provider {
            case .openAI:
                let oSeries = lower.first == "o" && lower.dropFirst().first?.isNumber == true
                let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation", "instruct", "codex", "-pro"]
                guard (lower.hasPrefix("gpt-") || oSeries), !excluded.contains(where: lower.contains),
                      lower.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil else { continue }
            case .anthropic:
                guard lower.hasPrefix("claude-") else { continue }
            case .openRouter:
                let architecture = item["architecture"] as? [String: Any]
                guard (architecture?["input_modalities"] as? [String] ?? []).contains("image"),
                      (item["supported_parameters"] as? [String] ?? []).contains("tools"),
                      !lower.hasSuffix(":free") else { continue }
            default: break
            }
            if seen.insert(lower).inserted { result.append(id) }
        }
        if provider == .anthropic {
            let aliases = Set(result.map { $0.lowercased() })
            result.removeAll { id in
                guard let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) else { return false }
                return aliases.contains(String(id[..<range.lowerBound]).lowercased())
            }
        }
        return result
    }
}
