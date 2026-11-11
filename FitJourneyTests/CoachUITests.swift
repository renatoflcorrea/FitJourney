import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct CoachUITests {
    private static var containers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(inMemory: true)
        Self.containers.append(container)
        return container.mainContext
    }

    // MARK: Erros

    @Test func errorMapping() {
        #expect(CoachErrorPresentation(.unauthorized(message: "x")).action == .configureKey)
        #expect(CoachErrorPresentation(.notConfigured(reason: "chave")).action == .configureKey)
        #expect(CoachErrorPresentation(.rateLimited(retryAfter: 3)).action == .retry)
        #expect(CoachErrorPresentation(.network(code: -1009, retryable: true)).action == .retry)
        #expect(CoachErrorPresentation(.incomplete(.refusal)).action == .none)
        #expect(CoachErrorPresentation(.incomplete(.toolRoundLimit)).action == .retry)
        #expect(!CoachErrorPresentation(.server(status: 500, message: "boom")).message.isEmpty)
    }

    // MARK: Estado da mensagem

    @Test func messageDisplayStates() {
        func resolve(_ role: LLMRole, _ state: ChatMessageState, _ content: String = "oi", reason: String? = nil,
                     proposal: Bool = false) -> CoachMessageDisplay {
            .resolve(role: role, state: state, content: content, failureReason: reason, hasProposal: proposal)
        }
        #expect(resolve(.user, .complete) == .user)
        #expect(resolve(.assistant, .streaming, "") == .thinking)
        #expect(resolve(.assistant, .streaming) == .streaming)
        #expect(resolve(.assistant, .complete) == .complete)
        #expect(resolve(.assistant, .stopped).canRetry)
        #expect(resolve(.assistant, .failed, reason: "Sem rede") == .failed(reason: "Sem rede"))
        #expect(resolve(.assistant, .failed, reason: nil).canRetry)
        #expect(!resolve(.assistant, .complete).canRetry)
        #expect(resolve(.tool, .complete, "{}", proposal: true) == .proposal)
    }

    // MARK: Primeira abertura

    @Test func gate() {
        #expect(CoachGate.evaluate(hasConsented: false, readiness: .ready) == .needsConsent)
        #expect(CoachGate.evaluate(hasConsented: true, readiness: .missingAPIKey(.openAI)) == .needsProvider)
        #expect(CoachGate.evaluate(hasConsented: true, readiness: .ready) == .ready)
    }

    // MARK: Cartão de proposta

    @Test func programCardMarksNewExercises() throws {
        let context = try makeContext()
        let proposal = CoachPreviewData.programProposal()
        guard case let .program(draft) = proposal.content else { Issue.record("esperava programa"); return }
        let matches = try DraftApplier(context: context).exerciseMatches(for: draft).map { $0.map { $0 != nil } }
        let model = ProposalCardModel(proposal, matches: matches)
        #expect(model.kind == .program)
        #expect(model.rows.count == 2)
        #expect(model.rows[0].items.count == 2)
        // O exercício inventado não existe no catálogo; "Supino reto" e "Remada curvada" costumam existir.
        let inventedIsNew = model.rows[0].items[1].isNew
        #expect(inventedIsNew)
        #expect(model.newExerciseCount >= 1)
        #expect(model.rows[0].items[0].detail == "4 × 8–12")
        #expect(model.subtitle.contains("2"))
    }

    @Test func cardWithoutMatchesMarksNothing() {
        let model = ProposalCardModel(CoachPreviewData.programProposal())
        #expect(model.newExerciseCount == 0)
    }

    @Test func planCardShowsTargets() {
        let model = ProposalCardModel(CoachPreviewData.planProposal())
        #expect(model.kind == .nutritionPlan)
        #expect(model.targets.first == "2200 kcal")
        #expect(model.rows[0].items.count == 2)
    }

    @Test func proposalStateIsRemembered() {
        let defaults = UserDefaults(suiteName: "coach.test.\(UUID().uuidString)")!
        let store = ProposalStateStore(defaults: defaults)
        #expect(store.state(for: "a") == .pending)
        store.markDiscarded("a")
        #expect(store.state(for: "a") == .discarded)
        let id = UUID()
        store.markSaved("b", id: id)
        #expect(store.state(for: "b") == .saved(id))
        #expect(store.state(for: "c") == .pending)
    }

    // MARK: Salvar cria inativo

    @Test func applyingProgramCreatesInactiveAIProgram() throws {
        let context = try makeContext()
        guard case let .program(draft) = CoachPreviewData.programProposal().content else { Issue.record("programa"); return }
        let program = try DraftApplier(context: context).makeProgram(from: draft)
        #expect(!program.isActive)
        #expect(program.sortedRoutines.count == 2)
    }

    // MARK: Lista e Markdown

    @Test func conversationPreviewAndTitle() throws {
        let context = try makeContext()
        CoachPreviewData.insertConversations(into: context)
        let conversations = try context.fetch(FetchDescriptor<ChatConversation>())
        let withProposal = try #require(conversations.first { $0.title.hasPrefix("ABC") })
        #expect(ConversationPreview.preview(withProposal).hasPrefix("Montei um"))
        let empty = ChatConversation()
        #expect(ConversationPreview.title(empty) == "Nova conversa")
        #expect(ConversationPreview.preview(empty) == "Sem mensagens")
        // Resultados de ferramenta sem proposta não aparecem; com proposta, sim.
        #expect(withProposal.visibleMessages.contains { $0.proposal != nil })
    }

    @Test func markdownFallsBackToPlainText() {
        let bold = CoachMarkdown.attributed("isto é **forte**")
        #expect(String(bold.characters) == "isto é forte")
        #expect(String(CoachMarkdown.attributed("meio **aberto").characters).contains("meio"))
    }

    // MARK: Ajustes

    @Test func urlValidation() {
        #expect(AISettingsText.urlProblem("") == nil)
        #expect(AISettingsText.urlProblem("http://192.168.0.10:11434/v1") == nil)
        #expect(AISettingsText.urlProblem("http://localhost:11434/v1") == nil)
        #expect(AISettingsText.urlProblem("https://meu.servidor.com/v1") == nil)
        #expect(AISettingsText.urlProblem("http://example.com/v1") != nil)
        #expect(AISettingsText.urlProblem("ftp://x") != nil)
        #expect(AISettingsText.urlProblem("não é url") != nil)
    }

    @Test func readinessText() {
        #expect(AISettingsText.readiness(.ready).tone == .success)
        #expect(AISettingsText.readiness(.missingAPIKey(.openAI)).tone == .attention)
        #expect(AISettingsText.readiness(.invalidEndpoint).tone == .attention)
    }

    @Test func suggestionsCoverSpecPrompts() {
        #expect(CoachSuggestions.prompts.count == 3)
        #expect(CoachSuggestions.prompts[0].contains("ABC"))
    }

    // MARK: Revisão

    @Test func streamingWithoutActiveTaskIsStopped() {
        let display = CoachMessageDisplay.resolve(role: .assistant, state: .streaming, content: "parcial",
                                                  failureReason: nil, hasProposal: false, isActive: false)
        #expect(display == .stopped)
        #expect(display.canRetry)
    }

    @Test func markdownDropsLinks() {
        let result = CoachMarkdown.attributed("veja [aqui](https://evil.example) e https://x.example **ok**")
        #expect(result.runs.allSatisfy { $0.link == nil })
        #expect(String(result.characters).contains("aqui"))
    }

    @Test func escapeKeepsProviderErrorsLiteral() {
        let escaped = CoachMarkdown.escape("erro [clique](https://x) *forte*")
        #expect(escaped == #"erro \[clique\]\(https://x\) \*forte\*"#)
    }

    @Test func proposalStateKeyDoesNotCollideAcrossMessages() {
        let defaults = UserDefaults(suiteName: "coach.test.\(UUID().uuidString)")!
        let store = ProposalStateStore(defaults: defaults)
        let m1 = UUID(), m2 = UUID()
        let k1 = ProposalStateStore.key(messageID: m1, proposalID: "call_1")
        let k2 = ProposalStateStore.key(messageID: m2, proposalID: "call_1")
        store.markDiscarded(k1)
        #expect(store.state(for: k1) == .discarded)
        #expect(store.state(for: k2) == .pending)
        store.markSaved(k2, id: UUID())
        store.clear(k2)
        #expect(store.state(for: k2) == .pending)
        store.clear(messageIDs: [m1])
        #expect(store.state(for: k1) == .pending)
    }
}
