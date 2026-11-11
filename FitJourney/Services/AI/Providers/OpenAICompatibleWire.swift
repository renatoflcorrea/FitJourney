import Foundation

// Tipos de fio da superfície OpenAI-compatível (Chat Completions). Internos e separados do
// domínio, para que mudar de provedor nunca toque o Core.

struct OAIChatRequest: Encodable {
    var model: String
    var messages: [OAIMessage]
    var stream: Bool
    var streamOptions: OAIStreamOptions?
    var temperature: Double?
    var responseFormat: OAIResponseFormat?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var tools: [OAITool]?
    var toolChoice: JSONValue?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case toolChoice = "tool_choice"
    }
}

struct OAIStreamOptions: Encodable {
    var includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

struct OAIMessage: Encodable {
    var role: String
    var content: String?
    var toolCalls: [OAIToolCall]?
    var toolCallID: String?
    /// Conteúdo multimodal (`text`/`image_url`/`file`); quando presente, substitui `content` no fio.
    var contentParts: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        // Assistente só com ferramentas manda `content: null` (alguns servidores recusam a chave ausente).
        if let contentParts, !contentParts.isEmpty {
            try container.encode(contentParts, forKey: .content)
        } else if let content { try container.encode(content, forKey: .content) } else { try container.encodeNil(forKey: .content) }
        if let toolCalls, !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        if let toolCallID { try container.encode(toolCallID, forKey: .toolCallID) }
    }
}

struct OAIToolCall: Codable {
    var id: String
    var type: String = "function"
    var function: OAIFunctionCall
}

struct OAIFunctionCall: Codable {
    var name: String
    var arguments: String
}

struct OAITool: Encodable {
    var type: String = "function"
    var function: OAIFunction
}

struct OAIFunction: Encodable {
    var name: String
    var description: String
    var parameters: JSONValue
    var strict: Bool?
}

struct OAIResponseFormat: Encodable {
    var type: String
    var jsonSchema: OAIJSONSchema?
    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct OAIJSONSchema: Encodable {
    var name: String
    var strict: Bool
    var schema: JSONValue
}

// MARK: - Respostas

struct OAIToolCallDelta: Decodable {
    var index: Int?
    var id: String?
    var function: OAIFunctionDelta?
}

struct OAIFunctionDelta: Decodable {
    var name: String?
    var arguments: String?
}

struct OAIContent: Decodable {
    var content: String?
    var reasoningContent: String?
    /// OpenRouter usa `reasoning`.
    var reasoning: String?
    var toolCalls: [OAIToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content, reasoning
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }

    var reasoningText: String? { reasoningContent ?? reasoning }
}

struct OAIUsage: Decodable {
    var promptTokens: Int?
    var completionTokens: Int?
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

struct OAIChoice: Decodable {
    var index: Int?
    var message: OAIContent?
    var delta: OAIContent?
    var finishReason: String?
    enum CodingKeys: String, CodingKey {
        case index, message, delta
        case finishReason = "finish_reason"
    }
}

struct OAIChatResponse: Decodable {
    var id: String?
    var model: String?
    var choices: [OAIChoice]?
    var usage: OAIUsage?
    /// Alguns servidores (OpenRouter) mandam erro dentro de um quadro 200.
    var error: OAIStreamError?
}

struct OAIStreamError: Decodable {
    var message: String?
    var code: JSONValue?
}
