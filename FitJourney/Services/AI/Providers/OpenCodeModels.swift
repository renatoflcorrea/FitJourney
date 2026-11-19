import Foundation

struct OpenCodeModel: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var readsImages: Bool
    var structuredOutput: Bool
    var inputPrice: Double?
    var outputPrice: Double?
    var trainsOnData: Bool
    var zeroDataRetention: Bool
}

struct OpenCodeModelCache {
    struct Snapshot: Codable, Sendable, Equatable {
        var fetchedAt: Date
        var models: [OpenCodeModel]
        var credentialHash: String? = nil
    }
    static let key = "coach.openCodeModels.v1"
    static let ttl: TimeInterval = 24 * 3600
    var defaults: UserDefaults = .standard
    func load() -> Snapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    func save(_ snapshot: Snapshot) {
        let previous = load()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
        if previous?.models != snapshot.models { AIAvailability.postChange() }
    }
}

enum OpenCodeModelCatalog {
    static func eligible(_ models: [OpenCodeModel]) -> [OpenCodeModel] {
        models.filter { $0.readsImages && !$0.trainsOnData && !OpenCodeGo.isFreeModel($0.id) }
    }
    static func parse(_ data: Data) -> [OpenCodeModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [Any] else { return [] }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let item = item as? [String: Any], let raw = item["id"] as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, (item["type"] as? String ?? "chat") == "chat",
                  !OpenCodeGo.isFreeModel(id), seen.insert(id).inserted else { return nil }
            let modalities = item["modalities"] as? [String: Any]
            let capabilities = item["capabilities"] as? [String: Any]
            let cost = item["cost"] as? [String: Any]
            let text = cost?["text"] as? [String: Any]
            let input = text?["input"] as? [String: Any]
            let output = text?["output"] as? [String: Any]
            let go = item["go"] as? [String: Any]
            return OpenCodeModel(id: id, name: item["name"] as? String ?? id,
                readsImages: (modalities?["input"] as? [String] ?? []).contains { $0.lowercased().hasPrefix("image/") },
                structuredOutput: capabilities?["structured_output"] as? Bool ?? false,
                inputPrice: input?["price"] as? Double, outputPrice: output?["price"] as? Double,
                trainsOnData: go?["training"] as? Bool ?? false, zeroDataRetention: go?["zdr"] as? Bool ?? false)
        }
    }
    static func pickerModels(discovered: [OpenCodeModel]?, suggested: [String] = OpenCodeGo.suggestedModels, limit: Int = 8) -> [String] {
        guard let discovered else { return Array(suggested.prefix(max(0, limit))) }
        let eligible = eligible(discovered)
        let first = suggested.filter { id in eligible.contains { $0.id == id } }
        let rest = eligible.filter { !first.contains($0.id) }.sorted {
            let a = ($0.inputPrice ?? .infinity, $0.outputPrice ?? .infinity, $0.id)
            let b = ($1.inputPrice ?? .infinity, $1.outputPrice ?? .infinity, $1.id)
            return a < b
        }.map(\.id)
        var choices = first + rest
        // A ordenação por preço não deve desempatar Lunas: usar a ordem original do catálogo.
        let lunas = eligible.map(\.id).filter { $0.lowercased().contains("luna") }
        if let preferred = ModelDefaults.preferred(in: lunas, provider: .openCode),
           let index = choices.firstIndex(of: preferred) { choices.remove(at: index); choices.insert(preferred, at: 0) }
        return Array(choices.prefix(max(0, limit)))
    }
    static func capabilities(model: String, cache: OpenCodeModelCache.Snapshot?) -> AttachmentCapabilities {
        let slug = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        let cached = cache?.models.first { $0.id.lowercased() == model.lowercased() }
        let vision = cached?.readsImages ?? ((OpenCodeGo.staticVisionModels.contains(slug) || OpenCodeGo.visionPrefixes.contains { slug.hasPrefix($0) }) && !OpenCodeGo.textOnlyModels.contains(slug))
        return AttachmentCapabilities(supportsImages: vision, supportsPDF: false)
    }
    static func trainsOnData(model: String, cache: OpenCodeModelCache.Snapshot?) -> Bool {
        cache?.models.first { $0.id.lowercased() == model.lowercased() }?.trainsOnData ?? false
    }
}

typealias OpenCodeDiscovery = (models: [OpenCodeModel], keyRejected: Bool)

actor OpenCodeModelLister {
    private let apiKey: String
    private let client: HTTPClient
    private let cache: OpenCodeModelCache
    private let clock: @Sendable () -> Date
    private let sessionID: String
    private let modelsURL: URL
    private let generationCache: ModelCache
    init(apiKey: String, client: HTTPClient = HTTPClient(), defaults: UserDefaults = .standard,
         clock: @escaping @Sendable () -> Date = { Date() }, modelsURL: URL = OpenCodeGo.modelsURL) {
        self.apiKey = apiKey
        self.client = client.withRetryPolicy(.none).withErrorDialect(.openCode).addingSensitiveHeaders(["User-Agent", "x-opencode-session"])
        self.cache = OpenCodeModelCache(defaults: defaults)
        self.generationCache = ModelCache(defaults: defaults)
        self.clock = clock
        self.modelsURL = modelsURL
        self.sessionID = OpenCodeGo.sessionID(installationID: OpenCodeGo.installationID(defaults: defaults))
    }
    func discover(refresh: Bool = false) async -> OpenCodeDiscovery {
        let fingerprint = ModelCache.fingerprint(apiKey)
        var cached = cache.load()
        if let existing = cached, existing.credentialHash != fingerprint {
            cache.defaults.removeObject(forKey: OpenCodeModelCache.key)
            generationCache.clear(.openCode)
            cached = nil
        }
        if cached?.models.isEmpty == true { cached = nil }
        let generation = generationCache.activate(.openCode, identity: fingerprint)
        let age = cached.map { clock().timeIntervalSince($0.fetchedAt) }
        if !refresh, let cached, let age, age >= 0, age < OpenCodeModelCache.ttl { return (cached.models, false) }
        let fallback = cached?.models ?? OpenCodeGo.suggestedModels.map {
            OpenCodeModel(id: $0, name: $0, readsImages: true, structuredOutput: false, inputPrice: nil, outputPrice: nil, trainsOnData: false, zeroDataRetention: false)
        }
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FitJourney/\(ChatGPTResponsesGateway.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        do {
            let (data, response) = try await client.dataAllowingErrorStatus(for: request)
            guard generationCache.isCurrent(generation, provider: .openCode) else {
                return (OpenCodeGo.suggestedModels.map {
                    OpenCodeModel(id: $0, name: $0, readsImages: true, structuredOutput: false, inputPrice: nil, outputPrice: nil, trainsOnData: false, zeroDataRetention: false)
                }, false)
            }
            if response.statusCode == 401 { return (fallback, true) }
            guard (200 ..< 300).contains(response.statusCode) else { return (fallback, false) }
            let models = OpenCodeModelCatalog.parse(data)
            guard !models.isEmpty else { return (fallback, false) }
            cache.save(.init(fetchedAt: clock(), models: models, credentialHash: fingerprint))
            return (models, false)
        } catch {
            guard generationCache.isCurrent(generation, provider: .openCode) else {
                return (OpenCodeGo.suggestedModels.map {
                    OpenCodeModel(id: $0, name: $0, readsImages: true, structuredOutput: false, inputPrice: nil, outputPrice: nil, trainsOnData: false, zeroDataRetention: false)
                }, false)
            }
            return (fallback, false)
        }
    }
}
