import Foundation

/// Chat pela assinatura ChatGPT (`chatgpt.com/backend-api/codex/responses`, API Responses por SSE), **com
/// function calling**. Experimental e não oficial — porta de `ChatGPTResponsesGateway` do fireplaice, que não
/// tinha ferramentas. O que se sabe (e não se sabe) do fio: `fireplaice/work/CHATGPT_OAUTH.md`.
///
/// Corpo obrigatório: `model`, `instructions` não vazio (as mensagens `system` viram `instructions`; o backend
/// recusa item `role: system`), `input`, `store: false`, `stream: true`. `temperature` e `maxTokens` são
/// omitidos (o backend recusa). Ferramentas no formato da Responses API (`type: function` plano); o histórico
/// do laço vira itens `function_call` / `function_call_output` ligados por `call_id`.
///
/// Erros: 401/403 renovam o token uma vez e repetem; se ainda recusar, `AIError.signInRequired`.
struct ChatGPTResponsesGateway: ChatGateway, StructuredCompleting {
    static let defaultBaseURL = URL(string: "https://chatgpt.com/backend-api/codex") ?? URL(fileURLWithPath: "/")
    static let defaultInstructions = "You are a helpful assistant."

    var provider: AIProviderID { .chatGPT }

    private let baseURL: URL
    private let session: ChatGPTAuthSession
    private let client: HTTPClient
    private let originator: String
    private let userAgent: String
    private let sessionID: String
    private let timeout: TimeInterval
    /// `strict` nas ferramentas. Desligado por padrão: o Codex CLI manda `false` e não se sabe se o backend
    /// aceita schemas estritos de terceiros; os argumentos já são validados localmente (`FitnessToolbox`).
    private let strictTools: Bool
    /// Pede `reasoning.summary = auto` (resumos de raciocínio no stream). Cai fora num 400 que o cite.
    private let reasoningSummary: Bool

    init(baseURL: URL = ChatGPTResponsesGateway.defaultBaseURL, session: ChatGPTAuthSession,
         client: HTTPClient = HTTPClient(), originator: String = ChatGPTOAuthConfiguration.default.originator,
         version: String = ChatGPTResponsesGateway.appVersion, sessionID: String = UUID().uuidString.lowercased(),
         timeout: TimeInterval = HTTPClient.Timeouts.standard.chat, strictTools: Bool = false,
         reasoningSummary: Bool = true) {
        self.baseURL = baseURL
        self.session = session
        self.client = client.addingSensitiveHeaders(Self.sensitiveHeaders).keepingForbiddenStatus()
        self.originator = originator
        userAgent = "FitJourney/\(version)"
        self.sessionID = sessionID
        self.timeout = timeout
        self.strictTools = strictTools
        self.reasoningSummary = reasoningSummary
    }

