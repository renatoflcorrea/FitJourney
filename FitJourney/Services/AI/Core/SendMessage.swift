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
///    a última volta vai com `toolChoice = .none` e, se mesmo assim vierem ferramentas, falha com
///    `AIError.incomplete(.toolRoundLimit)`.
/// 4. `stop()` cancela: o parcial fica, estado `.stopped`. Erro: estado `.failed` com motivo sem segredos.
///
/// **Histórico só-anexar dentro do turno** (verificação de edição de histórico dos modelos com thinking
/// vinculado à conversa): `system`, `tools` e o prefixo (histórico antes da mensagem do usuário, já
/// encaixado na janela) são fixados uma vez por envio; cada volta só acrescenta mensagens. Blocos de
/// raciocínio só são reenviados no turno em andamento — os de turnos anteriores são removidos (remoção
/// pela frente do histórico é permitida; pelo meio, não).
@MainActor
@Observable
final class CoachConversationService {
    static let maxToolRounds = 6
    static let persistInterval: Duration = .milliseconds(100)
    /// Teto do texto do usuário enviado ao provedor.
    static let maxUserTextCharacters = 8_000
    /// Teto de cada resultado de ferramenta gravado/enviado (acima disso vira `{"truncated":true,…}`).
    static let maxToolResultCharacters = 10_000
    /// Resultados de ferramenta das últimas N mensagens do usuário ficam completos; os mais antigos são
    /// compactados num marcador (o modelo chama a ferramenta de novo se precisar). Propostas ficam.
    static let toolResultRetentionTurns = 3

    /// Conversa com resposta em andamento (`nil` = ocioso).
    private(set) var runningConversationID: UUID?
    /// Último erro de envio (não inclui cancelamento). A UI mostra e limpa (`clearError()`).
    var lastError: AIError?
    /// Conversa em que `lastError` aconteceu: a UI só mostra o erro nela.
    private(set) var lastErrorConversationID: UUID?

    var isRunning: Bool { runningConversationID != nil }

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let toolbox: FitnessToolbox
    @ObservationIgnored private let resolveChat: @MainActor () throws -> ResolvedChat
    @ObservationIgnored private let systemPrompt: String
    @ObservationIgnored private var currentTask: Task<Bool, Never>?

    /// - Parameter resolveChat: monta o gateway a cada envio (pega mudanças de provedor/chave);
    ///   em produção, `{ try ProviderFactory.makeChat(secrets: KeychainSecretStore()) }`.
    init(context: ModelContext, toolbox: FitnessToolbox,
         resolveChat: @escaping @MainActor () throws -> ResolvedChat,
         systemPrompt: String = CoachPrompt.system) {
        self.context = context
        self.toolbox = toolbox
        self.resolveChat = resolveChat
        self.systemPrompt = systemPrompt
    }

    // MARK: - API pública

    @discardableResult
    func createConversation(title: String = "") throws -> ChatConversation {
        let conversation = ChatConversation(title: title)
        context.insert(conversation)
        try context.save()
        return conversation
    }

    /// Apaga a conversa. Se ela estiver respondendo, para e **espera a tarefa terminar** (que ainda grava o
    /// parcial como `.stopped`) antes de remover — nunca apaga por baixo de uma escrita em andamento.
    func delete(_ conversation: ChatConversation) async throws {
        if runningConversationID == conversation.id {
            stop()
            _ = await currentTask?.value
            // O `send` que aguarda a tarefa ainda precisa limpar o estado de execução.
            while runningConversationID == conversation.id { await Task.yield() }
        }
        if lastErrorConversationID == conversation.id { clearError() }
        context.delete(conversation)
        try context.save()
    }

    func clearError() {
        lastError = nil
        lastErrorConversationID = nil
    }

