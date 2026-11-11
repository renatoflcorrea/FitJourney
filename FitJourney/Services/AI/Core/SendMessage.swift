import Foundation
import Observation
import SwiftData

/// Laço do Coach (porta de `FireplaceCore/UseCases/SendMessage.swift` + function calling).
///
/// 1. Persiste a mensagem do usuário.
/// 2. Cria a resposta do assistente em `.streaming` e grava o parcial a cada ~100 ms — matar o app
///    no meio deixa uma linha `.streaming` que `repairInterruptedMessages` troca por `.stopped`.
/// 3. Se o modelo pedir ferramentas, executa localmente (`FitnessToolbox`), grava os resultados
///    (papel `tool`, com a proposta quando houver) e continua — no máximo `maxToolRounds` voltas;
///    a última volta vai com `toolChoice = .none` para forçar uma resposta em texto.
/// 4. `stop()` cancela: o parcial fica, estado `.stopped`. Erro: estado `.failed` com motivo sem segredos.
@MainActor
@Observable
final class CoachConversationService {
    static let maxToolRounds = 6
    static let persistInterval: Duration = .milliseconds(100)

    /// Conversa com resposta em andamento (`nil` = ocioso).
    private(set) var runningConversationID: UUID?
    /// Último erro de envio (não inclui cancelamento). A UI mostra e limpa.
    var lastError: AIError?

    var isRunning: Bool { runningConversationID != nil }

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let toolbox: FitnessToolbox
    @ObservationIgnored private let resolveChat: @MainActor () throws -> ResolvedChat
    @ObservationIgnored private let systemPrompt: String
    @ObservationIgnored private let characterBudget: Int
    @ObservationIgnored private var currentTask: Task<Bool, Never>?

    /// - Parameter resolveChat: monta o gateway a cada envio (pega mudanças de provedor/chave);
    ///   em produção, `{ try ProviderFactory.makeChat(secrets: KeychainSecretStore()) }`.
    init(context: ModelContext, toolbox: FitnessToolbox,
         resolveChat: @escaping @MainActor () throws -> ResolvedChat,
         systemPrompt: String = CoachPrompt.system, characterBudget: Int = ContextWindow.characterBudget) {
        self.context = context
        self.toolbox = toolbox
        self.resolveChat = resolveChat
        self.systemPrompt = systemPrompt
        self.characterBudget = characterBudget
    }

    // MARK: - API pública

    @discardableResult
    func createConversation(title: String = "") throws -> ChatConversation {
        let conversation = ChatConversation(title: title)
        context.insert(conversation)
        try context.save()
        return conversation
    }

    func delete(_ conversation: ChatConversation) throws {
        if runningConversationID == conversation.id { stop() }
        context.delete(conversation)
        try context.save()
    }

