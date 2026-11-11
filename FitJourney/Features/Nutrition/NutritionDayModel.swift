import Foundation
import Observation
import SwiftData
import SwiftUI

/// Estado da tela "Dieta — dia". Lê do `NutritionStore` (uma leitura por recarga) e recarrega depois de cada ação.
@MainActor
@Observable
final class NutritionDayModel {
    /// Relação do dia com os planos.
    enum Coverage {
        /// Um plano vigente cobre o dia.
        case covered
        /// Nenhum plano ativo nem arquivado cobre o dia e não há plano ativo: convite para criar a dieta.
        case noPlan
        /// Há plano ativo, mas o dia está fora da vigência dele: só registros avulsos.
        case outsideVigency(activeName: String)
    }

    var date: Date = .now
    private(set) var now: Date = .now
    private(set) var plan: NutritionPlan?
    private(set) var coverage: Coverage = .noPlan
    private(set) var timeline: [TimelineItem] = []
    private(set) var dayMeals: [Meal] = []
    private(set) var totals = DayNutritionTotals()
    private(set) var waterTotal: Double = 0
    private(set) var estimatedCount = 0
    var errorMessage: String?

    private var store: NutritionStore?
    private let calendar: Calendar = .autoupdatingCurrent

    var phase: NutritionDayPhase { NutritionDayPhase(date: date, now: now, calendar: calendar) }
    var hasPlan: Bool { plan != nil }
    var targets: NutritionTargets { plan?.targets ?? NutritionTargets() }
    var title: String { NutritionFormat.dayTitle(date, now: now, calendar: calendar) }
    var hasMealsPlanned: Bool { !dayMeals.isEmpty }
    /// Dia em que o "+" registra: o dia exibido, ou hoje se for futuro (a sheet mostra o dia).
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
            let state = try store.dayState(on: date)
            plan = state.plan
            if state.plan != nil {
                coverage = .covered
            } else if let active = state.activePlan {
                coverage = .outsideVigency(activeName: active.name)
            } else {
                coverage = .noPlan
            }
            dayMeals = state.planned.map(\.meal)
            timeline = NutritionTimeline.build(planned: state.planned, entries: state.entries, date: date, now: now, calendar: calendar)
            totals = state.totals
            waterTotal = state.waterTotal
            estimatedCount = NutritionEstimates.count(in: state.entries)
        } catch {
            fail()
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

    /// Virou o dia (meia-noite): se a tela mostrava "hoje", acompanha.
    func dayChanged() {
        if calendar.isDate(date, inSameDayAs: now) { date = .now }
        reload()
    }

    // MARK: Ações

    func markDone(_ meal: Meal) {
        if perform({ store, time in try store.markMealDone(meal, on: date, at: time) }) {
            announce(String(localized: "\(meal.name) marcada como feita"))
        }
    }

    func skip(_ meal: Meal) {
        if perform({ store, time in try store.skipMeal(meal, on: date, at: time) }) {
            announce(String(localized: "\(meal.name) pulada"))
        }
    }

    func undo(_ meal: Meal) {
        if perform({ store, _ in try store.resetMeal(meal, on: date) }) {
            announce(String(localized: "\(meal.name) voltou para pendente"))
        }
    }

    func delete(_ entry: FoodEntry) { perform { store, _ in try store.delete(entry) } }
    func addCup() { perform { store, _ in try store.addWater(milliliters: WaterCups.cupMilliliters, at: waterDate) } }
    func removeCup() { perform { store, _ in try store.removeLastWater(on: date) } }

    /// Salvar o ajuste: igual ao plano = "Feita"; sem mudança em relação ao registro = nada; senão "Ajustada".
    func saveAdjusted(_ meal: Meal, drafts: [AdjustDraftItem]) {
        let row = mealRow(meal)
        let status = row?.status ?? .pending
        let original = AdjustDraftItem.drafts(for: meal, entries: row?.entries ?? [])
        if AdjustDraftItem.matchesPlan(drafts, meal: meal) {
            if status != .done { markDone(meal) }
            return
        }
        if status == .adjusted && drafts == original { return }
        let items = AdjustDraftItem.adjustedItems(drafts)
        guard !items.isEmpty else { return }
        let existing = row?.loggedAt
        if perform({ store, time in try store.logAdjustedMeal(meal, on: date, adjusted: items, at: existing ?? time) }) {
            announce(String(localized: "\(meal.name) registrada com ajustes"))
        }
    }

    /// Entradas atuais da refeição no dia (para pré-preencher "Ajustar").
    func entries(for meal: Meal) -> [FoodEntry] { mealRow(meal)?.entries ?? [] }

    private func mealRow(_ meal: Meal) -> MealRowModel? {
        for case .meal(let row) in timeline where row.id == meal.id { return row }
        return nil
    }

    private var waterDate: Date {
        calendar.isDate(date, inSameDayAs: now) ? now : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date)
    }

    /// Hoje grava o instante atual; dia passado mantém o horário planejado da refeição.
    private var logTime: Date? { NutritionLogTime.entryTime(phase: phase, now: .now, existing: nil) }

    @discardableResult
    private func perform<T>(_ work: (NutritionStore, Date?) throws -> T) -> Bool {
        guard let store else { return false }
        var ok = true
        do { _ = try work(store, logTime) } catch { fail(); ok = false }
        reload()
        return ok
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func fail() {
        errorMessage = String(localized: "Não foi possível salvar. Tente de novo. Nada foi perdido.")
    }
}
