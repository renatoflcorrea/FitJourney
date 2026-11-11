import Foundation

/// Gateway nativo da Messages API da Anthropic (`POST /v1/messages`).
///
/// - Autenticação `x-api-key` + `anthropic-version`.
/// - `system` separado; papel `tool` vira bloco `tool_result` numa mensagem `user`; mensagens
///   consecutivas do mesmo papel são fundidas (resultados paralelos vão juntos, numa só mensagem).
/// - SSE: `message_start`, `content_block_start` (`text`/`tool_use`/`thinking`/`redacted_thinking`),
///   `content_block_delta` (`text_delta`/`input_json_delta`/`thinking_delta`/`signature_delta`),
///   `content_block_stop`, `message_delta` (stop_reason + usage), `message_stop`, `error`.
/// - Versão de API `2026-10-21`: não aceita `temperature`/`top_p`/`top_k`, então `temperature` é ignorada.
/// - Modelos atuais recusam `tool_choice` forçado (`any`/`tool`): `.required`/`.tool` viram `auto`.
struct AnthropicMessagesGateway: ChatGateway, StructuredCompleting {
    static let apiVersion = "2026-10-21"
    static let defaultMaxTokens = 16_000

    var provider: AIProviderID { configuration.provider }

    private let configuration: EndpointConfiguration
    private let client: HTTPClient

    init(configuration: EndpointConfiguration, client: HTTPClient = HTTPClient()) {
        self.configuration = configuration
        self.client = client.addingSensitiveHeaders(configuration.sensitiveHeaderNames.union(["x-api-key"]))
    }

