import SwiftData
import SwiftUI

/// Alerta "Renomear programa": campo de texto já preenchido com o nome atual. "Salvar" fica desabilitado com o nome
/// vazio (depois de tirar os espaços). A regra de nome e a gravação são do `ProgramStore`.
private struct RenameProgramAlert: ViewModifier {
    @Binding var program: TrainingProgram?
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var isShowing = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert("Renomear programa", isPresented: $isShowing) {
                TextField("Nome do programa", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityLabel(Text("Nome do programa"))
                Button("Cancelar", role: .cancel) {}
                Button("Salvar") { save() }
                    .disabled(ProgramStore.normalizedName(name) == nil)
            }
            // O nome entra no campo antes de o alerta aparecer (mesmo ciclo de atualização, nesta ordem).
            .onChange(of: program?.persistentModelID) { _, _ in
                guard let program else { return }
                name = program.name
                isShowing = true
            }
            .onChange(of: isShowing) { _, showing in if !showing { program = nil } }
            .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        guard let target = program else { return }
        do { try ProgramStore(context: context).rename(target, to: name) } catch { errorMessage = userMessage(for: error) }
    }
}

extension View {
    /// Alerta de renomear para `program` (nil = fechado). Defina o programa para abrir.
    func renameProgramAlert(program: Binding<TrainingProgram?>) -> some View {
        modifier(RenameProgramAlert(program: program))
    }
}
