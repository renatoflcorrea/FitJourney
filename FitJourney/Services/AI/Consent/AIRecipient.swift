import Foundation

/// Identidade de quem recebe os dados; o modelo não integra a chave, exceto pelo criador.
struct AIRecipient: Sendable, Hashable {
    struct Creator: Sendable, Hashable {
        let id: String
        let name: String
        let article: String
    }
    let provider: AIProviderID
    let creator: Creator?
    let host: String?
    let model: String

    var key: String {
        switch provider {
        case .openRouter, .openCode: "\(provider.rawValue):\(creator?.id ?? model.lowercased())"
        case .custom: "custom:\(host ?? "")"
        default: provider.rawValue
        }
    }
    var displayName: String {
        switch provider {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter · \(creator?.name ?? model)"
        case .openCode: "OpenCode · \(creator?.name ?? model)"
        case .custom: host ?? ""
        case .chatGPT: String(localized: "OpenAI (sua conta ChatGPT)")
        }
    }
    var article: String {
        switch provider {
        case .openAI, .anthropic, .chatGPT: "a"
        case .openRouter, .openCode, .custom: "o"
        }
    }
    var isLocalNetwork: Bool { provider == .custom && host.map(ProviderReadiness.isLocalNetworkHost) == true }
    var privacyURL: URL? {
        let value: String? = switch provider {
        case .openAI, .chatGPT: "https://openai.com/policies/privacy-policy/"
        case .anthropic: "https://www.anthropic.com/legal/privacy"
        case .openRouter: "https://openrouter.ai/privacy"
        case .openCode: "https://opencode.ai/legal/privacy-policy"
        case .custom: nil
        }
        return value.flatMap(URL.init(string:))
    }
    var modelURL: URL? {
        guard provider == .openRouter else { return nil }
        return URL(string: "https://openrouter.ai/")?.appending(path: model)
    }
}

enum AIRecipientResolver {
    private static let creators: [(prefix: String, id: String, name: String, article: String)] = [
        ("gpt-", "openai", "OpenAI", "a"), ("claude-", "anthropic", "Anthropic", "a"),
        ("glm-", "z-ai", "Z.ai", "a"), ("qwen", "alibaba", "Alibaba (Qwen)", "a"),
        ("mimo-", "xiaomi", "Xiaomi", "a"), ("deepseek-", "deepseek", "DeepSeek", "a"),
        ("kimi-", "moonshot", "Moonshot AI", "a"), ("hy", "tencent", "Tencent", "a"),
        ("minimax-", "minimax", "MiniMax", "a"), ("gemini-", "google", "Google", "o"),
        ("grok-", "xai", "xAI", "a"),
    ]
    private static let routerCreators: [String: (String, String)] = [
        "openai": ("OpenAI", "a"), "anthropic": ("Anthropic", "a"), "google": ("Google", "o"),
        "z-ai": ("Z.ai", "a"), "qwen": ("Alibaba (Qwen)", "a"), "alibaba": ("Alibaba (Qwen)", "a"),
        "xiaomi": ("Xiaomi", "a"), "deepseek": ("DeepSeek", "a"), "moonshotai": ("Moonshot AI", "a"),
        "tencent": ("Tencent", "a"), "minimax": ("MiniMax", "a"), "x-ai": ("xAI", "a"),
    ]
    static func resolve(settings: ProviderSettings) -> AIRecipient {
        let model = settings.model
        let lower = model.lowercased()
        var creator: AIRecipient.Creator?
        if settings.provider == .openRouter {
            let id = String(lower.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            let info = routerCreators[id]
            creator = .init(id: id, name: info?.0 ?? id, article: info?.1 ?? "o")
        } else if settings.provider == .openCode {
            if let entry = creators.first(where: { lower.hasPrefix($0.prefix) }) {
                creator = .init(id: entry.id, name: entry.name, article: entry.article)
            } else {
                creator = .init(id: lower, name: model, article: "o")
            }
        }
        return AIRecipient(provider: settings.provider, creator: creator,
                           host: settings.provider == .custom ? settings.customBaseURL?.host?.lowercased() : nil,
                           model: model)
    }
}
