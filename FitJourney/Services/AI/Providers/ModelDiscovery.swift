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
        // Estes provedores têm listadores próprios (OAuth e endpoint Go, respectivamente).
        // Não invalidar o cache da conta ao consultar esta API genérica.
        if provider == .chatGPT {
            let saved = cache.load(.chatGPT)
            if let saved, !saved.models.isEmpty { return (saved.models, true, saved.fetchedAt) }
            return (ChatGPTModelLister.fallbackModels, false, nil)
        }
        if provider == .openCode {
            let saved = OpenCodeModelCache(defaults: cache.defaults).load()
            if let saved, saved.credentialHash == ModelCache.fingerprint(apiKey ?? ""), !saved.models.isEmpty {
                let models = OpenCodeModelCatalog.pickerModels(discovered: saved.models, limit: .max)
                if !models.isEmpty { return (models, true, saved.fetchedAt) }
            }
            return (OpenCodeGo.suggestedModels, false, nil)
        }
        let fingerprint = ModelCache.fingerprint(apiKey ?? "")
        let urlIdentity = provider == .custom ? baseURL?.absoluteString : nil
        var cached = cache.load(provider)
        if let existing = cached, existing.credentialHash != fingerprint || existing.baseURL != urlIdentity {
            cache.clear(provider)
            cached = nil
        }
        if cached?.models.isEmpty == true { cached = nil }
        let generation = cache.activate(provider, identity: fingerprint + "|" + (urlIdentity ?? ""))
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
            guard cache.isCurrent(generation, provider: provider) else { return (fallback, false, nil) }
            let models = Self.parse(data, provider: provider)
            guard !models.isEmpty else { return (cached?.models ?? fallback, cached != nil, cached?.fetchedAt) }
            let now = clock()
            cache.save(.init(models: models, fetchedAt: now, credentialHash: fingerprint, baseURL: urlIdentity,
                             capabilities: Self.capabilities(data, provider: provider)), provider: provider)
            return (models, false, now)
        } catch {
            guard cache.isCurrent(generation, provider: provider) else { return (fallback, false, nil) }
            return (cached?.models ?? fallback, cached != nil, cached?.fetchedAt)
        }
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
                guard let range = id.range(of: #"-(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, options: .regularExpression) else { return false }
                return aliases.contains(String(id[..<range.lowerBound]).lowercased())
            }
        }
        return result
    }

    /// `/models` da OpenAI pode retornar só IDs. Não transformar ausência de metadados em "não suporta".
    /// O catálogo OpenRouter inclui também modelos inelegíveis, cujas capacidades ainda interessam
    /// quando a pessoa escolheu um deles manualmente antes da atualização da lista.
    static func capabilities(_ data: Data, provider: AIProviderID) -> [String: AttachmentCapabilities]? {
        guard provider == .openAI || provider == .openRouter,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return nil }
        var result: [String: AttachmentCapabilities] = [:]
        for item in items {
            guard let raw = item["id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { continue }
            let architecture = item["architecture"] as? [String: Any]
            let modalities = (architecture?["input_modalities"] ?? item["input_modalities"]) as? [String]
            let explicit = item["capabilities"] as? [String: Any]
            let image = (explicit?["vision"] as? Bool) ?? modalities.map { $0.contains { $0.lowercased() == "image" } }
            let pdf = (explicit?["pdf"] as? Bool) ?? modalities.flatMap { values -> Bool? in
                if values.contains(where: { ["pdf", "file"].contains($0.lowercased()) }) { return true }
                // OpenRouter converte PDFs em imagens. OpenAI não informa isso em `/models`.
                return provider == .openRouter ? image : nil
            }
            guard image != nil || pdf != nil else { continue }
            let slug = (id.split(separator: "/").last.map(String.init) ?? id)
            let staticImage = !slug.hasPrefix("gpt-3.5")
            let staticPDF = ["gpt-4o", "gpt-4.1", "gpt-5", "gpt-6", "o1", "o3", "o4"].contains { slug.hasPrefix($0) }
            result[id] = AttachmentCapabilities(supportsImages: image ?? staticImage,
                                                supportsPDF: pdf ?? (provider == .openRouter ? (image ?? true) : staticPDF))
        }
        return result.isEmpty ? nil : result
    }
}
