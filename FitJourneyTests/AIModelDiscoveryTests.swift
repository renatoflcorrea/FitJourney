import Foundation
import Testing
@testable import FitJourney

@Suite(.serialized)
struct AIModelDiscoveryTests {
    @Test func filtrosOpenAI() {
        let ids = ["gpt-6-luna", "o3", "gpt-6-audio", "gpt-6-realtime", "gpt-6-transcribe", "gpt-6-tts", "gpt-6-image", "gpt-6-search", "gpt-6-embedding", "gpt-6-moderation", "gpt-6-instruct", "gpt-6-codex", "gpt-6-pro", "gpt-6-2026-01-01", "other"]
        let data = try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
        #expect(ModelDiscovery.parse(data, provider: .openAI) == ["gpt-6-luna", "o3"])
    }

    @Test func filtrosAnthropicEOpenRouter() {
        let anthropic = Data(#"{"data":[{"id":"claude-haiku-5-5-20260101"},{"id":"claude-haiku-5-5"},{"id":"claude-sonnet-5-5-20260101"},{"id":"outro"}]}"#.utf8)
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
}
