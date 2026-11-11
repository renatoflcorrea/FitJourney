import Foundation

/// Configuração de transporte em memória. A credencial vem do `SecretStore`; este tipo
/// deliberadamente não é Codable nem `CustomStringConvertible` e nunca deve ser logado.
struct EndpointConfiguration: Sendable {
    enum Authentication: Sendable, Hashable {
        case none
        case bearer(String)
        case header(name: String, value: String)
    }

    var provider: AIProviderID
    var baseURL: URL
    var auth: Authentication
    var extraHeaders: [String: String]
    var timeouts: HTTPClient.Timeouts
    var quirks: ProviderQuirks

    init(provider: AIProviderID, baseURL: URL, auth: Authentication, extraHeaders: [String: String] = [:],
         timeouts: HTTPClient.Timeouts = .standard, quirks: ProviderQuirks = ProviderQuirks()) {
        self.provider = provider
        self.baseURL = baseURL
        self.auth = auth
        self.extraHeaders = extraHeaders
        self.timeouts = timeouts
        self.quirks = quirks
    }

    /// Nomes de cabeçalhos que carregam segredo (para limpeza de corpo de erro e redirecionamento).
    var sensitiveHeaderNames: Set<String> {
        var names = Set(extraHeaders.keys.map { $0.lowercased() })
        if case let .header(name, _) = auth { names.insert(name.lowercased()) }
        return names
    }

    func request(path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        switch auth {
        case .none: break
        case let .bearer(key): request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case let .header(name, value): request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Diferenças de fio por provedor; seleção e credenciais ficam na composição (`ProviderFactory`).
struct ProviderQuirks: Sendable, Hashable {
    /// Em 400 por `response_format`/schema, rebaixa jsonSchema → jsonObject → text (fireplaice).
    var structuredOutputFallback: Bool = true
    /// Força o nome do parâmetro de limite (`max_tokens`/`max_completion_tokens`); `nil` = por modelo.
    var tokenParameter: String?
    /// Envia `stream_options.include_usage` (OpenAI/OpenRouter; nem todo servidor compatível aceita).
    var includeStreamUsage: Bool = true
    /// Envia `strict: true` nas ferramentas.
    var strictTools: Bool = true
}

/// Diferenças por família de modelo, independentes do provedor que hospeda.
enum ModelCapabilities {
    /// gpt-5.x e série o recusam `max_tokens`.
    static func tokenParameter(for model: String) -> String {
        let slug = model.split(separator: "/").last.map(String.init) ?? model
        let needsCompletionTokens = slug.hasPrefix("gpt-5") || slug.hasPrefix("o1") || slug.hasPrefix("o3")
            || slug.hasPrefix("o4")
        return needsCompletionTokens ? "max_completion_tokens" : "max_tokens"
    }

    /// Modelos de raciocínio da OpenAI recusam `temperature` diferente do padrão.
    static func acceptsTemperature(_ model: String) -> Bool {
        tokenParameter(for: model) == "max_tokens"
    }
}
