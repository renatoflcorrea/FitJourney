import SwiftData
import SwiftUI

/// Cartão de alteração do copiloto dentro da conversa: Aplicar, Ajustar, Descartar e Desfazer. É a única coisa na
/// conversa que altera dados, e só com toque. Estados no `CopilotChangeStore`; o aplicar passa pelo `ChangeApplier`.
struct CopilotChangeCardView: View {
    let changeID: String
    /// "Ajustar": o compositor ganha este texto e o foco.
    let onAdjust: (String) -> Void
    var store: CopilotChangeStore = .shared

    @Environment(\.modelContext) private var context
    @State private var transient: CopilotChangePresentation.Transient?
    @State private var undoMessage: String?

    var body: some View {
        if let record = store.record(for: changeID) {
            let changeSet = record.changeSet
            let isFood = CopilotChangePresentation.isFoodLog(changeSet.scope)
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                FJChangeCard(
                    title: CopilotChangePresentation.title(changeSet),
                    scope: changeSet.scope.title,
                    area: CopilotChangePresentation.area(for: changeSet.scope),
                    changes: CopilotChangePresentation.changes(changeSet),
                    state: CopilotChangePresentation.cardState(record.state, transient: transient),
                    note: CopilotChangePresentation.note(for: record.state),
                    applyTitle: applyTitle(isFood: isFood, state: record.state),
                    appliedTitle: isFood ? "Registrado" : "Aplicado",
                    onApply: { apply() },
                    onAdjust: { onAdjust(CopilotChangePresentation.adjustPrompt(changeSet)) },
                    onDiscard: { discard() },
                    onUndo: { undo() })
                if let undoMessage {
                    FJBanner("Não foi possível desfazer", message: LocalizedStringKey(undoMessage), tone: .attention,
                             actionTitle: "Fechar") { self.undoMessage = nil }
                }
            }
            .onChange(of: record.state) { _, _ in transient = nil }
        }
    }

    private func applyTitle(isFood: Bool, state: CopilotChangeState) -> LocalizedStringKey {
        if state == .needsConfirmation { return "Confirmar e aplicar" }
        return isFood ? "Registrar" : "Aplicar"
    }

    private var applier: ChangeApplier { ChangeApplier(context: context, store: store) }

    private func apply() {
        undoMessage = nil
        transient = .applying
        do {
            switch try applier.apply(changeID) {
            case .applied, .needsConfirmation:
                transient = nil
            }
        } catch {
            transient = CopilotChangePresentation.transient(for: error)
        }
    }

    private func discard() {
        transient = nil
        try? applier.discard(changeID)
    }

    private func undo() {
        undoMessage = nil
        do { try applier.undo(changeID) } catch { undoMessage = error.localizedDescription }
    }
}
