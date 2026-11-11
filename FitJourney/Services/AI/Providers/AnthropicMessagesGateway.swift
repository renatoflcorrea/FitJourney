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
/// - Modelos com pensamento adaptativo (`AnthropicModelSupport`): `thinking: adaptive` com
///   `display: summarized` (o raciocínio resumido aparece na UI em vez de uma pausa longa) e
///   `output_config.effort: medium` explícito (Opus 5.5 já usa medium; Sonnet 5.5 usaria high).
/// - Recusas: modelos com fallback server-side recebem `fallbacks: "default"` (beta
///   `server-side-fallback-2026-07-01`). Depois de um bloco `fallback`, o raciocínio e os `tool_use`
///   anteriores à fronteira são descartados (regra de reenvio da skill); o texto parcial continua.
/// - Verificação de edição de histórico (thinking vinculado à conversa): o laço do Coach é só-anexar
///   dentro do turno e remove os blocos de turnos anteriores (remoção pela frente é permitida). Não
///   usamos `block_binding.prefix_mismatch_behavior` (beta; exige adaptive em todo modelo e qualquer
///   valor liga a verificação). Um 400 de assinatura de thinking é recuperado com uma nova tentativa
///   sem os blocos (strip-and-retry, a recuperação que a skill indica fora do beta).
/// - Stream sem `message_stop` é conexão perdida (`AIError.network`, repetível).
struct AnthropicMessagesGateway: ChatGateway, StructuredCompleting {
    static let apiVersion = "2026-10-21"
    /// Streaming: 64k (sem risco de timeout HTTP); uma vez: 16k (abaixo dos timeouts).
    static let defaultStreamMaxTokens = 64_000
    static let defaultMaxTokens = 16_000
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let effort = "medium"

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
                    let (bytes, _) = try await withThinkingRecovery(request) { candidate in
                        try await client.bytes(for: makeRequest(candidate, stream: true))
                    }
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
                    if case let .data(payload) = parser.flush(), try state.consume(payload, into: continuation) {
                        continuation.finish()
                        return
                    }
                    // Sem `message_stop`: conexão perdida. Blocos abertos (tool_use pela metade) são descartados.
                    throw AIError.network(code: URLError.networkConnectionLost.rawValue, retryable: true)
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
        /// Blocos fechados, emitidos só em `message_stop` (um bloco `fallback` pode invalidá-los antes).
        var closedToolCalls: [ToolCall] = []
        var closedReasoning: [ReasoningBlock] = []
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
                case "fallback":
                    // Fronteira de fallback server-side: raciocínio e tool_use anteriores não são reenviados
                    // nem executados; o texto já recebido segue como contexto de continuação.
                    closedToolCalls = []
                    closedReasoning = []
                    blocks = blocks.filter { $0.value.kind == .text }
                    blocks[index] = Block(kind: .other)
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
                if let block = blocks.removeValue(forKey: index) { close(block) }
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

        mutating func close(_ block: Block) {
            switch block.kind {
            case .toolUse:
                let json = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
                closedToolCalls.append(ToolCall(id: block.id, name: block.name, argumentsJSON: json.isEmpty ? "{}" : json))
            case .thinking:
                closedReasoning.append(ReasoningBlock(kind: .thinking, text: block.thinking,
                                                      signature: block.signature.isEmpty ? nil : block.signature))
            case .redactedThinking:
                closedReasoning.append(ReasoningBlock(kind: .redactedThinking, data: block.data))
            case .text, .other:
                break
            }
        }

