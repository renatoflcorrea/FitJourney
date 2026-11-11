import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct NutritionUITests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return cal
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// Mantém os containers vivos até o fim do processo de teste (o contexto não retém o container).
    private static var containers: [ModelContainer] = []

    private func makeStore() throws -> (NutritionStore, ModelContext, [Meal]) {
        let container = try PersistenceController.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let store = NutritionStore(context: context, calendar: calendar)
        let plan = NutritionPlan(name: "P")
        context.insert(plan)
        let day = NutritionDay(name: "Todos")
        context.insert(day)
        day.plan = plan
        var meals: [Meal] = []
        for (index, (name, minutes)) in [("Café", 420), ("Almoço", 750), ("Jantar", 1_200)].enumerated() {
            let meal = Meal(name: name, minutesFromMidnight: minutes, sortIndex: index)
            context.insert(meal)
            meal.day = day
            let item = MealItem(name: "Arroz", quantity: 100, unit: .grams, values: NutrientValues(kcal: 130), sortIndex: 0)
            context.insert(item)
            item.meal = meal
            item.substitutions = [MealSubstitution(name: "Macarrão", quantity: 80, unit: .grams, values: NutrientValues(kcal: 120))]
            meals.append(meal)
        }
        try store.activate(plan)
        return (store, context, meals)
    }

    @Test func pastPendingIsNoRecordNeverSkipped() {
        #expect(MealDisplay.resolve(status: .pending, phase: .past, isNext: false, isOverdue: false) == .noRecord)
        #expect(MealDisplay.resolve(status: .pending, phase: .future, isNext: false, isOverdue: false) == .planned)
        #expect(MealDisplay.resolve(status: .skipped, phase: .past, isNext: false, isOverdue: false) == .skipped)
        #expect(MealDisplay.resolve(status: .pending, phase: .today, isNext: true, isOverdue: false) == .next)
        #expect(MealDisplay.resolve(status: .pending, phase: .today, isNext: false, isOverdue: true) == .overdue)
    }

    @Test func timelineMarksNextAndOverdueAndOrdersExtras() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 9, 30) // café passou de 1 h; almoço é o próximo
        try store.logFood(name: "Chocolate", quantity: 20, unit: .grams, at: at(11, 8))
        let planned = try store.plannedMeals(on: now)
        let entries = try store.entries(on: now)
        let items = NutritionTimeline.build(planned: planned, entries: entries, date: now, now: now, calendar: calendar)
        #expect(items.count == 4)
        guard case .meal(let cafe) = items[0], case .extra = items[1], case .meal(let almoco) = items[2] else {
            Issue.record("ordem inesperada"); return
        }
        #expect(cafe.meal.id == meals[0].id && cafe.display == .overdue)
        #expect(almoco.display == .next)
    }

    @Test func pastDayShowsNoRecordAndFutureHasNoNext() throws {
        let (store, _, _) = try makeStore()
        let now = at(11, 12)
        let past = at(9, 12)
        let planned = try store.plannedMeals(on: past)
        let items = NutritionTimeline.build(planned: planned, entries: [], date: past, now: now, calendar: calendar)
        for case .meal(let row) in items { #expect(row.display == .noRecord) }
        let future = at(13, 12)
        let futureItems = NutritionTimeline.build(planned: try store.plannedMeals(on: future), entries: [], date: future, now: now, calendar: calendar)
        for case .meal(let row) in futureItems { #expect(row.display == .planned) }
    }

    @Test func linkedEntriesStayInsideMealAndSkippedMarkersAreHidden() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 20)
        try store.skipMeal(meals[0], on: now)
        try store.logFood(name: "Suco", quantity: 200, unit: .milliliters, at: at(11, 12, 45), meal: meals[1])
        let items = NutritionTimeline.build(planned: try store.plannedMeals(on: now), entries: try store.entries(on: now),
                                            date: now, now: now, calendar: calendar)
        #expect(items.count == 3) // sem extras: o marcador de pulo e o vinculado ficam na refeição
        guard case .meal(let cafe) = items[0], case .meal(let almoco) = items[1] else { Issue.record("ordem"); return }
        #expect(cafe.display == .skipped && cafe.entries.isEmpty)
        #expect(almoco.display == .adjusted && almoco.entries.count == 1)
    }

    @Test func adjustDraftScalesAndSubstitutes() throws {
        let (_, _, meals) = try makeStore()
        var drafts = AdjustDraftItem.drafts(for: meals[1], entries: [])
        #expect(drafts.count == 1 && drafts[0].included)
        drafts[0].quantity = 200
        #expect(drafts[0].values.kcal == 260)
        drafts[0].apply(drafts[0].substitutions[0])
        #expect(drafts[0].name == "Macarrão" && drafts[0].quantity == 80 && drafts[0].values.kcal == 120)
        drafts[0].quantity = 40
        #expect(drafts[0].values.kcal == 60)
    }

    @Test func adjustDraftFromExistingRegistryUnchecksMissingAndKeepsAdded() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 13)
        let logged = try store.logAdjustedMeal(meals[1], on: now, items: [
            (name: "Banana", quantity: 1, unit: .unit, values: NutrientValues(kcal: 90)),
        ])
        let drafts = AdjustDraftItem.drafts(for: meals[1], entries: logged)
        #expect(drafts.count == 2)
        #expect(drafts[0].name == "Arroz" && !drafts[0].included)
        #expect(drafts[1].name == "Banana" && drafts[1].included && drafts[1].isAdded)
    }

    @Test func storeExtensionsUpdateDuplicateAndWater() throws {
        let (store, context, meals) = try makeStore()
        let now = at(11, 10)
        let entry = try store.logFood(name: "Pão", quantity: 1, unit: .slice, at: now)
        try store.update(entry, name: "Pão integral", quantity: 2, unit: .slice, values: NutrientValues(kcal: 140),
                         estimation: .estimated, at: now, meal: meals[0], notes: "")
        #expect(entry.mealID == meals[0].id && entry.mealStatus == .adjusted && entry.kcal == 140)
        try store.update(entry, name: "Pão", quantity: 1, unit: .slice, values: NutrientValues(), estimation: .informed,
                         at: now, meal: nil, notes: "")
        #expect(entry.isOffPlan && entry.mealStatus == nil)

        try store.addWater(milliliters: 250, at: now)
        try store.addWater(milliliters: 250, at: now.addingTimeInterval(60))
        #expect(try store.removeLastWater(on: now))
        #expect(try store.waterTotal(on: now) == 250)

        let plan = try #require(try store.activePlan())
        let copy = try store.duplicate(plan)
        #expect(!copy.isActive && copy.sortedDays.first?.sortedMeals.count == 3)
        #expect(copy.sortedDays.first?.sortedMeals.first?.sortedItems.first?.substitutions.count == 1)
        let other = try #require(copy.sortedDays.first?.sortedMeals.first)
        #expect(other.id != meals[0].id)

        try store.switchActive(to: copy)
        #expect(try store.activePlan()?.id == copy.id)
        #expect(plan.isPrevious && !copy.isPrevious)
        _ = context
    }

    @Test func waterCupLayoutAndFormatting() {
        #expect(WaterCups.layout(total: 1_250, goal: 3_000) == (5, 12))
        #expect(WaterCups.layout(total: 0, goal: nil) == (0, 8))
        #expect(WaterCups.layout(total: 10_000, goal: 2_000).capacity == 24)
        #expect(NutritionFormat.clock(minutes: 750) == "12:30")
        #expect(NutritionFormat.dayTitle(at(12, 9), now: at(11, 9), calendar: calendar).hasPrefix("Amanhã"))
    }
}
