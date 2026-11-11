import Foundation
import UserNotifications
@testable import FitJourney

@MainActor
final class FakeMealReminderCenter: MealReminderNotificationCenter {
    var status: RestNotificationAuthorization = .authorized
    private(set) var pending: [String: MealReminderRequest] = [:]
    private(set) var foreign: Set<String> = []
    private(set) var addCount = 0
    private(set) var removedDelivered: [String] = []

    func authorization() async -> RestNotificationAuthorization { status }
    func requestAuthorization() async -> Bool { status = .authorized; return true }
    func pendingRequests() async -> [MealReminderRequest] { Array(pending.values) }
    func add(_ request: MealReminderRequest, calendar: Calendar) async throws { pending[request.identifier] = request; addCount += 1 }
    func remove(identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func removeDelivered(identifiers: [String]) { removedDelivered += identifiers }
    /// Pendente de outro recurso (ex.: descanso): nunca deve ser tocado.
    func seedForeign(_ id: String) { foreign.insert(id) }
}

@MainActor
final class FakeCategoryStore: NotificationCategoryStore {
    var stored: Set<UNNotificationCategory>
    init(_ initial: Set<UNNotificationCategory> = []) { stored = initial }
    func categories() async -> Set<UNNotificationCategory> { stored }
    func setCategories(_ categories: Set<UNNotificationCategory>) { stored = categories }
}
