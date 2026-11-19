import Foundation
import Network
import SwiftData
import Testing
@testable import FitJourney

// Provedor experimental "ChatGPT (login)": OAuth PKCE, listener loopback, gateway Responses com ferramentas.
// Nenhum teste toca a rede real nem o Keychain.

private final class MemoryChatGPTStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTCredentials?

    init(_ value: ChatGPTCredentials?) { self.value = value }

    func load() throws -> ChatGPTCredentials? { lock.withLock { value } }
    func save(_ credentials: ChatGPTCredentials) throws { lock.withLock { value = credentials } }
    func clear() throws { lock.withLock { value = nil } }
}

/// Devolve as leituras em sequência (a última se repete): simula outra tela mudando o Keychain no meio.
private final class ScriptedStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [ChatGPTCredentials?]
    private var clearCount = 0
    var clears: Int { lock.withLock { clearCount } }

    init(reads: [ChatGPTCredentials?]) { self.reads = reads }

    func load() throws -> ChatGPTCredentials? {
        lock.withLock { reads.count > 1 ? reads.removeFirst() : (reads.first ?? nil) }
    }
    func save(_ credentials: ChatGPTCredentials) throws { lock.withLock { reads = [credentials] } }
    func clear() throws { lock.withLock { clearCount += 1; reads = [nil] } }
}

private final class FlakyStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTCredentials?
    private var failing = false
    var failSaves: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    init(_ value: ChatGPTCredentials?) { self.value = value }

    func load() throws -> ChatGPTCredentials? { lock.withLock { value } }
    func save(_ credentials: ChatGPTCredentials) throws {
        try lock.withLock {
            if failing { throw SecretStoreError.keychain(status: -25308) }
            value = credentials
        }
    }
    func clear() throws { lock.withLock { value = nil } }
}

private func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ChatGPTPKCE.base64URL(data)
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
}

private let idToken = jwt([
    "email": "pessoa@example.com",
    "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123", "chatgpt_plan_type": "plus"],
])

private func tokenJSON(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: Int = 3600) -> String {
    let refreshPart = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
    return #"{"access_token":"\#(access)","id_token":"\#(idToken)","expires_in":\#(expiresIn)\#(refreshPart)}"#
}

private func oauth(host: String, now: Date = Date()) throws -> ChatGPTOAuthClient {
    var configuration = ChatGPTOAuthConfiguration.default
    configuration.issuer = try #require(URL(string: "https://\(host)"))
    return ChatGPTOAuthClient(configuration: configuration, client: HTTPClient(session: StubURLProtocol.makeSession()),
                              now: { now })
}

private func form(_ request: URLRequest) -> [String: String] {
    let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var result: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        result[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
    }
    return result
}

private func signedIn(token: String = "access-1", expiresIn: TimeInterval = 3600) -> MemoryChatGPTStore {
    MemoryChatGPTStore(ChatGPTCredentials(accessToken: token, refreshToken: "refresh-\(UUID().uuidString)",
                                          expiresAt: Date().addingTimeInterval(expiresIn), accountID: "acct-123",
                                          plan: "plus"))
}

private func chatGPTGateway(host: String, store: MemoryChatGPTStore, oauthHost: String? = nil) throws -> ChatGPTResponsesGateway {
    let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: oauthHost ?? StubURLProtocol.uniqueHost()))
    return ChatGPTResponsesGateway(baseURL: try #require(URL(string: "https://\(host)/backend-api/codex")),
                                   session: session,
                                   client: HTTPClient(session: StubURLProtocol.makeSession(), retryPolicy: .none),
                                   version: "9.9", sessionID: "session-1")
}

private func responses(_ frames: [String]) -> String {
    frames.map { "data: \($0)\n\n" }.joined()
}

