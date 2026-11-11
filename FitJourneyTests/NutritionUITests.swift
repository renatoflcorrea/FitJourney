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
        let plan = NutritionPlan(name: "P", startDate: at(1, 0)) // vigente desde 1/nov
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

    // MARK: Fase do dia e linha do tempo

    @Test func pastPendingIsNoRecordNeverSkipped() {
        #expect(MealDisplay.resolve(status: .pending, phase: .past, isNext: false, isOverdue: false) == .noRecord)
        #expect(MealDisplay.resolve(status: .pending, phase: .future, isNext: false, isOverdue: false) == .planned)
        #expect(MealDisplay.resolve(status: .skipped, phase: .past, isNext: false, isOverdue: false) == .skipped)
        #expect(MealDisplay.resolve(status: .pending, phase: .today, isNext: true, isOverdue: false) == .next)
        #expect(MealDisplay.resolve(status: .pending, phase: .today, isNext: false, isOverdue: true) == .overdue)
    }

    @Test func dayPhase() {
        #expect(NutritionDayPhase(date: at(11, 23), now: at(11, 1), calendar: calendar) == .today)
        #expect(NutritionDayPhase(date: at(10, 23), now: at(11, 1), calendar: calendar) == .past)
        #expect(NutritionDayPhase(date: at(12, 0), now: at(11, 23), calendar: calendar) == .future)
    }

    @Test func timelineMarksNextAndOverdueAndOrdersExtras() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 9, 30) // café passou de 1 h; almoço é o próximo
        try store.logFood(name: "Chocolate", quantity: 20, unit: .grams, at: at(11, 8))
        let state = try store.dayState(on: now)
        let items = NutritionTimeline.build(planned: state.planned, entries: state.entries, date: now, now: now, calendar: calendar)
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
        let items = NutritionTimeline.build(planned: try store.plannedMeals(on: past), entries: [], date: past, now: now, calendar: calendar)
        #expect(items.count == 3)
        for case .meal(let row) in items { #expect(row.display == .noRecord) }
        let future = at(13, 12)
        let futureItems = NutritionTimeline.build(planned: try store.plannedMeals(on: future), entries: [], date: future, now: now, calendar: calendar)
        for case .meal(let row) in futureItems { #expect(row.display == .planned) }
    }

    @Test func skippedMarkersAreHiddenAndLinkedEntriesStayInsideMeal() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 20)
        try store.skipMeal(meals[0], on: now)
        try store.logFood(name: "Suco", quantity: 200, unit: .milliliters, at: at(11, 12, 45), meal: meals[1])
        let state = try store.dayState(on: now)
        let items = NutritionTimeline.build(planned: state.planned, entries: state.entries, date: now, now: now, calendar: calendar)
        #expect(items.count == 3) // sem extras
        guard case .meal(let cafe) = items[0], case .meal(let almoco) = items[1] else { Issue.record("ordem"); return }
        #expect(cafe.display == .skipped && cafe.entries.isEmpty && cafe.kcalSummary == nil)
        // Avulso vinculado a refeição sem registro = parcial: a refeição segue pendente (regra documentada).
        #expect(almoco.status == .pending && almoco.entries.count == 1)
    }

    @Test func orphanMealEntryBecomesExtraWithSnapshotName() throws {
        let (store, context, meals) = try makeStore()
        let now = at(11, 20)
        let entry = try store.logFood(name: "Suco", quantity: 200, unit: .milliliters, at: at(11, 12, 45), meal: meals[1])
        context.delete(meals[1])
        try context.save()
        let state = try store.dayState(on: now)
        let items = NutritionTimeline.build(planned: state.planned, entries: state.entries, date: now, now: now, calendar: calendar)
        let extras = items.compactMap { item -> FoodEntry? in if case .extra(let e) = item { e } else { nil } }
        #expect(extras.map(\.id) == [entry.id])
        #expect(extras.first?.mealID != nil && extras.first?.mealName == "Almoço")
    }

    // MARK: Vigência

    @Test func vigencyResolvePicksLatestStartAndPrefersActive() {
        let a = NutritionVigency.Candidate(id: UUID(), startDate: at(1, 0), endDate: at(9, 0), isActive: false, updatedAt: at(10, 0))
        let b = NutritionVigency.Candidate(id: UUID(), startDate: at(10, 0), endDate: nil, isActive: true, updatedAt: at(10, 0))
        #expect(NutritionVigency.resolve(day: at(9, 12), candidates: [a, b], calendar: calendar) == a.id)
        #expect(NutritionVigency.resolve(day: at(10, 12), candidates: [a, b], calendar: calendar) == b.id)
        #expect(NutritionVigency.resolve(day: at(11, 12), candidates: [a, b], calendar: calendar) == b.id)
        #expect(NutritionVigency.resolve(day: at(31, 12), candidates: [a], calendar: calendar) == nil) // depois do fim
        // arquivado sem endDate (dado antigo) termina em updatedAt
        let old = NutritionVigency.Candidate(id: UUID(), startDate: at(1, 0), endDate: nil, isActive: false, updatedAt: at(5, 0))
        #expect(NutritionVigency.resolve(day: at(5, 20), candidates: [old], calendar: calendar) == old.id)
        #expect(NutritionVigency.resolve(day: at(6, 1), candidates: [old], calendar: calendar) == nil)
        // empate de início: ativo vence
        let x = NutritionVigency.Candidate(id: UUID(), startDate: at(3, 0), endDate: nil, isActive: false, updatedAt: at(20, 0))
        let y = NutritionVigency.Candidate(id: UUID(), startDate: at(3, 0), endDate: nil, isActive: true, updatedAt: at(1, 0))
        #expect(NutritionVigency.resolve(day: at(4, 0), candidates: [x, y], calendar: calendar) == y.id)
    }

    @Test func outgoingEndDateIsYesterdayButNeverBeforeStart() {
        let now = at(11, 10)
        #expect(NutritionVigency.outgoingEndDate(start: at(1, 0), current: nil, now: now, calendar: calendar) == at(10, 0))
        #expect(NutritionVigency.outgoingEndDate(start: at(1, 0), current: at(5, 0), now: now, calendar: calendar) == at(5, 0))
        #expect(NutritionVigency.outgoingEndDate(start: at(1, 0), current: at(30, 0), now: now, calendar: calendar) == at(10, 0))
        #expect(NutritionVigency.outgoingEndDate(start: at(11, 0), current: nil, now: now, calendar: calendar) == at(11, 0))
    }

    @Test func storeOnlyResolvesMealsInsideVigency() throws {
        let (store, _, _) = try makeStore()
        #expect(try store.plannedMeals(on: at(11, 12)).count == 3)
        #expect(try store.plannedMeals(on: at(1, 12)).count == 3)
        #expect(try store.plannedMeals(on: at(1, 12).addingTimeInterval(-86_400)).isEmpty) // 31/out: antes do início
        let state = try store.dayState(on: at(1, 12).addingTimeInterval(-86_400))
        #expect(state.plan == nil && state.activePlan != nil && state.planned.isEmpty)
    }

    @Test func switchActiveEndsOutgoingPlanYesterday() throws {
        let (store, context, meals) = try makeStore()
        let old = try #require(try store.activePlan())
        let next = NutritionPlan(name: "N", startDate: at(11, 0))
        context.insert(next)
        let day = NutritionDay(name: "Todos")
        context.insert(day)
        day.plan = next
        let meal = Meal(name: "Única", minutesFromMidnight: 600)
        context.insert(meal)
        meal.day = day

        try store.switchActive(to: next, now: at(11, 9))
        #expect(old.isArchived && !old.isActive)
        #expect(old.endDate == at(10, 0))
        // 10/nov: plano antigo; 11/nov: o novo. Dia sem cobertura nenhuma: só avulsos.
        #expect(try store.plannedMeals(on: at(10, 12)).count == 3)
        #expect(try store.plannedMeals(on: at(11, 12)).map(\.meal.id) == [meal.id])
        #expect(try store.plan(covering: at(10, 12))?.id == old.id)
        _ = meals
        // Reativar o antigo: passa a valer de hoje em diante, sem endDate.
        try store.switchActive(to: old, now: at(15, 9))
        #expect(old.endDate == nil && old.startDate == at(15, 0) && old.isActive)
        #expect(next.endDate == at(14, 0) && next.isArchived)
    }

    // MARK: Totais, estado parcial e regras de edição

    @Test func plannedKcalSummaryFlagsPartialSums() throws {
        let (_, context, meals) = try makeStore()
        let meal = meals[1]
        #expect(meal.plannedKcalSummary == PlannedKcalSummary(kcal: 130, itemsWithoutKcal: 0, itemCount: 1))
        let extra = MealItem(name: "Salada", quantity: 1, unit: .serving, sortIndex: 1)
        context.insert(extra)
        extra.meal = meal
        let summary = meal.plannedKcalSummary
        #expect(summary.kcal == 130 && summary.itemsWithoutKcal == 1 && summary.isPartial)
        #expect(NutritionFormat.kcal(summary) == "≥ 130 kcal")
        let empty = Meal(name: "Vazia", minutesFromMidnight: 0)
        #expect(empty.plannedKcalSummary.kcal == nil)
    }

    @Test func entryStatusRulesOnEdit() {
        let a = UUID(), b = UUID()
        #expect(NutritionEntryRules.statusAfterEdit(current: .done, oldMealID: a, newMealID: a) == .adjusted)
        #expect(NutritionEntryRules.statusAfterEdit(current: .adjusted, oldMealID: a, newMealID: a) == .adjusted)
        #expect(NutritionEntryRules.statusAfterEdit(current: .done, oldMealID: a, newMealID: b) == .adjusted)
        #expect(NutritionEntryRules.statusAfterEdit(current: nil, oldMealID: nil, newMealID: a) == nil)
        #expect(NutritionEntryRules.statusAfterEdit(current: .done, oldMealID: a, newMealID: nil) == nil)
    }

    @Test func storeUpdateKeepsOrphanLinkAndAppliesRules() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 10)
        let entry = try store.logFood(name: "Pão", quantity: 1, unit: .slice, at: now)
        try store.update(entry, name: "Pão integral", quantity: 2, unit: .slice, values: NutrientValues(kcal: 140),
                         estimation: .estimated, at: now, link: .meal(meals[0]), notes: "")
        #expect(entry.mealID == meals[0].id && entry.mealStatus == nil && entry.kcal == 140 && entry.estimation == .estimated)
        // done → adjusted ao editar; vínculo preservado com .keep
        let done = try store.markMealDone(meals[1], on: now).first!
        try store.update(done, name: done.name, quantity: 90, unit: .grams, values: done.values, estimation: .informed,
                         at: done.date, link: .keep, notes: "")
        #expect(done.mealID == meals[1].id && done.mealStatus == .adjusted)
        try store.update(entry, name: "Pão", quantity: 1, unit: .slice, values: NutrientValues(), estimation: .informed,
                         at: now, link: .none, notes: "")
        #expect(entry.isOffPlan && entry.mealStatus == nil)
    }

    @Test func partialLinkedEntrySurvivesUndoAndMakesDoneMealAdjusted() throws {
        let (store, _, meals) = try makeStore()
        let day = at(11, 13)
        try store.logFood(name: "Suco", quantity: 200, unit: .milliliters, at: day, meal: meals[1])
        #expect(try store.plannedMeals(on: day)[1].status == .pending)
        try store.markMealDone(meals[1], on: day)
        #expect(try store.plannedMeals(on: day)[1].status == .adjusted) // feita + extra
        try store.resetMeal(meals[1], on: day)
        #expect(try store.entries(on: day).count == 1) // o parcial continua
        #expect(try store.plannedMeals(on: day)[1].status == .pending)
    }

    @Test func storeExtensionsWaterAndDuplicate() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 10)
        try store.addWater(milliliters: 250, at: now)
        try store.addWater(milliliters: 250, at: now.addingTimeInterval(60))
        #expect(try store.removeLastWater(on: now))
        #expect(try store.waterTotal(on: now) == 250)
        #expect(try store.removeLastWater(on: at(5, 10)) == false)

        let plan = try #require(try store.activePlan())
        let copy = try store.duplicate(plan)
        #expect(!copy.isActive && copy.sortedDays.first?.sortedMeals.count == 3)
        #expect(copy.sortedDays.first?.sortedMeals.first?.sortedItems.first?.substitutions.count == 1)
        #expect(copy.sortedDays.first?.sortedMeals.first?.id != meals[0].id)
        #expect(!copy.isPrevious)
    }

    @Test func timesAreNowTodayAndPlannedInPastDays() throws {
        #expect(NutritionLogTime.entryTime(phase: .today, now: at(11, 14, 5), existing: nil) == at(11, 14, 5))
        #expect(NutritionLogTime.entryTime(phase: .past, now: at(11, 14, 5), existing: nil) == nil)
        #expect(NutritionLogTime.entryTime(phase: .past, now: at(11, 14, 5), existing: at(9, 12)) == at(9, 12))
        let (store, _, meals) = try makeStore()
        let entries = try store.markMealDone(meals[1], on: at(9, 18), at: nil) // dia passado: horário do plano
        #expect(NutritionFormat.clock(entries[0].date, calendar: calendar) == "12:30")
        try store.skipMeal(meals[0], on: at(11, 18), at: at(11, 15, 40))
        let marker = try store.entries(on: at(11, 18)).first { $0.mealStatus == .skipped }
        #expect(NutritionFormat.clock(try #require(marker).date, calendar: calendar) == "15:40")
    }

    // MARK: Ajustar

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

    @Test func setKcalRescalesMacrosTogether() {
        var item = AdjustDraftItem(id: UUID(), name: "X", quantity: 100, unit: .grams,
                                   baseValues: NutrientValues(kcal: 200, protein: 10, carbs: 20), baseQuantity: 100,
                                   included: true, substitutions: [], isAdded: true)
        item.setKcal(400)
        #expect(item.values.kcal == 400 && item.values.protein == 20 && item.values.carbs == 40)
        var unknown = AdjustDraftItem(id: UUID(), name: "Y", quantity: 1, unit: .unit, baseValues: NutrientValues(protein: 5),
                                      baseQuantity: 1, included: true, substitutions: [], isAdded: true)
        unknown.setKcal(90)
        #expect(unknown.values.kcal == 90 && unknown.values.protein == 5)
    }

    @Test func adjustReopensMatchedToPlannedItemEvenWhenSubstituted() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 13)
        var drafts = AdjustDraftItem.drafts(for: meals[1], entries: [])
        drafts[0].apply(drafts[0].substitutions[0])
        drafts[0].estimation = .estimated
        drafts[0].notes = "no prato"
        let logged = try store.logAdjustedMeal(meals[1], on: now, adjusted: AdjustDraftItem.adjustedItems(drafts))
        #expect(logged[0].plannedItemID == meals[1].sortedItems[0].id && logged[0].estimation == .estimated && logged[0].notes == "no prato")
        let reopened = AdjustDraftItem.drafts(for: meals[1], entries: logged)
        #expect(reopened.count == 1 && !reopened[0].isAdded && reopened[0].name == "Macarrão" && reopened[0].included)
        #expect(reopened[0].estimation == .estimated && reopened[0].notes == "no prato")
        #expect(reopened[0].substitutions.count == 1) // pode trocar de novo
        #expect(!AdjustDraftItem.matchesPlan(reopened, meal: meals[1]))
    }

    @Test func adjustDraftFromExistingRegistryUnchecksMissingAndKeepsAdded() throws {
        let (store, _, meals) = try makeStore()
        let logged = try store.logAdjustedMeal(meals[1], on: at(11, 13), items: [
            (name: "Banana", quantity: 1, unit: .unit, values: NutrientValues(kcal: 90)),
        ])
        let drafts = AdjustDraftItem.drafts(for: meals[1], entries: logged)
        #expect(drafts.count == 2)
        #expect(drafts[0].name == "Arroz" && !drafts[0].included)
        #expect(drafts[1].name == "Banana" && drafts[1].included && drafts[1].isAdded)
    }

    @Test func savingUnchangedMatchesPlan() throws {
        let (_, _, meals) = try makeStore()
        var drafts = AdjustDraftItem.drafts(for: meals[1], entries: [])
        #expect(AdjustDraftItem.matchesPlan(drafts, meal: meals[1])) // sem mudança = "Feita"
        drafts[0].quantity = 90
        #expect(!AdjustDraftItem.matchesPlan(drafts, meal: meals[1]))
        drafts[0].quantity = 100
        drafts[0].included = false
        #expect(!AdjustDraftItem.matchesPlan(drafts, meal: meals[1]))
    }

    // MARK: Entrada numérica

    @Test func numericParsing() {
        func v(_ t: String, _ f: NutritionInput.Field = .kcal) -> NutritionInput.ParseResult { NutritionInput.parse(t, field: f) }
        #expect(v("") == .empty)
        #expect(v("   ") == .empty)
        #expect(v("2.600") == .value(2_600))
        #expect(v("2600") == .value(2_600))
        #expect(v("1.234,5") == .value(1_234.5))
        #expect(v("1,234.5") == .value(1_234.5))
        #expect(v("12,5") == .value(12.5))
        #expect(v("12.5") == .value(12.5))
        #expect(v("0.250") == .value(0.25))
        #expect(v("1.234.567", .grams) == .invalid) // acima do teto
        #expect(v("abc") == .invalid)
        #expect(v("1,2,3") == .invalid)
        #expect(v("-5") == .invalid)
        #expect(v("20001") == .invalid)
        #expect(v("20000") == .value(20_000))
        #expect(v("10001", .milliliters) == .invalid)
        #expect(v("5001", .grams) == .invalid)
        #expect(v("5,") == .value(5)) // digitação em andamento
    }

    @Test func numericRoundTrip() {
        for value in [0, 1, 12.5, 130, 2_600, 3_000, 0.5, 4_999.5] as [Double] {
            #expect(NutritionInput.parse(NutritionInput.format(value), maximum: 20_000) == .value(value))
        }
        #expect(NutritionInput.format(nil) == "")
        #expect(!NutritionInput.format(2_600).contains(" ") && NutritionInput.format(2_600) == "2600")
    }

    // MARK: Água, estimativa, formatação

    @Test func waterCupLayoutAndFormatting() {
        #expect(WaterCups.layout(total: 1_250, goal: 3_000) == (5, 12))
        #expect(WaterCups.layout(total: 0, goal: nil) == (0, 8))
        #expect(WaterCups.layout(total: 0, goal: 0) == (0, 8)) // meta 0 = ausente
        #expect(WaterCups.layout(total: 10_000, goal: 2_000).capacity == 24)
        #expect(NutritionFormat.clock(minutes: 750) == "12:30")
        #expect(NutritionFormat.dayTitle(at(12, 9), now: at(11, 9), calendar: calendar).hasPrefix("Amanhã"))
    }

    @Test func estimatedCountIgnoresInformedAndSkipped() throws {
        let (store, _, meals) = try makeStore()
        let now = at(11, 10)
        try store.logFood(name: "A", quantity: 1, unit: .unit, estimation: .estimated, at: now)
        try store.logFood(name: "B", quantity: 1, unit: .unit, estimation: .ai, at: now)
        try store.logFood(name: "C", quantity: 1, unit: .unit, at: now)
        try store.skipMeal(meals[0], on: now)
        #expect(NutritionEstimates.count(in: try store.entries(on: now)) == 2)
    }

    @Test func progressIgnoresZeroTargets() {
        let totals = DayNutritionTotals(kcal: 500, protein: 40)
        let progress = NutritionTotals.progress(totals: totals, waterMilliliters: 0,
                                                targets: NutritionTargets(kcal: 0, protein: 100, waterMilliliters: 0))
        #expect(progress.keys.map(\.rawValue) == ["protein"])
    }
}