        mutating func finish(into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) {
            guard !finished else { return }
            finished = true
            // Blocos ainda abertos em `message_stop` não são confiáveis: descartados.
            blocks = [:]
            for block in closedReasoning { continuation.yield(.reasoningBlock(block)) }
            for call in closedToolCalls {
                continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
            }
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
        let (data, _) = try await withThinkingRecovery(request) { candidate in
            try await client.data(for: makeRequest(candidate, stream: false))
        }
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
            case "fallback":
                calls = []
                blocks = []
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

        let defaultMax = stream ? Self.defaultStreamMaxTokens : Self.defaultMaxTokens
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens ?? defaultMax)),
            "messages": .array(Self.wireMessages(request.messages)),
        ]
        if stream { body["stream"] = .bool(true) }
        var outputConfig: [String: JSONValue] = [:]
        if AnthropicModelSupport.supportsAdaptiveThinking(request.model) {
            body["thinking"] = .object(["type": .string("adaptive"), "display": .string("summarized")])
            outputConfig["effort"] = .string(Self.effort)
        }
        if AnthropicModelSupport.supportsServerFallbacks(request.model) {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = .string("default")
        }
        let system = request.messages.filter { $0.role == .system }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
            outputConfig["format"] = .object(["type": .string("json_schema"), "schema": try JSONValue.parse(schema)])
        }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
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
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Anexos antes do texto (skill claude-api): `image`/`document` com fonte base64.
                append("user", message.parts.compactMap(attachmentBlock)
                    + (text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]))
            case .tool:
                var block: [String: JSONValue] = [
                    "type": .string("tool_result"),
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "{}" : message.content),
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
                // A API recusa blocos de texto vazios/só espaços (e espaço no fim do último bloco).
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string(text)]))
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

    /// Bloco de anexo: imagem → `image` (base64 + `media_type`), PDF → `document` (base64,
    /// `application/pdf`, título = nome do arquivo), arquivo de texto → `text`. Limites da API: 32 MB por
    /// pedido e 600 páginas de PDF — o `AttachmentPreparer` mantém o total bem abaixo.
    static func attachmentBlock(_ part: LLMContentPart) -> JSONValue? {
        switch part {
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .object(["type": .string("text"), "text": .string(trimmed)])
        case let .image(mime, base64):
            return .object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string(mime), "data": .string(base64),
            ])])
        case let .pdf(filename, base64):
            return .object(["type": .string("document"), "title": .string(filename), "source": .object([
                "type": .string("base64"), "media_type": .string("application/pdf"), "data": .string(base64),
            ])])
        case let .fileText(filename, text):
            return .object(["type": .string("text"),
                            "text": .string(LLMContentPart.fileTextBody(filename: filename, text: text))])
        }
    }

    /// Um 400 de assinatura de thinking (verificação de edição de histórico) é recuperado uma vez,
    /// reenviando sem nenhum bloco de raciocínio.
    private func withThinkingRecovery<Value>(_ request: ChatRequest,
                                             perform: (ChatRequest) async throws -> Value) async throws -> Value {
        do {
            return try await perform(request)
        } catch let AIError.badRequest(status, message)
            where status == 400 && Self.isThinkingBindingError(message)
            && request.messages.contains(where: { !$0.reasoningBlocks.isEmpty }) {
            var stripped = request
            stripped.messages = stripped.messages.map { message in
                var copy = message
                copy.reasoningBlocks = []
                return copy
            }
            return try await perform(stripped)
        }
    }

    static func isThinkingBindingError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("thinking") && (lower.contains("signature") || lower.contains("different conversation"))
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

/// O que cada família de modelo Claude aceita (IDs da skill `claude-api`, cache de 2026-11).
enum AnthropicModelSupport {
    /// `thinking: {type: adaptive}` + `output_config.effort`. Haiku 4.5 e anteriores ficam de fora
    /// (usariam `budget_tokens`) e recebem o pedido sem esses campos.
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        let id = model.lowercased()
        let families = ["claude-fable-", "claude-mythos-", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
                        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return families.contains { id.hasPrefix($0) }
    }

    /// Modelos que aceitam `fallbacks: "default"` (recusa por classificador → modelo alternativo no servidor).
    static func supportsServerFallbacks(_ model: String) -> Bool {
        ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
            .contains(model.lowercased())
    }
}