private let tool = ToolSpec(name: "list_programs", description: "Lista programas",
                            parametersSchema: #"{"type":"object","properties":{"include_archived":{"type":"boolean"}},"required":["include_archived"],"additionalProperties":false}"#)

// MARK: - OAuth

@Suite("AI · ChatGPT login (OAuth PKCE)")
struct ChatGPTOAuthTests {
    @Test("PKCE S256 bate com o vetor da RFC 7636")
    func pkceVector() {
        let rfc = ChatGPTPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(rfc.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = ChatGPTPKCE.generate()
        #expect((43 ... 128).contains(generated.verifier.count))
        #expect(!generated.verifier.contains("=") && !generated.verifier.contains("+") && !generated.verifier.contains("/"))
        #expect(ChatGPTPKCE.randomState() != ChatGPTPKCE.randomState())
    }

    @Test("URL de authorize: PKCE S256, state, escopo, cliente do Codex e originator fitjourney")
    func authorizeURL() throws {
        let attempt = ChatGPTOAuthClient().beginLogin(pkce: ChatGPTPKCE(verifier: "v"), state: "st")
        let components = try #require(URLComponents(url: attempt.authorizeURL, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/oauth/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(items["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == ChatGPTPKCE(verifier: "v").challenge)
        #expect(items["state"] == "st")
        #expect(items["scope"] == "openid profile email offline_access")
        #expect(items["id_token_add_organizations"] == "true")
        #expect(items["codex_cli_simplified_flow"] == "true")
        #expect(items["originator"] == "fitjourney")
        #expect(attempt.verifier == "v")
        #expect(attempt.state == "st")
    }

    @Test("callback colado: só a URL completa com state")
    func callbackParsing() {
        let full = ChatGPTOAuthClient.parseCallback(" http://localhost:1455/auth/callback?code=abc&state=xyz ")
        #expect(full == .init(code: "abc", state: "xyz", error: nil))
        #expect(ChatGPTOAuthClient.parseCallback("abc123") == nil) // código solto não serve
        #expect(ChatGPTOAuthClient.parseCallback("http://localhost:1455/auth/callback?code=abc") == nil)
        #expect(ChatGPTOAuthClient.parseCallback("http://localhost:1455/outro?code=abc&state=x") == nil)
        #expect(ChatGPTOAuthClient.parseCallback("http://localhost:1455/auth/callback?error=access_denied&state=x")?.error
            == "access_denied")
        #expect(ChatGPTOAuthClient.parseCallback("") == nil)
        #expect(ChatGPTOAuthClient.parseCallback("dois tokens") == nil)
    }

    @Test("troca do código: form-urlencoded, conta e plano do id_token, sem e-mail guardado")
    func exchange() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(tokenJSON())], host: host)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = try oauth(host: host, now: now)
        let attempt = client.beginLogin(pkce: ChatGPTPKCE(verifier: "verifier-1"), state: "s")
        let credentials = try await client.exchange(code: "code/1+", attempt: attempt)
        #expect(credentials.accountID == "acct-123")
        #expect(credentials.planLabel == "Plus")
        #expect(credentials.refreshToken == "refresh-1")
        #expect(credentials.expiresAt == now.addingTimeInterval(3600))
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path == "/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(raw.contains("code=code%2F1%2B"))
        let body = form(request)
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "code/1+")
        #expect(body["code_verifier"] == "verifier-1")
        #expect(body["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(body["redirect_uri"] == "http://localhost:1455/auth/callback")
        // Nada sensível na descrição nem no blob além do necessário (o e-mail não é guardado).
        #expect(!"\(credentials)".contains("refresh-1"))
        let blob = try credentials.encoded()
        #expect(!blob.contains("pessoa@example.com"))
        #expect(!blob.contains(idToken)) // o id_token (com o e-mail) não é guardado
        #expect(!"\(credentials)".contains("acct-123"))
    }

    @Test("refresh: form com refresh_token; mantém o antigo quando não vem outro e rotaciona quando vem")
    func refresh() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-2", refresh: nil)),
                                 .json(tokenJSON(access: "access-3", refresh: "refresh-3"))], host: host)
        let client = try oauth(host: host)
        let start = ChatGPTCredentials(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: Date(),
                                       accountID: "acct-old")
        let first = try await client.refresh(start)
        #expect(first.accessToken == "access-2")
        #expect(first.refreshToken == "refresh-1")
        #expect(first.accountID == "acct-123")
        let second = try await client.refresh(first)
        #expect(second.refreshToken == "refresh-3")
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 2)
        #expect(form(requests[0]) == ["grant_type": "refresh_token", "refresh_token": "refresh-1",
                                      "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("refresh recusado (invalid_grant) vira signInRequired e a sessão apaga o login")
    func refreshRejected() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"error":"invalid_grant"}"#, status: 400)], host: host)
        let store = signedIn(expiresIn: -10) // vencido: força a renovação
        let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
        await #expect(throws: AIError.signInRequired) { try await session.credentials() }
        #expect(try store.load() == nil)
    }

    @Test("token dentro da folga renova sozinho e grava; renovações simultâneas viram uma só")
    func singleFlightRefresh() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-new", refresh: "refresh-new"))], host: host)
        let store = signedIn(token: "old", expiresIn: 60) // dentro da folga de 120 s
        let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 5 { group.addTask { try await session.credentials().accessToken } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(tokens) == ["access-new"])
        #expect(StubURLProtocol.requests(host: host).count == 1)
        #expect(try store.load()?.refreshToken == "refresh-new")
    }

    @Test("leitura velha: se outro já renovou, devolve o login atual sem rede")
    func staleReadSkipsNetwork() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([], host: host)
        let old = ChatGPTCredentials(accessToken: "old", refreshToken: "r-old-\(UUID())", expiresAt: Date().addingTimeInterval(-5),
                                     accountID: "x")
        let renewed = ChatGPTCredentials(accessToken: "new", refreshToken: "r-new-\(UUID())",
                                         expiresAt: Date().addingTimeInterval(3600), accountID: "x")
        let store = ScriptedStore(reads: [old, renewed])
        let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
        #expect(try await session.credentials().accessToken == "new")
        #expect(StubURLProtocol.requests(host: host).isEmpty)
        #expect(store.clears == 0)
    }

    @Test("recusa permanente só apaga se o blob ainda tiver o refresh token que falhou")
    func clearOnlyIfSameToken() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"error":"invalid_grant"}"#, status: 400)], host: host)
        let old = ChatGPTCredentials(accessToken: "old", refreshToken: "r-old-\(UUID())", expiresAt: Date().addingTimeInterval(-5),
                                     accountID: "x")
        let other = ChatGPTCredentials(accessToken: "novo-login", refreshToken: "r-other-\(UUID())",
                                       expiresAt: Date().addingTimeInterval(3600), accountID: "x")
        // A sessão lê o velho, a operação relê o velho, e na hora de apagar já há um login novo.
        let store = ScriptedStore(reads: [old, old, other])
        let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
        await #expect(throws: AIError.signInRequired) { try await session.credentials() }
        #expect(store.clears == 0)
    }

    @Test("403 e 5xx no endpoint de token são transitórios: login mantido")
    func transientRefreshFailure() async throws {
        for status in [403, 500] {
            let host = StubURLProtocol.uniqueHost()
            StubURLProtocol.enqueue([.json(#"{"error":"blocked"}"#, status: status)], host: host)
            let store = signedIn(expiresIn: -10)
            let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
            var caught: (any Error)?
            do { _ = try await session.credentials() } catch { caught = error }
            #expect(caught != nil)
            #expect((caught as? AIError) != .signInRequired, "status \(status)")
            #expect(try store.load() != nil, "status \(status)")
        }
    }

    @Test("falha ao gravar a renovação: devolve o token novo, guarda em memória e grava depois")
    func saveFailureKeepsRenewed() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-new", refresh: "refresh-new-\(UUID())"))], host: host)
        let stale = ChatGPTCredentials(accessToken: "old", refreshToken: "r-\(UUID())", expiresAt: Date().addingTimeInterval(-5),
                                       accountID: "x")
        let store = FlakyStore(stale)
        store.failSaves = true
        let session = ChatGPTAuthSession(store: store, oauth: try oauth(host: host))
        #expect(try await session.credentials().accessToken == "access-new")
        #expect(try store.load()?.accessToken == "old") // o Keychain falhou
        // A próxima leitura usa a renovação em memória (sem rede) e tenta gravar de novo.
        store.failSaves = false
        #expect(try await session.credentials().accessToken == "access-new")
        #expect(try store.load()?.accessToken == "access-new")
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test("sem login: signInRequired")
    func signedOut() async {
        let session = ChatGPTAuthSession(store: MemoryChatGPTStore(nil))
        await #expect(throws: AIError.signInRequired) { try await session.credentials() }
    }

    @Test("JWT: conta (namespaced, topo, organizations), plano e expiração")
    func jwtParsing() {
        #expect(ChatGPTJWT.accountID(from: idToken) == "acct-123")
        #expect(ChatGPTJWT.plan(from: idToken) == "plus")
        #expect(ChatGPTJWT.accountID(from: jwt(["chatgpt_account_id": "top"])) == "top")
        #expect(ChatGPTJWT.accountID(from: jwt(["organizations": [["id": "org-9"]]])) == "org-9")
        #expect(ChatGPTJWT.accountID(from: jwt(["sub": "x"])) == nil)
        #expect(ChatGPTJWT.accountID(from: "não-é-jwt") == nil)
        #expect(ChatGPTJWT.expiry(of: jwt(["exp": 2_000_000_000])) == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test("blob ida e volta; corrompido = deslogado; folga de expiração")
    func blobAndExpiry() throws {
        let original = ChatGPTCredentials(accessToken: "a", refreshToken: "r",
                                          expiresAt: Date(timeIntervalSince1970: 5), accountID: "x", plan: "pro")
        #expect(ChatGPTCredentials.decode(try original.encoded()) == original)
        #expect(ChatGPTCredentials.decode("não é json") == nil)
        let now = Date(timeIntervalSince1970: 100)
        #expect(!ChatGPTCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(600),
                                    accountID: "x").needsRefresh(now: now))
        #expect(ChatGPTCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(60),
                                   accountID: "x").needsRefresh(now: now))
    }

    @Test("SecretChatGPTStore usa um único blob em SecretKey.chatGPTAuth e sair apaga")
    func secretStore() throws {
        let secrets = InMemorySecretStore()
        let store = SecretChatGPTStore(secrets: secrets)
        try store.save(ChatGPTCredentials(accessToken: "a", refreshToken: "r", expiresAt: Date(), accountID: "x"))
        #expect(secrets.contains(.chatGPTAuth))
        #expect(try store.load()?.accountID == "x")
        try store.clear()
        #expect(!secrets.contains(.chatGPTAuth))
    }
}

