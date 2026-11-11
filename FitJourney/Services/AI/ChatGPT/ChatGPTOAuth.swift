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

    /// Extrai o callback de uma URL colada. Exige a URL completa (com `state`): um código solto não pode
    /// ser ligado a esta tentativa.
    static func parseCallback(_ text: String) -> ChatGPTLoopbackListener.Callback? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme != nil,
              components.path == ChatGPTLoopbackListener.path, let items = components.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else { return nil }
        let code = items.first { $0.name == "code" }?.value
        let error = items.first { $0.name == "error" }?.value
        guard code?.isEmpty == false || error != nil else { return nil }
        return ChatGPTLoopbackListener.Callback(code: code, state: state, error: error)
    }

    func exchange(code: String, attempt: ChatGPTLoginAttempt) async throws -> ChatGPTCredentials {
        let response = try await tokenRequest(refreshing: false, [
            ("grant_type", "authorization_code"),
            ("client_id", configuration.clientID),
            ("code", code),
            ("code_verifier", attempt.verifier),
            ("redirect_uri", configuration.redirectURI),
        ])
        return try credentials(from: response, previous: nil)
    }

    /// Só recusa **permanente** (400 `invalid_grant`/`refresh_token_*` ou 401) vira `AIError.signInRequired`;
    /// 403 (ex.: bloqueio do Cloudflare), outros 4xx, 5xx e rede são transitórios e mantêm os tokens guardados.
    func refresh(_ current: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let response = try await tokenRequest(refreshing: true, [
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refreshToken),
            ("client_id", configuration.clientID),
        ])
        return try credentials(from: response, previous: current)
    }

    static let permanentRefreshErrors: Set<String> = [
        "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]

    // MARK: - Privado

    private func tokenRequest(refreshing: Bool, _ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, response) = try await client.dataAllowingErrorStatus(for: request)
        let status = response.statusCode
        guard (200 ..< 300).contains(status) else {
            let code = Self.errorCode(in: data)
            let permanent = status == 401 || (status == 400 && code.map(Self.permanentRefreshErrors.contains) == true)
            if refreshing, permanent { throw AIError.signInRequired }
            // O corpo nunca vai cru para a mensagem: só o código de erro OAuth.
            let message = Redactor.redact(code ?? "HTTP \(status)")
            switch status {
            case 429: throw AIError.rateLimited(retryAfter: nil)
            case 400 ..< 500: throw AIError.badRequest(status: status, message: message)
            default: throw AIError.server(status: status, message: message)
            }
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw AIError.decoding(context: "ChatGPT token", message: "ilegível")
        }
    }

    /// `{"error":"invalid_grant"}` ou `{"error":{"code":"refresh_token_expired"}}`.
    static func errorCode(in data: Data) -> String? {
        guard let object = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        if let code = object["error"]?.stringValue { return code }
        return object["error"]?["code"]?.stringValue ?? object["code"]?.stringValue
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
/// Também guarda em memória uma renovação que não pôde ser gravada no Keychain, até conseguir gravar.
actor ChatGPTRefreshCoordinator {
    static let shared = ChatGPTRefreshCoordinator()

    private var inFlight: [String: Task<ChatGPTCredentials, any Error>] = [:]
    /// Renovações não gravadas, pela chave do refresh token que substituíram.
    private var unsaved: [String: ChatGPTCredentials] = [:]

    static func key(_ refreshToken: String) -> String {
        SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func run(refreshToken: String,
             _ operation: @escaping @Sendable () async throws -> ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let key = Self.key(refreshToken)
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    func rememberUnsaved(_ renewed: ChatGPTCredentials, replacing refreshToken: String) {
        unsaved[Self.key(refreshToken)] = renewed
    }

    func unsaved(replacing refreshToken: String) -> ChatGPTCredentials? {
        unsaved[Self.key(refreshToken)]
    }

    func forgetUnsaved(replacing refreshToken: String) {
        unsaved[Self.key(refreshToken)] = nil
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
        guard let current = try await load() else { throw AIError.signInRequired }
        guard current.needsRefresh(now: now()) else { return current }
        return try await refresh(current, force: false)
    }

    /// Depois de um 401/403 com um token que parecia válido: renova, a não ser que alguém já tenha renovado.
    func credentialsAfterRejection(of rejectedAccessToken: String) async throws -> ChatGPTCredentials {
        guard let current = try await load() else { throw AIError.signInRequired }
        if current.accessToken != rejectedAccessToken { return current }
        return try await refresh(current, force: true)
    }

    /// Recusa repetida mesmo com token renovado: o login guardado não serve mais. Apaga só se ainda for o mesmo,
    /// para a UI voltar ao estado "Entrar com ChatGPT".
    func invalidate(accessToken: String) async {
        guard let stored = (try? store.load()) ?? nil else { return }
        let current = await coordinator.unsaved(replacing: stored.refreshToken) ?? stored
        guard current.accessToken == accessToken else { return }
        await coordinator.forgetUnsaved(replacing: stored.refreshToken)
        try? store.clear()
    }

    /// O blob do Keychain, ou a renovação ainda não gravada que o substitui (e tenta gravá-la de novo).
    private func load() async throws -> ChatGPTCredentials? {
        let stored: ChatGPTCredentials?
        do {
            stored = try store.load()
        } catch {
            throw AIError.notConfigured(reason: String(localized: "não foi possível ler o login do ChatGPT no Keychain"))
        }
        guard let stored else { return nil }
        guard let pending = await coordinator.unsaved(replacing: stored.refreshToken) else { return stored }
        if (try? store.save(pending)) != nil { await coordinator.forgetUnsaved(replacing: stored.refreshToken) }
        return pending
    }

    private func refresh(_ stale: ChatGPTCredentials, force: Bool) async throws -> ChatGPTCredentials {
        let oauth = oauth
        let store = store
        let now = now
        let coordinator = coordinator
        /// Visão atual: o blob gravado, ou a renovação em memória que o substitui. `storedToken` é a chave do blob.
        @Sendable func effective() async -> (storedToken: String, credentials: ChatGPTCredentials)? {
            guard let stored = (try? store.load()) ?? nil else { return nil }
            let pending = await coordinator.unsaved(replacing: stored.refreshToken)
            return (stored.refreshToken, pending ?? stored)
        }
        return try await coordinator.run(refreshToken: stale.refreshToken) {
            // Relê dentro da operação: outra chamada pode ter renovado (ou saído) entre a leitura e aqui.
            guard let latest = await effective() else { throw AIError.signInRequired }
            if latest.credentials.refreshToken != stale.refreshToken { return latest.credentials }
            if !force, !latest.credentials.needsRefresh(now: now()) { return latest.credentials }
            let renewed: ChatGPTCredentials
            do {
                renewed = try await oauth.refresh(stale)
            } catch AIError.signInRequired {
                // Recusa permanente: apaga só se o login atual ainda tiver o refresh token que falhou.
                if let current = await effective(), current.credentials.refreshToken == stale.refreshToken {
                    await coordinator.forgetUnsaved(replacing: current.storedToken)
                    try? store.clear()
                }
                throw AIError.signInRequired
            }
            do {
                try store.save(renewed)
                await coordinator.forgetUnsaved(replacing: latest.storedToken)
            } catch {
                // O token novo vale (o antigo pode já estar gasto): fica em memória e grava depois.
                await coordinator.rememberUnsaved(renewed, replacing: latest.storedToken)
            }
            return renewed
        }
    }
}