    static let sensitiveHeaders = ["chatgpt-account-id", "session_id"]

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }

    // MARK: - Streaming

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await open(request)
                    var parser = SSEParser()
                    var decoder = ResponsesStreamDecoder(requestedModel: request.model)
                    for try await line in SSEParser.lines(from: bytes) {
                        try Task.checkCancellation()
                        guard let event = parser.consume(line: line) else { continue }
                        guard case let .data(payload) = event else { break }
                        for output in try decoder.consume(payload) { continuation.yield(output) }
                        if decoder.isFinished { break }
                    }
                    if !decoder.isFinished, case let .data(payload) = parser.flush() {
                        for output in try decoder.consume(payload) { continuation.yield(output) }
                    }
                    // Sem `response.completed/incomplete`: a conexão caiu no meio; chamadas parciais são descartadas.
                    guard decoder.isFinished else {
                        throw AIError.network(code: URLError.networkConnectionLost.rawValue, retryable: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPClient.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// O backend só responde em stream: `complete` monta a resposta a partir dele.
    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        var content = "", reasoning = "", model = request.model
        var usage: TokenUsage?
        var reason = FinishReason.stop
        var calls: [ToolCall] = []
        for try await event in stream(request) {
            switch event {
            case let .started(_, started): if !started.isEmpty { model = started }
            case let .delta(text): content += text
            case let .reasoningDelta(text): reasoning += text
            case .reasoningBlock: break
            case let .toolCall(id, name, arguments): calls.append(ToolCall(id: id, name: name, argumentsJSON: arguments))
            case let .usage(value): usage = value
            case let .finished(finished): reason = finished
            }
        }
        return ChatCompletion(content: content, reasoning: reasoning.isEmpty ? nil : reasoning, model: model,
                              usage: usage, finishReason: reason, toolCalls: calls)
    }

    // MARK: - Pedido

    /// 401/403 antes do stream: renova uma vez e repete. Recusa repetida: 401 apaga o login e pede novo
    /// (`signInRequired`, a UI volta a "Entrar com ChatGPT"); 403 com token novo é bloqueio do endpoint
    /// (Cloudflare, `originator`), que um novo login não resolve. 400 que cite pelo nome um parâmetro opcional:
    /// repete sem ele.
    private func open(_ request: ChatRequest) async throws -> URLSession.AsyncBytes {
        var credentials = try await session.credentials()
        var options = BodyOptions(strictTools: strictTools, reasoningSummary: reasoningSummary,
                                  reasoningEffort: request.effort != nil)
        var refreshed = false
        while true {
            do {
                return try await client.bytes(for: makeRequest(request, credentials: credentials, options: options)).0
            } catch AIError.unauthorized {
                guard !refreshed else {
                    await session.invalidate(accessToken: credentials.accessToken)
                    throw AIError.signInRequired
                }
                refreshed = true
                credentials = try await session.credentialsAfterRejection(of: credentials.accessToken)
            } catch AIError.badRequest(status: 403, _) {
                guard !refreshed else {
                    throw AIError.server(status: 403, message: String(localized: "O ChatGPT recusou o acesso mesmo com o login renovado. O endpoint não oficial pode ter mudado ou bloqueado o app."))
                }
                refreshed = true
                credentials = try await session.credentialsAfterRejection(of: credentials.accessToken)
            } catch AIError.badRequest(status: 400, let message) {
                guard let relaxed = options.dropping(citedIn: message) else {
                    throw AIError.badRequest(status: 400, message: message)
                }
                options = relaxed
            }
        }
    }

    struct BodyOptions: Sendable, Hashable {
        var strictTools: Bool
        var reasoningSummary: Bool
        var parallelToolCalls: Bool = true
        /// Envia `reasoning.effort` (ligado quando o pedido traz `effort`).
        var reasoningEffort: Bool = false

        /// Sem o(s) parâmetro(s) opcional(is) citado(s) **pelo nome** no erro; `nil` = nada a tirar.
        func dropping(citedIn message: String) -> BodyOptions? {
            let lower = message.lowercased()
            var copy = self
            if lower.contains("reasoning") {
                // Primeiro tira só o esforço; se o erro voltar, tira o resumo também.
                if copy.reasoningEffort { copy.reasoningEffort = false } else { copy.reasoningSummary = false }
            }
            if lower.contains("parallel_tool_calls") { copy.parallelToolCalls = false }
            if lower.contains("strict") { copy.strictTools = false }
            return copy == self ? nil : copy
        }
    }

    func makeRequest(_ request: ChatRequest, credentials: ChatGPTCredentials,
                     options: BodyOptions? = nil) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        urlRequest.setValue(originator, forHTTPHeaderField: "originator")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        urlRequest.setValue(sessionID, forHTTPHeaderField: "session_id")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try Self.body(for: request,
                                 options: options ?? BodyOptions(strictTools: strictTools, reasoningSummary: reasoningSummary,
                                                                 reasoningEffort: request.effort != nil))
        urlRequest.httpBody = Data(body.jsonString().utf8)
        return urlRequest
    }

    /// Corpo da Responses API. Mensagens `system` (e o pedido de JSON, se houver) viram `instructions`.
    static func body(for request: ChatRequest,
                     options: BodyOptions = BodyOptions(strictTools: false, reasoningSummary: true)) throws -> JSONValue {
        var instructions = request.messages.filter { $0.role == .system }.map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch request.responseFormat {
        case .text: break
        case .jsonObject: instructions.append("Return only a valid JSON object, without Markdown.")
        case let .jsonSchema(_, schema, _):
            instructions.append("Return only a JSON object matching this schema, without Markdown: \(schema)")
        }

        var input: [JSONValue] = []
        for message in request.messages {
            switch message.role {
            case .system:
                continue
            case .user where !message.parts.isEmpty:
                input.append(.object([
                    "type": .string("message"), "role": .string("user"), "content": .array(inputContent(message)),
                ]))
            case .user:
                input.append(messageItem(role: "user", type: "input_text", text: message.content))
            case .assistant:
                if !message.content.isEmpty {
                    input.append(messageItem(role: "assistant", type: "output_text", text: message.content))
                }
                for call in message.toolCalls {
                    // Sem `id` (fc_…): com `store:false` o backend não conhece itens anteriores; basta o `call_id`.
                    input.append(.object([
                        "type": .string("function_call"), "call_id": .string(call.id),
                        "name": .string(call.name), "arguments": .string(call.argumentsJSON),
                    ]))
                }
            case .tool:
                guard let callID = message.toolCallID else { continue }
                input.append(.object([
                    "type": .string("function_call_output"), "call_id": .string(callID),
                    "output": .string(message.content),
                ]))
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "instructions": .string(instructions.isEmpty ? defaultInstructions : instructions.joined(separator: "\n\n")),
            "input": .array(input),
            "store": .bool(false),
            "stream": .bool(true),
        ]
        var reasoning: [String: JSONValue] = [:]
        if options.reasoningSummary { reasoning["summary"] = .string("auto") }
        if options.reasoningEffort, let effort = request.effort { reasoning["effort"] = .string(effort.rawValue) }
        if !reasoning.isEmpty { body["reasoning"] = .object(reasoning) }
        if !request.tools.isEmpty {
            body["tools"] = .array(try request.tools.map { spec in
                var tool: [String: JSONValue] = [
                    "type": .string("function"), "name": .string(spec.name),
                    "description": .string(spec.description),
                    "parameters": try JSONValue.parse(spec.parametersSchema),
                ]
                tool["strict"] = .bool(options.strictTools && spec.strict)
                return .object(tool)
            })
            body["tool_choice"] = toolChoice(request.toolChoice ?? .auto)
            if options.parallelToolCalls { body["parallel_tool_calls"] = .bool(true) }
        }
        return .object(body)
    }

    /// Anexos antes do texto: imagem → `input_image` (data URL), PDF → `input_file` (`file_data` data URL),
    /// arquivo de texto → `input_text`.
    static func inputContent(_ message: LLMMessage) -> [JSONValue] {
        var content: [JSONValue] = message.parts.map { part in
            switch part {
            case let .text(text):
                .object(["type": .string("input_text"), "text": .string(text)])
            case .image:
                .object(["type": .string("input_image"), "image_url": .string(part.dataURL ?? "")])
            case let .pdf(filename, _):
                .object(["type": .string("input_file"), "filename": .string(filename),
                         "file_data": .string(part.dataURL ?? "")])
            case let .fileText(filename, text):
                .object(["type": .string("input_text"),
                         "text": .string(LLMContentPart.fileTextBody(filename: filename, text: text))])
            }
        }
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(.object(["type": .string("input_text"), "text": .string(message.content)]))
        }
        return content
    }

    private static func messageItem(role: String, type: String, text: String) -> JSONValue {
        .object([
            "type": .string("message"), "role": .string(role),
            "content": .array([.object(["type": .string(type), "text": .string(text)])]),
        ])
    }

    private static func toolChoice(_ choice: ToolChoice) -> JSONValue {
        switch choice {
        case .auto: .string("auto")
        case .none: .string("none")
        case .required: .string("required")
        case let .tool(name): .object(["type": .string("function"), "name": .string(name)])
        }
    }
}