// MARK: - Listener

@Suite("AI · ChatGPT listener loopback")
struct ChatGPTListenerTests {
    @Test("linha de pedido: só GET /auth/callback")
    func parsing() {
        let ok = ChatGPTLoopbackListener.parse(requestLine: "GET /auth/callback?code=c&state=s HTTP/1.1\r\nHost: x\r\n")
        #expect(ok == .init(code: "c", state: "s", error: nil))
        #expect(ChatGPTLoopbackListener.parse(requestLine: "GET /favicon.ico HTTP/1.1\r\n") == nil)
        #expect(ChatGPTLoopbackListener.parse(requestLine: "POST /auth/callback?code=c HTTP/1.1\r\n") == nil)
    }

    @Test("comparação de state em tempo constante e só loopback (127/8, ::1, ::ffff:127.x)")
    func pureHelpers() throws {
        #expect(ChatGPTLoopbackListener.constantTimeEquals("abc", "abc"))
        #expect(!ChatGPTLoopbackListener.constantTimeEquals("abc", "abd"))
        #expect(!ChatGPTLoopbackListener.constantTimeEquals("abc", "abcd"))
        #expect(!ChatGPTLoopbackListener.constantTimeEquals("", "a"))
        func endpoint(_ host: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: 1455) }
        #expect(ChatGPTLoopbackListener.isLoopback(endpoint("127.0.0.1")))
        #expect(ChatGPTLoopbackListener.isLoopback(endpoint("127.8.9.10")))
        #expect(ChatGPTLoopbackListener.isLoopback(endpoint("::1")))
        #expect(ChatGPTLoopbackListener.isLoopback(endpoint("::ffff:127.0.0.1")))
        #expect(!ChatGPTLoopbackListener.isLoopback(endpoint("192.168.0.10")))
        #expect(!ChatGPTLoopbackListener.isLoopback(endpoint("fe80::1")))
        #expect(!ChatGPTLoopbackListener.isLoopback(endpoint("localhost"))) // nome, não endereço
    }

    private func get(_ port: UInt16, _ query: String) async throws -> (Int, String) {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/auth/callback?\(query)"))
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("state certo entrega o código e consome o uso único")
    func rightState() async throws {
        let attempt = ChatGPTOAuthClient().beginLogin(pkce: ChatGPTPKCE(verifier: "v"), state: "estado-1")
        let listener = ChatGPTLoopbackListener(expectedState: "estado-1", port: 0)
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)
        async let callback = listener.callback()
        let (status, body) = try await get(port, "code=codigo-1&state=estado-1")
        #expect(status == 200)
        #expect(body.contains("FitJourney"))
        let received = try await callback
        #expect(received == .init(code: "codigo-1", state: "estado-1", error: nil))
        #expect(try ChatGPTLoginValidation.code(from: received, attempt: attempt) == "codigo-1")
        // Uso único: a porta foi liberada.
        #expect(listener.boundPort == nil)
    }

    @Test("state errado ou ausente recebe 404 e a espera continua até o state certo")
    func wrongStateKeepsWaiting() async throws {
        let listener = ChatGPTLoopbackListener(expectedState: "estado-1", port: 0)
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)
        async let callback = listener.callback()
        #expect(try await get(port, "code=forjado&state=outro").0 == 404)
        #expect(try await get(port, "code=sem-state").0 == 404)
        #expect(listener.boundPort == port) // ainda escutando
        #expect(try await get(port, "code=bom&state=estado-1").0 == 200)
        #expect(try await callback.code == "bom")
    }

    @Test("validação: state ausente ou diferente é recusado; negado também")
    func validation() {
        let attempt = ChatGPTOAuthClient().beginLogin(pkce: ChatGPTPKCE(verifier: "v"), state: "estado-1")
        #expect(throws: ChatGPTLoginValidation.Failure.stateMismatch) {
            try ChatGPTLoginValidation.code(from: .init(code: "c", state: "outro", error: nil), attempt: attempt)
        }
        #expect(throws: ChatGPTLoginValidation.Failure.stateMismatch) {
            try ChatGPTLoginValidation.code(from: .init(code: "c", state: nil, error: nil), attempt: attempt)
        }
        #expect(throws: ChatGPTLoginValidation.Failure.denied) {
            try ChatGPTLoginValidation.code(from: .init(code: nil, state: "estado-1", error: "access_denied"), attempt: attempt)
        }
    }

    @Test("stop encerra a espera, cancela conexões pendentes e libera a porta")
    func stopEndsWaitAndConnections() async throws {
        let listener = ChatGPTLoopbackListener(expectedState: "s", port: 0, connectionTimeout: 30)
        try await listener.start()
        let port = try #require(listener.boundPort)
        // Conexão que não manda nada: fica pendente.
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        idle.start(queue: .global())
        defer { idle.cancel() }
        for _ in 0 ..< 100 where listener.openConnectionCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(listener.openConnectionCount == 1)
        listener.stop()
        #expect(listener.openConnectionCount == 0)
        #expect(listener.boundPort == nil)
        await #expect(throws: AIError.cancelled) { try await listener.callback() }
        // A porta está livre de novo.
        let again = ChatGPTLoopbackListener(expectedState: "s", port: port)
        try await again.start()
        again.stop()
    }

    @Test("timeout da espera encerra com erro e libera a porta")
    func timeout() async throws {
        let listener = ChatGPTLoopbackListener(expectedState: "s", port: 0, timeout: 0.2)
        try await listener.start()
        await #expect(throws: AIError.network(code: URLError.timedOut.rawValue, retryable: false)) {
            try await listener.callback()
        }
        #expect(listener.boundPort == nil)
    }
}

