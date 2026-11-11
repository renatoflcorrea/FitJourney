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
        }
    }

    static func makeChat(settings: ProviderSettings, apiKey: String?, client: HTTPClient = HTTPClient()) throws -> ResolvedChat {
        let configuration = try endpoint(settings: settings, apiKey: apiKey)
        let gateway: any ChatGateway & StructuredCompleting = switch settings.provider {
        case .anthropic: AnthropicMessagesGateway(configuration: configuration, client: client)
        case .openAI, .openRouter, .custom: OpenAICompatibleChatGateway(configuration: configuration, client: client)
        }
        return ResolvedChat(gateway: gateway, model: settings.model, contextBudgetTokens: settings.contextBudgetTokens)
    }

    /// Lê configurações e chave e monta o gateway. Lança `AIError.notConfigured` se faltar algo.
    static func makeChat(settingsStore: ProviderSettingsStore = ProviderSettingsStore(),
                         secrets: any SecretStore, client: HTTPClient = HTTPClient()) throws -> ResolvedChat {
        let settings = settingsStore.load()
        let key = try secrets.string(for: ProviderCatalog.descriptor(for: settings.provider).secretKey)
        return try makeChat(settings: settings, apiKey: key, client: client)
    }
}