/// Converte eventos SSE da Responses API em `ChatEvent`. Tipos desconhecidos (e `ping`) são ignorados.
///
/// Chamadas de ferramenta: `response.output_item.added` abre o item (`id`, `call_id`, `name`), os
/// `response.function_call_arguments.delta` acumulam por `item_id`, e `…arguments.done` /
/// `response.output_item.done` trazem o texto final (autoritativo). As chamadas saem em ordem de
/// `output_index`, antes de `.finished(.toolCalls)`.
struct ResponsesStreamDecoder: Sendable {
    private struct PartialCall: Sendable {
        var order: Int
        var callID: String
        var name: String
        var arguments: String
    }

    private let requestedModel: String
    private var announced = false
    private var calls: [String: PartialCall] = [:]
    private var nextOrder = 0
    private var sawRefusal = false
    private var sawText = false
    private(set) var isFinished = false

    init(requestedModel: String) {
        self.requestedModel = requestedModel
    }

    mutating func consume(_ payload: String) throws -> [ChatEvent] {
        guard !isFinished, let event = try? JSONValue.parse(payload), let type = event["type"]?.stringValue else {
            return []
        }
        var out: [ChatEvent] = []
        switch type {
        case "response.created", "response.in_progress":
            announce(event["response"], into: &out)
        case "response.output_text.delta":
            if let delta = event["delta"]?.stringValue, !delta.isEmpty {
                announce(nil, into: &out)
                sawText = true
                out.append(.delta(delta))
            }
        case "response.refusal.delta", "response.refusal.done":
            sawRefusal = true
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = event["delta"]?.stringValue, !delta.isEmpty {
                announce(nil, into: &out)
                out.append(.reasoningDelta(delta))
            }
        case "response.reasoning_summary_part.added":
            if let index = event["summary_index"]?.intValue, index > 0 { out.append(.reasoningDelta("\n\n")) }
        case "response.output_item.added", "response.output_item.done":
            if let item = event["item"], item["type"]?.stringValue == "function_call" {
                upsertCall(item, outputIndex: event["output_index"]?.intValue, final: type == "response.output_item.done")
            }
        case "response.function_call_arguments.delta":
            if let itemID = event["item_id"]?.stringValue, let delta = event["delta"]?.stringValue {
                let key = callKey(for: itemID)
                var call = calls[key] ?? newCall(order: event["output_index"]?.intValue)
                call.arguments += delta
                calls[key] = call
            }
        case "response.function_call_arguments.done":
            if let itemID = event["item_id"]?.stringValue, let arguments = event["arguments"]?.stringValue {
                let key = callKey(for: itemID)
                var call = calls[key] ?? newCall(order: event["output_index"]?.intValue)
                call.arguments = arguments
                calls[key] = call
            }
        case "response.completed":
            announce(event["response"], into: &out)
            appendUsage(event["response"], into: &out)
            let ready = drainCalls()
            out += ready.map { .toolCall(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON) }
            let reason: FinishReason = !ready.isEmpty ? .toolCalls : (sawRefusal && !sawText ? .refusal : .stop)
            out.append(.finished(reason: reason))
            isFinished = true
        case "response.incomplete":
            announce(event["response"], into: &out)
            appendUsage(event["response"], into: &out)
            calls = [:] // argumentos possivelmente cortados: nunca executar
            let reason = event["response"]?["incomplete_details"]?["reason"]?.stringValue
            out.append(.finished(reason: reason == "content_filter" ? .contentFilter : .length))
            isFinished = true
        case "response.failed", "error":
            isFinished = true
            let error = event["response"]?["error"] ?? event["error"] ?? event
            throw Self.failure(code: error["code"]?.stringValue, message: error["message"]?.stringValue)
        default:
            break
        }
        return out
    }

