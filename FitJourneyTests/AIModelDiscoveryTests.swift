import Foundation
import Testing
@testable import FitJourney

/// Mantém a primeira resposta em voo enquanto outra conta conclui a descoberta.
private final class DelayedDiscoveryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: DelayedDiscoveryProtocol?
    nonisolated(unsafe) private static var waiter: CheckedContinuation<Void, Never>?

    static func waitForFirst() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if pending != nil { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    static func releaseFirst() {
        let protocolInstance = lock.withLock { () -> DelayedDiscoveryProtocol? in
            defer { pending = nil }
            return pending
        }
        protocolInstance?.respond(id: "modelo-antigo")
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer anterior" {
            let continuation = Self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                Self.pending = self
                defer { Self.waiter = nil }
                return Self.waiter
            }
            continuation?.resume()
        } else { respond(id: "modelo-novo") }
    }
    private func respond(id: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"data\":[{\"id\":\"\(id)\"}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct AIModelDiscoveryTests {
    @Test func filtrosOpenAI() {
        let ids = ["gpt-6-luna", "o3", "gpt-6-audio", "gpt-6-realtime", "gpt-6-transcribe", "gpt-6-tts", "gpt-6-image", "gpt-6-search", "gpt-6-embedding", "gpt-6-moderation", "gpt-6-instruct", "gpt-6-codex", "gpt-6-pro", "gpt-6-2026-01-01", "other"]
        let data = try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
        #expect(ModelDiscovery.parse(data, provider: .openAI) == ["gpt-6-luna", "o3"])
    }

    @Test func filtrosAnthropicEOpenRouter() {
        let anthropic = Data(#"{"data":[{"id":"claude-haiku-5-5-20260101"},{"id":"claude-haiku-5-5-2026-01-01"},{"id":"claude-haiku-5-5"},{"id":"claude-sonnet-5-5-20260101"},{"id":"outro"}]}"#.utf8)
        #expect(ModelDiscovery.parse(anthropic, provider: .anthropic) == ["claude-haiku-5-5", "claude-sonnet-5-5-20260101"])
        let router = Data(#"{"data":[{"id":"a","architecture":{"input_modalities":["image"]},"supported_parameters":["tools"]},{"id":"b:free","architecture":{"input_modalities":["image"]},"supported_parameters":["tools"]},{"id":"c","architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]},{"id":"d","architecture":{"input_modalities":["image"]},"supported_parameters":[]}]}"#.utf8)
        #expect(ModelDiscovery.parse(router, provider: .openRouter) == ["a"])
        #expect(ModelDiscovery.parse(Data(#"{"data":[{"id":"local"}]}"#.utf8), provider: .custom) == ["local"])
    }

    @Test func padroes() {
        #expect(ModelDefaults.preferred(in: ["gpt-5.9-luna", "gpt-6-luna", "gpt-6.0-luna"], provider: .openAI) == "gpt-6-luna")
        #expect(ModelDefaults.preferred(in: ["gpt-5-mini", "gpt-6-mini"], provider: .openAI) == "gpt-6-mini")
        #expect(ModelDefaults.preferred(in: ["claude-haiku-5-5", "claude-haiku-6-0"], provider: .anthropic) == "claude-haiku-6-0")
        #expect(ModelDefaults.preferred(in: ["anthropic/claude-haiku-9", "openai/gpt-6-luna"], provider: .openRouter) == "openai/gpt-6-luna")
        #expect(ModelDefaults.preferred(in: ["anthropic/claude-haiku-6", "anthropic/claude-haiku-7"], provider: .openRouter) == "anthropic/claude-haiku-7")
        #expect(ModelDefaults.preferred(in: ["x", "y"], provider: .chatGPT) == "x")
        #expect(ModelDefaults.preferred(in: [], provider: .openAI) == nil)
    }

    @Test func cacheRefreshETrocaDeCredencial() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let host = StubURLProtocol.uniqueHost()
        let url = URL(string: "https://\(host)/v1")!
        StubURLProtocol.enqueue([.json(#"{"data":[{"id":"one"}]}"#), .json(#"{"data":[{"id":"two"}]}"#), .json("{}", status: 500)], host: host)
        let discovery = ModelDiscovery(client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: defaults)
        let first = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        let cached = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        let refreshed = await discovery.models(for: .custom, apiKey: nil, baseURL: url, refresh: true)
        let changed = await discovery.models(for: .custom, apiKey: "outra", baseURL: url)
        #expect(first.models == ["one"] && !first.fromCache)
        #expect(cached.models == ["one"] && cached.fromCache)
        #expect(refreshed.models == ["two"] && !refreshed.fromCache)
        #expect(changed.models == ["llama3.1"] && !changed.fromCache)
        #expect(StubURLProtocol.requests(host: host).count == 3)
    }

    @Test func cabecalhosAnthropicEReserva() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let host = "api.anthropic.com"
        StubURLProtocol.enqueue([.json(#"{"data":[{"id":"claude-haiku-6"}]}"#), .json("{}", status: 500)], host: host)
        let discovery = ModelDiscovery(client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: defaults)
        let first = await discovery.models(for: .anthropic, apiKey: "exemplo")
        let fallback = await discovery.models(for: .anthropic, apiKey: "exemplo", refresh: true)
        #expect(first.models == ["claude-haiku-6"])
        #expect(fallback.models == first.models && fallback.fromCache)
        #expect(StubURLProtocol.requests(host: host).first?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(StubURLProtocol.requests(host: host).first?.value(forHTTPHeaderField: "x-api-key") == "exemplo")
        #expect(StubURLProtocol.requests(host: host).first?.url?.query == "limit=1000")
    }

    @Test @MainActor func endpointsOpenAIeOpenRouterECapacidades() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = HTTPClient(session: StubURLProtocol.makeSession())
        let discovery = ModelDiscovery(client: client, defaults: UserDefaults(suiteName: suite)!)
        let openAI = #"{"data":[{"id":"gpt-6-luna","input_modalities":["text","image","file"]},{"id":"gpt-6-text","input_modalities":["text"],"capabilities":{"pdf":false}},{"id":"gpt-6-plain"},{"id":"gpt-6-audio"}]}"#
        StubURLProtocol.enqueue([.json(openAI)], host: "api.openai.com")
        let first = await discovery.models(for: .openAI, apiKey: "exemplo")
        #expect(first.models == ["gpt-6-luna", "gpt-6-text", "gpt-6-plain"])
        let request = try #require(StubURLProtocol.requests(host: "api.openai.com").first)
        #expect(request.httpMethod == "GET" && request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer exemplo")
        let cached = try #require(ModelCache(defaults: defaults).load(.openAI))
        #expect(AttachmentCapabilities.resolve(provider: .openAI, model: "gpt-6-luna", modelCache: cached) == .init(supportsImages: true, supportsPDF: true))
        #expect(AttachmentCapabilities.resolve(provider: .openAI, model: "gpt-6-text", modelCache: cached) == .init(supportsImages: false, supportsPDF: false))
        // O endpoint oficial pode omitir capacidades: usa a tabela, não confunde omissão com false.
        #expect(AttachmentCapabilities.resolve(provider: .openAI, model: "gpt-6-plain", modelCache: cached) == .init(supportsImages: true, supportsPDF: true))

        let router = #"{"data":[{"id":"openai/gpt-6-luna","architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools"]},{"id":"text/only","architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]},{"id":"image/no-tools","architecture":{"input_modalities":["image"]},"supported_parameters":[]},{"id":"test/free:free","architecture":{"input_modalities":["image"]},"supported_parameters":["tools"]}]}"#
        StubURLProtocol.enqueue([.json(router)], host: "openrouter.ai")
        let second = await discovery.models(for: .openRouter, apiKey: nil)
        #expect(second.models == ["openai/gpt-6-luna"])
        let routerRequest = try #require(StubURLProtocol.requests(host: "openrouter.ai").first)
        #expect(routerRequest.httpMethod == "GET" && routerRequest.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        let routerCache = try #require(ModelCache(defaults: defaults).load(.openRouter))
        #expect(AttachmentCapabilities.resolve(provider: .openRouter, model: "openai/gpt-6-luna", modelCache: routerCache) == .init(supportsImages: true, supportsPDF: true))
        #expect(AttachmentCapabilities.resolve(provider: .openRouter, model: "text/only", modelCache: routerCache) == .init(supportsImages: false, supportsPDF: false))
        #expect(AttachmentCapabilities.resolve(provider: .openRouter, model: "image/no-tools", modelCache: routerCache).supportsImages)
        #expect(AttachmentCapabilities.resolve(provider: .openRouter, model: "novo/desconhecido", modelCache: routerCache).supportsImages)
        // Disponibilidade usa o cache da loja, inclusive para escolhas que sumiram da lista.
        ProviderSettingsStore(defaults: defaults).save(.init(provider: .openAI, models: [.openAI: "gpt-6-text"]))
        let secrets = InMemorySecretStore([.apiKey(.openAI): "exemplo"])
        #expect(!AIAvailability.evaluate(defaults: defaults, secrets: secrets).modelSupportsImages)
    }

    @Test func falhasNuncaVaziasETTL() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = StubURLProtocol.uniqueHost()
        let url = try #require(URL(string: "https://\(host)/v1"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let discovery = ModelDiscovery(client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: suite)!, clock: { now })
        StubURLProtocol.enqueue([.json("{}", status: 500), .json(#"{"data":[]}"#), .json(#"{"data":[{"id":"local-2"}]}"#)], host: host)
        let failure = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        let empty = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        #expect(failure.models == ["llama3.1"] && failure.fetchedAt == nil && !failure.fromCache)
        #expect(empty.models == ["llama3.1"] && !empty.fromCache)
        let fetched = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        #expect(fetched.models == ["local-2"] && fetched.fetchedAt == now)
        let cache = ModelCache(defaults: defaults)
        cache.save(.init(models: ["stale"], fetchedAt: now.addingTimeInterval(-ModelCache.ttl), credentialHash: ModelCache.fingerprint(""), baseURL: url.absoluteString), provider: .custom)
        StubURLProtocol.enqueue([.json("{}", status: 503)], host: host)
        let stale = await discovery.models(for: .custom, apiKey: nil, baseURL: url)
        #expect(stale.models == ["stale"] && stale.fromCache && stale.fetchedAt == now.addingTimeInterval(-ModelCache.ttl))
        for provider in AIProviderID.allCases {
            let separate = UserDefaults(suiteName: UUID().uuidString)!
            let service = ModelDiscovery(client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: separate)
            let result = await service.models(for: provider, apiKey: nil, baseURL: nil)
            #expect(!result.models.isEmpty, "\(provider)")
        }
    }

    @Test func padraoOpenCodeSegueDescobertaSemFixarEscolha() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = StubURLProtocol.uniqueHost()
        let modelsURL = try #require(URL(string: "https://\(host)/models"))
        let a = #"{"data":[{"id":"gpt-6-luna","modalities":{"input":["image/png"]}},{"id":"gpt-7-luna","modalities":{"input":["image/png"]}}]}"#
        let b = #"{"data":[{"id":"gpt-7-luna","modalities":{"input":["image/png"]}},{"id":"gpt-8-luna","modalities":{"input":["image/png"]}}]}"#
        StubURLProtocol.enqueue([.json(a), .json(b)], host: host)
        let lister = OpenCodeModelLister(apiKey: "exemplo", client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: suite)!, modelsURL: modelsURL)
        let settings = ProviderSettings(provider: .openCode)
        _ = await lister.discover()
        #expect(settings.model(for: .openCode, defaults: defaults) == "gpt-7-luna")
        _ = await lister.discover()
        #expect(StubURLProtocol.requests(host: host).count == 1)
        _ = await lister.discover(refresh: true)
        #expect(settings.model(for: .openCode, defaults: defaults) == "gpt-8-luna")
        #expect(settings.models[.openCode] == nil)
        let chosen = ProviderSettings(provider: .openCode, models: [.openCode: "gpt-6-luna"])
        #expect(chosen.model(for: .openCode, defaults: defaults) == "gpt-6-luna")
        ProviderSettingsStore(defaults: defaults).save(settings)
        let factory = try ProviderFactory.makeChat(settingsStore: ProviderSettingsStore(defaults: defaults), secrets: InMemorySecretStore([.apiKey(.openCode): "exemplo"]))
        #expect(factory.model == "gpt-8-luna")
        #expect(ProviderSettingsStore(defaults: defaults).load().models[.openCode] == nil)
        // Empate numérico preserva a ordem de descoberta, mesmo quando o preço é outro.
        let tie = OpenCodeModelCatalog.parse(Data(#"{"data":[{"id":"gpt-8-luna","modalities":{"input":["image/png"]},"cost":{"text":{"input":{"price":9}}}},{"id":"gpt-8.0-luna","modalities":{"input":["image/png"]},"cost":{"text":{"input":{"price":1}}}}]}"#.utf8))
        #expect(OpenCodeModelCatalog.pickerModels(discovered: tie).first == "gpt-8-luna")
        let noLight = OpenCodeModelCatalog.parse(Data(#"{"data":[{"id":"primeiro","modalities":{"input":["image/png"]},"cost":{"text":{"input":{"price":9}}}},{"id":"segundo","modalities":{"input":["image/png"]},"cost":{"text":{"input":{"price":1}}}}]}"#.utf8))
        OpenCodeModelCache(defaults: defaults).save(.init(fetchedAt: .now, models: noLight, credentialHash: ModelCache.fingerprint("exemplo")))
        #expect(settings.model(for: .openCode, defaults: defaults) == "primeiro")
        // Uma credencial nova não herda os modelos da conta anterior.
        StubURLProtocol.enqueue([.json("{}", status: 500)], host: host)
        let changed = OpenCodeModelLister(apiKey: "outra", client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: suite)!, modelsURL: modelsURL)
        let fallback = await changed.discover()
        #expect(fallback.models.map(\.id) == OpenCodeGo.suggestedModels)
        #expect(OpenCodeModelCache(defaults: defaults).load() == nil)
    }

    @Test func padraoChatGPTSegueContaESemFixarEscolha() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = StubURLProtocol.uniqueHost()
        let url = try #require(URL(string: "https://\(host)/backend"))
        let a = #"{"models":[{"slug":"gpt-6-luna","visibility":"list","priority":0},{"slug":"gpt-7-luna","visibility":"list","priority":1}]}"#
        let b = #"{"models":[{"slug":"gpt-7-luna","visibility":"list","priority":0},{"slug":"gpt-8-luna","visibility":"list","priority":1}]}"#
        StubURLProtocol.enqueue([.json(a), .json(b)], host: host)
        let secrets = InMemorySecretStore()
        let store = SecretChatGPTStore(secrets: secrets)
        try store.save(.init(accessToken: "exemplo", refreshToken: "exemplo", expiresAt: Date().addingTimeInterval(3600), accountID: "conta-1"))
        let lister = ChatGPTModelLister(baseURL: url, session: ChatGPTAuthSession(store: store), client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: suite)!)
        let settings = ProviderSettings(provider: .chatGPT)
        #expect(await lister.models().first == "gpt-7-luna")
        #expect(settings.model(for: .chatGPT, defaults: defaults) == "gpt-7-luna")
        _ = await lister.models()
        #expect(StubURLProtocol.requests(host: host).count == 1)
        #expect(await lister.models(refresh: true).first == "gpt-8-luna")
        #expect(settings.model(for: .chatGPT, defaults: defaults) == "gpt-8-luna")
        let recreated = ChatGPTModelLister(baseURL: url, session: ChatGPTAuthSession(store: store), client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: suite)!)
        #expect(await recreated.models().first == "gpt-8-luna")
        #expect(StubURLProtocol.requests(host: host).count == 2)
        #expect(settings.models[.chatGPT] == nil)
        #expect(ProviderSettings(provider: .chatGPT, models: [.chatGPT: "minha-escolha"]).model(for: .chatGPT, defaults: defaults) == "minha-escolha")
        ProviderSettingsStore(defaults: defaults).save(settings)
        let factory = try ProviderFactory.makeChat(settingsStore: ProviderSettingsStore(defaults: defaults), secrets: secrets)
        #expect(factory.model == "gpt-8-luna")
        #expect(ProviderSettingsStore(defaults: defaults).load().models[.chatGPT] == nil)
        try store.save(.init(accessToken: "exemplo", refreshToken: "exemplo", expiresAt: Date().addingTimeInterval(3600), accountID: "conta-2"))
        StubURLProtocol.enqueue([.json("{}", status: 500)], host: host)
        #expect(await lister.models(refresh: true) == ChatGPTModelLister.fallbackModels)
        #expect(ModelCache(defaults: defaults).load(.chatGPT) == nil)
    }

    @Test func comparacaoNumericaEPadroesAdicionais() {
        #expect(ModelDefaults.isNewer([6, 10], than: [6, 9]))
        #expect(ModelDefaults.isNewer([7], than: [6, 99]))
        #expect(!ModelDefaults.isNewer([6], than: [6, 0]))
        #expect(ModelDefaults.version(of: "gpt-6.12-luna") == [6, 12])
        #expect(ModelDefaults.preferred(in: ["gpt-6.0-luna", "gpt-6-luna"], provider: .chatGPT) == "gpt-6.0-luna")
        #expect(ModelDefaults.preferred(in: ["outro", "sem-leve"], provider: .anthropic) == "outro")
        #expect(ModelDefaults.preferred(in: ["outro", "sem-leve"], provider: .openRouter) == "outro")
        #expect(ModelDefaults.preferred(in: ["outro", "sem-leve"], provider: .openCode) == "outro")
        #expect(ModelDefaults.preferred(in: ["gpt-6.2-luna", "gpt-6.10-luna"], provider: .openCode) == "gpt-6.10-luna")
    }

    @Test func reservaDeCadaEndpointNaoFicaVazia() async {
        let cases: [(AIProviderID, String)] = [(.openAI, "api.openai.com"), (.anthropic, "api.anthropic.com"), (.openRouter, "openrouter.ai")]
        for (provider, host) in cases {
            StubURLProtocol.enqueue([.json("{}", status: 500)], host: host)
            let discovery = ModelDiscovery(client: HTTPClient(session: StubURLProtocol.makeSession()), defaults: UserDefaults(suiteName: UUID().uuidString)!)
            let result = await discovery.models(for: provider, apiKey: nil)
            #expect(result.models == ProviderCatalog.descriptor(for: provider).suggestedModels)
            #expect(!result.models.isEmpty && !result.fromCache && result.fetchedAt == nil)
        }
    }

    @Test func trocaDeChaveDuranteRespostaNaoRestauraCacheAntigo() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedDiscoveryProtocol.self]
        let discovery = ModelDiscovery(client: HTTPClient(session: URLSession(configuration: config)),
                                       defaults: UserDefaults(suiteName: suite)!)
        let url = try #require(URL(string: "https://example.invalid/v1"))
        let first = Task { await discovery.models(for: .custom, apiKey: "anterior", baseURL: url) }
        await DelayedDiscoveryProtocol.waitForFirst()
        let second = await discovery.models(for: .custom, apiKey: "atual", baseURL: url)
        DelayedDiscoveryProtocol.releaseFirst()
        let obsolete = await first.value
        #expect(second.models == ["modelo-novo"])
        #expect(obsolete.models == ["llama3.1"])
        let snapshot = try #require(ModelCache(defaults: defaults).load(.custom))
        #expect(snapshot.models == ["modelo-novo"])
        #expect(snapshot.credentialHash == ModelCache.fingerprint("atual"))
    }

}