// MARK: - Gateway Responses

@Suite("AI · ChatGPT gateway Responses")
struct ChatGPTGatewayTests {
    private let textStream = responses([
        #"{"type":"response.created","response":{"id":"resp_1","model":"gpt-6-luna"}}"#,
        #"{"type":"response.reasoning_summary_text.delta","delta":"Pensando"}"#,
        #"{"type":"response.reasoning_summary_part.added","summary_index":1}"#,
        #"{"type":"response.reasoning_summary_text.delta","delta":"mais"}"#,
        #"{"type":"response.output_text.delta","delta":"Olá"}"#,
        #"{"type":"response.output_text.delta","delta":"!"}"#,
        #"{"type":"response.unknown_future_event","x":1}"#,
        #"{"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":2}}}"#,
    ])

    @Test("pedido: headers, originator fitjourney e corpo obrigatório (store:false, stream:true, instructions)")
    func requestShape() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.sse(": keep-alive\n\n" + textStream)], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        let events = try await collect(chat.stream(ChatRequest(
            model: "gpt-6-luna", messages: [.system("Seja breve."), .user("Oi"), .assistant("Olá"), .user("De novo")],
            temperature: 0.2, maxTokens: 50)))
        #expect(events == [
            .started(id: "resp_1", model: "gpt-6-luna"),
            .reasoningDelta("Pensando"), .reasoningDelta("\n\n"), .reasoningDelta("mais"),
            .delta("Olá"), .delta("!"),
            .usage(TokenUsage(promptTokens: 7, completionTokens: 2)),
            .finished(reason: .stop),
        ])
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path == "/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-123")
        #expect(request.value(forHTTPHeaderField: "originator") == "fitjourney")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(request.value(forHTTPHeaderField: "session_id") == "session-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "FitJourney/9.9")
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["instructions"] == .string("Seja breve."))
        #expect(body["model"] == .string("gpt-6-luna"))
        #expect(body["temperature"] == nil)
        #expect(body["max_output_tokens"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["reasoning"]?["summary"] == .string("auto"))
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.count == 3)
        #expect(input.allSatisfy { $0["role"]?.stringValue != "system" })
        #expect(input[0]["content"]?.arrayValue?.first?["type"] == .string("input_text"))
        #expect(input[1]["content"]?.arrayValue?.first?["type"] == .string("output_text"))
    }

    @Test("sem system: instructions padrão não vazio")
    func defaultInstructions() throws {
        let body = try ChatGPTResponsesGateway.body(for: ChatRequest(model: "m", messages: [.user("oi")]))
        #expect(body["instructions"] == .string(ChatGPTResponsesGateway.defaultInstructions))
    }

    @Test("function_call fragmentado por item_id vira toolCall em ordem, antes de finished(.toolCalls)")
    func fragmentedFunctionCalls() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.sse(responses([
            #"{"type":"response.created","response":{"id":"resp_2","model":"gpt-6-luna"}}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"list_programs","arguments":""}}"#,
            #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"get_program","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_b","output_index":2,"delta":"{\"id\":"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_a","output_index":1,"delta":"{\"include_"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_a","output_index":1,"delta":"archived\":false}"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_b","output_index":2,"delta":"\"p1\"}"}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"fc_a","output_index":1,"arguments":"{\"include_archived\":false}"}"#,
            #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"get_program","arguments":"{\"id\":\"p1\"}"}}"#,
            #"{"type":"response.completed","response":{"usage":{"input_tokens":50,"output_tokens":10}}}"#,
        ]))], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        let events = try await collect(chat.stream(ChatRequest(model: "gpt-6-luna", messages: [.user("oi")],
                                                               tools: [tool], toolChoice: .auto)))
        #expect(events == [
            .started(id: "resp_2", model: "gpt-6-luna"),
            .usage(TokenUsage(promptTokens: 50, completionTokens: 10)),
            .toolCall(id: "call_a", name: "list_programs", argumentsJSON: #"{"include_archived":false}"#),
            .toolCall(id: "call_b", name: "get_program", argumentsJSON: #"{"id":"p1"}"#),
            .finished(reason: .toolCalls),
        ])
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        let wireTool = try #require(body["tools"]?.arrayValue?.first)
        #expect(wireTool["type"] == .string("function"))
        #expect(wireTool["name"] == .string("list_programs"))
        #expect(wireTool["description"] == .string("Lista programas"))
        #expect(wireTool["parameters"]?["additionalProperties"] == .bool(false))
        #expect(wireTool["strict"] == .bool(false))
        #expect(wireTool["function"] == nil) // formato plano da Responses API, não o do Chat Completions
        #expect(body["tool_choice"] == .string("auto"))
    }

    @Test("reenvio: function_call e function_call_output ligados por call_id; tool_choice none")
    func toolHistoryWire() throws {
        let body = try ChatGPTResponsesGateway.body(for: ChatRequest(
            model: "m",
            messages: [.system("sys"), .user("oi"),
                       .assistant("Vou olhar.", toolCalls: [ToolCall(id: "call_1", name: "list_programs",
                                                                     argumentsJSON: #"{"include_archived":false}"#)]),
                       .toolResult(id: "call_1", name: "list_programs", content: #"{"programs":[]}"#)],
            tools: [tool], toolChoice: ToolChoice.none))
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.count == 4)
        #expect(input[1]["role"] == .string("assistant"))
        #expect(input[2] == .object(["type": .string("function_call"), "call_id": .string("call_1"),
                                     "name": .string("list_programs"),
                                     "arguments": .string(#"{"include_archived":false}"#)]))
        #expect(input[3] == .object(["type": .string("function_call_output"), "call_id": .string("call_1"),
                                     "output": .string(#"{"programs":[]}"#)]))
        #expect(body["tool_choice"] == .string("none"))
    }

    @Test("incomplete → length/contentFilter sem executar ferramentas; recusa → refusal")
    func finishReasons() throws {
        var decoder = ResponsesStreamDecoder(requestedModel: "m")
        _ = try decoder.consume(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c","name":"x","arguments":"{\"a"}}"#)
        let length = try decoder.consume(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
        #expect(length.last == .finished(reason: .length))
        #expect(!length.contains { if case .toolCall = $0 { true } else { false } })

        var filter = ResponsesStreamDecoder(requestedModel: "m")
        #expect(try filter.consume(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#).last
            == .finished(reason: .contentFilter))

        var refusal = ResponsesStreamDecoder(requestedModel: "m")
        _ = try refusal.consume(#"{"type":"response.refusal.delta","delta":"Não posso."}"#)
        #expect(try refusal.consume(#"{"type":"response.completed","response":{}}"#).last == .finished(reason: .refusal))
    }

    @Test("response.failed vira erro sem token; limite de uso vira rateLimited")
    func failures() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.sse(responses([#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"falhou eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.sig"}}}"#]))], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        do {
            _ = try await chat.complete(ChatRequest(model: "m", messages: [.user("oi")]))
            Issue.record("esperado erro")
        } catch let AIError.server(_, message) {
            #expect(!message.contains("eyJ"))
        }
        #expect(ResponsesStreamDecoder.failure(code: "usage_limit_reached", message: nil) == .rateLimited(retryAfter: nil))
    }

    @Test("stream que termina sem response.completed é falha de rede (parcial descartado)")
    func truncatedStream() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.sse(responses([#"{"type":"response.output_text.delta","delta":"Ol"}"#]))], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        await #expect(throws: AIError.self) { _ = try await collect(chat.stream(ChatRequest(model: "m", messages: []))) }
    }

    @Test("401 renova o token uma vez e repete; 401 de novo pede novo login")
    func reauth() async throws {
        let host = StubURLProtocol.uniqueHost()
        let authHost = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"detail":"expired"}"#, status: 401), .sse(textStream)], host: host)
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-2", refresh: "refresh-2"))], host: authHost)
        let store = signedIn(token: "access-1")
        let chat = try chatGPTGateway(host: host, store: store, oauthHost: authHost)
        let result = try await chat.complete(ChatRequest(model: "gpt-6-luna", messages: [.user("oi")]))
        #expect(result.content == "Olá!")
        #expect(result.reasoning == "Pensando\n\nmais")
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(try store.load()?.accessToken == "access-2")

        // 401 de novo com o token renovado: apaga o login (a UI volta a "Entrar com ChatGPT").
        let host2 = StubURLProtocol.uniqueHost()
        let authHost2 = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json("{}", status: 401), .json("{}", status: 401)], host: host2)
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-3", refresh: "refresh-3"))], host: authHost2)
        let store2 = signedIn()
        let chat2 = try chatGPTGateway(host: host2, store: store2, oauthHost: authHost2)
        await #expect(throws: AIError.signInRequired) {
            _ = try await chat2.complete(ChatRequest(model: "m", messages: [.user("oi")]))
        }
        #expect(try store2.load() == nil)
    }

    @Test("403 repetido com token renovado é bloqueio do endpoint: erro do provedor, login mantido")
    func repeatedForbidden() async throws {
        let host = StubURLProtocol.uniqueHost()
        let authHost = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json("{}", status: 403), .json("{}", status: 403)], host: host)
        StubURLProtocol.enqueue([.json(tokenJSON(access: "access-3", refresh: "refresh-3"))], host: authHost)
        let store = signedIn()
        let chat = try chatGPTGateway(host: host, store: store, oauthHost: authHost)
        var caught: AIError?
        do {
            _ = try await chat.complete(ChatRequest(model: "m", messages: [.user("oi")]))
        } catch let error as AIError {
            caught = error
        }
        guard case .server(403, _)? = caught else { Issue.record("veio \(String(describing: caught))"); return }
        #expect(try store.load()?.accessToken == "access-3")
    }

    @Test("item_id igual ao call_id também acumula os argumentos")
    func itemIDAlias() throws {
        var decoder = ResponsesStreamDecoder(requestedModel: "m")
        _ = try decoder.consume(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"list_programs","arguments":""}}"#)
        _ = try decoder.consume(#"{"type":"response.function_call_arguments.delta","item_id":"call_1","delta":"{\"include_archived\":true}"}"#)
        let events = try decoder.consume(#"{"type":"response.completed","response":{}}"#)
        #expect(events.contains(.toolCall(id: "call_1", name: "list_programs", argumentsJSON: #"{"include_archived":true}"#)))
    }

    @Test("400 sem citar um parâmetro opcional pelo nome não repete")
    func noBlindFallback() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"detail":"Unsupported parameter: foo"}"#, status: 400), .sse(textStream)], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        await #expect(throws: AIError.self) { _ = try await chat.complete(ChatRequest(model: "m", messages: [.user("oi")])) }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test("400 citando parâmetro opcional repete sem reasoning/parallel_tool_calls")
    func optionalFallback() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"detail":"Unsupported parameter: reasoning.summary"}"#, status: 400),
                                 .sse(textStream)], host: host)
        let chat = try chatGPTGateway(host: host, store: signedIn())
        _ = try await chat.complete(ChatRequest(model: "m", messages: [.user("oi")], tools: [tool]))
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 2)
        #expect(bodies[0]["reasoning"] != nil)
        #expect(bodies[1]["reasoning"] == nil)
        #expect(bodies[1]["parallel_tool_calls"] == .bool(true)) // só o citado sai
    }

    @Test("lista de modelos: visibility list, ordem por priority, sem duplicados; sem login = lista estática")
    func modelLister() async throws {
        let data = Data(#"{"models":[{"slug":"b","visibility":"list","priority":5},{"slug":"hidden","visibility":"hide","priority":0},{"slug":"a","visibility":"list","priority":1},{"slug":"a","visibility":"list","priority":9},{"slug":"c","visibility":"list"}]}"#.utf8)
        #expect(ChatGPTModelLister.parse(data) == ["a", "b", "c"])
        let lister = ChatGPTModelLister(session: ChatGPTAuthSession(store: MemoryChatGPTStore(nil)))
        #expect(await lister.models() == ChatGPTModelLister.fallbackModels)

        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(String(decoding: data, as: UTF8.self))], host: host)
        let live = ChatGPTModelLister(baseURL: try #require(URL(string: "https://\(host)/backend-api/codex")),
                                      session: ChatGPTAuthSession(store: signedIn()),
                                      client: HTTPClient(session: StubURLProtocol.makeSession()),
                                      defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(await live.models() == ["a", "b", "c"])
        #expect(await live.models() == ["a", "b", "c"]) // cache: um pedido só
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(StubURLProtocol.requests(host: host).count == 1)
        #expect(request.url?.query == "client_version=\(ChatGPTModelLister.defaultClientVersion)")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-123")
    }
}

