import Foundation
import SwiftData
import UserNotifications

/// Uma notificação de refeição já resolvida (o que seria agendado).
struct MealReminderRequest: Equatable, Sendable {
    let identifier: String
    let mealID: UUID
    /// Início do dia (no calendário usado) a que a notificação pertence.
    let day: Date
    let fireDate: Date
    let title: String
    let body: String
}

/// Decide quais lembretes de refeição devem estar pendentes (SPEC §5: lembrete opcional por refeição).
///
/// Decisão: **janela rolante** de notificações com gatilho de calendário de data completa (não repetidas),
/// em vez de gatilhos semanais repetidos. Um gatilho repetido continuaria disparando depois do fim da
/// vigência do plano, para refeição já feita e depois de o plano mudar sem o app abrir; a janela respeita
/// vigência, variações por dia da semana e o status do dia, e é refeita a cada launch/foreground e a cada
/// edição. Os próximos dias vêm primeiro; passado o limite de pendentes do iOS (64), o excedente é cortado
/// pelos dias mais distantes.
enum MealReminderPlanner {
    static let identifierPrefix = "br.com.renatocorrea.fitjourney.meal."
    /// Dias olhados à frente (os 7 primeiros têm prioridade pela ordenação por data).
    static let horizonDays = 14
    /// Máximo de pendentes do app (64 do iOS, menos folga para o aviso de descanso).
    static let pendingLimit = 60

    static func identifier(mealID: UUID, day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return identifierPrefix + mealID.uuidString + String(format: ".%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @MainActor
    static func requests(store: NutritionStore, now: Date, horizonDays: Int = horizonDays,
                         limit: Int = pendingLimit) throws -> [MealReminderRequest] {
        let calendar = store.calendar
        let today = calendar.startOfDay(for: now)
        var result: [MealReminderRequest] = []
        for offset in 0..<max(0, horizonDays) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for state in try store.plannedMeals(on: day) where state.meal.reminderEnabled && state.status == .pending {
                guard state.scheduledAt > now.addingTimeInterval(1) else { continue }
                let meal = state.meal
                let name = meal.name.trimmingCharacters(in: .whitespaces)
                let shownName = name.isEmpty ? String(localized: "Refeição") : name
                result.append(MealReminderRequest(
                    identifier: identifier(mealID: meal.id, day: day, calendar: calendar),
                    mealID: meal.id, day: day, fireDate: state.scheduledAt,
                    title: "\(shownName) · \(NutritionFormat.clock(minutes: meal.minutesFromMidnight))",
                    body: body(for: meal)))
            }
        }
        result.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(result.prefix(max(0, limit)))
    }

    /// Itens resumidos: até 3 nomes e "+N".
    @MainActor
    static func body(for meal: Meal) -> String {
        let names = meal.sortedItems.map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return String(localized: "Hora da refeição.") }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }
}

/// Fronteira com o sistema de notificações (real: `UNUserNotificationCenter`; testes: fake).
@MainActor
protocol MealReminderNotificationCenter: AnyObject {
    func authorization() async -> RestNotificationAuthorization
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> [String]
    func add(_ request: MealReminderRequest, calendar: Calendar) async
    func remove(identifiers: [String])
    func registerCategory()
}

@MainActor
protocol MealReminderScheduling: AnyObject {
    func authorization() async -> RestNotificationAuthorization
    /// Pede permissão (chamar de um gesto/contexto da UI). Devolve se ficou autorizado.
    func requestAuthorization() async -> Bool
    /// Leva as notificações pendentes ao estado desejado pelo plano vigente. Idempotente; nunca pergunta permissão.
    func reschedule(for context: ModelContext, now: Date) async
    func cancelAll() async
}

extension MealReminderScheduling {
    func reschedule(for context: ModelContext) async { await reschedule(for: context, now: .now) }
}

@MainActor
final class MealReminderScheduler: MealReminderScheduling {
    private let center: MealReminderNotificationCenter
    private let calendar: Calendar
    private var tail: Task<Void, Never>?

