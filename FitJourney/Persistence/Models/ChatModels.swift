import Foundation
import SwiftData

// Coach de IA (SPEC §7, docs/ia.md). Mesmas regras CloudKit dos demais modelos: sem `.unique`,
// tudo com padrão ou opcional, relação opcional com inverso e deleteRule explícito.
// Tipos compostos ficam em JSON (`…Data`), com acessores tipados.

/// Estado de uma mensagem do Coach (mesmo contrato do fireplaice).
/// `streaming` é transitório: no launch, `CoachConversationService.repairInterruptedMessages`
/// troca por `stopped` mantendo o texto parcial.
enum ChatMessageState: String, Codable, Sendable, Hashable, CaseIterable {
    case streaming, complete, stopped, failed

    var isFinal: Bool { self != .streaming }
}

@Model
final class ChatConversation {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var title: String = ""
    var titleIsUserEdited: Bool = false
    /// Provedor/modelo da última resposta (informativo; a configuração atual manda).
    var providerRaw: String?
    var modelID: String?
    var isArchived: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]? = []

    init(title: String = "", createdAt: Date = .now) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var sortedMessages: [ChatMessage] { (messages ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Mensagens para a UI: usuário e assistente (resultados de ferramenta ficam escondidos,
    /// exceto os que carregam proposta — ver `ChatMessage.proposal`).
    var visibleMessages: [ChatMessage] {
        sortedMessages.filter { $0.role == .user || ($0.role == .assistant && !($0.content.isEmpty && $0.state == .complete)) || $0.proposal != nil }
    }

    var nextSortIndex: Int { ((messages ?? []).map(\.sortIndex).max() ?? -1) + 1 }
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var conversation: ChatConversation?

    var roleRaw: String = LLMRole.user.rawValue
    var content: String = ""
    /// Raciocínio visível (quando o provedor expõe).
    var reasoning: String?
    var stateRaw: String = ChatMessageState.complete.rawValue
    /// Motivo da falha (já sem segredos).
    var failureReason: String?
    var sortIndex: Int = 0
    var modelID: String?
    var promptTokens: Int?
    var completionTokens: Int?

    /// `assistant`: JSON `[ToolCall]`.
    var toolCallsData: Data?
    /// `assistant`: JSON `[ReasoningBlock]` (reenviados sem alteração ao provedor).
    var reasoningBlocksData: Data?
    /// `tool`: id da chamada respondida e nome da ferramenta.
    var toolCallID: String?
    var toolName: String?
    var toolResultIsError: Bool = false
    /// `tool`: JSON `CoachProposal` quando a ferramenta foi `propose_*` e validou.
    var proposalData: Data?

    init(role: LLMRole, content: String, state: ChatMessageState = .complete, sortIndex: Int, createdAt: Date = .now) {
        self.roleRaw = role.rawValue
        self.content = content
        self.stateRaw = state.rawValue
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var role: LLMRole {
        get { LLMRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var state: ChatMessageState {
        get { ChatMessageState(rawValue: stateRaw) ?? .complete }
        set { stateRaw = newValue.rawValue }
    }

    var toolCalls: [ToolCall] {
        get { StorageCoding.decode([ToolCall].self, from: toolCallsData) ?? [] }
        set { toolCallsData = newValue.isEmpty ? nil : StorageCoding.encode(newValue) }
    }

    var reasoningBlocks: [ReasoningBlock] {
        get { StorageCoding.decode([ReasoningBlock].self, from: reasoningBlocksData) ?? [] }
        set { reasoningBlocksData = newValue.isEmpty ? nil : StorageCoding.encode(newValue) }
    }

    /// Proposta validada (programa ou plano alimentar) para o cartão "Revisar e salvar".
    var proposal: CoachProposal? {
        get { StorageCoding.decode(CoachProposal.self, from: proposalData) }
        set { proposalData = StorageCoding.encode(newValue) }
    }

    var usage: TokenUsage? {
        guard let promptTokens, let completionTokens else { return nil }
        return TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    /// Representação de fio para reenviar ao provedor.
    var llmMessage: LLMMessage {
        LLMMessage(role: role, content: content, toolCalls: toolCalls, toolCallID: toolCallID, toolName: toolName,
                   reasoningBlocks: reasoningBlocks, isError: toolResultIsError)
    }
}