// MARK: - Catálogo, prontidão e fábrica

@Suite("AI · ChatGPT catálogo e prontidão")
struct ChatGPTCatalogTests {
    @Test("descritor experimental, sem chave de API, credencial no blob do login")
    func descriptor() {
        let descriptor = ProviderCatalog.descriptor(for: .chatGPT)
        #expect(descriptor.id == .chatGPT)
        #expect(descriptor.name == "ChatGPT (login) · Experimental / não oficial")
        #expect(descriptor.displayShortName == "ChatGPT (login)")
        #expect(descriptor.isExperimental)
        #expect(!descriptor.requiresAPIKey)
        #expect(descriptor.secretKey == .chatGPTAuth)
        #expect(descriptor.defaultModel == "gpt-6-luna")
        #expect(!ProviderCatalog.descriptor(for: .openAI).isExperimental)
    }

    @Test("prontidão considera o login")
    func readiness() {
        let settings = ProviderSettings(provider: .chatGPT)
        #expect(ProviderReadiness.evaluate(settings, hasAPIKey: false) == .signedOut)
        #expect(ProviderReadiness.evaluate(settings, hasAPIKey: true) == .ready)
        #expect(AISettingsText.readiness(.signedOut).tone == .attention)
        #expect(SettingsPresentation.aiTitle(settings: settings, hasAPIKey: true) == "ChatGPT (login) · gpt-6-luna")
        #expect(SettingsPresentation.aiTitle(settings: settings, hasAPIKey: false) == "Não configurado")
        #expect(AISettingsText.chatGPTStatus(plan: "Plus") == "Conectado · Plus")
        #expect(AISettingsText.chatGPTStatus(plan: nil) == "Conectado")
        #expect(AISettingsText.chatGPTRisk.contains("não documentado"))
    }

