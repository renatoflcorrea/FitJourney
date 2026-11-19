import Foundation

/// Metadados estáticos de provedor. Listar um provedor nunca autoriza um pedido de rede.
struct ProviderDescriptor: Sendable, Hashable, Identifiable {
    let id: AIProviderID
    /// Nome completo (seletor de provedor). Experimentais carregam o aviso no próprio nome.
    let name: String
    /// URL base padrão (`nil` = o usuário precisa informar).
    let defaultBaseURL: URL?
    /// `false` = chave opcional (ex.: Ollama local).
    let requiresAPIKey: Bool
    /// Sugestões editáveis para o seletor de modelo — o usuário pode digitar qualquer outro.
    let suggestedModels: [String]
    /// Onde o usuário cria a chave (para o texto de ajuda da UI).
    let keyHelpURL: URL?
    /// Nome curto para resumos ("ChatGPT (login) · gpt-6-luna"); `nil` = `name`.
    var shortName: String?
    /// Endpoint não documentado/não oficial: a UI mostra o aviso de risco.
    var isExperimental = false

    var defaultModel: String { suggestedModels.first ?? "" }
    var displayShortName: String { shortName ?? name }
    /// Credencial por login OAuth (ChatGPT), não por chave de API.
    var usesChatGPTLogin: Bool { id == .chatGPT }
    /// Onde a credencial fica no `SecretStore`: a chave de API, ou o blob do login ChatGPT.
    var secretKey: SecretKey { usesChatGPTLogin ? .chatGPTAuth : SecretKey.apiKey(id) }
}

enum ProviderCatalog {
    static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .openAI, name: "OpenAI",
            defaultBaseURL: URL(string: "https://api.openai.com/v1"),
            requiresAPIKey: true,
            suggestedModels: ["gpt-5-mini", "gpt-5", "gpt-4.1-mini"],
            keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        ProviderDescriptor(
            id: .anthropic, name: "Anthropic",
            defaultBaseURL: URL(string: "https://api.anthropic.com/v1"),
            requiresAPIKey: true,
            suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
            keyHelpURL: URL(string: "https://console.anthropic.com/settings/keys")),
        ProviderDescriptor(
            id: .openRouter, name: "OpenRouter",
            defaultBaseURL: URL(string: "https://openrouter.ai/api/v1"),
            requiresAPIKey: true,
            suggestedModels: ["openai/gpt-5-mini", "anthropic/claude-sonnet-5.5", "google/gemini-2.5-pro"],
            keyHelpURL: URL(string: "https://openrouter.ai/keys")),
        ProviderDescriptor(
            id: .openCode, name: "OpenCode Go",
            defaultBaseURL: OpenCodeGo.baseURL,
            requiresAPIKey: true,
            suggestedModels: OpenCodeGo.suggestedModels,
            keyHelpURL: URL(string: "https://opencode.ai/auth")),
        ProviderDescriptor(
            id: .custom, name: String(localized: "Compatível com OpenAI (URL própria)"),
            defaultBaseURL: nil,
            requiresAPIKey: false,
            suggestedModels: ["llama3.1"],
            keyHelpURL: nil),
        ProviderDescriptor(
            id: .chatGPT, name: String(localized: "ChatGPT (login) · Experimental / não oficial"),
            defaultBaseURL: ChatGPTResponsesGateway.defaultBaseURL,
            requiresAPIKey: false,
            suggestedModels: ChatGPTModelLister.fallbackModels,
            keyHelpURL: nil,
            shortName: String(localized: "ChatGPT (login)"),
            isExperimental: true),
    ]

    static func descriptor(for id: AIProviderID) -> ProviderDescriptor {
        // Todo AIProviderID tem descritor (coberto por teste).
        all.first { $0.id == id } ?? all[0]
    }
}
