import Foundation

/// Tokens OAuth de um login da assinatura ChatGPT, guardados como **um único blob** no Keychain
/// (`SecretKey.chatGPTAuth`). Nunca logado: `description` é fixo e o tipo não é `CustomDebugStringConvertible`.
/// O `id_token` (que traz o e-mail) **não é guardado**: só se tiram dele a conta e o plano na hora da troca.
struct ChatGPTCredentials: Sendable, Codable, Equatable, CustomStringConvertible {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountID: String
    /// Rótulo curto do plano ("plus", "pro") para a UI.
    var plan: String?

    init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String, plan: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.plan = plan
    }

    var description: String { "ChatGPTCredentials(<redacted>)" }

    /// Folga padrão de renovação: 2 minutos antes de expirar.
    static let refreshMargin: TimeInterval = 120

    func needsRefresh(now: Date = Date(), margin: TimeInterval = ChatGPTCredentials.refreshMargin) -> Bool {
        expiresAt.timeIntervalSince(now) <= margin
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }

    /// Blob corrompido = deslogado.
    static func decode(_ blob: String) -> ChatGPTCredentials? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ChatGPTCredentials.self, from: Data(blob.utf8))
    }

    /// "Plus", "Pro" ou `nil`.
    var planLabel: String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// Lê claims de um JWT **sem verificar a assinatura** — só para tirar conta, plano e expiração de tokens
/// recém-recebidos do emissor por TLS. Nunca para decisões de confiança.
enum ChatGPTJWT {
    private static let authClaim = "https://api.openai.com/auth"

    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Claim namespaced `chatgpt_account_id`, depois o de topo, depois `organizations[0].id`.
    static func accountID(from token: String) -> String? {
        guard let claims = claims(of: token) else { return nil }
        let auth = claims[authClaim] as? [String: Any]
        if let id = auth?["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let id = claims["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let organizations = (auth?["organizations"] ?? claims["organizations"]) as? [[String: Any]],
           let id = organizations.first?["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    static func plan(from token: String) -> String? {
        (claims(of: token)?[authClaim] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    static func expiry(of token: String) -> Date? {
        (claims(of: token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

/// Onde as credenciais vivem: no app, o Keychain (`SecretStore`); nos testes, memória.
protocol ChatGPTCredentialStore: Sendable {
    func load() throws -> ChatGPTCredentials?
    func save(_ credentials: ChatGPTCredentials) throws
    func clear() throws
}

/// Um blob no `SecretStore` (Keychain, `ThisDeviceOnly`, fora de backup).
struct SecretChatGPTStore: ChatGPTCredentialStore {
    let secrets: any SecretStore

    func load() throws -> ChatGPTCredentials? {
        try secrets.string(for: .chatGPTAuth).flatMap(ChatGPTCredentials.decode)
    }

    func save(_ credentials: ChatGPTCredentials) throws {
        try secrets.set(credentials.encoded(), for: .chatGPTAuth)
    }

    func clear() throws {
        try secrets.set(nil, for: .chatGPTAuth)
    }
}

extension SecretChatGPTStore {
    /// Para a UI: blob ilegível ou erro de Keychain = deslogado.
    func loadIgnoringErrors() -> ChatGPTCredentials? { (try? load()) ?? nil }
}