    /// Envia e aguarda o fim da resposta (incluindo as voltas de ferramenta).
    /// Devolve `false` se já havia uma resposta em andamento, se o texto era vazio ou se falhou.
    @discardableResult
    func send(_ text: String, in conversation: ChatConversation) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, currentTask == nil else { return false }
        return await execute(in: conversation) {
            try await self.run(String(trimmed.prefix(Self.maxUserTextCharacters)), in: conversation, reusing: nil)
        }
    }

    /// "Tentar de novo": apaga a resposta que parou ou falhou (e o que o turno gerou depois da mensagem do
    /// usuário) e reexecuta o turno com a **mesma** mensagem do usuário, sem inserir outra.
    /// Só vale para a última mensagem da conversa, em estado `.stopped` ou `.failed`.
    /// Devolve `false` se a mensagem não é elegível ou se já havia resposta em andamento.
    @discardableResult
    func regenerate(after failedMessage: ChatMessage, in conversation: ChatConversation) async -> Bool {
        guard currentTask == nil, failedMessage.role == .assistant,
              failedMessage.state == .stopped || failedMessage.state == .failed,
              let last = conversation.sortedMessages.last, last.id == failedMessage.id,
              let user = conversation.sortedMessages.last(where: { $0.role == .user && $0.sortIndex < failedMessage.sortIndex })
        else { return false }
        return await execute(in: conversation) {
            try await self.run(user.content, in: conversation, reusing: user)
        }
    }

    private func execute(in conversation: ChatConversation, _ body: @escaping @MainActor () async throws -> Void) async -> Bool {
        clearError()
        runningConversationID = conversation.id
        let task = Task { @MainActor () -> Bool in
            do {
                try await body()
                return true
            } catch {
                if !Self.isCancellation(error) {
                    self.lastError = (error as? AIError) ?? .decoding(context: "coach", message: Redactor.redact("\(error)"))
                    self.lastErrorConversationID = conversation.id
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

    /// **O App chama isto no launch** (`FitJourneyApp`, antes de mostrar a aba Coach): respostas que ficaram
    /// `.streaming` (app morto no meio) viram `.stopped`. A UI do Coach também trata `.streaming` sem tarefa
    /// ativa como parada, caso o reparo não tenha rodado.
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

    /// - Parameter existingUser: ao refazer um turno, a mensagem do usuário que já existe (nada é inserido);
    ///   tudo que veio depois dela é apagado, só depois de o provedor ter sido resolvido com sucesso.
    private func run(_ text: String, in conversation: ChatConversation, reusing existingUser: ChatMessage?) async throws {
        let chat = try resolveChat()

        let user: ChatMessage
        if let existingUser {
            for message in conversation.sortedMessages where message.sortIndex > existingUser.sortIndex {
                context.delete(message)
            }
            user = existingUser
        } else {
            compactOldToolResults(in: conversation)
            user = ChatMessage(role: .user, content: text, sortIndex: conversation.nextSortIndex)
            context.insert(user)
            user.conversation = conversation
            if conversation.title.isEmpty, !conversation.titleIsUserEdited {
                conversation.title = String(text.prefix(60))
            }
        }
        conversation.updatedAt = .now
        try context.save()

        // Fixos durante todo o envio: system, tools e o prefixo encaixado na janela.
        let tools = toolbox.specs
        let system = systemPrompt
        let prefix = conversation.sortedMessages.filter { $0.sortIndex < user.sortIndex }.compactMap(Self.historyMessage)
        let budget = chat.contextBudgetTokens * ContextWindow.charactersPerToken
        let overhead = system.count + ContextWindow.toolsCost(tools)
        var window = ContextWindow.fitPrefix(prefix, current: [user.llmMessage], budgetCharacters: budget - overhead)
        let note = window.droppedCount > 0
            ? "[Nota do app: \(window.droppedCount) mensagens anteriores desta conversa não foram incluídas.]\n\n" : nil
        if let note, !window.messages.isEmpty { window.messages[0].content = note + window.messages[0].content }
        let frozenPrefix = window.messages

        for round in 0 ..< Self.maxToolRounds {
            try Task.checkCancellation()
            let finalRound = round == Self.maxToolRounds - 1
            var current = conversation.sortedMessages.filter { $0.sortIndex >= user.sortIndex }.compactMap(Self.historyMessage)
            if let note, frozenPrefix.isEmpty, !current.isEmpty { current[0].content = note + current[0].content }
            let request = ChatRequest(
                model: chat.model, messages: [.system(system)] + ContextWindow.sanitize(frozenPrefix + current),
                tools: tools, toolChoice: tools.isEmpty ? nil : (finalRound ? ToolChoice.none : .auto),
                metadata: ["module": "coach"])

            let assistant = ChatMessage(role: .assistant, content: "", state: .streaming, sortIndex: conversation.nextSortIndex)
            assistant.modelID = chat.model
            context.insert(assistant)
            assistant.conversation = conversation
            conversation.providerRaw = chat.gateway.provider.rawValue
            conversation.modelID = chat.model
            try context.save()

            let calls = try await consume(chat.gateway.stream(request), into: assistant)
            guard !calls.isEmpty else { break }
            if finalRound {
                assistant.state = .failed
                assistant.failureReason = AIError.IncompleteReason.toolRoundLimit.localizedDescription
                try context.save()
                throw AIError.incomplete(.toolRoundLimit)
            }

            for call in calls {
                try Task.checkCancellation()
                let outcome = await toolbox.execute(call)
                // Parado durante a ferramenta (ex.: leitura do Saúde): nada de "cancelled" gravado.
                try Task.checkCancellation()
                let result = ChatMessage(role: .tool, content: Self.limitToolResult(outcome.content),
                                         sortIndex: conversation.nextSortIndex)
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
    /// Término por limite, recusa ou filtro não executa ferramentas e lança `AIError.incomplete`.
    private func consume(_ stream: AsyncThrowingStream<ChatEvent, any Error>,
                         into message: ChatMessage) async throws -> [ToolCall] {
        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var blocks: [ReasoningBlock] = []
        var usage: TokenUsage?
        var finish: FinishReason?
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
                case let .finished(reason):
                    finish = reason
                }
            }
            // Um stream cancelado termina sem erro: confira antes de marcar como completo.
            try Task.checkCancellation()
            message.promptTokens = usage?.promptTokens
            message.completionTokens = usage?.completionTokens

            if let incomplete = Self.incompleteReason(finish) {
                if incomplete == .refusal { content = "" } // a skill manda descartar o parcial de uma recusa
                write(incomplete == .length ? .stopped : .failed)
                message.failureReason = incomplete.localizedDescription
                try context.save()
                throw AIError.incomplete(incomplete)
            }
            write(.complete)
            message.toolCalls = calls
            message.reasoningBlocks = blocks
            try context.save()
            return calls
        } catch let error as AIError where error.isIncomplete {
            throw error
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

    private static func incompleteReason(_ finish: FinishReason?) -> AIError.IncompleteReason? {
        switch finish {
        case .length: .length
        case .refusal: .refusal
        case .contentFilter: .contentFilter
        default: nil
        }
    }

    /// Mensagem persistida → fio (sem as respostas em andamento e as falhas vazias).
    private static func historyMessage(_ message: ChatMessage) -> LLMMessage? {
        if message.role == .assistant, message.state == .streaming { return nil }
        if message.state == .failed, message.content.isEmpty { return nil }
        return message.llmMessage
    }

    /// Resultado acima do teto vira um objeto JSON válido com o começo do conteúdo.
    static func limitToolResult(_ content: String) -> String {
        guard content.count > maxToolResultCharacters else { return content }
        return JSONValue.object([
            "truncated": .bool(true),
            "originalLength": .number(Double(content.count)),
            "partial": .string(String(content.prefix(maxToolResultCharacters - 200))),
        ]).jsonString()
    }

    static let compactedToolResult = #"{"compacted":true,"note":"Resultado antigo removido; chame a ferramenta de novo se precisar."}"#

    /// Retenção (M7): resultados de ferramenta anteriores às últimas `toolResultRetentionTurns` mensagens
    /// do usuário viram um marcador. Roda antes de fixar o prefixo, então não altera o turno em andamento.
    private func compactOldToolResults(in conversation: ChatConversation) {
        let messages = conversation.sortedMessages
        let userIndices = messages.filter { $0.role == .user }.map(\.sortIndex)
        guard userIndices.count >= Self.toolResultRetentionTurns else { return }
        let cutoff = userIndices[userIndices.count - Self.toolResultRetentionTurns]
        for message in messages where message.role == .tool && message.sortIndex < cutoff
            && message.content != Self.compactedToolResult {
            message.content = Self.compactedToolResult
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AIError) == .cancelled || (error as? URLError)?.code == .cancelled
    }
}

extension AIError {
    var isIncomplete: Bool {
        if case .incomplete = self { true } else { false }
    }
}

/// Encaixa o histórico no orçamento (≈ 4 caracteres por token), do mais novo para o mais antigo, e diz
/// quanto cortou em vez de truncar em silêncio.
///
/// - O turno em andamento (última mensagem do usuário + o que veio depois) é sempre mantido.
/// - O prefixo começa sempre numa mensagem do usuário e perde os blocos de raciocínio.
/// - Pares chamada/resultado de ferramenta ficam coerentes (`sanitize`).
enum ContextWindow {
    static let charactersPerToken = 4

    struct Result: Sendable {
        var messages: [LLMMessage]
        var droppedCount: Int
    }

    static func cost(_ message: LLMMessage) -> Int {
        message.content.count + message.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count + $1.name.count }
            + message.reasoningBlocks.reduce(0) { $0 + $1.text.count }
    }

    /// Caracteres que as definições de ferramenta ocupam no pedido.
    static func toolsCost(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.parametersSchema.count }
    }

    /// Encaixa `prefix` no que sobra de `budgetCharacters` depois do turno `current` (que nunca é cortado).
    /// Devolve só o prefixo encaixado (sem raciocínio, começando no usuário, saneado).
    static func fitPrefix(_ prefix: [LLMMessage], current: [LLMMessage], budgetCharacters: Int) -> Result {
        var remaining = budgetCharacters - current.reduce(0) { $0 + cost($1) }
        var kept: [LLMMessage] = []
        for message in prefix.reversed() {
            let c = cost(message)
            if c > remaining { break }
            remaining -= c
            kept.insert(message, at: 0)
        }
        if let firstUser = kept.firstIndex(where: { $0.role == .user }) {
            kept.removeFirst(firstUser)
        } else {
            kept = []
        }
        let sanitized = sanitize(stripReasoning(kept))
        return Result(messages: sanitized, droppedCount: prefix.count - sanitized.count)
    }

    static func stripReasoning(_ messages: [LLMMessage]) -> [LLMMessage] {
        messages.map { message in
            var copy = message
            copy.reasoningBlocks = []
            return copy
        }
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
                if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.toolCalls.isEmpty {
                    continue
                }
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