    static func failure(code: String?, message: String?) -> AIError {
        let detail = Redactor.redact(String((message ?? "O backend do ChatGPT informou um erro.").prefix(300)))
        switch code {
        case "rate_limit_exceeded", "usage_limit_reached", "insufficient_quota": return .rateLimited(retryAfter: nil)
        case "context_length_exceeded", "invalid_prompt", "invalid_request_error": return .badRequest(status: 400, message: detail)
        default: return .server(status: 502, message: detail)
        }
    }

    private mutating func announce(_ response: JSONValue?, into out: inout [ChatEvent]) {
        guard !announced else { return }
        announced = true
        let model = response?["model"]?.stringValue ?? ""
        out.append(.started(id: response?["id"]?.stringValue ?? "", model: model.isEmpty ? requestedModel : model))
    }

    private func appendUsage(_ response: JSONValue?, into out: inout [ChatEvent]) {
        guard let usage = response?["usage"], usage.objectValue != nil else { return }
        out.append(.usage(TokenUsage(promptTokens: usage["input_tokens"]?.intValue ?? 0,
                                     completionTokens: usage["output_tokens"]?.intValue ?? 0)))
    }

    /// `item_id` costuma ser o `id` (fc_…) do item; alguns servidores mandam o `call_id` — aceita os dois.
    private func callKey(for itemID: String) -> String {
        if calls[itemID] != nil { return itemID }
        return calls.first { $0.value.callID == itemID }?.key ?? itemID
    }

    private mutating func newCall(order: Int?) -> PartialCall {
        defer { nextOrder += 1 }
        return PartialCall(order: order ?? (1_000_000 + nextOrder), callID: "", name: "", arguments: "")
    }

    private mutating func upsertCall(_ item: JSONValue, outputIndex: Int?, final: Bool) {
        let callID = item["call_id"]?.stringValue ?? ""
        guard let key = item["id"]?.stringValue ?? (callID.isEmpty ? nil : callID) else { return }
        var call = calls[key] ?? newCall(order: outputIndex)
        if let outputIndex { call.order = outputIndex }
        if !callID.isEmpty { call.callID = callID }
        if let name = item["name"]?.stringValue, !name.isEmpty { call.name = name }
        if let arguments = item["arguments"]?.stringValue, final || call.arguments.isEmpty {
            if final || !arguments.isEmpty { call.arguments = arguments }
        }
        calls[key] = call
    }

    private mutating func drainCalls() -> [ToolCall] {
        defer { calls = [:] }
        return calls.sorted { $0.value.order < $1.value.order }.compactMap { key, call in
            guard !call.name.isEmpty else { return nil }
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolCall(id: call.callID.isEmpty ? key : call.callID, name: call.name,
                            argumentsJSON: arguments.isEmpty ? "{}" : arguments)
        }
    }
}

private extension JSONValue {
    var intValue: Int? {
        if case let .number(value) = self, value.isFinite { Int(value) } else { nil }
    }
}
