import Foundation

/// Gateway Chat Completions (OpenAI, OpenRouter, Ollama e outros compatíveis), com function
/// calling em streaming: os fragmentos de `tool_calls` são montados por `index` e emitidos como
/// `.toolCall` antes de `.finished`.
struct OpenAICompatibleChatGateway: ChatGateway, StructuredCompleting {
    var provider: AIProviderID { configuration.provider }

    private let configuration: EndpointConfiguration
    private let client: HTTPClient

    init(configuration: EndpointConfiguration, client: HTTPClient = HTTPClient()) {
        self.configuration = configuration
        self.client = client.addingSensitiveHeaders(configuration.sensitiveHeaderNames)
    }

    // MARK: - Streaming

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await withFallbacks(request) { candidate in
                        try await client.bytes(for: makeRequest(candidate, stream: true))
                    }
                    var state = StreamState()
                    var parser = SSEParser()
                    for try await line in SSEParser.lines(from: bytes) {
                        try Task.checkCancellation()
                        guard let event = parser.consume(line: line) else { continue }
                        switch event {
                        case .done:
                            guard state.pendingFinish != nil || state.sawContent else {
                                throw AIError.network(code: URLError.networkConnectionLost.rawValue, retryable: true)
                            }
                            state.finish(into: continuation)
                            continuation.finish()
                            return
                        case let .data(payload):
                            try state.consume(payload, into: continuation)
                        }
                    }
                    if case let .data(payload) = parser.flush() { try state.consume(payload, into: continuation) }
                    // Sem `[DONE]` nem `finish_reason`: a conexão caiu no meio; chamadas parciais são descartadas.
                    guard state.pendingFinish != nil else {
                        throw AIError.network(code: URLError.networkConnectionLost.rawValue, retryable: true)
                    }
                    state.finish(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPClient.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Estado do stream: anúncio, chamadas parciais e motivo de término adiado até a usage chegar.
    private struct StreamState {
        var announced = false
        var tools = ToolCallAccumulator()
        var pendingFinish: FinishReason?
        var finished = false
        /// Algum quadro válido chegou (servidores compatíveis às vezes mandam `[DONE]` sem `finish_reason`).
        var sawContent = false

        mutating func consume(_ payload: String,
                              into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) throws {
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OAIChatResponse.self, from: data) else { return }
            if let error = chunk.error {
                throw AIError.server(status: 200, message: Redactor.redact(error.message ?? "stream error"))
            }
            sawContent = true
            // Azure abre o stream com um quadro sem `choices`.
            if !announced, let model = chunk.model, !model.isEmpty {
                announced = true
                continuation.yield(.started(id: chunk.id ?? "", model: model))
            }
            for choice in chunk.choices ?? [] {
                if let content = choice.delta?.content, !content.isEmpty { continuation.yield(.delta(content)) }
                if let reasoning = choice.delta?.reasoningText, !reasoning.isEmpty {
                    continuation.yield(.reasoningDelta(reasoning))
                }
                for (offset, call) in (choice.delta?.toolCalls ?? []).enumerated() {
                    let index = call.index ?? offset
                    tools.begin(index: index, id: call.id, name: call.function?.name)
                    if let arguments = call.function?.arguments { tools.append(index: index, arguments: arguments) }
                }
                if let reason = choice.finishReason {
                    pendingFinish = OpenAICompatibleChatGateway.finishReason(reason)
                    emitToolCalls(into: continuation)
                }
            }
            if let usage = chunk.usage {
                continuation.yield(.usage(TokenUsage(promptTokens: usage.promptTokens ?? 0,
                                                     completionTokens: usage.completionTokens ?? 0)))
            }
        }

        mutating func emitToolCalls(into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) {
            for call in tools.drain() {
                continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
            }
        }

        mutating func finish(into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) {
            guard !finished else { return }
            finished = true
            let hadTools = !tools.isEmpty
            emitToolCalls(into: continuation)
            let reason = pendingFinish ?? (hadTools ? .toolCalls : .stop)
            continuation.yield(.finished(reason: reason))
        }
    }

