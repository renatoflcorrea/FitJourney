import Foundation
import SwiftUI

// Lógica de apresentação do Coach, sem SwiftUI: testável e sem rede.

/// O que a UI mostra para um `AIError`: texto e ação oferecida.
struct CoachErrorPresentation: Equatable {
    enum Action: Equatable { case configureKey, retry, none }

    var title: String
    var message: String
    var action: Action

    init(_ error: AIError) {
        message = error.errorDescription ?? ""
        switch error {
        case .unauthorized:
            title = String(localized: "Chave recusada")
            action = .configureKey
        case .notConfigured:
            title = String(localized: "Coach não configurado")
            action = .configureKey
        case .rateLimited:
            title = String(localized: "Limite de uso atingido")
            action = .retry
        case .network:
            title = String(localized: "Sem conexão")
            action = .retry
        case .server:
            title = String(localized: "Provedor indisponível")
            action = .retry
        case .incomplete(.toolRoundLimit), .incomplete(.length):
            title = String(localized: "Resposta incompleta")
            action = .retry
        case .incomplete:
            title = String(localized: "Resposta não entregue")
            action = .none
        case .badRequest, .decoding, .cancelled:
            title = String(localized: "Não foi possível responder")
            action = .retry
        }
    }
}

/// Como uma mensagem aparece no chat.
enum CoachMessageDisplay: Equatable {
    case user
    /// Resposta começou, ainda sem texto.
    case thinking
    case streaming
    case complete
    case stopped
    case failed(reason: String)
    case proposal

    /// - Parameter isActive: há uma resposta em andamento nesta conversa. Uma mensagem `.streaming` sem tarefa
    ///   ativa (app morto no meio e reparo do launch não rodou) é tratada como parada.
    static func resolve(role: LLMRole, state: ChatMessageState, content: String, failureReason: String?,
                        hasProposal: Bool, isActive: Bool = true) -> CoachMessageDisplay {
        if hasProposal { return .proposal }
        if role == .user { return .user }
        switch state {
        case .streaming:
            if !isActive { return .stopped }
            return content.isEmpty ? .thinking : .streaming
        case .complete: return .complete
        case .stopped: return .stopped
        case .failed:
            let reason = failureReason ?? ""
            return .failed(reason: reason.isEmpty ? String(localized: "A resposta falhou.") : reason)
        }
    }

    var canRetry: Bool {
        switch self {
        case .stopped, .failed: true
        default: false
        }
    }
}

/// Primeira abertura: consentimento e provedor prontos?
enum CoachGate: Equatable {
    case needsConsent
    case needsProvider
    case ready

    static func evaluate(hasConsented: Bool, readiness: ProviderReadiness) -> CoachGate {
        if !hasConsented { return .needsConsent }
        return readiness.isReady ? .ready : .needsProvider
    }
}

enum CoachSuggestions {
    static var prompts: [String] {
        [
            String(localized: "Monte um ABC de hipertrofia, 4x/semana, 60 min"),
            String(localized: "Ajuste minha dieta para 2.200 kcal"),
            String(localized: "Como foi minha evolução no supino?"),
        ]
    }
}

enum ConversationPreview {
    /// Título da lista: o da conversa ou "Nova conversa".
    static func title(_ conversation: ChatConversation) -> String {
        conversation.title.isEmpty ? String(localized: "Nova conversa") : conversation.title
    }

    /// Prévia: última mensagem de usuário/assistente com texto, numa linha.
    static func preview(_ conversation: ChatConversation) -> String {
        let last = conversation.visibleMessages.last { !$0.content.isEmpty && $0.role != .tool }
        let plain = String(CoachMarkdown.attributed(last?.content ?? "").characters)
        let flat = plain.split(whereSeparator: \.isNewline).joined(separator: " ")
        if flat.isEmpty {
            return conversation.visibleMessages.contains { $0.proposal != nil }
                ? String(localized: "Proposta do Coach") : String(localized: "Sem mensagens")
        }
        return String(flat.prefix(140))
    }
}

/// Texto da resposta com Markdown básico. **Links são removidos** (texto do modelo não deve abrir URLs);
/// cai para texto puro se o parcial do streaming não fechar.
enum CoachMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in result.runs where run.link != nil {
            result[run.range].link = nil
        }
        return result
    }

    /// Escapa sintaxe Markdown para exibir texto externo (erros do provedor) literalmente num `LocalizedStringKey`.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_{}[]()<>#+-!|~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Chave de texto que não interpreta Markdown nem links.
    static func literal(_ text: String) -> LocalizedStringKey { LocalizedStringKey(escape(text)) }
}

/// Linha do cartão de proposta (ficha ou dia).
struct ProposalRow: Equatable, Identifiable {
    var id: Int
    var title: String
    var detail: String
    var items: [Item]

    struct Item: Equatable {
        var name: String
        var detail: String
        /// Exercício que será criado (sem correspondência no catálogo).
        var isNew: Bool
    }
}

/// Resumo do cartão "Revisar e salvar", montado do rascunho e do casamento com o catálogo.
struct ProposalCardModel: Equatable {
    enum Kind { case program, nutritionPlan }

