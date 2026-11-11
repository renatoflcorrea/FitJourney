import Foundation
import SwiftData
import Testing
@testable import FitJourney

private func anthropic(_ host: String, retry: HTTPClient.RetryPolicy = .none) throws -> AnthropicMessagesGateway {
    AnthropicMessagesGateway(
        configuration: EndpointConfiguration(provider: .anthropic, baseURL: try #require(URL(string: "https://\(host)/v1")),
                                             auth: .header(name: "x-api-key", value: "test-key-not-real")),
        client: HTTPClient(session: StubURLProtocol.makeSession(), retryPolicy: retry))
}

private func openAI(_ host: String, retry: HTTPClient.RetryPolicy = .none) throws -> OpenAICompatibleChatGateway {
    OpenAICompatibleChatGateway(
        configuration: EndpointConfiguration(provider: .openAI, baseURL: try #require(URL(string: "https://\(host)/v1")),
                                             auth: .bearer("test-key-not-real")),
        client: HTTPClient(session: StubURLProtocol.makeSession(), retryPolicy: retry))
}

private let okAnthropicStream = sseBody([
    #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":0}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
    #"{"type":"message_stop"}"#,
], done: false)

@Suite("AI · Correções da revisão (provedores)")
struct AIReviewProviderTests {
    let host = StubURLProtocol.uniqueHost()

    @Test("A1: 400 de assinatura de thinking → nova tentativa sem blocos de raciocínio")
    func thinkingStripAndRetry() async throws {
        StubURLProtocol.enqueue([
            .json(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages.2.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation."}}"#, status: 400),
            .sse(okAnthropicStream),
        ], host: host)
        let messages: [LLMMessage] = [
            .user("oi"),
            LLMMessage(role: .assistant, content: "",
                       toolCalls: [ToolCall(id: "t", name: "get_profile", argumentsJSON: "{}")],
                       reasoningBlocks: [ReasoningBlock(kind: .thinking, text: "x", signature: "s")]),
            .toolResult(id: "t", name: "get_profile", content: "{}"),
        ]
        let events = try await collect(try anthropic(host).stream(ChatRequest(model: "claude-opus-5-5", messages: messages)))
        #expect(events.contains(.delta("ok")))
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 2)
        let types = { (body: JSONValue) in
            (body["messages"]?.arrayValue ?? []).flatMap { $0["content"]?.arrayValue ?? [] }.compactMap { $0["type"]?.stringValue }
        }
        #expect(types(bodies[0]).contains("thinking"))
        #expect(!types(bodies[1]).contains("thinking"))
        #expect(types(bodies[1]).contains("tool_use"))
    }

