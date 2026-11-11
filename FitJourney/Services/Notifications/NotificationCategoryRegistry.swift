import Foundation
import UserNotifications

/// Onde as categorias de notificação do app vivem (real: `UNUserNotificationCenter`; testes: fake).
@MainActor
protocol NotificationCategoryStore: AnyObject {
    func categories() async -> Set<UNNotificationCategory>
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor
final class UserNotificationCategoryStore: NotificationCategoryStore {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func categories() async -> Set<UNNotificationCategory> { await center.notificationCategories() }
    func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
}

/// Dono único das categorias de notificação do app. `setNotificationCategories` **substitui** tudo,
/// então cada recurso registra a sua aqui (refeição agora; descanso/Live Activity depois) e `apply()`
/// grava a mescla: as registradas aqui vencem por identificador e as de terceiros já presentes ficam.
/// Chamar `apply()` uma vez no launch, antes de qualquer notificação ser tratada.
@MainActor
final class NotificationCategoryRegistry {
    private let store: NotificationCategoryStore
    private var owned: [String: UNNotificationCategory] = [:]
    private var tail: Task<Void, Never>?

    init(store: NotificationCategoryStore = UserNotificationCategoryStore()) { self.store = store }

    func register(_ category: UNNotificationCategory) { owned[category.identifier] = category }

    /// Serializado: duas chamadas nunca leem/gravam intercaladas.
    func apply() async {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            let existing = await store.categories().filter { owned[$0.identifier] == nil }
            store.setCategories(existing.union(owned.values))
        }
        tail = task
        await task.value
    }
}
