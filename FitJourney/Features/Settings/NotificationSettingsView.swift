import SwiftData
import SwiftUI

/// Ajustes › Notificações: estado real da autorização do sistema, atalho para os Ajustes do iPhone e o
/// liga/desliga geral dos lembretes de refeição.
struct NotificationSettingsView: View {
    @Environment(\.mealReminderScheduler) private var scheduler
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppPreferenceKeys.mealReminders) private var mealReminders = true
    @State private var state: SettingsPresentation.NotificationState = .notRequested

    var body: some View {
        Form {
            Section {
                switch state {
                case .denied:
                    FJBanner("Desativadas nos Ajustes do iPhone",
                             message: "Sem permissão, nenhum aviso chega. Suas escolhas abaixo ficam salvas.",
                             tone: .attention, systemImage: "bell.slash", actionTitle: "Abrir Ajustes") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                case .allowed, .notRequested:
                    LabeledContent("Estado do sistema") {
                        Text(verbatim: state.title).foregroundStyle(FJColor.textSecondary)
                    }
                }
            } footer: {
                if state == .notRequested {
                    Text("O pedido de permissão aparece ao ligar o primeiro lembrete.")
                }
            }

            Section {
                Toggle("Lembretes de refeição", isOn: Binding(
                    get: { mealReminders },
                    set: { setMealReminders($0) }))
                    .disabled(!state.togglesEnabled)
            } footer: {
                Text("Edite os horários no plano alimentar. O aviso de fim de descanso é ligado pelo próprio treino, na primeira vez que você descansa.")
            }
        }
        .navigationTitle("Notificações")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        state = .init(await scheduler?.authorization())
    }

    private func setMealReminders(_ on: Bool) {
        mealReminders = on
        Task {
            if on {
                if state == .notRequested { _ = await scheduler?.requestAuthorization() }
                await scheduler?.reschedule(for: context)
            } else {
                await scheduler?.cancelAll()
            }
            await refresh()
        }
    }
}
