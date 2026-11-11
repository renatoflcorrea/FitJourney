import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import FitJourney


@MainActor
struct MealReminderTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return cal
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private static var containers: [ModelContainer] = []

    private struct Fixture {
        let context: ModelContext
        let store: NutritionStore
        let plan: NutritionPlan
        let day: NutritionDay
    }

    private func makeFixture(planStart: Date? = nil, planEnd: Date? = nil) throws -> Fixture {
        let container = try PersistenceController.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let store = NutritionStore(context: context, calendar: calendar)
        let plan = NutritionPlan(name: "P", startDate: planStart ?? at(1, 0))
        plan.endDate = planEnd
        context.insert(plan)
        let day = NutritionDay(name: "Todos")
        context.insert(day)
        day.plan = plan
        try store.activate(plan)
        return Fixture(context: context, store: store, plan: plan, day: day)
    }

    @discardableResult
    private func addMeal(_ f: Fixture, _ name: String, minutes: Int, reminder: Bool = true, to day: NutritionDay? = nil,
                         items: [String] = ["Arroz"]) -> Meal {
        let target = day ?? f.day
        let meal = Meal(name: name, minutesFromMidnight: minutes, sortIndex: (target.meals ?? []).count, reminderEnabled: reminder)
        f.context.insert(meal)
        meal.day = target
        for (index, item) in items.enumerated() {
            let mealItem = MealItem(name: item, quantity: 100, unit: .grams, sortIndex: index)
            f.context.insert(mealItem)
            mealItem.meal = meal
        }
        return meal
    }

    private func requests(_ f: Fixture, now: Date, horizon: Int = 7, limit: Int = 60) throws -> [MealReminderRequest] {
        try MealReminderPlanner.requests(store: f.store, now: now, horizonDays: horizon, limit: limit)
    }

    @Test func onlyEnabledMealsAndContent() throws {
        let f = try makeFixture()
        addMeal(f, "Almoço", minutes: 750, items: ["Arroz", "Feijão", "Frango", "Salada", "Fruta"])
        addMeal(f, "Jantar", minutes: 1_200, reminder: false)
        let result = try requests(f, now: at(11, 6), horizon: 1)
        #expect(result.count == 1)
        #expect(result[0].title == "Almoço · 12:30")
        #expect(result[0].body == "Arroz, Feijão, Frango +2")
        #expect(result[0].fireDate == at(11, 12, 30))
    }

    @Test func skipsPastAndCompletedMeals() throws {
        let f = try makeFixture()
        let breakfast = addMeal(f, "Café", minutes: 420)
        addMeal(f, "Almoço", minutes: 750)
        let dinner = addMeal(f, "Jantar", minutes: 1_200)
        try f.context.save()
        _ = try f.store.markMealDone(dinner, on: at(11, 0))
        let result = try requests(f, now: at(11, 8), horizon: 1)
        #expect(result.map(\.mealID) == [result[0].mealID] && result.count == 1) // só o almoço
        #expect(result[0].title.hasPrefix("Almoço"))
        _ = breakfast
    }

    @Test func respectsVigencyStartAndEnd() throws {
        let f = try makeFixture(planStart: at(13, 0), planEnd: at(15, 0))
        addMeal(f, "Almoço", minutes: 750)
        let result = try requests(f, now: at(11, 6), horizon: 7) // 11…17
        let days = result.map { calendar.component(.day, from: $0.fireDate) }
        #expect(days == [13, 14, 15])
    }

    @Test func weekdayVariationsPickTheRightDay() throws {
        let f = try makeFixture()
        f.day.weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
        let weekend = NutritionDay(name: "Fim de semana", weekdays: [.saturday, .sunday], sortIndex: 1)
        f.context.insert(weekend)
        weekend.plan = f.plan
        addMeal(f, "Almoço útil", minutes: 750)
        addMeal(f, "Brunch", minutes: 640, to: weekend)
        // 11/nov/2026 é quarta; 14 e 15 são sábado e domingo.
        let result = try requests(f, now: at(11, 6), horizon: 7)
        let byDay = Dictionary(grouping: result) { calendar.component(.day, from: $0.fireDate) }
        #expect(byDay[11]?.first?.title.hasPrefix("Almoço útil") == true)
        #expect(byDay[14]?.first?.title.hasPrefix("Brunch") == true)
        #expect(byDay[15]?.first?.title.hasPrefix("Brunch") == true)
        #expect(byDay[14]?.count == 1)
    }

    @Test func identifiersAreDeterministicAndUnique() throws {
        let f = try makeFixture()
        addMeal(f, "A", minutes: 420)
        addMeal(f, "B", minutes: 750)
        let first = try requests(f, now: at(11, 0))
        let second = try requests(f, now: at(11, 0))
        #expect(first.map(\.identifier) == second.map(\.identifier))
        #expect(Set(first.map(\.identifier)).count == first.count)
        #expect(first.allSatisfy { $0.identifier.hasPrefix(MealReminderPlanner.identifierPrefix) })
    }

    @Test func pendingLimitKeepsEarliestDays() throws {
        let f = try makeFixture()
        for i in 0..<10 { addMeal(f, "M\(i)", minutes: 360 + i * 60) }
        let result = try requests(f, now: at(11, 0), horizon: 14, limit: 25)
        #expect(result.count == 25)
        #expect(result == result.sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) })
        #expect(calendar.component(.day, from: result.last!.fireDate) == 13) // 10/dia → 2 dias + 5
    }

    @Test func rescheduleIsIdempotentAndCleansStale() async throws {
        let f = try makeFixture()
        let meal = addMeal(f, "Almoço", minutes: 750)
        let center = FakeMealReminderCenter()
        center.seedForeign("br.com.renatocorrea.fitjourney.rest-end")
        let scheduler = MealReminderScheduler(center: center, calendar: calendar)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        let once = Set(center.pending.keys)
        #expect(once.count == 14)
        let addsAfterFirst = center.addCount
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(Set(center.pending.keys) == once)
        #expect(center.addCount == addsAfterFirst) // nada mudou: nada reagendado
        // Renomear a refeição reagenda só o conteúdo alterado (mesmos identificadores).
        meal.name = "Almoço 2"
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(Set(center.pending.keys) == once && center.addCount == addsAfterFirst + 14)
        #expect(center.pending.values.allSatisfy { $0.title.hasPrefix("Almoço 2") })
        // Desligar o lembrete remove só os nossos.
        meal.reminderEnabled = false
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.pending.isEmpty)
        #expect(center.foreign == ["br.com.renatocorrea.fitjourney.rest-end"])
    }

    @Test func deniedPermissionSchedulesNothingAndNeverAsks() async throws {
        let f = try makeFixture()
        addMeal(f, "Almoço", minutes: 750)
        let center = FakeMealReminderCenter()
        center.status = .denied
        let scheduler = MealReminderScheduler(center: center, calendar: calendar)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.pending.isEmpty)
        #expect(center.addCount == 0)
        center.status = .notDetermined
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.status == .notDetermined)
    }

    @Test func globalToggleOffCancelsAndBlocksScheduling() async throws {
        let f = try makeFixture()
        addMeal(f, "Almoço", minutes: 750)
        let center = FakeMealReminderCenter()
        let suite = "fj-meal-toggle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = MealReminderScheduler(center: center, calendar: calendar, defaults: defaults)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(!center.pending.isEmpty) // ausente = ligado
        defaults.set(false, forKey: MealReminderScheduler.enabledKey)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.pending.isEmpty)
        let adds = center.addCount
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.addCount == adds)
        defaults.set(true, forKey: MealReminderScheduler.enabledKey)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(!center.pending.isEmpty)
    }

    @Test func archivingPlanStopsFutureReminders() async throws {
        let f = try makeFixture()
        addMeal(f, "Almoço", minutes: 750)
        let center = FakeMealReminderCenter()
        let scheduler = MealReminderScheduler(center: center, calendar: calendar)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(!center.pending.isEmpty)
        let other = NutritionPlan(name: "Outro", startDate: at(1, 0))
        f.context.insert(other)
        try f.store.switchActive(to: other) // o primeiro vai para o histórico
        f.plan.endDate = at(10, 0)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(center.pending.isEmpty)
    }

    @Test func markDoneActionRegistersTheMeal() throws {
        let f = try makeFixture()
        let meal = addMeal(f, "Almoço", minutes: 750, items: ["Arroz", "Feijão"])
        try f.context.save()
        let info = MealReminderResponder.userInfo(mealID: meal.id, day: at(11, 0))
        #expect(!MealReminderResponder.handle(actionIdentifier: "outra", userInfo: info, context: f.context, calendar: calendar))
        #expect(MealReminderResponder.handle(actionIdentifier: MealReminderResponder.markDoneActionIdentifier,
                                             userInfo: info, context: f.context, calendar: calendar))
        let state = try f.store.plannedMeals(on: at(11, 0)).first
        #expect(state?.status == .done)
        #expect(try f.store.entries(on: at(11, 0)).count == 2)
    }

    // MARK: Aderência

    @Test func adherenceCountsDoneAndAdjusted() throws {
        let f = try makeFixture()
        let a = addMeal(f, "A", minutes: 420, reminder: false)
        let b = addMeal(f, "B", minutes: 750, reminder: false)
        let c = addMeal(f, "C", minutes: 1_200, reminder: false)
        addMeal(f, "D", minutes: 1_300, reminder: false)
        try f.context.save()
        _ = try f.store.markMealDone(a, on: at(10, 0))
        _ = try f.store.logAdjustedMeal(b, on: at(10, 0), items: [(name: "X", quantity: 1, unit: .unit, values: NutrientValues(kcal: 100))])
        try f.store.skipMeal(c, on: at(10, 0))
        let adherence = try f.store.adherence(on: at(10, 12), now: at(11, 9))
        #expect(adherence == DayAdherence(planned: 4, done: 2, skipped: 1, phase: .past))
        #expect(adherence.level == .partial)
        #expect(adherence.ratio == 0.5)
        #expect(try f.store.adherence(on: at(9, 12), now: at(11, 9)).level == .none)
        #expect(try f.store.adherence(on: at(12, 12), now: at(11, 9)).level == .upcoming)
        #expect(DayAdherence(planned: 3, done: 3).level == .complete)
        #expect(DayAdherence(planned: 0, done: 0).level == .noPlan)
    }

    @Test func weekStripAndHistory() throws {
        let f = try makeFixture()
        let a = addMeal(f, "A", minutes: 420, reminder: false)
        try f.context.save()
        _ = try f.store.markMealDone(a, on: at(10, 0))
        let strip = try f.store.weekStrip(containing: at(11, 12), now: at(11, 9))
        #expect(strip.count == 7)
        #expect(strip.filter(\.isSelected).count == 1 && strip.filter(\.isToday).count == 1)
        let history = try f.store.history(days: 5, now: at(11, 9))
        #expect(history.map(\.date) == [calendar.startOfDay(for: at(10, 0))])
        #expect(history[0].adherence.level == .complete)
    }

    // MARK: Revisão

    @Test func handleIsNoOpWhenNotPendingOrNotPlanned() throws {
        let f = try makeFixture()
        let meal = addMeal(f, "Almoço", minutes: 750)
        try f.context.save()
        let info = MealReminderResponder.userInfo(mealID: meal.id, day: at(11, 0))
        let action = MealReminderResponder.markDoneActionIdentifier
        try f.store.skipMeal(meal, on: at(11, 0)) // pulada: a notificação velha não pode "desfazer"
        #expect(!MealReminderResponder.handle(actionIdentifier: action, userInfo: info, context: f.context, calendar: calendar, now: at(11, 13)))
        #expect(try f.store.plannedMeals(on: at(11, 0)).first?.status == .skipped)
        try f.store.resetMeal(meal, on: at(11, 0))
        #expect(MealReminderResponder.handle(actionIdentifier: action, userInfo: info, context: f.context, calendar: calendar, now: at(11, 13)))
        // Já feita: segunda ação não duplica entradas.
        let count = try f.store.entries(on: at(11, 0)).count
        #expect(!MealReminderResponder.handle(actionIdentifier: action, userInfo: info, context: f.context, calendar: calendar, now: at(11, 14)))
        #expect(try f.store.entries(on: at(11, 0)).count == count)
        // Refeição que saiu do plano.
        let gone = MealReminderResponder.userInfo(mealID: UUID(), day: at(11, 0))
        #expect(!MealReminderResponder.handle(actionIdentifier: action, userInfo: gone, context: f.context, calendar: calendar))
    }

    @Test func actionTappedOnAnotherDayUsesPlannedTimeAndAcceptsNSNumber() throws {
        let f = try makeFixture()
        let meal = addMeal(f, "Almoço", minutes: 750)
        try f.context.save()
        let info: [AnyHashable: Any] = [MealReminderResponder.mealIDKey: meal.id.uuidString,
                                        MealReminderResponder.dayKey: NSNumber(value: at(10, 0).timeIntervalSince1970)]
        #expect(MealReminderResponder.handle(actionIdentifier: MealReminderResponder.markDoneActionIdentifier, userInfo: info,
                                             context: f.context, calendar: calendar, now: at(11, 9, 17)))
        let entries = try f.store.entries(on: at(10, 0))
        #expect(entries.count == 1 && entries[0].date == at(10, 12, 30))
    }

    @Test func clearNotificationsRemovesPendingAndDelivered() async throws {
        let f = try makeFixture()
        let meal = addMeal(f, "Almoço", minutes: 750)
        let center = FakeMealReminderCenter()
        let scheduler = MealReminderScheduler(center: center, calendar: calendar)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        let id = MealReminderPlanner.identifier(mealID: meal.id, day: at(11, 0), calendar: calendar)
        #expect(center.pending[id] != nil)
        await scheduler.clearNotifications(mealID: meal.id, day: at(11, 0))
        #expect(center.pending[id] == nil && center.removedDelivered == [id])
    }

    @Test func daylightSavingKeepsLocalClockTime() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let container = try PersistenceController.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let store = NutritionStore(context: context, calendar: ny)
        let plan = NutritionPlan(name: "P", startDate: ny.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        context.insert(plan)
        let day = NutritionDay(name: "Todos")
        context.insert(day)
        day.plan = plan
        let meal = Meal(name: "Café", minutesFromMidnight: 480, reminderEnabled: true)
        context.insert(meal)
        meal.day = day
        try store.activate(plan)
        let now = ny.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 6))!
        let result = try MealReminderPlanner.requests(store: store, now: now, horizonDays: 4, limit: 60) // 30, 31, 1/nov (fim do DST), 2
        #expect(result.count == 4)
        #expect(result.allSatisfy { ny.component(.hour, from: $0.fireDate) == 8 && ny.component(.minute, from: $0.fireDate) == 0 })
        #expect(Set(result.map(\.identifier)).count == 4)
        #expect(result[2].fireDate.timeIntervalSince(result[1].fireDate) == 25 * 3_600)
    }

    @Test func categoryRegistryMergesAndKeepsThirdParty() async {
        let thirdParty = UNNotificationCategory(identifier: "terceiro", actions: [], intentIdentifiers: [], options: [])
        let stale = UNNotificationCategory(identifier: MealReminderResponder.categoryIdentifier, actions: [], intentIdentifiers: [], options: [])
        let store = FakeCategoryStore([thirdParty, stale])
        let registry = NotificationCategoryRegistry(store: store)
        registry.register(MealReminderResponder.category)
        await registry.apply()
        await registry.apply() // idempotente
        #expect(store.stored.count == 2)
        #expect(store.stored.contains { $0.identifier == "terceiro" })
        let meal = store.stored.first { $0.identifier == MealReminderResponder.categoryIdentifier }
        #expect(meal?.actions.first?.identifier == MealReminderResponder.markDoneActionIdentifier)
    }

    @Test func foregroundPresentationOnlyForMealReminders() {
        #expect(AppNotificationDelegate.presentationOptions(forCategory: MealReminderResponder.categoryIdentifier).contains(.banner))
        #expect(AppNotificationDelegate.presentationOptions(forCategory: "").isEmpty)
    }

    // MARK: Aderência (regras puras)

    @Test func adherenceRules() {
        func level(_ s: [MealStatus], _ phase: NutritionDayPhase) -> DayAdherence.Level { DayAdherence.make(statuses: s, phase: phase).level }
        #expect(level([], .past) == .noPlan)
        #expect(level([.pending, .pending], .future) == .upcoming)
        #expect(level([.done, .adjusted], .past) == .complete)
        #expect(level([.done, .adjusted], .today) == .complete)
        #expect(level([.skipped, .skipped], .past) == .allSkipped) // 100% pulado ≠ nada feito
        #expect(level([.skipped, .skipped], .today) == .allSkipped)
        #expect(level([.pending, .pending], .past) == .none)
        #expect(level([.pending, .skipped], .past) == .none)
        #expect(level([.pending, .pending], .today) == .upcoming) // dia aberto, nada feito
        #expect(level([.done, .pending], .today) == .partial)
        #expect(level([.done, .skipped], .past) == .partial)
    }
}