    // MARK: - Uma vez

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        let (data, _) = try await withFallbacks(request) { candidate in
            try await client.data(for: makeRequest(candidate, stream: false))
        }
        let decoded: OAIChatResponse
        do {
            decoded = try JSONDecoder().decode(OAIChatResponse.self, from: data)
        } catch {
            throw AIError.decoding(context: "chat completion", message: "\(error)")
        }
        let choice = decoded.choices?.first
        var tools = ToolCallAccumulator()
        for (offset, call) in (choice?.message?.toolCalls ?? []).enumerated() {
            tools.begin(index: call.index ?? offset, id: call.id, name: call.function?.name)
            tools.append(index: call.index ?? offset, arguments: call.function?.arguments ?? "")
        }
        return ChatCompletion(
            content: choice?.message?.content ?? "",
            reasoning: choice?.message?.reasoningText,
            model: decoded.model ?? request.model,
            usage: decoded.usage.map { TokenUsage(promptTokens: $0.promptTokens ?? 0, completionTokens: $0.completionTokens ?? 0) },
            finishReason: Self.finishReason(choice?.finishReason),
            toolCalls: tools.drain())
    }

    // MARK: - Privado

    /// Repete só um pedido recusado (400), nunca um stream já iniciado:
    /// schema → objeto JSON → texto (fireplaice) e ferramentas `strict` → não estritas.
    private func withFallbacks<Value>(_ request: ChatRequest,
                                      perform: (ChatRequest) async throws -> Value) async throws -> Value {
        var candidate = request
        var strictTools = configuration.quirks.strictTools
        var relaxedTools = false
        while true {
            do {
                return try await perform(strictTools ? candidate : Self.relaxingTools(candidate))
            } catch AIError.badRequest(status: 400, let message) {
                // Só repete quando o erro cita o parâmetro recusado; qualquer outro 400 sobe como está.
                let lower = message.lowercased()
                if candidate.effort != nil, lower.contains("reasoning") {
                    candidate.effort = nil
                    continue
                }
                if strictTools, !candidate.tools.isEmpty, !relaxedTools, lower.contains("strict") {
                    strictTools = false
                    relaxedTools = true
                    continue
                }
                guard configuration.quirks.structuredOutputFallback,
                      lower.contains("response_format") || lower.contains("json_schema")
                else { throw AIError.badRequest(status: 400, message: message) }
                switch candidate.responseFormat {
                case let .jsonSchema(_, schema, _):
                    candidate.responseFormat = .jsonObject
                    candidate.messages.append(.system("Return only a JSON object matching this schema: \(schema)"))
                case .jsonObject:
                    candidate.responseFormat = .text
                    candidate.messages.append(.system("Return only valid JSON, without Markdown."))
                case .text:
                    throw AIError.badRequest(status: 400, message: message)
                }
            }
        }
    }

    private static func relaxingTools(_ request: ChatRequest) -> ChatRequest {
        var copy = request
        copy.tools = copy.tools.map { var t = $0; t.strict = false; return t }
        return copy
    }

    func makeRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = configuration.request(path: "chat/completions", timeout: configuration.timeouts.chat)

        var wire = OAIChatRequest(
            model: request.model,
            messages: request.messages.map(Self.wireMessage),
            stream: stream,
            streamOptions: stream && configuration.quirks.includeStreamUsage ? OAIStreamOptions(includeUsage: true) : nil,
            temperature: ModelCapabilities.acceptsTemperature(request.model) ? request.temperature : nil,
            responseFormat: try Self.responseFormat(request.responseFormat))
        if let limit = request.maxTokens {
            let parameter = configuration.quirks.tokenParameter ?? ModelCapabilities.tokenParameter(for: request.model)
            if parameter == "max_completion_tokens" { wire.maxCompletionTokens = limit } else { wire.maxTokens = limit }
        }
        // Só modelos de raciocínio (gpt-5.x, série o) aceitam `reasoning_effort`; um 400 que o cite tira o campo.
        if let effort = request.effort, !ModelCapabilities.acceptsTemperature(request.model) {
            wire.reasoningEffort = effort.rawValue
        }
        if !request.tools.isEmpty {
            wire.tools = try request.tools.map { spec in
                OAITool(function: OAIFunction(name: spec.name, description: spec.description,
                                              parameters: try JSONValue.parse(spec.parametersSchema),
                                              strict: spec.strict && configuration.quirks.strictTools ? true : nil))
            }
            wire.toolChoice = request.toolChoice.map(Self.toolChoice)
        }
        do {
            urlRequest.httpBody = try JSONEncoder().encode(wire)
        } catch {
            throw AIError.decoding(context: "chat request", message: "\(error)")
        }
        return urlRequest
    }

    private static func wireMessage(_ message: LLMMessage) -> OAIMessage {
        switch message.role {
        case .assistant where !message.toolCalls.isEmpty:
            OAIMessage(role: "assistant", content: message.content.isEmpty ? nil : message.content,
                       toolCalls: message.toolCalls.map {
                           OAIToolCall(id: $0.id, function: OAIFunctionCall(name: $0.name, arguments: $0.argumentsJSON))
                       })
        case .tool:
            OAIMessage(role: "tool", content: message.content, toolCallID: message.toolCallID)
        case .user where !message.parts.isEmpty:
            OAIMessage(role: "user", content: message.content, contentParts: contentParts(message))
        default:
            OAIMessage(role: message.role.rawValue, content: message.content)
        }
    }

    /// Anexos antes do texto: imagem → `image_url` (data URL), PDF → `file` (`file_data` data URL),
    /// arquivo de texto → `text`. Quem decide se o modelo aceita PDF é `AttachmentCapabilities`
    /// (sem suporte, o PDF chega aqui já rasterizado em imagens).
    static func contentParts(_ message: LLMMessage) -> [JSONValue] {
        var parts: [JSONValue] = message.parts.map { part in
            switch part {
            case let .text(text):
                .object(["type": .string("text"), "text": .string(text)])
            case .image:
                .object(["type": .string("image_url"), "image_url": .object(["url": .string(part.dataURL ?? "")])])
            case let .pdf(filename, _):
                .object(["type": .string("file"),
                         "file": .object(["filename": .string(filename), "file_data": .string(part.dataURL ?? "")])])
            case let .fileText(filename, text):
                .object(["type": .string("text"), "text": .string(LLMContentPart.fileTextBody(filename: filename, text: text))])
            }
        }
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(message.content)]))
        }
        return parts
    }

    private static func toolChoice(_ choice: ToolChoice) -> JSONValue {
        switch choice {
        case .auto: .string("auto")
        case .none: .string("none")
        case .required: .string("required")
        case let .tool(name): .object(["type": .string("function"), "function": .object(["name": .string(name)])])
        }
    }

    private static func responseFormat(_ format: ResponseFormat) throws -> OAIResponseFormat? {
        switch format {
        case .text: nil
        case .jsonObject: OAIResponseFormat(type: "json_object")
        case let .jsonSchema(name, schema, strict):
            OAIResponseFormat(type: "json_schema",
                              jsonSchema: OAIJSONSchema(name: name, strict: strict, schema: try JSONValue.parse(schema)))
        }
    }

    static func finishReason(_ raw: String?) -> FinishReason {
        switch raw {
        case "length", "max_tokens": .length
        case "content_filter": .contentFilter
        case "tool_calls", "function_call": .toolCalls
        default: .stop
        }
    }
}