    var kind: Kind
    var title: String
    var subtitle: String
    var rows: [ProposalRow]
    var newExerciseCount: Int
    /// Metas do plano (kcal, macros); vazio para programa.
    var targets: [String]

    /// - Parameter matches: por ficha, por exercício, `true` = existe no catálogo. `nil` = ainda não calculado
    ///   (nada é marcado como novo).
    init(_ proposal: CoachProposal, matches: [[Bool]]? = nil) {
        switch proposal.content {
        case let .program(draft):
            kind = .program
            title = draft.name
            let sets = draft.routines.reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } }
            let exercises = draft.routines.reduce(0) { $0 + $1.exercises.count }
            subtitle = String(localized: "\(draft.routines.count) fichas · \(exercises) exercícios · \(sets) séries")
            var newCount = 0
            rows = draft.routines.enumerated().map { r, routine in
                let items = routine.exercises.enumerated().map { e, exercise in
                    var found = true
                    if let matches, matches.indices.contains(r), matches[r].indices.contains(e) { found = matches[r][e] }
                    if !found { newCount += 1 }
                    return ProposalRow.Item(name: exercise.name, detail: Self.setsText(exercise.sets), isNew: !found)
                }
                let setCount = routine.exercises.reduce(0) { $0 + $1.sets.count }
                return ProposalRow(id: r, title: routine.name,
                                   detail: String(localized: "\(routine.exercises.count) exercícios · \(setCount) séries"),
                                   items: items)
            }
            newExerciseCount = newCount
            targets = []
        case let .nutritionPlan(draft):
            kind = .nutritionPlan
            title = draft.name
            let meals = draft.days.reduce(0) { $0 + $1.meals.count }
            subtitle = String(localized: "\(draft.days.count) dia(s) · \(meals) refeições")
            rows = draft.days.enumerated().map { d, day in
                ProposalRow(id: d, title: day.name,
                            detail: String(localized: "\(day.meals.count) refeições"),
                            items: day.meals.map {
                                ProposalRow.Item(name: $0.name, detail: "\($0.time) · \($0.items.count) itens", isNew: false)
                            })
            }
            newExerciseCount = 0
            let t = draft.targets
            targets = [
                t.kcal.map { "\(Int($0)) kcal" },
                t.protein.map { String(localized: "P \(Int($0)) g") },
                t.carbs.map { String(localized: "C \(Int($0)) g") },
                t.fat.map { String(localized: "G \(Int($0)) g") },
            ].compactMap { $0 }
        }
    }

    /// "4 × 8–12" a partir das séries; "N séries" se não houver alvo de repetições.
    static func setsText(_ sets: [ProgramDraft.SetDraft]) -> String {
        guard let first = sets.first else { return "" }
        let reps: String
        switch first.repTarget?.repTarget {
        case let .fixed(reps: n)?: reps = "\(n)"
        case let .range(min: a, max: b)?: reps = "\(a)–\(b)"
        case .amrap?: reps = "AMRAP"
        default: reps = ""
        }
        return reps.isEmpty ? String(localized: "\(sets.count) séries") : "\(sets.count) × \(reps)"
    }
}

/// Lembra, por proposta, o que o usuário fez (descartou ou salvou), já que `ChatMessage` não tem campo para isso.
/// A chave combina o id da mensagem com o id da chamada de ferramenta: `call.id` sozinho pode repetir entre
/// conversas ou provedores.
struct ProposalStateStore {
    enum State: Equatable {
        case pending
        case discarded
        case saved(UUID)
    }

    static let key = "coach.proposalStates.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(messageID: UUID, proposalID: String) -> String { "\(messageID.uuidString)|\(proposalID)" }

    func state(for key: String) -> State {
        guard let value = all()[key] else { return .pending }
        if value == "discarded" { return .discarded }
        if value.hasPrefix("saved:"), let id = UUID(uuidString: String(value.dropFirst(6))) { return .saved(id) }
        return .pending
    }

    func markDiscarded(_ key: String) { set(key, "discarded") }
    func markSaved(_ key: String, id: UUID) { set(key, "saved:\(id.uuidString)") }

    /// Esquece uma proposta (item salvo que foi apagado).
    func clear(_ key: String) {
        var current = all()
        current[key] = nil
        defaults.set(current, forKey: Self.key)
    }

    /// Esquece tudo que pertence às mensagens dadas (conversa apagada).
    func clear(messageIDs: [UUID]) {
        let prefixes = messageIDs.map { $0.uuidString + "|" }
        let current = all().filter { entry in !prefixes.contains { entry.key.hasPrefix($0) } }
        defaults.set(current, forKey: Self.key)
    }

    private func all() -> [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    private func set(_ key: String, _ value: String) {
        var current = all()
        current[key] = value
        defaults.set(current, forKey: Self.key)
    }
}

extension Notification.Name {
    /// Consentimento concedido ou revogado (Ajustes de IA ↔ aba Coach): a aba revalida o gate e para respostas.
    static let coachConsentChanged = Notification.Name("coach.consentChanged")
}
