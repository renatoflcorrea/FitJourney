import Foundation
import Testing
@testable import FitJourney

private func openAIGateway(host: String, provider: AIProviderID = .openAI,
                           quirks: ProviderQuirks = ProviderQuirks()) throws -> OpenAICompatibleChatGateway {
    OpenAICompatibleChatGateway(
        configuration: EndpointConfiguration(provider: provider, baseURL: try #require(URL(string: "https://\(host)/v1")),
                                             auth: .bearer("test-key-not-real"), quirks: quirks),
        client: HTTPClient(session: StubURLProtocol.makeSession()))
}

private func anthropicGateway(host: String) throws -> AnthropicMessagesGateway {
    AnthropicMessagesGateway(
        configuration: EndpointConfiguration(provider: .anthropic, baseURL: try #require(URL(string: "https://\(host)/v1")),
                                             auth: .header(name: "x-api-key", value: "test-key-not-real"),
                                             quirks: ProviderQuirks(strictTools: false)),
        client: HTTPClient(session: StubURLProtocol.makeSession()))
}

private let sampleTool = ToolSpec(name: "list_programs", description: "Lista programas",
                                  parametersSchema: #"{"type":"object","properties":{"include_archived":{"type":"boolean"}},"required":["include_archived"],"additionalProperties":false}"#)

@Suite("AI · OpenAI-compatível")
struct AIOpenAIGatewayTests {
    let host = StubURLProtocol.uniqueHost()

    @Test("tool_calls fragmentados por índice são montados e emitidos antes de finished")
    func streamingToolCalls() async throws {
        let frames = [
            #"{"id":"c1","model":"gpt-5-mini","choices":[{"index":0,"delta":{"role":"assistant","content":"Vou "}}]}"#,
            #"{"id":"c1","model":"gpt-5-mini","choices":[{"index":0,"delta":{"content":"olhar."}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"list_programs","arguments":""}}]}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"list_exercises","arguments":"{\"qu"}}]}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"include_"}}]}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"archived\":false}"}}]}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"ery\":\"supino\"}"}}]}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"id":"c1","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30}}"#,
        ]
        StubURLProtocol.enqueue([.sse(sseBody(frames))], host: host)
        let events = try await collect(try openAIGateway(host: host).stream(
            ChatRequest(model: "gpt-5-mini", messages: [.user("oi")], maxTokens: 500, tools: [sampleTool], toolChoice: .auto)))

        #expect(events == [
            .started(id: "c1", model: "gpt-5-mini"),
            .delta("Vou "), .delta("olhar."),
            .toolCall(id: "call_a", name: "list_programs", argumentsJSON: #"{"include_archived":false}"#),
            .toolCall(id: "call_b", name: "list_exercises", argumentsJSON: #"{"query":"supino"}"#),
            .usage(TokenUsage(promptTokens: 120, completionTokens: 30)),
            .finished(reason: .toolCalls),
        ])

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real")
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["max_completion_tokens"] == .number(500))
        #expect(body["max_tokens"] == nil)
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"]?["include_usage"] == .bool(true))
        #expect(body["tool_choice"] == .string("auto"))
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool["type"] == .string("function"))
        #expect(tool["function"]?["name"] == .string("list_programs"))
        #expect(tool["function"]?["strict"] == .bool(true))
        #expect(tool["function"]?["parameters"]?["additionalProperties"] == .bool(false))
    }

    @Test("histórico com tool_calls e resultados vai no formato OpenAI")
    func toolHistoryWire() async throws {
        StubURLProtocol.enqueue([.sse(sseBody([#"{"model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#]))], host: host)
        let messages: [LLMMessage] = [
            .system("sys"), .user("oi"),
            .assistant("", toolCalls: [ToolCall(id: "call_1", name: "list_programs", argumentsJSON: "{}")]),
            .toolResult(id: "call_1", name: "list_programs", content: #"{"programs":[]}"#),
        ]
        _ = try await collect(try openAIGateway(host: host).stream(ChatRequest(model: "gpt-4.1", messages: messages, temperature: 0.3)))
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        let wire = try #require(body["messages"]?.arrayValue)
        #expect(wire.count == 4)
        #expect(wire[2]["role"] == .string("assistant"))
        #expect(wire[2]["content"] == .null)
        #expect(wire[2]["tool_calls"]?.arrayValue?.first?["id"] == .string("call_1"))
        #expect(wire[3]["role"] == .string("tool"))
        #expect(wire[3]["tool_call_id"] == .string("call_1"))
        #expect(body["temperature"] == .number(0.3))
    }

    @Test("401 no stream vira unauthorized sem vazar a chave")
    func unauthorized() async throws {
        StubURLProtocol.enqueue([.json(#"{"error":{"message":"Incorrect API key provided: test-key-not-real"}}"#, status: 401)], host: host)
        do {
            _ = try await collect(try openAIGateway(host: host).stream(ChatRequest(model: "m", messages: [.user("oi")])))
            Issue.record("não lançou")
        } catch let AIError.unauthorized(message) {
            #expect(!message.contains("test-key-not-real"))
        }
    }

    @Test("429 vira rateLimited com Retry-After")
    func rateLimited() async throws {
        StubURLProtocol.enqueue([.json(#"{"error":{"message":"slow down"}}"#, status: 429, headers: ["Retry-After": "7"])], host: host)
        await #expect(throws: AIError.rateLimited(retryAfter: 7)) {
            _ = try await collect(try openAIGateway(host: self.host).stream(ChatRequest(model: "m", messages: [.user("oi")])))
        }
    }

    @Test("400 por response_format rebaixa schema → objeto → texto (fireplaice)")
    func formatFallback() async throws {
        struct Payload: Decodable, Sendable { let title: String }
        let rejection = #"{"error":{"message":"response_format json_schema unsupported"}}"#
        StubURLProtocol.enqueue([
            .json(rejection, status: 400), .json(rejection, status: 400),
            .json(#"{"model":"m","choices":[{"message":{"content":"Aqui: {\"title\":\"ok\"}"}}]}"#),
        ], host: host)
        let value = try await openAIGateway(host: host).complete(
            ChatRequest(model: "m", messages: [.user("t")],
                        responseFormat: .jsonSchema(name: "t", schema: #"{"type":"object"}"#, strict: true)), as: Payload.self)
        #expect(value.title == "ok")
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.map { $0["response_format"]?["type"] } == [.string("json_schema"), .string("json_object"), nil])
    }

    @Test("400 por ferramenta estrita repete sem strict")
    func strictToolFallback() async throws {
        StubURLProtocol.enqueue([
            .json(#"{"error":{"message":"Invalid schema for function 'list_programs': strict mode"}}"#, status: 400),
            .sse(sseBody([#"{"model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#])),
        ], host: host)
        let events = try await collect(try openAIGateway(host: host).stream(
            ChatRequest(model: "m", messages: [.user("oi")], tools: [sampleTool])))
        #expect(events.contains(.delta("ok")))
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 2)
        #expect(bodies[1]["tools"]?.arrayValue?.first?["function"]?["strict"] == nil)
    }

    @Test("complete devolve tool_calls")
    func completeWithTools() async throws {
        StubURLProtocol.enqueue([.json(#"{"model":"m","choices":[{"message":{"content":null,"tool_calls":[{"id":"c9","type":"function","function":{"name":"get_profile","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#)], host: host)
        let completion = try await openAIGateway(host: host).complete(ChatRequest(model: "m", messages: [.user("oi")], tools: [sampleTool]))
        #expect(completion.toolCalls == [ToolCall(id: "c9", name: "get_profile", argumentsJSON: "{}")])
        #expect(completion.finishReason == .toolCalls)
        #expect(completion.usage == TokenUsage(promptTokens: 5, completionTokens: 2))
    }

    @Test("servidor compatível (Ollama) sem stream_options e sem auth")
    func customQuirks() async throws {
        StubURLProtocol.enqueue([.sse(sseBody([#"{"model":"llama3.1","choices":[{"index":0,"delta":{"content":"oi"},"finish_reason":"stop"}]}"#]))], host: host)
        let gateway = OpenAICompatibleChatGateway(
            configuration: EndpointConfiguration(provider: .custom, baseURL: try #require(URL(string: "https://\(host)/v1")),
                                                 auth: .none, quirks: ProviderQuirks(includeStreamUsage: false, strictTools: false)),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
        _ = try await collect(gateway.stream(ChatRequest(model: "llama3.1", messages: [.user("oi")], tools: [sampleTool])))
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["stream_options"] == nil)
        #expect(body["tools"]?.arrayValue?.first?["function"]?["strict"] == nil)
    }
}

@Suite("AI · Anthropic Messages")
struct AIAnthropicGatewayTests {
    let host = StubURLProtocol.uniqueHost()

    private static let events = ["message_start", "content_block_start", "content_block_delta", "content_block_delta",
                                 "content_block_stop", "content_block_start", "content_block_delta", "content_block_stop",
                                 "content_block_start", "content_block_delta", "content_block_delta", "content_block_delta",
                                 "content_block_stop", "message_delta", "message_stop"]

    @Test("SSE com thinking, texto e tool_use montado de input_json_delta")
    func streamingToolUse() async throws {
        let frames = [
            #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pensando"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Vou ver seus programas."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_programs","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"include_arch"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ived\": true}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
            #"{"type":"message_stop"}"#,
        ]
        StubURLProtocol.enqueue([.sse(": ping\n\n" + sseBody(frames, done: false, events: Self.events))], host: host)
        let events = try await collect(try anthropicGateway(host: host).stream(
            ChatRequest(model: "claude-opus-5-5", messages: [.system("sys"), .user("oi")], temperature: 0.2,
                        tools: [sampleTool], toolChoice: .required)))
        #expect(events == [
            .started(id: "msg_1", model: "claude-opus-5-5"),
            .reasoningDelta("pensando"),
            .reasoningBlock(ReasoningBlock(kind: .thinking, text: "pensando", signature: "sig123")),
            .delta("Vou ver seus programas."),
            .toolCall(id: "toolu_1", name: "list_programs", argumentsJSON: #"{"include_archived": true}"#),
            .usage(TokenUsage(promptTokens: 50, completionTokens: 40)),
            .finished(reason: .toolCalls),
        ])

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key-not-real")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicMessagesGateway.apiVersion)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["system"] == .string("sys"))
        #expect(body["temperature"] == nil) // API 2026-10-21 recusa temperature
        #expect(body["max_tokens"] == .number(Double(AnthropicMessagesGateway.defaultMaxTokens)))
        #expect(body["tool_choice"]?["type"] == .string("auto")) // forçado é recusado pelos modelos atuais
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool["input_schema"]?["type"] == .string("object"))
        #expect(body["messages"]?.arrayValue?.count == 1)
    }

    @Test("histórico: system separado, tool_use/tool_result, resultados paralelos fundidos e thinking reenviado")
    func wireMessages() {
        let messages: [LLMMessage] = [
            .system("sys"), .user("oi"),
            LLMMessage(role: .assistant, content: "Vou ver.",
                       toolCalls: [ToolCall(id: "t1", name: "a", argumentsJSON: #"{"x":1}"#),
                                   ToolCall(id: "t2", name: "b", argumentsJSON: "")],
                       reasoningBlocks: [ReasoningBlock(kind: .thinking, text: "hm", signature: "s")]),
            .toolResult(id: "t1", name: "a", content: "r1"),
            .toolResult(id: "t2", name: "b", content: "erro", isError: true),
        ]
        let wire = AnthropicMessagesGateway.wireMessages(messages)
        #expect(wire.count == 3)
        #expect(wire[0]["role"] == .string("user"))
        let assistant = wire[1]["content"]?.arrayValue ?? []
        #expect(assistant.map { $0["type"] } == [.string("thinking"), .string("text"), .string("tool_use"), .string("tool_use")])
        #expect(assistant[0]["signature"] == .string("s"))
        #expect(assistant[2]["input"] == .object(["x": .number(1)]))
        #expect(assistant[3]["input"] == .object([:]))
        let results = wire[2]["content"]?.arrayValue ?? []
        #expect(wire[2]["role"] == .string("user"))
        #expect(results.count == 2)
        #expect(results[0]["tool_use_id"] == .string("t1"))
        #expect(results[1]["is_error"] == .bool(true))
    }

    @Test("evento error no meio do stream vira AIError")
    func streamErrorEvent() async throws {
        let frames = [
            #"{"type":"message_start","message":{"id":"m","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]
        StubURLProtocol.enqueue([.sse(sseBody(frames, done: false))], host: host)
        await #expect(throws: AIError.server(status: 529, message: "Overloaded")) {
            _ = try await collect(try anthropicGateway(host: self.host).stream(ChatRequest(model: "x", messages: [.user("oi")])))
        }
    }

    @Test("401 e 429 da Anthropic")
    func httpErrors() async throws {
        StubURLProtocol.enqueue([
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401),
            .json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#, status: 429, headers: ["retry-after": "3"]),
        ], host: host)
        let gateway = try anthropicGateway(host: host)
        do {
            _ = try await collect(gateway.stream(ChatRequest(model: "x", messages: [.user("oi")])))
            Issue.record("não lançou")
        } catch let error as AIError {
            guard case .unauthorized = error else { Issue.record("veio \(error)"); return }
        }
        await #expect(throws: AIError.rateLimited(retryAfter: 3)) {
            _ = try await collect(gateway.stream(ChatRequest(model: "x", messages: [.user("oi")])))
        }
    }

    @Test("complete lê texto, tool_use e usage; jsonSchema vai em output_config")
    func complete() async throws {
        StubURLProtocol.enqueue([.json(#"{"id":"m","model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"tu","name":"get_profile","input":{}}],"usage":{"input_tokens":3,"output_tokens":4}}"#)], host: host)
        let completion = try await anthropicGateway(host: host).complete(
            ChatRequest(model: "claude-haiku-5-5", messages: [.user("oi")],
                        responseFormat: .jsonSchema(name: "x", schema: #"{"type":"object"}"#, strict: true)))
        #expect(completion.content == "ok")
        #expect(completion.toolCalls == [ToolCall(id: "tu", name: "get_profile", argumentsJSON: "{}")])
        #expect(completion.finishReason == .toolCalls)
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body["output_config"]?["format"]?["type"] == .string("json_schema"))
        #expect(body["stream"] == nil)
    }
}

@Suite("AI · Catálogo, configurações e fábrica")
struct AIProviderConfigurationTests {
    @Test("todo provedor tem descritor e modelo padrão (exceto custom, que sugere um)")
    func catalogCoversAll() {
        for id in AIProviderID.allCases {
            let descriptor = ProviderCatalog.descriptor(for: id)
            #expect(descriptor.id == id)
            #expect(!descriptor.suggestedModels.isEmpty)
        }
        #expect(ProviderCatalog.descriptor(for: .custom).defaultBaseURL == nil)
    }

    @Test("configurações sobrevivem a ida e volta e guardam modelo por provedor")
    func settingsRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "ai-settings-\(UUID().uuidString)"))
        let store = ProviderSettingsStore(defaults: defaults)
        #expect(store.load() == .default)
        var settings = ProviderSettings(provider: .anthropic)
        settings.model = "claude-sonnet-5-5"
        settings.provider = .custom
        settings.customBaseURL = URL(string: "http://localhost:11434/v1")
        store.save(settings)
        let loaded = store.load()
        #expect(loaded == settings)
        #expect(loaded.model(for: .anthropic) == "claude-sonnet-5-5")
        #expect(loaded.model(for: .openAI) == ProviderCatalog.descriptor(for: .openAI).defaultModel)
        // Nada de segredo no UserDefaults.
        let raw = String(decoding: try #require(defaults.data(forKey: ProviderSettingsStore.key)), as: UTF8.self)
        #expect(!raw.lowercased().contains("key"))
    }

    @Test("prontidão: modelo, endpoint e chave")
    func readiness() throws {
        #expect(ProviderReadiness.evaluate(ProviderSettings(provider: .openAI), hasAPIKey: false) == .missingAPIKey(.openAI))
        #expect(ProviderReadiness.evaluate(ProviderSettings(provider: .openAI), hasAPIKey: true) == .ready)
        #expect(ProviderReadiness.evaluate(ProviderSettings(provider: .custom), hasAPIKey: false) == .invalidEndpoint)
        let ollama = ProviderSettings(provider: .custom, customBaseURL: URL(string: "http://localhost:11434/v1"))
        #expect(ProviderReadiness.evaluate(ollama, hasAPIKey: false) == .ready)
        let insecure = ProviderSettings(provider: .custom, customBaseURL: URL(string: "http://example.com/v1"))
        #expect(ProviderReadiness.evaluate(insecure, hasAPIKey: false) == .invalidEndpoint)
        let withUser = ProviderSettings(provider: .custom, customBaseURL: URL(string: "https://user:pw@example.com/v1"))
        #expect(ProviderReadiness.evaluate(withUser, hasAPIKey: false) == .invalidEndpoint)
    }

    @Test("fábrica escolhe o gateway certo e lança notConfigured sem chave")
    func factory() throws {
        #expect(throws: AIError.self) { try ProviderFactory.makeChat(settings: ProviderSettings(provider: .openAI), apiKey: nil) }
        #expect(try ProviderFactory.makeChat(settings: ProviderSettings(provider: .anthropic), apiKey: "k").gateway is AnthropicMessagesGateway)
        #expect(try ProviderFactory.makeChat(settings: ProviderSettings(provider: .openRouter), apiKey: "k").gateway is OpenAICompatibleChatGateway)
        let secrets = InMemorySecretStore([.apiKey(.openAI): "k"])
        let defaults = try #require(UserDefaults(suiteName: "ai-factory-\(UUID().uuidString)"))
        let chat = try ProviderFactory.makeChat(settingsStore: ProviderSettingsStore(defaults: defaults), secrets: secrets)
        #expect(chat.model == ProviderCatalog.descriptor(for: .openAI).defaultModel)
        #expect(chat.gateway.provider == .openAI)
    }

    @Test("SecretStore em memória: gravar, ler e apagar")
    func secretStore() throws {
        let store = InMemorySecretStore()
        #expect(!store.contains(.apiKey(.openAI)))
        try store.set("abc", for: .apiKey(.openAI))
        #expect(try store.string(for: .apiKey(.openAI)) == "abc")
        try store.set(nil, for: .apiKey(.openAI))
        #expect(try store.string(for: .apiKey(.openAI)) == nil)
        #expect(KeychainSecretStore().service == "br.com.renatocorrea.fitjourney")
    }
}