    @Test("fábrica: monta o gateway com o blob do Keychain; sem login lança signInRequired")
    func factory() throws {
        let secrets = InMemorySecretStore()
        let settings = ProviderSettings(provider: .chatGPT)
        #expect(throws: AIError.signInRequired) { try ProviderFactory.makeChat(settings: settings, secrets: secrets) }
        try SecretChatGPTStore(secrets: secrets).save(ChatGPTCredentials(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), accountID: "x"))
        let chat = try ProviderFactory.makeChat(settings: settings, secrets: secrets)
        #expect(chat.gateway is ChatGPTResponsesGateway)
        #expect(chat.gateway.provider == .chatGPT)
        #expect(chat.model == "gpt-6-luna")
        // A API key de outro provedor não conta como login.
        let other = InMemorySecretStore([SecretKey.apiKey(.chatGPT): "sk-qualquer-coisa-000000"])
        #expect(throws: AIError.signInRequired) { try ProviderFactory.makeChat(settings: settings, secrets: other) }
    }

    @Test("credencial do ChatGPT só conta com blob legível")
    func hasCredential() throws {
        let descriptor = ProviderCatalog.descriptor(for: .chatGPT)
        #expect(!descriptor.hasCredential(in: InMemorySecretStore([.chatGPTAuth: "corrompido"])))
        #expect(!descriptor.hasCredential(in: InMemorySecretStore()))
        let blob = try ChatGPTCredentials(accessToken: "a", refreshToken: "r", expiresAt: Date(), accountID: "x").encoded()
        #expect(descriptor.hasCredential(in: InMemorySecretStore([.chatGPTAuth: blob])))
        #expect(ProviderCatalog.descriptor(for: .openAI).hasCredential(in: InMemorySecretStore([.apiKey(.openAI): "sk-x"])))
    }

    @Test("erro de login no Coach oferece 'Entrar de novo'")
    func coachError() {
        let presentation = CoachErrorPresentation(.signInRequired)
        #expect(presentation.action == .signIn)
        #expect(!presentation.message.isEmpty)
    }
}

