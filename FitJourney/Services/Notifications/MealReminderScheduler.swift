import Foundation
import OSLog
import SwiftData
import UserNotifications

private let reminderLog = Logger(subsystem: "br.com.renatocorrea.fitjourney", category: "meal-reminders")

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
        for resolved in try store.resolvedDays(from: today, count: max(0, horizonDays)) {
            for state in resolved.planned where state.meal.reminderEnabled && state.status == .pending {
                guard state.scheduledAt > now.addingTimeInterval(1) else { continue }
                let meal = state.meal
                let name = meal.name.trimmingCharacters(in: .whitespaces)
                let shownName = name.isEmpty ? String(localized: "Refeição") : name
                result.append(MealReminderRequest(
                    identifier: identifier(mealID: meal.id, day: resolved.date, calendar: calendar),
                    mealID: meal.id, day: resolved.date, fireDate: state.scheduledAt,
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
    /// Só os lembretes de refeição pendentes (identificador com o prefixo do planejador).
    func pendingRequests() async -> [MealReminderRequest]
    func add(_ request: MealReminderRequest, calendar: Calendar) async throws
    func remove(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor
protocol MealReminderScheduling: AnyObject {
    func authorization() async -> RestNotificationAuthorization
    /// Pede permissão (chamar de um gesto/contexto da UI). Devolve se ficou autorizado.
    func requestAuthorization() async -> Bool
    /// Leva as notificações pendentes ao estado desejado pelo plano vigente. Idempotente; só adiciona e
    /// remove o que mudou; nunca pergunta permissão.
    func reschedule(for context: ModelContext, now: Date) async
    /// Refeição resolvida (feita/pulada): remove a notificação pendente e a já entregue daquele dia.
    func clearNotifications(mealID: UUID, day: Date) async
    func cancelAll() async
}

extension MealReminderScheduling {
    func reschedule(for context: ModelContext) async { await reschedule(for: context, now: .now) }
}

@MainActor
final class MealReminderScheduler: MealReminderScheduling {
    private let center: MealReminderNotificationCenter
    private let calendar: Calendar
    private let defaults: UserDefaults
    private var tail: Task<Void, Never>?

    /// Chave do liga/desliga geral de Ajustes (`AppPreferenceKeys.mealReminders`); ausente = ligado.
    static let enabledKey = "fj.mealReminders"

    init(center: MealReminderNotificationCenter = UserNotificationMealReminderCenter(),
         calendar: Calendar = .autoupdatingCurrent, defaults: UserDefaults = .standard) {
        self.center = center
        self.calendar = calendar
        self.defaults = defaults
    }

    private var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    func authorization() async -> RestNotificationAuthorization { await center.authorization() }
    func requestAuthorization() async -> Bool { await center.requestAuthorization() }

    func reschedule(for context: ModelContext, now: Date) async {
        await enqueue { await $0.perform(context: context, now: now) }
    }

    func cancelAll() async {
        await enqueue { await $0.removeOwned(except: []) }
    }

    func clearNotifications(mealID: UUID, day: Date) async {
        let id = MealReminderPlanner.identifier(mealID: mealID, day: day, calendar: calendar)
        await enqueue {
            $0.center.remove(identifiers: [id])
            $0.center.removeDelivered(identifiers: [id])
        }
    }

    /// Serializado: uma chamada mais nova nunca é sobrescrita por outra mais velha ainda em voo.
    private func enqueue(_ operation: @escaping @MainActor (MealReminderScheduler) async -> Void) async {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await operation(self)
        }
        tail = task
        await task.value
    }

    private func perform(context: ModelContext, now: Date) async {
        // Desligado em Ajustes: nada de agendar (launch, primeiro plano e edição do plano passam por aqui).
        guard isEnabled else {
            await removeOwned(except: [])
            return
        }
        switch await center.authorization() {
        case .authorized: break
        case .notDetermined, .denied:
            await removeOwned(except: [])
            return
        }
        let store = NutritionStore(context: context, calendar: calendar)
        let desired: [MealReminderRequest]
        do { desired = try MealReminderPlanner.requests(store: store, now: now) } catch {
            reminderLog.error("Falha ao calcular lembretes: \(error.localizedDescription, privacy: .public)")
            return
        }
        let pending = Dictionary(await center.pendingRequests().map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        let keep = Set(desired.map(\.identifier))
        let stale = pending.keys.filter { !keep.contains($0) }
        if !stale.isEmpty { center.remove(identifiers: Array(stale)) }
        for request in desired where !Self.isUpToDate(pending[request.identifier], request) {
            do { try await center.add(request, calendar: calendar) } catch {
                reminderLog.error("Falha ao agendar \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isUpToDate(_ existing: MealReminderRequest?, _ desired: MealReminderRequest) -> Bool {
        guard let existing else { return false }
        return existing.title == desired.title && existing.body == desired.body
            && abs(existing.fireDate.timeIntervalSince(desired.fireDate)) < 1
    }

    private func removeOwned(except keep: Set<String>) async {
        let stale = await center.pendingRequests().map(\.identifier).filter { !keep.contains($0) }
        if !stale.isEmpty { center.remove(identifiers: stale) }
    }
}

/// Implementação nula (previews, testes de UI).
@MainActor
final class NoopMealReminderScheduler: MealReminderScheduling {
    init() {}
    func authorization() async -> RestNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func reschedule(for context: ModelContext, now: Date) async {}
    func clearNotifications(mealID: UUID, day: Date) async {}
    func cancelAll() async {}
}

/// Resposta às ações da notificação. O `AppNotificationDelegate` chama `handle`.
enum MealReminderResponder {
    static let categoryIdentifier = "br.com.renatocorrea.fitjourney.meal-reminder"
    static let markDoneActionIdentifier = "br.com.renatocorrea.fitjourney.meal-reminder.done"
    static let mealIDKey = "mealID"
    static let dayKey = "day"

    static func userInfo(mealID: UUID, day: Date) -> [String: Any] {
        [mealIDKey: mealID.uuidString, dayKey: day.timeIntervalSince1970]
    }

    /// Categoria com a ação "Marcar como feita" (registrada pelo `NotificationCategoryRegistry`).
    static var category: UNNotificationCategory {
        let done = UNNotificationAction(identifier: markDoneActionIdentifier,
                                        title: String(localized: "Marcar como feita"), options: [])
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [done], intentIdentifiers: [], options: [])
    }

    /// Trata "Marcar como feita". Devolve `true` só se registrou. Não faz nada se a refeição não está mais
    /// no plano do dia ou se ela não está mais pendente (já feita, ajustada ou pulada). Tocada no dia do
    /// lembrete grava a hora atual; em outro dia, o horário planejado.
    @MainActor @discardableResult
    static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], context: ModelContext,
                       calendar: Calendar = .autoupdatingCurrent, now: Date = .now) -> Bool {
        guard actionIdentifier == markDoneActionIdentifier,
              let raw = userInfo[mealIDKey] as? String, let mealID = UUID(uuidString: raw),
              let stamp = (userInfo[dayKey] as? NSNumber)?.doubleValue else { return false }
        let day = Date(timeIntervalSince1970: stamp)
        let store = NutritionStore(context: context, calendar: calendar)
        guard let state = try? store.plannedMeals(on: day).first(where: { $0.meal.id == mealID }),
              state.status == .pending, !state.meal.sortedItems.isEmpty else { return false }
        let time: Date? = calendar.isDate(day, inSameDayAs: now) ? now : nil
        return (try? store.markMealDone(state.meal, on: day, at: time)) != nil
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
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingRequests() async -> [MealReminderRequest] {
        await center.pendingNotificationRequests().compactMap { request in
            guard request.identifier.hasPrefix(MealReminderPlanner.identifierPrefix) else { return nil }
            let info = request.content.userInfo
            let mealID = (info[MealReminderResponder.mealIDKey] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let stamp = (info[MealReminderResponder.dayKey] as? NSNumber)?.doubleValue ?? 0
            let fire = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantPast
            return MealReminderRequest(identifier: request.identifier, mealID: mealID,
                                       day: Date(timeIntervalSince1970: stamp), fireDate: fire,
                                       title: request.content.title, body: request.content.body)
        }
    }

    func add(_ request: MealReminderRequest, calendar: Calendar) async throws {
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
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
