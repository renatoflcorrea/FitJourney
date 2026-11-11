import SwiftData
import SwiftUI

/// O App injeta o agendador (`FitJourneyApp`); sem ele (previews, testes) a UI simplesmente não agenda.
private struct MealReminderSchedulerKey: EnvironmentKey {
    static var defaultValue: (any MealReminderScheduling)? { nil }
}

extension EnvironmentValues {
    var mealReminderScheduler: (any MealReminderScheduling)? {
        get { self[MealReminderSchedulerKey.self] }
        set { self[MealReminderSchedulerKey.self] = newValue }
    }
}

/// Faixa "Notificações desativadas" com atalho para os Ajustes do sistema (DESIGN §4.9).
struct NotificationsDisabledBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        FJBanner("Notificações desativadas",
                 message: "Sem permissão, os lembretes de refeição não chegam. A preferência fica salva.",
                 tone: .attention, systemImage: "bell.slash", actionTitle: "Abrir Ajustes") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}