    /// Envia e aguarda o fim da resposta (incluindo as voltas de ferramenta).
    /// Devolve `false` se já havia uma resposta em andamento, se o texto era vazio ou se falhou.
    @discardableResult
    func send(_ text: String, in conversation: ChatConversation) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, currentTask == nil else { return false }
        lastError = nil
        runningConversationID = conversation.id
        let task = Task { @MainActor () -> Bool in
            do {
                try await self.run(trimmed, in: conversation)
                return true
            } catch {
                if !Self.isCancellation(error) {
                    self.lastError = (error as? AIError) ?? .decoding(context: "coach", message: Redactor.redact("\(error)"))
                }
                return false
            }
        }
        currentTask = task
        let succeeded = await task.value
        currentTask = nil
        runningConversationID = nil
        return succeeded
    }

    /// Interrompe a resposta em andamento; o texto parcial fica salvo como `.stopped`.
    func stop() {
        currentTask?.cancel()
    }

    /// Chamar no launch: respostas que ficaram `.streaming` (app morto no meio) viram `.stopped`.
    @discardableResult
    static func repairInterruptedMessages(in context: ModelContext) throws -> Int {
        let streaming = ChatMessageState.streaming.rawValue
        let stuck = try context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.stateRaw == streaming }))
        for message in stuck {
            message.state = .stopped
            message.updatedAt = .now
        }
        if !stuck.isEmpty { try context.save() }
        return stuck.count
    }

    // MARK: - Laço

    private func run(_ text: String, in conversation: ChatConversation) async throws {
        let chat = try resolveChat()

        let user = ChatMessage(role: .user, content: text, sortIndex: conversation.nextSortIndex)
        context.insert(user)
        user.conversation = conversation
        if conversation.title.isEmpty, !conversation.titleIsUserEdited {
            conversation.title = String(text.prefix(60))
        }
        conversation.updatedAt = .now
        try context.save()

        for round in 0 ..< Self.maxToolRounds {
            try Task.checkCancellation()
            let finalRound = round == Self.maxToolRounds - 1
            let tools = toolbox.specs
            let request = makeRequest(conversation: conversation, model: chat.model, tools: tools,
                                      toolChoice: tools.isEmpty ? nil : (finalRound ? ToolChoice.none : .auto))

            let assistant = ChatMessage(role: .assistant, content: "", state: .streaming, sortIndex: conversation.nextSortIndex)
            assistant.modelID = chat.model
            context.insert(assistant)
            assistant.conversation = conversation
            conversation.providerRaw = chat.gateway.provider.rawValue
            conversation.modelID = chat.model
            try context.save()

            let calls = try await consume(chat.gateway.stream(request), into: assistant)
            guard !calls.isEmpty, !finalRound else { break }

            for call in calls {
                try Task.checkCancellation()
                let outcome = toolbox.execute(call)
                let result = ChatMessage(role: .tool, content: outcome.content, sortIndex: conversation.nextSortIndex)
                result.toolCallID = call.id
                result.toolName = call.name
                result.toolResultIsError = outcome.isError
                result.proposal = outcome.proposal
                context.insert(result)
                result.conversation = conversation
            }
            conversation.updatedAt = .now
            try context.save()
        }
        conversation.updatedAt = .now
        try context.save()
    }

    /// Drena o stream gravando o parcial; devolve as chamadas de ferramenta do turno.
    private func consume(_ stream: AsyncThrowingStream<ChatEvent, any Error>,
                         into message: ChatMessage) async throws -> [ToolCall] {
        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var blocks: [ReasoningBlock] = []
        var usage: TokenUsage?
        let clock = ContinuousClock()
        var lastWrite = clock.now

        func write(_ state: ChatMessageState) {
            message.content = content
            message.reasoning = reasoning.isEmpty ? nil : reasoning
            message.state = state
            message.updatedAt = .now
        }

        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .started(_, model):
                    if !model.isEmpty { message.modelID = model }
                case let .delta(chunk):
                    content += chunk
                    if clock.now - lastWrite >= Self.persistInterval {
                        lastWrite = clock.now
                        write(.streaming)
                        try context.save()
                    }
                case let .reasoningDelta(chunk):
                    reasoning += chunk
                case let .reasoningBlock(block):
                    blocks.append(block)
                case let .toolCall(id, name, arguments):
                    calls.append(ToolCall(id: id, name: name, argumentsJSON: arguments))
                case let .usage(value):
                    usage = value
                case .finished:
                    break
                }
            }
            // Um stream cancelado termina sem erro: confira antes de marcar como completo.
            try Task.checkCancellation()
            write(.complete)
            message.toolCalls = calls
            message.reasoningBlocks = blocks
            message.promptTokens = usage?.promptTokens
            message.completionTokens = usage?.completionTokens
            try context.save()
            return calls
        } catch {
            if Self.isCancellation(error) {
                write(.stopped)
                try? context.save()
                throw CancellationError()
            }
            write(.failed)
            message.failureReason = Redactor.redact((error as? LocalizedError)?.errorDescription ?? "\(error)")
            try? context.save()
            throw error
        }
    }

    private func makeRequest(conversation: ChatConversation, model: String, tools: [ToolSpec],
                             toolChoice: ToolChoice?) -> ChatRequest {
        let history = conversation.sortedMessages
            .filter { !($0.role == .assistant && $0.state == .streaming) }
            .filter { !($0.state == .failed && $0.content.isEmpty) }
            .map(\.llmMessage)
        let window = ContextWindow.fit(history, limit: characterBudget)
        var system = systemPrompt
        if window.droppedCount > 0 {
            system += "\n\n(\(window.droppedCount) mensagens anteriores desta conversa não foram incluídas.)"
        }
        return ChatRequest(model: model, messages: [.system(system)] + window.messages, tools: tools,
                           toolChoice: toolChoice, metadata: ["module": "coach"])
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AIError) == .cancelled || (error as? URLError)?.code == .cancelled
    }
}

/// Encaixa o histórico no orçamento de caracteres, do mais novo para o mais antigo, e diz quanto
/// cortou em vez de truncar em silêncio. Mantém pares chamada/resultado de ferramenta coerentes.
enum ContextWindow {
    static let characterBudget = 48_000

    struct Result: Sendable {
        var messages: [LLMMessage]
        var droppedCount: Int
    }

    static func cost(_ message: LLMMessage) -> Int {
        message.content.count + message.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count + $1.name.count }
            + message.reasoningBlocks.reduce(0) { $0 + $1.text.count }
    }

    static func fit(_ history: [LLMMessage], limit: Int = characterBudget) -> Result {
        var kept: [LLMMessage] = []
        var used = 0
        for message in history.reversed() {
            let c = cost(message)
            if used + c > limit, !kept.isEmpty { break }
            used += c
            kept.insert(message, at: 0)
        }
        // Começa sempre numa mensagem do usuário (nunca num resultado de ferramenta solto).
        if let firstUser = kept.firstIndex(where: { $0.role == .user }) {
            kept.removeFirst(firstUser)
        }
        let sanitized = sanitize(kept)
        return Result(messages: sanitized, droppedCount: history.count - sanitized.count)
    }

    /// Remove chamadas sem resultado (ex.: cancelado no meio das ferramentas) e resultados sem chamada,
    /// que os provedores recusam.
    static func sanitize(_ messages: [LLMMessage]) -> [LLMMessage] {
        let answered = Set(messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        var issued: Set<String> = []
        var result: [LLMMessage] = []
        for var message in messages {
            switch message.role {
            case .assistant:
                message.toolCalls = message.toolCalls.filter { answered.contains($0.id) }
                issued.formUnion(message.toolCalls.map(\.id))
                if message.content.isEmpty, message.toolCalls.isEmpty { continue }
            case .tool:
                guard let id = message.toolCallID, issued.contains(id) else { continue }
            case .user, .system:
                break
            }
            result.append(message)
        }
        return result
    }
}
