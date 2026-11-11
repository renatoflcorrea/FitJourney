import SwiftData
import SwiftUI

extension MealReminderScheduler {
    /// Instância única do app: a UI usa pelo `Environment`; o App usa a mesma no launch/foreground.
    static let shared = MealReminderScheduler()
}

private struct MealReminderSchedulerKey: EnvironmentKey {
    static var defaultValue: any MealReminderScheduling {
        MainActor.assumeIsolated { MealReminderScheduler.shared }
    }
}

extension EnvironmentValues {
    var mealReminderScheduler: any MealReminderScheduling {
        get { self[MealReminderSchedulerKey.self] }
        set { self[MealReminderSchedulerKey.self] = newValue }
    }
}

extension View {
    /// Refaz os lembretes ao aparecer e ao voltar para o primeiro plano.
    func refreshesMealReminders() -> some View { modifier(MealReminderRefresh()) }
}

private struct MealReminderRefresh: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mealReminderScheduler) private var scheduler

    func body(content: Content) -> some View {
        content
            .task { await scheduler.reschedule(for: context) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await scheduler.reschedule(for: context) } }
            }
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
