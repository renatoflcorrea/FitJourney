import Foundation

/// Gateway pronto + modelo escolhido.
struct ResolvedChat: Sendable {
    var gateway: any ChatGateway & StructuredCompleting
    var model: String
    /// Orçamento de contexto (tokens aproximados) para a janela do histórico.
    var contextBudgetTokens: Int = ProviderSettings.cloudContextTokens
}

/// Composição pura: configurações + segredo → gateway. Sem rede, sem log.
///
/// O roteador por tarefa do fireplaice (`GatewayRouter`) não foi portado: o FitJourney tem uma
/// única tarefa (chat do Coach) e um único provedor ativo por vez.
enum ProviderFactory {
    static func endpoint(settings: ProviderSettings, apiKey: String?) throws -> EndpointConfiguration {
        let provider = settings.provider
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch ProviderReadiness.evaluate(settings, hasAPIKey: !key.isEmpty) {
        case .ready: break
        case .missingModel: throw AIError.notConfigured(reason: String(localized: "escolha um modelo"))
        case .invalidEndpoint: throw AIError.notConfigured(reason: String(localized: "URL do provedor inválida"))
        case .missingAPIKey: throw AIError.notConfigured(reason: String(localized: "informe a chave do provedor"))
        case .signedOut: throw AIError.signInRequired
        }
        guard let url = settings.baseURL(for: provider) else {
            throw AIError.notConfigured(reason: String(localized: "URL do provedor inválida"))
        }
        switch provider {
        case .openAI:
            return EndpointConfiguration(provider: .openAI, baseURL: url, auth: .bearer(key))
        case .openRouter:
            return EndpointConfiguration(
                provider: .openRouter, baseURL: url, auth: .bearer(key),
                extraHeaders: ["X-Title": "FitJourney"],
                quirks: ProviderQuirks(tokenParameter: "max_tokens"))
        case .anthropic:
            // `strict` desligado: validamos localmente (schema + Codable) e evitamos 400 por
            // palavras-chave de schema que o modo estrito da Anthropic não aceite.
            return EndpointConfiguration(provider: .anthropic, baseURL: url, auth: .header(name: "x-api-key", value: key),
                                         quirks: ProviderQuirks(strictTools: false))
        case .custom:
            return EndpointConfiguration(
                provider: .custom, baseURL: url, auth: key.isEmpty ? .none : .bearer(key),
                timeouts: HTTPClient.Timeouts(chat: 300),
                quirks: ProviderQuirks(includeStreamUsage: false, strictTools: false))
        case .chatGPT:
            // O ChatGPT usa login OAuth com renovação (`makeChatGPT`), não uma configuração com credencial fixa.
            throw AIError.notConfigured(reason: String(localized: "o ChatGPT (login) não usa chave de API"))
        }
    }

    /// - Parameter apiKey: a chave do provedor; no ChatGPT, o blob do login (renovações ficam só em memória —
    ///   em produção use `makeChat(settings:secrets:)`, que grava a renovação no Keychain).
    static func makeChat(settings: ProviderSettings, apiKey: String?, client: HTTPClient = HTTPClient()) throws -> ResolvedChat {
        if settings.provider == .chatGPT {
            let secrets = InMemorySecretStore(apiKey.map { [SecretKey.chatGPTAuth: $0] } ?? [:])
            return try makeChat(settings: settings, secrets: secrets, client: client)
        }
        let configuration = try endpoint(settings: settings, apiKey: apiKey)
        let gateway: any ChatGateway & StructuredCompleting = switch settings.provider {
        case .anthropic: AnthropicMessagesGateway(configuration: configuration, client: client)
        case .openAI, .openRouter, .custom, .chatGPT: OpenAICompatibleChatGateway(configuration: configuration, client: client)
        }
        return ResolvedChat(gateway: gateway, model: settings.model, contextBudgetTokens: settings.contextBudgetTokens)
    }

    /// Lê configurações e chave e monta o gateway. Lança `AIError.notConfigured` (ou `.signInRequired`) se faltar algo.
    static func makeChat(settingsStore: ProviderSettingsStore = ProviderSettingsStore(),
                         secrets: any SecretStore, client: HTTPClient = HTTPClient()) throws -> ResolvedChat {
        try makeChat(settings: settingsStore.load(), secrets: secrets, client: client)
    }

    static func makeChat(settings: ProviderSettings, secrets: any SecretStore,
                         client: HTTPClient = HTTPClient()) throws -> ResolvedChat {
        guard settings.provider == .chatGPT else {
            let key = try secrets.string(for: ProviderCatalog.descriptor(for: settings.provider).secretKey)
            return try makeChat(settings: settings, apiKey: key, client: client)
        }
        // Experimental: login da assinatura ChatGPT. A sessão renova o token e grava o blob no mesmo `SecretStore`.
        let store = SecretChatGPTStore(secrets: secrets)
        let signedIn = ((try? store.load()) ?? nil) != nil
        switch ProviderReadiness.evaluate(settings, hasAPIKey: signedIn) {
        case .ready: break
        case .signedOut: throw AIError.signInRequired
        case .missingModel: throw AIError.notConfigured(reason: String(localized: "escolha um modelo"))
        case .invalidEndpoint, .missingAPIKey: throw AIError.notConfigured(reason: String(localized: "URL do provedor inválida"))
        }
        let session = ChatGPTAuthSession(store: store, oauth: ChatGPTOAuthClient(client: client))
        let gateway = ChatGPTResponsesGateway(baseURL: settings.baseURL(for: .chatGPT) ?? ChatGPTResponsesGateway.defaultBaseURL,
                                              session: session, client: client)
        return ResolvedChat(gateway: gateway, model: settings.model, contextBudgetTokens: settings.contextBudgetTokens)
    }
}