    // MARK: - Streaming

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await client.bytes(for: makeRequest(request, stream: true))
                    var state = StreamState()
                    var parser = SSEParser()
                    for try await line in SSEParser.lines(from: bytes) {
                        try Task.checkCancellation()
                        guard let event = parser.consume(line: line) else { continue }
                        if case let .data(payload) = event, try state.consume(payload, into: continuation) {
                            continuation.finish()
                            return
                        }
                    }
                    if case let .data(payload) = parser.flush() { _ = try state.consume(payload, into: continuation) }
                    state.finish(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPClient.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamState {
        enum BlockKind { case text, toolUse, thinking, redactedThinking, other }
        struct Block {
            var kind: BlockKind
            var id = ""
            var name = ""
            var json = ""
            var thinking = ""
            var signature = ""
            var data = ""
        }

        var blocks: [Int: Block] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var stopReason: FinishReason?
        var finished = false

        /// Devolve `true` quando o stream terminou (`message_stop`).
        mutating func consume(_ payload: String,
                              into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) throws -> Bool {
            guard let object = try? JSONValue.parse(payload), let type = object["type"]?.stringValue else { return false }
            switch type {
            case "message_start":
                let message = object["message"]
                inputTokens = message?["usage"]?["input_tokens"].flatMap(Self.int) ?? 0
                outputTokens = message?["usage"]?["output_tokens"].flatMap(Self.int) ?? 0
                continuation.yield(.started(id: message?["id"]?.stringValue ?? "",
                                            model: message?["model"]?.stringValue ?? ""))
            case "content_block_start":
                let index = object["index"].flatMap(Self.int) ?? 0
                let block = object["content_block"]
                switch block?["type"]?.stringValue {
                case "text":
                    blocks[index] = Block(kind: .text)
                    if let text = block?["text"]?.stringValue, !text.isEmpty { continuation.yield(.delta(text)) }
                case "tool_use":
                    blocks[index] = Block(kind: .toolUse, id: block?["id"]?.stringValue ?? "",
                                          name: block?["name"]?.stringValue ?? "")
                case "thinking":
                    blocks[index] = Block(kind: .thinking, thinking: block?["thinking"]?.stringValue ?? "",
                                          signature: block?["signature"]?.stringValue ?? "")
                case "redacted_thinking":
                    blocks[index] = Block(kind: .redactedThinking, data: block?["data"]?.stringValue ?? "")
                default:
                    blocks[index] = Block(kind: .other)
                }
            case "content_block_delta":
                let index = object["index"].flatMap(Self.int) ?? 0
                let delta = object["delta"]
                switch delta?["type"]?.stringValue {
                case "text_delta":
                    if let text = delta?["text"]?.stringValue, !text.isEmpty { continuation.yield(.delta(text)) }
                case "input_json_delta":
                    blocks[index, default: Block(kind: .toolUse)].json += delta?["partial_json"]?.stringValue ?? ""
                case "thinking_delta":
                    let text = delta?["thinking"]?.stringValue ?? ""
                    blocks[index, default: Block(kind: .thinking)].thinking += text
                    if !text.isEmpty { continuation.yield(.reasoningDelta(text)) }
                case "signature_delta":
                    blocks[index, default: Block(kind: .thinking)].signature += delta?["signature"]?.stringValue ?? ""
                default:
                    break
                }
            case "content_block_stop":
                let index = object["index"].flatMap(Self.int) ?? 0
                if let block = blocks.removeValue(forKey: index) { emit(block, into: continuation) }
            case "message_delta":
                if let reason = object["delta"]?["stop_reason"]?.stringValue {
                    stopReason = AnthropicMessagesGateway.finishReason(reason)
                }
                if let output = object["usage"]?["output_tokens"].flatMap(Self.int) { outputTokens = output }
                if let input = object["usage"]?["input_tokens"].flatMap(Self.int), input > 0 { inputTokens = input }
            case "message_stop":
                finish(into: continuation)
                return true
            case "error":
                let error = object["error"]
                let kind = error?["type"]?.stringValue ?? ""
                let message = Redactor.redact(error?["message"]?.stringValue ?? "stream error")
                switch kind {
                case "rate_limit_error": throw AIError.rateLimited(retryAfter: nil)
                case "authentication_error", "permission_error": throw AIError.unauthorized(message: message)
                case "invalid_request_error": throw AIError.badRequest(status: 400, message: message)
                default: throw AIError.server(status: kind == "overloaded_error" ? 529 : 500, message: message)
                }
            default:
                break // ping e eventos futuros
            }
            return false
        }

        func emit(_ block: Block, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) {
            switch block.kind {
            case .toolUse:
                let json = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.yield(.toolCall(id: block.id, name: block.name, argumentsJSON: json.isEmpty ? "{}" : json))
            case .thinking:
                continuation.yield(.reasoningBlock(ReasoningBlock(kind: .thinking, text: block.thinking,
                                                                  signature: block.signature.isEmpty ? nil : block.signature)))
            case .redactedThinking:
                continuation.yield(.reasoningBlock(ReasoningBlock(kind: .redactedThinking, data: block.data)))
            case .text, .other:
                break
            }
        }

        mutating func finish(into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) {
            guard !finished else { return }
            finished = true
            // Blocos não fechados (stream cortado): entrega o que houver.
            for index in blocks.keys.sorted() { if let block = blocks[index] { emit(block, into: continuation) } }
            blocks = [:]
            continuation.yield(.usage(TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)))
            continuation.yield(.finished(reason: stopReason ?? .stop))
        }

        static func int(_ value: JSONValue) -> Int? {
            if case let .number(n) = value { return Int(n) }
            return nil
        }
    }

