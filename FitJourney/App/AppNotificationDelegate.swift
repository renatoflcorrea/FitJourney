import SwiftData
import UserNotifications

/// Trata notificações locais do app. Instalado no `init` do App, antes de qualquer view.
/// - Lembrete de refeição: banner em primeiro plano e ação "Marcar como feita".
/// - Fim do descanso: nada em primeiro plano (o app vibra e mostra o descanso sozinho).
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // `@unchecked Sendable`: as propriedades são imutáveis e só usadas no `@MainActor`.
    private let context: ModelContext
    private let reminders: any MealReminderScheduling

    @MainActor
    init(context: ModelContext, reminders: any MealReminderScheduling) {
        self.context = context
        self.reminders = reminders
        super.init()
    }

    /// Opções de apresentação em primeiro plano, por categoria.
    static func presentationOptions(forCategory category: String) -> UNNotificationPresentationOptions {
        category == MealReminderResponder.categoryIdentifier ? [.banner, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentationOptions(forCategory: notification.request.content.categoryIdentifier))
    }

    /// O `completionHandler` só é chamado depois de gravar: o sistema considera a ação concluída ali.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let category = content.categoryIdentifier
        // Cópia imutável do plist da notificação, só lida no `@MainActor`.
        nonisolated(unsafe) let userInfo = content.userInfo
        Task { @MainActor in
            if category == MealReminderResponder.categoryIdentifier,
               MealReminderResponder.handle(actionIdentifier: action, userInfo: userInfo, context: context) {
                await reminders.reschedule(for: context)
            }
            completionHandler()
        }
    }
}
