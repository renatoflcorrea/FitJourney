import CryptoKit
import Foundation

// Login da assinatura ChatGPT pelo cliente OAuth (não oficial) do Codex CLI — porta de
// `FireplaceProviders/ChatGPT/ChatGPTOAuth.swift`. Pesquisa, riscos e incertezas:
// `/Users/renato/Code/fireplaice/work/CHATGPT_OAUTH.md`. **Experimental**: o endpoint não é documentado.

/// Endpoints e identidade do cliente OAuth. Se o usuário obtiver um client ID do programa oficial
/// ("Sign in with ChatGPT"), basta trocar estes valores.
struct ChatGPTOAuthConfiguration: Sendable, Hashable {
    var issuer: URL
    var clientID: String
    var redirectURI: String
    var scope: String
    var originator: String

    static let `default` = ChatGPTOAuthConfiguration(
        issuer: URL(string: "https://auth.openai.com") ?? URL(fileURLWithPath: "/"),
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        redirectURI: "http://localhost:\(ChatGPTLoopbackListener.port)\(ChatGPTLoopbackListener.path)",
        scope: "openid profile email offline_access",
        originator: "fitjourney")
}

/// Uma tentativa de login: guardada até o callback chegar, depois trocada por tokens.
struct ChatGPTLoginAttempt: Sendable, Equatable {
    let authorizeURL: URL
    let state: String
    let verifier: String
}

/// Cliente Authorization Code + PKCE de `auth.openai.com`. Só HTTP: sem UI e sem armazenamento.
struct ChatGPTOAuthClient: Sendable {
    let configuration: ChatGPTOAuthConfiguration
    private let client: HTTPClient
    private let now: @Sendable () -> Date

    init(configuration: ChatGPTOAuthConfiguration = .default, client: HTTPClient = HTTPClient(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        // Sem repetição automática: um refresh repetido poderia gastar um refresh token rotativo.
        self.client = client.withRetryPolicy(.none)
        self.now = now
    }

    func beginLogin(pkce: ChatGPTPKCE = .generate(), state: String = ChatGPTPKCE.randomState()) -> ChatGPTLoginAttempt {
        var components = URLComponents(url: configuration.issuer.appending(path: "oauth/authorize"),
                                       resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: configuration.originator),
        ]
        return ChatGPTLoginAttempt(authorizeURL: components.url ?? configuration.issuer, state: state,
                                   verifier: pkce.verifier)
    }

    /// Extrai `code` e `state` de uma URL de callback colada, ou aceita só o código.
    static func parseCallback(_ text: String) -> (code: String, state: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.contains("?") {
            guard let items = URLComponents(string: trimmed)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
            return (code, items.first { $0.name == "state" }?.value)
        }
        return trimmed.contains(where: \.isWhitespace) ? nil : (trimmed, nil)
    }

