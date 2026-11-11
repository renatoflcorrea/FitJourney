import Foundation
import Observation
import SwiftData

/// Estado da tela "Dieta — dia". Lê do `NutritionStore` e recarrega depois de cada ação.
@MainActor
@Observable
final class NutritionDayModel {
    var date: Date = .now
    private(set) var now: Date = .now
    private(set) var plan: NutritionPlan?
    private(set) var timeline: [TimelineItem] = []
    private(set) var dayMeals: [Meal] = []
    private(set) var totals = DayNutritionTotals()
    private(set) var progress: [Nutrient: TargetProgress] = [:]
    private(set) var waterTotal: Double = 0
    private(set) var estimatedCount = 0
    var errorMessage: String?

    private var store: NutritionStore?
    private let calendar: Calendar = .current

    var phase: NutritionDayPhase { NutritionDayPhase(date: date, now: now, calendar: calendar) }
    var hasPlan: Bool { plan != nil }
    var targets: NutritionTargets { plan?.targets ?? NutritionTargets() }
    var title: String { NutritionFormat.dayTitle(date, now: now, calendar: calendar) }
    var hasMealsPlanned: Bool { !dayMeals.isEmpty }
    /// Dia em que o "+" registra: o dia exibido, ou hoje se for futuro.
    var registrationDate: Date { phase == .future ? now : date }

    func attach(_ context: ModelContext) {
        guard store == nil else { return }
        store = NutritionStore(context: context, calendar: calendar)
        reload()
    }

    func reload() {
        guard let store else { return }
        now = .now
        do {
            plan = try store.activePlan()
            let planned = try store.plannedMeals(on: date)
            let entries = try store.entries(on: date)
            dayMeals = planned.map(\.meal)
            timeline = NutritionTimeline.build(planned: planned, entries: entries, date: date, now: now, calendar: calendar)
            totals = NutritionTotals.totals(entries.map(\.totalsEntry))
            waterTotal = try store.waterTotal(on: date)
            progress = NutritionTotals.progress(totals: totals, waterMilliliters: waterTotal, targets: plan?.targets ?? NutritionTargets())
            estimatedCount = entries.filter { $0.mealStatus != .skipped && $0.estimation != .informed }.count
        } catch {
            fail(error)
        }
    }

    func shift(by days: Int) {
        date = calendar.date(byAdding: .day, value: days, to: date) ?? date
        reload()
    }

    func jump(to newDate: Date) {
        date = newDate
        reload()
    }

    // MARK: Ações

    func markDone(_ meal: Meal) { perform { try $0.markMealDone(meal, on: date) } }
    func skip(_ meal: Meal) { perform { try $0.skipMeal(meal, on: date) } }
    func undo(_ meal: Meal) { perform { try $0.resetMeal(meal, on: date) } }
    func delete(_ entry: FoodEntry) { perform { try $0.delete(entry) } }
    func addCup() { perform { try $0.addWater(milliliters: WaterCups.cupMilliliters, at: waterDate) } }
    func removeCup() { perform { try $0.removeLastWater(on: date) } }

    func saveAdjusted(_ meal: Meal, items: [AdjustDraftItem]) {
        let included = items.filter(\.included).map { (name: $0.name, quantity: $0.quantity, unit: $0.unit, values: $0.values) }
        guard !included.isEmpty else { return }
        perform { try $0.logAdjustedMeal(meal, on: date, items: included) }
    }

    /// Entradas atuais da refeição no dia (para pré-preencher "Ajustar").
    func entries(for meal: Meal) -> [FoodEntry] {
        for case .meal(let row) in timeline where row.id == meal.id { return row.entries }
        return []
    }

    private var waterDate: Date {
        calendar.isDate(date, inSameDayAs: now) ? now : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date)
    }

    private func perform<T>(_ work: (NutritionStore) throws -> T) {
        guard let store else { return }
        do { _ = try work(store) } catch { fail(error) }
        reload()
    }

    private func fail(_ error: Error) {
        errorMessage = String(localized: "Não foi possível salvar. Tente de novo. Nada foi perdido.")
    }
}
