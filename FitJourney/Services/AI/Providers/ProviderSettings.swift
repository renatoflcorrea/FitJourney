import Foundation

/// Configuração **não secreta** do Coach: provedor, modelo e URL própria. Fica em UserDefaults;
/// a chave fica só no Keychain (`SecretStore`).
struct ProviderSettings: Codable, Sendable, Hashable {
    var provider: AIProviderID
    /// Modelo por provedor (trocar de provedor e voltar mantém a escolha anterior).
    var models: [AIProviderID: String]
    /// URL base do provedor `custom` (ex.: `http://localhost:11434/v1` para Ollama).
    var customBaseURL: URL?
    /// Janela de contexto (tokens aproximados) do provedor `custom`; `nil` = padrão conservador.
    var customContextTokens: Int?

    static let `default` = ProviderSettings(provider: .openAI, models: [:], customBaseURL: nil)

    /// Orçamento de contexto padrão (tokens aproximados) para provedores na nuvem e para `custom`.
    static let cloudContextTokens = 32_000
    static let customDefaultContextTokens = 8_000

    init(provider: AIProviderID, models: [AIProviderID: String] = [:], customBaseURL: URL? = nil,
         customContextTokens: Int? = nil) {
        self.provider = provider
        self.models = models
        self.customBaseURL = customBaseURL
        self.customContextTokens = customContextTokens
    }

    /// Orçamento de contexto do provedor atual, em tokens aproximados (≈ 4 caracteres por token).
    var contextBudgetTokens: Int {
        guard provider == .custom else { return Self.cloudContextTokens }
        return max(2_000, min(customContextTokens ?? Self.customDefaultContextTokens, 200_000))
    }

    /// Modelo escolhido para o provedor atual, ou o primeiro sugerido do catálogo.
    var model: String {
        get { model(for: provider) }
        set { models[provider] = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func model(for provider: AIProviderID) -> String {
        let chosen = models[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chosen.isEmpty { return chosen }
        let cached = ModelCache().load(provider)?.models ?? []
        return ModelDefaults.preferred(in: cached, provider: provider) ?? ProviderCatalog.descriptor(for: provider).defaultModel
    }

    func baseURL(for provider: AIProviderID) -> URL? {
        provider == .custom ? customBaseURL : ProviderCatalog.descriptor(for: provider).defaultBaseURL
    }

    private enum CodingKeys: String, CodingKey { case provider, models, customBaseURL, customContextTokens }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? values.decodeIfPresent(AIProviderID.self, forKey: .provider)) ?? .openAI
        let raw = (try? values.decodeIfPresent([String: String].self, forKey: .models)) ?? [:]
        models = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            AIProviderID(rawValue: key).map { ($0, value) }
        })
        customBaseURL = try? values.decodeIfPresent(URL.self, forKey: .customBaseURL)
        customContextTokens = try? values.decodeIfPresent(Int.self, forKey: .customContextTokens)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: .models)
        try container.encodeIfPresent(customBaseURL, forKey: .customBaseURL)
        try container.encodeIfPresent(customContextTokens, forKey: .customContextTokens)
    }
}

/// Avaliação local da configuração (não testa a chave na rede).
enum ProviderReadiness: Sendable, Equatable {
    case ready
    case missingModel
    case invalidEndpoint
    case missingAPIKey(AIProviderID)
    /// Provedor ChatGPT (login) sem login guardado.
    case signedOut

    var isReady: Bool { self == .ready }

    /// - Parameter hasAPIKey: há credencial guardada em `descriptor.secretKey` — a chave de API ou, no
    ///   ChatGPT, o blob do login.
    static func evaluate(_ settings: ProviderSettings, hasAPIKey: Bool) -> ProviderReadiness {
        let descriptor = ProviderCatalog.descriptor(for: settings.provider)
        if descriptor.usesChatGPTLogin, !hasAPIKey { return .signedOut }
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
        return isLocalNetworkHost(host)
    }

    /// `localhost`, `*.local` (Bonjour) ou IPv4 de rede privada/loopback/CGNAT:
    /// 10/8, 172.16/12, 192.168/16, 100.64/10, 127/8. Nomes comuns e IPv6 não contam.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), (0 ... 255).contains(value) else { return false }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16 ... 31): return true
        case (100, 64 ... 127): return true
        default: return false
        }
    }
}

/// Persistência das configurações em UserDefaults (chave versionada).
struct ProviderSettingsStore {
    static let key = "coach.providerSettings.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> ProviderSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else { return .default }
        return settings
    }

    func save(_ settings: ProviderSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
        AIAvailability.postChange()
    }
}