    func exchange(code: String, attempt: ChatGPTLoginAttempt) async throws -> ChatGPTCredentials {
        let response = try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("client_id", configuration.clientID),
            ("code", code),
            ("code_verifier", attempt.verifier),
            ("redirect_uri", configuration.redirectURI),
        ])
        return try credentials(from: response, previous: nil)
    }

    /// Recusa permanente (refresh token revogado, reutilizado ou expirado: 400 `invalid_grant`, 401, 403)
    /// vira `AIError.signInRequired`; falhas de rede ou 5xx mantêm os tokens guardados.
    func refresh(_ current: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let response: TokenResponse
        do {
            response = try await tokenRequest([
                ("grant_type", "refresh_token"),
                ("refresh_token", current.refreshToken),
                ("client_id", configuration.clientID),
            ])
        } catch AIError.unauthorized {
            throw AIError.signInRequired
        } catch AIError.badRequest(status: 400, _) {
            throw AIError.signInRequired
        }
        return try credentials(from: response, previous: current)
    }

    // MARK: - Privado

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, _) = try await client.data(for: request)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw AIError.decoding(context: "ChatGPT token", message: "ilegível")
        }
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    private func credentials(from response: TokenResponse, previous: ChatGPTCredentials?) throws -> ChatGPTCredentials {
        guard let access = response.accessToken, !access.isEmpty else {
            throw AIError.decoding(context: "ChatGPT token", message: "sem access token")
        }
        guard let refresh = response.refreshToken ?? previous?.refreshToken, !refresh.isEmpty else {
            throw AIError.decoding(context: "ChatGPT token", message: "sem refresh token")
        }
        let idToken = response.idToken // lido e descartado: traz o e-mail
        guard let accountID = idToken.flatMap(ChatGPTJWT.accountID(from:)) ?? ChatGPTJWT.accountID(from: access)
            ?? previous?.accountID else {
            throw AIError.decoding(context: "ChatGPT token", message: "sem conta ChatGPT")
        }
        let expiry = response.expiresIn.map { now().addingTimeInterval($0) }
            ?? ChatGPTJWT.expiry(of: access) ?? now().addingTimeInterval(3600)
        return ChatGPTCredentials(
            accessToken: access, refreshToken: refresh, expiresAt: expiry, accountID: accountID,
            plan: idToken.flatMap(ChatGPTJWT.plan(from:)) ?? ChatGPTJWT.plan(from: access) ?? previous?.plan)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double?
}

/// Serializa renovações no processo inteiro: um segundo refresh simultâneo gastaria um refresh token
/// rotativo e invalidaria o primeiro. A chave é o hash do refresh token (o valor não fica como chave).
actor ChatGPTRefreshCoordinator {
    static let shared = ChatGPTRefreshCoordinator()

    private var inFlight: [String: Task<ChatGPTCredentials, any Error>] = [:]

    func run(refreshToken: String,
             _ operation: @escaping @Sendable () async throws -> ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let key = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// Credenciais utilizáveis com renovação automática (folga de 2 min). Barato de criar: a coordenação
/// de renovação é global (`ChatGPTRefreshCoordinator`).
struct ChatGPTAuthSession: Sendable {
    let store: any ChatGPTCredentialStore
    let oauth: ChatGPTOAuthClient
    private let now: @Sendable () -> Date
    private let coordinator: ChatGPTRefreshCoordinator

    init(store: any ChatGPTCredentialStore, oauth: ChatGPTOAuthClient = ChatGPTOAuthClient(),
         now: @escaping @Sendable () -> Date = { Date() },
         coordinator: ChatGPTRefreshCoordinator = .shared) {
        self.store = store
        self.oauth = oauth
        self.now = now
        self.coordinator = coordinator
    }

    /// Token válido, renovando antes se estiver para expirar. Sem login: `AIError.signInRequired`.
    func credentials() async throws -> ChatGPTCredentials {
        guard let current = try load() else { throw AIError.signInRequired }
        guard current.needsRefresh(now: now()) else { return current }
        return try await refresh(current)
    }

    /// Depois de um 401/403 com um token que parecia válido: renova, a não ser que alguém já tenha renovado.
    func credentialsAfterRejection(of rejectedAccessToken: String) async throws -> ChatGPTCredentials {
        guard let current = try load() else { throw AIError.signInRequired }
        if current.accessToken != rejectedAccessToken { return current }
        return try await refresh(current)
    }

    private func load() throws -> ChatGPTCredentials? {
        do {
            return try store.load()
        } catch {
            throw AIError.notConfigured(reason: String(localized: "não foi possível ler o login do ChatGPT no Keychain"))
        }
    }

    private func refresh(_ current: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let oauth = oauth
        let store = store
        return try await coordinator.run(refreshToken: current.refreshToken) {
            do {
                let renewed = try await oauth.refresh(current)
                try store.save(renewed)
                return renewed
            } catch AIError.signInRequired {
                // Recusa permanente: o login guardado não serve mais. Apaga para a UI pedir "Entre de novo".
                try? store.clear()
                throw AIError.signInRequired
            }
        }
    }
}
