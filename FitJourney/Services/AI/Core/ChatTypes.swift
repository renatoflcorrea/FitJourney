import Foundation

// Tipos de fio neutros de provedor (porta de `FireplaceCore/Protocols/Gateways.swift`, com
// function calling). Nada aqui é SwiftData: a persistência fica em `ChatConversation`/`ChatMessage`.
//
// Nome: a mensagem de fio chama-se `LLMMessage` porque `ChatMessage` é o modelo SwiftData.

/// Provedores suportados (SPEC §7). O `rawValue` é persistido em `ProviderSettings` — não renomeie.
/// `chatGPT` = login da assinatura ChatGPT (experimental, não oficial; `Services/AI/ChatGPT/`).
enum AIProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case openAI, anthropic, openRouter, custom, chatGPT
}

/// Papel de uma mensagem no fio.
enum LLMRole: String, Codable, Sendable, Hashable {
    case system, user, assistant, tool
}

/// Pedido do modelo para executar uma ferramenta local.
struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Argumentos como JSON (objeto). Pode chegar inválido — quem executa valida.
    var argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Bloco de raciocínio opaco que alguns provedores exigem de volta sem alteração
/// (Anthropic: `thinking` com `signature`, `redacted_thinking` com `data`).
struct ReasoningBlock: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, Hashable { case thinking, redactedThinking }
    var kind: Kind
    var text: String = ""
    var signature: String?
    var data: String?
}

/// Parte de conteúdo multimodal de uma mensagem do usuário (SPEC §7A.3). **Nunca persistida**: fica fora do
/// `Codable` de `LLMMessage`, não entra em `ChatMessage.content`, log nem backup — só vive no pedido em memória.
enum LLMContentPart: Sendable, Hashable {
    case text(String)
    /// Imagem já preparada (redimensionada, sem EXIF/GPS) em base64, com o tipo MIME (`image/jpeg`, `image/png`).
    case image(mimeType: String, base64: String)
    /// PDF em base64 (só para provedores/modelos com `AttachmentCapabilities.supportsPDF`).
    case pdf(filename: String, base64: String)
    /// Arquivo de texto (.txt/.md) já decodificado.
    case fileText(filename: String, text: String)

    /// `data:` URL (OpenAI/ChatGPT) para imagem e PDF; `nil` nas partes de texto.
    var dataURL: String? {
        switch self {
        case let .image(mime, base64): "data:\(mime);base64,\(base64)"
        case let .pdf(_, base64): "data:application/pdf;base64,\(base64)"
        case .text, .fileText: nil
        }
    }

    /// Texto de um arquivo de texto com o nome à frente (todos os provedores o recebem como texto).
    static func fileTextBody(filename: String, text: String) -> String {
        "[Arquivo: \(filename)]\n\(text)"
    }
}

struct LLMMessage: Codable, Sendable, Hashable {
    var role: LLMRole
    var content: String
    /// Só em `user`: anexos multimodais (enviados antes de `content`). Fora do `Codable` de propósito.
    var parts: [LLMContentPart] = []
    /// Só em `assistant`: ferramentas pedidas neste turno.
    var toolCalls: [ToolCall]
    /// Só em `tool`: a qual `ToolCall.id` este resultado responde.
    var toolCallID: String?
    /// Só em `tool`: nome da ferramenta (alguns provedores pedem).
    var toolName: String?
    /// Só em `assistant`: blocos de raciocínio a reenviar sem alteração.
    var reasoningBlocks: [ReasoningBlock]
    /// Só em `tool`: o resultado é um erro (Anthropic `is_error`).
    var isError: Bool

    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls, toolCallID, toolName, reasoningBlocks, isError
    }

    init(role: LLMRole, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
         toolName: String? = nil, reasoningBlocks: [ReasoningBlock] = [], isError: Bool = false,
         parts: [LLMContentPart] = []) {
        self.role = role
        self.content = content
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.reasoningBlocks = reasoningBlocks
        self.isError = isError
    }

    static func system(_ text: String) -> LLMMessage { LLMMessage(role: .system, content: text) }
    static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, content: text) }
    /// Mensagem do usuário com anexos (os anexos vão antes do texto no fio).
    static func user(_ text: String, parts: [LLMContentPart]) -> LLMMessage {
        LLMMessage(role: .user, content: text, parts: parts)
    }
    static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> LLMMessage {
        LLMMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }
    static func toolResult(id: String, name: String?, content: String, isError: Bool = false) -> LLMMessage {
        LLMMessage(role: .tool, content: content, toolCallID: id, toolName: name, isError: isError)
    }
}

