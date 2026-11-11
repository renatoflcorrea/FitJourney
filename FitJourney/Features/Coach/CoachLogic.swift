import Foundation

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

    static func resolve(role: LLMRole, state: ChatMessageState, content: String, failureReason: String?,
                        hasProposal: Bool) -> CoachMessageDisplay {
        if hasProposal { return .proposal }
        if role == .user { return .user }
        switch state {
        case .streaming: return content.isEmpty ? .thinking : .streaming
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

/// Texto da resposta com Markdown básico; cai para texto puro se o parcial do streaming não fechar.
enum CoachMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
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
struct ProposalStateStore {
    enum State: Equatable {
        case pending
        case discarded
        case saved(UUID)
    }

    static let key = "coach.proposalStates.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func state(for proposalID: String) -> State {
        guard let value = all()[proposalID] else { return .pending }
        if value == "discarded" { return .discarded }
        if value.hasPrefix("saved:"), let id = UUID(uuidString: String(value.dropFirst(6))) { return .saved(id) }
        return .pending
    }

    func markDiscarded(_ proposalID: String) { set(proposalID, "discarded") }
    func markSaved(_ proposalID: String, id: UUID) { set(proposalID, "saved:\(id.uuidString)") }

    private func all() -> [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    private func set(_ id: String, _ value: String) {
        var current = all()
        current[id] = value
        defaults.set(current, forKey: Self.key)
    }
}