    init(center: MealReminderNotificationCenter = UserNotificationMealReminderCenter(),
         calendar: Calendar = .autoupdatingCurrent) {
        self.center = center
        self.calendar = calendar
        center.registerCategory()
    }

    func authorization() async -> RestNotificationAuthorization { await center.authorization() }
    func requestAuthorization() async -> Bool { await center.requestAuthorization() }

    func reschedule(for context: ModelContext, now: Date) async {
        // Serializado: uma chamada mais nova nunca é sobrescrita por outra mais velha ainda em voo.
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await perform(context: context, now: now)
        }
        tail = task
        await task.value
    }

    func cancelAll() async {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await removeOwned(except: [])
        }
        tail = task
        await task.value
    }

    private func perform(context: ModelContext, now: Date) async {
        guard await center.authorization() == .authorized else {
            await removeOwned(except: [])
            return
        }
        let store = NutritionStore(context: context, calendar: calendar)
        guard let desired = try? MealReminderPlanner.requests(store: store, now: now) else { return }
        await removeOwned(except: Set(desired.map(\.identifier)))
        for request in desired { await center.add(request, calendar: calendar) }
    }

    private func removeOwned(except keep: Set<String>) async {
        let stale = await center.pendingIdentifiers().filter {
            $0.hasPrefix(MealReminderPlanner.identifierPrefix) && !keep.contains($0)
        }
        if !stale.isEmpty { center.remove(identifiers: stale) }
    }
}

/// Implementação nula (previews).
@MainActor
final class NoopMealReminderScheduler: MealReminderScheduling {
    init() {}
    func authorization() async -> RestNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func reschedule(for context: ModelContext, now: Date) async {}
    func cancelAll() async {}
}

/// Resposta às ações da notificação. O `UNUserNotificationCenterDelegate` do App chama `handle`.
enum MealReminderResponder {
    static let categoryIdentifier = "br.com.renatocorrea.fitjourney.meal-reminder"
    static let markDoneActionIdentifier = "br.com.renatocorrea.fitjourney.meal-reminder.done"
    static let mealIDKey = "mealID"
    static let dayKey = "day"

    static func userInfo(mealID: UUID, day: Date) -> [String: Any] {
        [mealIDKey: mealID.uuidString, dayKey: day.timeIntervalSince1970]
    }

    /// Trata "Marcar como feita". Devolve `true` se registrou. O toque no corpo da notificação não é
    /// tratado aqui (só abre o app).
    @MainActor @discardableResult
    static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], context: ModelContext,
                       calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard actionIdentifier == markDoneActionIdentifier,
              let raw = userInfo[mealIDKey] as? String, let mealID = UUID(uuidString: raw),
              let stamp = userInfo[dayKey] as? TimeInterval else { return false }
        let target = mealID
        var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == target })
        descriptor.fetchLimit = 1
        guard let meal = try? context.fetch(descriptor).first, !meal.sortedItems.isEmpty else { return false }
        let store = NutritionStore(context: context, calendar: calendar)
        return (try? store.markMealDone(meal, on: Date(timeIntervalSince1970: stamp), at: .now)) != nil
    }
}

/// `UNUserNotificationCenter` por trás de `MealReminderNotificationCenter`.
@MainActor
final class UserNotificationMealReminderCenter: MealReminderNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorization() async -> RestNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ request: MealReminderRequest, calendar: Calendar) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "meal"
        content.categoryIdentifier = MealReminderResponder.categoryIdentifier
        content.userInfo = MealReminderResponder.userInfo(mealID: request.mealID, day: request.day)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: request.fireDate)
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func registerCategory() {
        let done = UNNotificationAction(identifier: MealReminderResponder.markDoneActionIdentifier,
                                        title: String(localized: "Marcar como feita"), options: [])
        let category = UNNotificationCategory(identifier: MealReminderResponder.categoryIdentifier, actions: [done],
                                              intentIdentifiers: [], options: [])
        let center = center
        Task {
            // As categorias são do app inteiro: preserva as de outros recursos.
            var all = await center.notificationCategories().filter { $0.identifier != category.identifier }
            all.insert(category)
            center.setNotificationCategories(all)
        }
    }
}
