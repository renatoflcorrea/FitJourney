import Foundation

/// Metadados estáticos de provedor. Listar um provedor nunca autoriza um pedido de rede.
struct ProviderDescriptor: Sendable, Hashable, Identifiable {
    let id: AIProviderID
    let name: String
    /// URL base padrão (`nil` = o usuário precisa informar).
    let defaultBaseURL: URL?
    /// `false` = chave opcional (ex.: Ollama local).
    let requiresAPIKey: Bool
    /// Sugestões editáveis para o seletor de modelo — o usuário pode digitar qualquer outro.
    let suggestedModels: [String]
    /// Onde o usuário cria a chave (para o texto de ajuda da UI).
    let keyHelpURL: URL?

    var defaultModel: String { suggestedModels.first ?? "" }
    /// Chave no `SecretStore`.
    var secretKey: SecretKey { SecretKey.apiKey(id) }
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
            id: .custom, name: String(localized: "Compatível com OpenAI (URL própria)"),
            defaultBaseURL: nil,
            requiresAPIKey: false,
            suggestedModels: ["llama3.1"],
            keyHelpURL: nil),
    ]

    static func descriptor(for id: AIProviderID) -> ProviderDescriptor {
        // Todo AIProviderID tem descritor (coberto por teste).
        all.first { $0.id == id } ?? all[0]
    }
}
