import SwiftUI

// Pontos de integração: telas de outros pacotes ainda não integradas.

/// TODO(P2.4): trocar por `HistoryView` (Histórico de treinos).
struct HistoryPlaceholder: View {
    var body: some View {
        FJEmptyState("Histórico", systemImage: "clock.arrow.circlepath",
                     message: "Em breve: seus treinos concluídos, com séries e recordes.")
            .navigationTitle("Histórico")
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// TODO(P2.2): remover quando a sessão de treino existir; "Iniciar treino" abre a sessão de verdade.
    func comingSoonAlert(isPresented: Binding<Bool>) -> some View {
        alert("Em breve", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A tela de treino chega no próximo pacote. Suas fichas já estão prontas.")
        }
    }
}