/// Definição de ferramenta exposta ao modelo.
struct ToolSpec: Sendable, Hashable {
    var name: String
    var description: String
    /// JSON Schema (objeto) dos argumentos.
    var parametersSchema: String
    /// Pede validação estrita ao provedor quando suportado (OpenAI `strict`).
    var strict: Bool

    init(name: String, description: String, parametersSchema: String, strict: Bool = true) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.strict = strict
    }
}

enum ToolChoice: Sendable, Hashable {
    case auto
    case none
    /// Obriga alguma ferramenta. Modelos Anthropic recentes recusam (400) — o gateway rebaixa para `auto`.
    case required
    case tool(String)
}

enum ResponseFormat: Sendable, Hashable {
    case text
    case jsonObject
    case jsonSchema(name: String, schema: String, strict: Bool)
}

struct ChatRequest: Sendable, Hashable {
    var model: String
    var messages: [LLMMessage]
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: ResponseFormat
    var tools: [ToolSpec]
    var toolChoice: ToolChoice?
    var metadata: [String: String]

    init(model: String, messages: [LLMMessage], temperature: Double? = nil, maxTokens: Int? = nil,
         responseFormat: ResponseFormat = .text, tools: [ToolSpec] = [], toolChoice: ToolChoice? = nil,
         metadata: [String: String] = [:]) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
        self.metadata = metadata
    }
}

struct TokenUsage: Codable, Sendable, Hashable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
}

enum FinishReason: String, Codable, Sendable, Hashable {
    case stop, length, toolCalls, contentFilter, refusal, cancelled, error
}

enum ChatEvent: Sendable, Hashable {
    case started(id: String, model: String)
    case delta(String)
    case reasoningDelta(String)
    /// Bloco de raciocínio completo a reenviar no próximo turno (Anthropic).
    case reasoningBlock(ReasoningBlock)
    /// Chamada de ferramenta já montada (argumentos concatenados a partir dos deltas por índice).
    case toolCall(id: String, name: String, argumentsJSON: String)
    case usage(TokenUsage)
    case finished(reason: FinishReason)
}

struct ChatCompletion: Sendable, Hashable {
    var content: String
    var reasoning: String?
    var model: String
    var usage: TokenUsage?
    var finishReason: FinishReason
    var toolCalls: [ToolCall]
    var reasoningBlocks: [ReasoningBlock]

    init(content: String, reasoning: String? = nil, model: String, usage: TokenUsage? = nil,
         finishReason: FinishReason = .stop, toolCalls: [ToolCall] = [], reasoningBlocks: [ReasoningBlock] = []) {
        self.content = content
        self.reasoning = reasoning
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.reasoningBlocks = reasoningBlocks
    }
}

protocol ChatGateway: Sendable {
    var provider: AIProviderID { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error>
    func complete(_ request: ChatRequest) async throws -> ChatCompletion
}

/// Saída estruturada: decodificação tolerante + uma tentativa de reparo.
protocol StructuredCompleting: Sendable {
    func complete<T: Decodable & Sendable>(_ request: ChatRequest, as type: T.Type) async throws -> T
}

extension StructuredCompleting where Self: ChatGateway {
    /// Implementação padrão: completa, decodifica tolerante e, se falhar, pede uma correção.
    func complete<T: Decodable & Sendable>(_ request: ChatRequest, as type: T.Type) async throws -> T {
        let completion = try await complete(request)
        do {
            return try StructuredDecoder.decode(type, from: completion.content)
        } catch {
            var repair = request
            repair.messages.append(.assistant(completion.content))
            repair.messages.append(.user(
                "That was not valid JSON for the requested schema. Return only the JSON object."))
            let second = try await complete(repair)
            return try StructuredDecoder.decode(type, from: second.content)
        }
    }
}

/// Monta chamadas de ferramenta a partir de fragmentos indexados (OpenAI `tool_calls[].index`,
/// Anthropic `content_block` index). Emite em ordem de índice.
struct ToolCallAccumulator: Sendable {
    private struct Partial: Sendable {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var partials: [Int: Partial] = [:]

    var isEmpty: Bool { partials.isEmpty }

    mutating func begin(index: Int, id: String?, name: String?) {
        var partial = partials[index] ?? Partial()
        if let id, !id.isEmpty { partial.id = id }
        if let name, !name.isEmpty, partial.name.isEmpty { partial.name = name }
        partials[index] = partial
    }

    mutating func append(index: Int, arguments: String) {
        partials[index, default: Partial()].arguments += arguments
    }

    /// Esvazia, devolvendo as chamadas montadas (argumento vazio vira `{}`; id ausente é gerado).
    mutating func drain() -> [ToolCall] {
        defer { partials = [:] }
        return partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let args = partial.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolCall(id: partial.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : partial.id,
                            name: partial.name, argumentsJSON: args.isEmpty ? "{}" : args)
        }
    }
}