// MARK: - Laço do Coach com o gateway ChatGPT

@Suite("AI · Laço do Coach via ChatGPT")
@MainActor
struct ChatGPTCoachLoopTests {
    @Test("laço completo: function_call list_programs → function_call_output → texto final")
    func fullLoop() async throws {
        let fixture = try ToolboxFixture()
        _ = try fixture.persistence.makeProgram(name: "Atual", activate: true)
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([
            .sse(responses([
                #"{"type":"response.created","response":{"id":"r1","model":"gpt-6-luna"}}"#,
                #"{"type":"response.reasoning_summary_text.delta","delta":"Vou ver os programas."}"#,
                #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_list","name":"list_programs","arguments":""}}"#,
                #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"include_archived\""}"#,
                #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":":false}"}"#,
                #"{"type":"response.completed","response":{"usage":{"input_tokens":300,"output_tokens":12}}}"#,
            ])),
            .sse(responses([
                #"{"type":"response.created","response":{"id":"r2","model":"gpt-6-luna"}}"#,
                #"{"type":"response.output_text.delta","delta":"Seu programa ativo é "}"#,
                #"{"type":"response.output_text.delta","delta":"Atual."}"#,
                #"{"type":"response.completed","response":{"usage":{"input_tokens":420,"output_tokens":8}}}"#,
            ])),
        ], host: host)
        let store = signedIn()
        let service = CoachConversationService(context: fixture.context, toolbox: fixture.toolbox(), requireConsent: { _ in }) {
            ResolvedChat(gateway: try chatGPTGateway(host: host, store: store), model: "gpt-6-luna")
        }
        let conversation = try service.createConversation()

        let ok = await service.send("Qual é meu programa?", in: conversation)
        #expect(ok)
        #expect(service.lastError == nil)

        let messages = conversation.sortedMessages
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(messages.allSatisfy { $0.state == .complete })
        #expect(messages[1].toolCalls.map(\.id) == ["call_list"])
        #expect(messages[1].reasoning == "Vou ver os programas.")
        #expect(messages[2].toolCallID == "call_list")
        #expect(messages[2].content.contains("Atual"))
        #expect(messages[3].content == "Seu programa ativo é Atual.")
        #expect(conversation.providerRaw == "chatGPT")

        // A segunda volta reenviou a chamada e o resultado no formato da Responses API.
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 2)
        #expect(bodies[0]["instructions"]?.stringValue?.isEmpty == false)
        let input = try #require(bodies[1]["input"]?.arrayValue)
        let call = try #require(input.first { $0["type"] == .string("function_call") })
        #expect(call["call_id"] == .string("call_list"))
        #expect(call["arguments"] == .string(#"{"include_archived":false}"#))
        let output = try #require(input.first { $0["type"] == .string("function_call_output") })
        #expect(output["call_id"] == .string("call_list"))
        #expect(output["output"]?.stringValue?.contains("Atual") == true)
        #expect(bodies[1]["tool_choice"] == .string("auto"))
    }

    @Test("login recusado no meio: o Coach mostra signInRequired")
    func signInRequiredSurfaces() async throws {
        let fixture = try ToolboxFixture()
        let host = StubURLProtocol.uniqueHost()
        let authHost = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json("{}", status: 401)], host: host)
        StubURLProtocol.enqueue([.json(#"{"error":"invalid_grant"}"#, status: 400)], host: authHost)
        let store = signedIn()
        let service = CoachConversationService(context: fixture.context, toolbox: fixture.toolbox(), requireConsent: { _ in }) {
            ResolvedChat(gateway: try chatGPTGateway(host: host, store: store, oauthHost: authHost), model: "m")
        }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation) == false)
        #expect(service.lastError == .signInRequired)
        #expect(try store.load() == nil) // refresh recusado apaga o login
    }
}
