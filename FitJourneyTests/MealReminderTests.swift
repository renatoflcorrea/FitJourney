import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
final class FakeMealReminderCenter: MealReminderNotificationCenter {
    var status: RestNotificationAuthorization = .authorized
    private(set) var pending: [String: MealReminderRequest] = [:]
    private(set) var addCount = 0
    private(set) var categoryRegistered = false

    func authorization() async -> RestNotificationAuthorization { status }
    func requestAuthorization() async -> Bool { status = .authorized; return true }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func add(_ request: MealReminderRequest, calendar: Calendar) async { pending[request.identifier] = request; addCount += 1 }
    func remove(identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func registerCategory() { categoryRegistered = true }
    /// Pendente de outro recurso (ex.: descanso): nunca deve ser tocado.
    func seedForeign(_ id: String) {
        pending[id] = MealReminderRequest(identifier: id, mealID: UUID(), day: .now, fireDate: .now, title: "", body: "")
    }
}

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
        #expect(center.categoryRegistered)
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        let once = Set(center.pending.keys)
        #expect(once.count == 15) // 14 dias + o aviso de descanso de outro recurso
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(Set(center.pending.keys) == once)
        // Desligar o lembrete remove só os nossos.
        meal.reminderEnabled = false
        await scheduler.reschedule(for: f.context, now: at(11, 6))
        #expect(Set(center.pending.keys) == ["br.com.renatocorrea.fitjourney.rest-end"])
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
        #expect(adherence == DayAdherence(planned: 4, done: 2))
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
}
