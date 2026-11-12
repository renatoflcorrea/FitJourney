import Foundation
import Observation
import SwiftData
import SwiftUI

// Cartões de alteração do copiloto na conversa do Coach (DESIGN §4.15.8): mapeamento do `CopilotChangeSet` para o
// `FJChangeCard`, sem rede e sem SwiftUI de layout (testável).

enum CopilotChangePresentation {
    /// Mensagem do design para ficha com treino em andamento.
    static var sessionConflictMessage: String {
        String(localized: "Você está treinando esta ficha agora. Aplique depois de finalizar o treino.")
    }

    /// Estado transitório da tela (aplicando, falhou, conflito) por cima do estado gravado.
    enum Transient: Equatable {
        case applying
        case failed(String)
        case conflict(String)
    }

    static func area(for scope: CopilotScope) -> FJArea {
        switch scope {
        case .routine: .training
        case .nutritionPlan, .foodLog: .nutrition
        }
    }

    static func isFoodLog(_ scope: CopilotScope) -> Bool {
        if case .foodLog = scope { true } else { false }
    }

    /// Estado do `FJChangeCard` a partir do registro e do estado transitório.
    static func cardState(_ state: CopilotChangeState, transient: Transient?) -> FJChangeCardState {
        if let transient {
            switch transient {
            case .applying: return .applying
            case let .failed(message): return .failed(message)
            case let .conflict(message): return .conflict(message)
            }
        }
        switch state {
        case .proposed, .needsConfirmation: return .proposed
        case .applied: return .applied
        case .discarded: return .discarded
        case .undone: return .undone
        }
    }

    /// Linhas do diff (antes → depois). O `id` é a posição: o diff recalculado substitui o antigo.
    static func changes(_ changeSet: CopilotChangeSet) -> [FJChange] {
        changeSet.diff.enumerated().map { index, line in
            FJChange(id: "\(changeSet.id)-\(index)", label: line.context, before: line.before, after: line.after)
        }
    }

    /// Título curto do cartão pelas operações.
    static func title(_ changeSet: CopilotChangeSet) -> String {
        let operations = changeSet.operations
        guard operations.count == 1, let operation = operations.first else {
            return operations.count > 1 ? String(localized: "\(operations.count) alterações") : String(localized: "Alteração proposta")
        }
        switch operation {
        case .setLoad: return String(localized: "Mudar a carga")
        case .setReps: return String(localized: "Mudar as repetições")
        case .setSetCount: return String(localized: "Mudar o número de séries")
        case .setRest: return String(localized: "Mudar o descanso")
        case .replaceExercise: return String(localized: "Trocar um exercício")
        case .addExercise: return String(localized: "Adicionar um exercício")
        case .removeExercise: return String(localized: "Remover um exercício")
        case .moveExercise: return String(localized: "Reordenar exercícios")
        case .addItem: return String(localized: "Adicionar um alimento")
        case .removeItem: return String(localized: "Remover um alimento")
        case .updateItem: return String(localized: "Alterar um alimento")
        case .addMeal: return String(localized: "Adicionar uma refeição")
        case .removeMeal: return String(localized: "Remover uma refeição")
        case .updateMeal: return String(localized: "Alterar uma refeição")
        case .setTargets: return String(localized: "Mudar as metas")
        case .logFood: return String(localized: "Registrar o que você comeu")
        }
    }

    /// Texto inicial do compositor ao tocar em "Ajustar".
    static func adjustPrompt(_ changeSet: CopilotChangeSet) -> String {
        String(localized: "Sobre “\(title(changeSet))” (\(changeSet.scope.title)): ")
    }

    /// Nota quando o estado mudou desde a proposta.
    static func note(for state: CopilotChangeState) -> String? {
        state == .needsConfirmation
            ? String(localized: "O que estava salvo mudou desde a sugestão. Este é o antes → depois atualizado: confira e confirme.")
            : nil
    }

    /// Mensagem do cartão para um erro do `ChangeApplier`.
    static func transient(for error: any Error) -> Transient {
        if let applierError = error as? ChangeApplierError {
            switch applierError {
            case .sessionInProgress:
                return .conflict(sessionConflictMessage)
            case .targetMissing, .notPending:
                return .conflict(applierError.localizedDescription)
            default:
                return .failed(applierError.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
}

/// Ponte "Editar com IA" → conversa do Coach (aba Coach abre uma conversa nova com o escopo da ficha/plano).
@MainActor
@Observable
final class CoachHandoff {
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let draft: String
    }

    private(set) var request: Request?
    @ObservationIgnored private var drafts: [UUID: String] = [:]

    func open(title: String, draft: String) {
        request = Request(title: title, draft: draft)
    }

    func clearRequest() { request = nil }

    func setDraft(_ text: String, for conversationID: UUID) { drafts[conversationID] = text }

    func takeDraft(for conversationID: UUID) -> String? { drafts.removeValue(forKey: conversationID) }

    /// Texto inicial para editar uma ficha.
    static func routineDraft(routineName: String, programName: String?) -> (title: String, draft: String) {
        let title = String(localized: "Ficha \(routineName)")
        let draft = programName.map { String(localized: "Na ficha “\(routineName)” do programa “\($0)”: ") }
            ?? String(localized: "Na ficha “\(routineName)”: ")
        return (title, draft)
    }

    static func planDraft(planName: String) -> (title: String, draft: String) {
        (String(localized: "Dieta \(planName)"), String(localized: "Na dieta “\(planName)”: "))
    }
}

extension ChatConversation {
    /// Mensagens para a UI do Coach: as de sempre mais as `tool` que carregam um cartão de alteração do copiloto.
    @MainActor
    func visibleMessages(including store: CopilotChangeStore) -> [ChatMessage] {
        let base = Set(visibleMessages.map(\.id))
        return sortedMessages.filter { base.contains($0.id) || store.record(for: $0) != nil }
    }
}
