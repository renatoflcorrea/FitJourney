import Foundation
import Testing
@testable import FitJourney

struct NutritionRulesTests {
    @Test func totalsSumKnownValuesAndCountMissingKcal() {
        let totals = NutritionTotals.totals([
            .init(values: NutrientValues(kcal: 200, protein: 20, carbs: 10, fat: 5), mealStatus: .done),
            .init(values: NutrientValues(kcal: nil, protein: 3)),
            .init(values: NutrientValues()),
            .init(values: NutrientValues(kcal: 999, protein: 99), mealStatus: .skipped), // marcador de pulo
        ])
        #expect(totals.kcal == 200)
        #expect(totals.protein == 23)
        #expect(totals.entryCount == 3)
        #expect(totals.itemsWithoutKcal == 2)
    }

    @Test func progressOnlyForDefinedTargets() {
        let totals = DayNutritionTotals(kcal: 1_300, protein: 200, entryCount: 3)
        let progress = NutritionTotals.progress(totals: totals, waterMilliliters: 750,
                                                targets: NutritionTargets(kcal: 2_600, protein: 160, carbs: 0, waterMilliliters: 3_000))
        #expect(progress.keys.sorted { $0.rawValue < $1.rawValue } == [.kcal, .protein, .water])
        #expect(progress[.kcal]?.fraction == 0.5)
        #expect(progress[.kcal]?.remaining == 1_300)
        #expect(progress[.protein]?.remaining == 0)
        #expect(progress[.water]?.fraction == 0.25)
    }

    @Test func mealStatusDerivation() {
        #expect(NutritionTotals.mealStatus(entryStatuses: []) == .pending)
        #expect(NutritionTotals.mealStatus(entryStatuses: [.done, .done]) == .done)
        #expect(NutritionTotals.mealStatus(entryStatuses: [.done, .adjusted]) == .adjusted)
        #expect(NutritionTotals.mealStatus(entryStatuses: [nil]) == .pending) // avulso vinculado = registro parcial
        #expect(NutritionTotals.mealStatus(entryStatuses: [.done, nil]) == .adjusted)
        #expect(NutritionTotals.mealStatus(entryStatuses: [.skipped]) == .skipped)
    }

    @Test func nutritionDayResolverPrefersSpecificWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let thursday = wednesday.addingTimeInterval(86_400)
        let all = UUID(), training = UUID()
        let days = [
            NutritionDayResolver.DayInfo(id: all, sortIndex: 0, weekdays: []),
            NutritionDayResolver.DayInfo(id: training, sortIndex: 1, weekdays: [.monday, .wednesday, .friday]),
        ]
        #expect(NutritionDayResolver.day(for: wednesday, days: days, calendar: cal) == training)
        #expect(NutritionDayResolver.day(for: thursday, days: days, calendar: cal) == all)
        #expect(NutritionDayResolver.day(for: thursday, days: [days[1]], calendar: cal) == nil)
    }

    @Test func scaling() {
        let v = NutrientValues(kcal: 100, protein: 10).scaled(by: 1.5)
        #expect(v.kcal == 150 && v.protein == 15 && v.carbs == nil)
    }
}