    @Test("fallback server-side: raciocínio e tool_use antes da fronteira são descartados; texto fica")
    func fallbackBoundary() async throws {
        let frames = [
            #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"a"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Parte 1. "}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"old","name":"get_profile","input":{}}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"content_block_start","index":4,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":4,"delta":{"type":"text_delta","text":"Parte 2."}}"#,
            #"{"type":"content_block_stop","index":4}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ]
        StubURLProtocol.enqueue([.sse(sseBody(frames, done: false))], host: host)
        let events = try await collect(try anthropic(host).stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("oi")])))
        #expect(events.filter { if case .toolCall = $0 { true } else { false } }.isEmpty)
        #expect(events.filter { if case .reasoningBlock = $0 { true } else { false } }.isEmpty)
        #expect(events.contains(.delta("Parte 1. ")))
        #expect(events.contains(.delta("Parte 2.")))
        #expect(events.last == .finished(reason: .stop))
    }

    @Test("M1: Anthropic sem message_stop → network repetível, sem tool_use pela metade")
    func anthropicTruncated() async throws {
        let frames = [
            #"{"type":"message_start","message":{"id":"m","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"get_profile","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a"}}"#,
        ]
        StubURLProtocol.enqueue([.sse(sseBody(frames, done: false))], host: host)
        var seen: [ChatEvent] = []
        do {
            for try await event in try anthropic(host).stream(ChatRequest(model: "x", messages: [.user("oi")])) { seen.append(event) }
            Issue.record("não lançou")
        } catch let error as AIError {
            #expect(error.isRetryable)
            guard case .network = error else { Issue.record("veio \(error)"); return }
        }
        #expect(!seen.contains { if case .toolCall = $0 { true } else { false } })
    }

    @Test("M1: OpenAI sem [DONE] nem finish_reason → network repetível")
    func openAITruncated() async throws {
        StubURLProtocol.enqueue([.sse(sseBody([#"{"id":"r","model":"m","choices":[{"index":0,"delta":{"content":"meio"}}]}"#], done: false))], host: host)
        await #expect(throws: AIError.network(code: URLError.networkConnectionLost.rawValue, retryable: true)) {
            _ = try await collect(try openAI(self.host).stream(ChatRequest(model: "m", messages: [.user("oi")])))
        }
    }

    @Test("M2: blocos de texto vazios/brancos não vão para a Anthropic; texto é aparado")
    func trimsText() {
        let wire = AnthropicMessagesGateway.wireMessages([
            .user("  oi  \n"), .assistant("   "), .user("\n"), .assistant("resposta  "),
        ])
        let blocks = wire.flatMap { $0["content"]?.arrayValue ?? [] }
        #expect(blocks.map { $0["text"] } == [.string("oi"), .string("resposta")])
        #expect(wire.count == 2)
    }

    @Test("M6: 400 que não cita o parâmetro não é repetido")
    func noBlindFallback() async throws {
        StubURLProtocol.enqueue([.json(#"{"error":{"message":"Invalid schema: messages too long"}}"#, status: 400)], host: host)
        await #expect(throws: AIError.self) {
            _ = try await openAI(self.host).complete(ChatRequest(
                model: "m", messages: [.user("t")], responseFormat: .jsonSchema(name: "t", schema: #"{"type":"object"}"#, strict: true)))
        }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test("B5: 429 com Retry-After e 529 overloaded são repetidos (máx. 2); Retry-After longo não")
    func retries() async throws {
        let fast = HTTPClient.RetryPolicy(maxRetries: 2, baseDelay: 0.01, maxDelay: 1)
        StubURLProtocol.enqueue([
            .json(#"{"error":{"message":"slow"}}"#, status: 429, headers: ["Retry-After": "0"]),
            .json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529),
            .sse(okAnthropicStream),
        ], host: host)
        let events = try await collect(try anthropic(host, retry: fast).stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("oi")])))
        #expect(events.contains(.delta("ok")))
        #expect(StubURLProtocol.requests(host: host).count == 3)

        let other = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"error":{"message":"slow"}}"#, status: 429, headers: ["Retry-After": "120"])], host: other)
        await #expect(throws: AIError.rateLimited(retryAfter: 120)) {
            _ = try await collect(try anthropic(other, retry: fast).stream(ChatRequest(model: "x", messages: [.user("oi")])))
        }
        #expect(StubURLProtocol.requests(host: other).count == 1)
        #expect(fast.delay(for: AIError.badRequest(status: 400, message: "x"), attempt: 0) == nil)
        #expect(fast.delay(for: AIError.rateLimited(retryAfter: nil), attempt: 2) == nil)
    }

    @Test("M4: redirecionamento é recusado e a credencial não segue para outro host", .timeLimit(.minutes(1)))
    func refusesRedirect() async throws {
        let target = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.sse(okAnthropicStream)], host: target)
        StubURLProtocol.enqueue([Stub(statusCode: 307, headers: ["Location": "https://\(target)/v1/messages"])], host: host)
        await #expect(throws: AIError.badRequest(status: 307, message: "redirecionamento recusado")) {
            _ = try await collect(try anthropic(self.host).stream(ChatRequest(model: "x", messages: [.user("oi")])))
        }
        #expect(StubURLProtocol.requests(host: target).isEmpty)
    }

    @Test("M3: rede local por faixas IPv4 privadas, localhost e .local")
    func localNetwork() {
        for host in ["localhost", "mac.local", "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.20", "100.64.0.1",
                     "100.127.255.1", "127.0.0.1"] {
            #expect(ProviderReadiness.isLocalNetworkHost(host), "\(host)")
        }
        for host in ["example.com", "10.example.com", "192.168.evil.com", "172.32.0.1", "100.128.0.1", "8.8.8.8",
                     "1.2.3", "256.1.1.1", ".local", "10.0.0.5.nip.io"] {
            #expect(!ProviderReadiness.isLocalNetworkHost(host), "\(host)")
        }
        #expect(ProviderReadiness.isAcceptable(URL(string: "http://192.168.0.10:11434/v1")!))
        #expect(!ProviderReadiness.isAcceptable(URL(string: "http://192.168.evil.com/v1")!))
    }

    @Test("B12: modelos sem pensamento adaptativo não recebem thinking/effort/fallbacks")
    func olderModels() async throws {
        StubURLProtocol.enqueue([.sse(okAnthropicStream)], host: host)
        _ = try await collect(try anthropic(host).stream(ChatRequest(model: "claude-haiku-4-5", messages: [.user("oi")])))
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(StubURLProtocol.requests(host: host).first?.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(AnthropicModelSupport.supportsAdaptiveThinking("claude-sonnet-5-5"))
        #expect(AnthropicModelSupport.supportsServerFallbacks("claude-sonnet-5-5"))
        #expect(!AnthropicModelSupport.supportsServerFallbacks("claude-haiku-5-5"))
    }
}

private typealias Stub = StubURLProtocol.Stub

@Suite("AI · Correções da revisão (consentimento e catálogo)")
@MainActor
struct AIReviewLocalTests {
    @Test("M8: compartilhamento nasce desligado; consentimento grava a escolha e pode ser revogado")
    func consent() throws {
        let defaults = try #require(UserDefaults(suiteName: "ai-consent-\(UUID().uuidString)"))
        let store = CoachProfileStore(defaults: defaults)
        #expect(!store.hasConsented)
        #expect(store.load().sharing == .none)
        store.grantConsent(sharing: CoachProfile.Sharing(profile: true, workouts: true))
        #expect(store.hasConsented)
        #expect(store.load().sharing.workouts)
        #expect(!store.load().sharing.nutrition)
        store.revokeConsent()
        #expect(!store.hasConsented)
        #expect(store.load().sharing == .none)
    }

    @Test("B2: empate de nome prefere o exercício do catálogo")
    func matcherPrefersCatalog() throws {
        let fixture = try PersistenceFixture()
        let custom = Exercise(name: "Supino reto com barra")
        fixture.context.insert(custom)
        try fixture.context.save()
        let catalog = try fixture.context.fetch(FetchDescriptor<Exercise>())
        #expect(ExerciseMatcher.match(name: "supino reto com barra", catalogKey: nil, in: catalog)?.catalogKey == "bench-press")
    }

    @Test("B1: get_exercise_progress só olha o último ano")
    func progressWindow() throws {
        let fixture = try ToolboxFixture()
        try fixture.addSession(daysAgo: 400, load: 200)
        try fixture.addSession(daysAgo: 10, load: 50)
        let (json, _) = try fixture.run(fixture.toolbox(), "get_exercise_progress", #"{"exercise":"Supino reto com barra"}"#)
        #expect(json["totalSessions"] == .number(1))
        #expect(json["bests"]?["heaviestKg"] == .number(50))
    }
}