    // MARK: - Uma vez

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        let (data, _) = try await client.data(for: makeRequest(request, stream: false))
        guard let object = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw AIError.decoding(context: "anthropic message", message: "invalid JSON")
        }
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var blocks: [ReasoningBlock] = []
        for block in object["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                calls.append(ToolCall(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                                      argumentsJSON: block["input"]?.jsonString() ?? "{}"))
            case "thinking":
                let thinking = block["thinking"]?.stringValue ?? ""
                reasoning += thinking
                blocks.append(ReasoningBlock(kind: .thinking, text: thinking, signature: block["signature"]?.stringValue))
            case "redacted_thinking":
                blocks.append(ReasoningBlock(kind: .redactedThinking, data: block["data"]?.stringValue))
            default:
                break
            }
        }
        let usage = object["usage"].map {
            TokenUsage(promptTokens: $0["input_tokens"].flatMap(StreamState.int) ?? 0,
                       completionTokens: $0["output_tokens"].flatMap(StreamState.int) ?? 0)
        }
        return ChatCompletion(content: text, reasoning: reasoning.isEmpty ? nil : reasoning,
                              model: object["model"]?.stringValue ?? request.model, usage: usage,
                              finishReason: Self.finishReason(object["stop_reason"]?.stringValue),
                              toolCalls: calls, reasoningBlocks: blocks)
    }

    // MARK: - Pedido

    func makeRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = configuration.request(path: "messages", timeout: configuration.timeouts.chat)
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens ?? Self.defaultMaxTokens)),
            "messages": .array(Self.wireMessages(request.messages)),
        ]
        if stream { body["stream"] = .bool(true) }
        let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = .string(system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(try request.tools.map { spec in
                var tool: [String: JSONValue] = [
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "input_schema": try JSONValue.parse(spec.parametersSchema),
                ]
                if spec.strict, configuration.quirks.strictTools { tool["strict"] = .bool(true) }
                return .object(tool)
            })
            if let choice = request.toolChoice {
                body["tool_choice"] = .object(["type": .string(choice == .none ? "none" : "auto")])
            }
        }
        switch request.responseFormat {
        case .text, .jsonObject:
            break // `jsonObject` não existe aqui; o pedido de JSON vai no prompt e o decodificador tolera prosa
        case let .jsonSchema(_, schema, _):
            body["output_config"] = .object(["format": .object([
                "type": .string("json_schema"), "schema": try JSONValue.parse(schema),
            ])])
        }
        urlRequest.httpBody = Data(JSONValue.object(body).jsonString().utf8)
        return urlRequest
    }

    /// Converte o histórico para blocos Anthropic, fundindo papéis consecutivos.
    static func wireMessages(_ messages: [LLMMessage]) -> [JSONValue] {
        var result: [(role: String, blocks: [JSONValue])] = []
        func append(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let last = result.last, last.role == role {
                result[result.count - 1].blocks += blocks
            } else {
                result.append((role, blocks))
            }
        }
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                append("user", message.content.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(message.content)])])
            case .tool:
                var block: [String: JSONValue] = [
                    "type": .string("tool_result"),
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content),
                ]
                if message.isError { block["is_error"] = .bool(true) }
                append("user", [.object(block)])
            case .assistant:
                var blocks: [JSONValue] = message.reasoningBlocks.map { reasoning in
                    switch reasoning.kind {
                    case .thinking:
                        var b: [String: JSONValue] = ["type": .string("thinking"), "thinking": .string(reasoning.text)]
                        if let signature = reasoning.signature { b["signature"] = .string(signature) }
                        return .object(b)
                    case .redactedThinking:
                        return .object(["type": .string("redacted_thinking"), "data": .string(reasoning.data ?? "")])
                    }
                }
                if !message.content.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string(message.content)]))
                }
                for call in message.toolCalls {
                    let input = (try? JSONValue.parse(call.argumentsJSON)).flatMap { $0.objectValue.map(JSONValue.object) }
                        ?? .object([:])
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id),
                                           "name": .string(call.name), "input": input]))
                }
                append("assistant", blocks)
            }
        }
        return result.map { .object(["role": .string($0.role), "content": .array($0.blocks)]) }
    }

    static func finishReason(_ raw: String?) -> FinishReason {
        switch raw {
        case "max_tokens", "model_context_window_exceeded": .length
        case "tool_use": .toolCalls
        case "refusal": .refusal
        default: .stop
        }
    }
}
