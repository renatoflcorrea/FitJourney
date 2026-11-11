import SwiftUI

/// PONTO DE INTEGRAÇÃO (P1.2): o supervisor troca o corpo por `RoutineEditorView(routine: routine)`.
/// Stub temporário — só mostra o nome da ficha.
struct RoutineEditorDestination: View {
    let routine: Routine

    var body: some View {
        Text(routine.name)
    }
}
