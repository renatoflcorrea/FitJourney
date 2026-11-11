import Foundation

/// Configuração **não secreta** do Coach: provedor, modelo e URL própria. Fica em UserDefaults;
/// a chave fica só no Keychain (`SecretStore`).
struct ProviderSettings: Codable, Sendable, Hashable {
    var provider: AIProviderID
    /// Modelo por provedor (trocar de provedor e voltar mantém a escolha anterior).
    var models: [AIProviderID: String]
    /// URL base do provedor `custom` (ex.: `http://localhost:11434/v1` para Ollama).
    var customBaseURL: URL?

    static let `default` = ProviderSettings(provider: .openAI, models: [:], customBaseURL: nil)

    init(provider: AIProviderID, models: [AIProviderID: String] = [:], customBaseURL: URL? = nil) {
        self.provider = provider
        self.models = models
        self.customBaseURL = customBaseURL
    }

    /// Modelo escolhido para o provedor atual, ou o primeiro sugerido do catálogo.
    var model: String {
        get { model(for: provider) }
        set { models[provider] = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func model(for provider: AIProviderID) -> String {
        let chosen = models[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chosen.isEmpty ? ProviderCatalog.descriptor(for: provider).defaultModel : chosen
    }

    func baseURL(for provider: AIProviderID) -> URL? {
        provider == .custom ? customBaseURL : ProviderCatalog.descriptor(for: provider).defaultBaseURL
    }

    private enum CodingKeys: String, CodingKey { case provider, models, customBaseURL }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? values.decodeIfPresent(AIProviderID.self, forKey: .provider)) ?? .openAI
        let raw = (try? values.decodeIfPresent([String: String].self, forKey: .models)) ?? [:]
        models = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            AIProviderID(rawValue: key).map { ($0, value) }
        })
        customBaseURL = try? values.decodeIfPresent(URL.self, forKey: .customBaseURL)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: .models)
        try container.encodeIfPresent(customBaseURL, forKey: .customBaseURL)
    }
}

/// Avaliação local da configuração (não testa a chave na rede).
enum ProviderReadiness: Sendable, Equatable {
    case ready
    case missingModel
    case invalidEndpoint
    case missingAPIKey(AIProviderID)

    var isReady: Bool { self == .ready }

    static func evaluate(_ settings: ProviderSettings, hasAPIKey: Bool) -> ProviderReadiness {
        let descriptor = ProviderCatalog.descriptor(for: settings.provider)
        guard !settings.model.isEmpty else { return .missingModel }
        guard let url = settings.baseURL(for: settings.provider), isAcceptable(url) else { return .invalidEndpoint }
        if descriptor.requiresAPIKey, !hasAPIKey { return .missingAPIKey(settings.provider) }
        return .ready
    }

    /// HTTPS sempre; HTTP só para rede local (Ollama no Mac/LAN). Sem credenciais na URL.
    static func isAcceptable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }
}

/// Persistência das configurações em UserDefaults (chave versionada).
struct ProviderSettingsStore: Sendable {
    static let key = "coach.providerSettings.v1"
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> ProviderSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else { return .default }
        return settings
    }

    func save(_ settings: ProviderSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
