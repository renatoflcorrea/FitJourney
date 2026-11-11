import Foundation
import SwiftData

/// Refeição do plano no dia, com o status derivado das entradas.
struct PlannedMealState: Identifiable {
    let meal: Meal
    let status: MealStatus
    let scheduledAt: Date
    var id: UUID { meal.id }
}

/// Tudo que a tela do dia precisa, numa leitura só.
struct NutritionDayState {
    /// Plano cuja vigência cobre o dia (ativo ou arquivado).
    var plan: NutritionPlan?
    var activePlan: NutritionPlan?
    var planned: [PlannedMealState]
    var entries: [FoodEntry]
    var totals: DayNutritionTotals
    var waterTotal: Double
    var progress: [Nutrient: TargetProgress]
}

/// Item registrado ao ajustar uma refeição.
struct AdjustedMealItem {
    var name: String
    var quantity: Double
    var unit: FoodUnit
    var values: NutrientValues
    var estimation: EstimationSource = .informed
    var notes: String = ""
    /// Item do plano de onde veio (permite reabrir o ajuste casado, mesmo trocado por substituição).
    var plannedItemID: UUID?
}

/// Vínculo de uma entrada editada com uma refeição.
enum NutritionEntryLink {
    case none
    case meal(Meal)
    /// Mantém o vínculo atual (ex.: refeição que não está mais no plano).
    case keep
}

/// Dieta: plano ativo, registro do dia, totais, água e favoritos/recentes.
@MainActor
struct NutritionStore {
    let context: ModelContext
    var calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .autoupdatingCurrent) {
        self.context = context
        self.calendar = calendar
    }

    // MARK: Plano

    func activePlan() throws -> NutritionPlan? {
        var descriptor = FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.isActive })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Ativa a dieta e desativa as outras (exatamente uma ativa).
    func activate(_ plan: NutritionPlan) throws {
        let now = Date.now
        for other in try context.fetch(FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.isActive }))
        where other.persistentModelID != plan.persistentModelID {
            other.isActive = false
            other.updatedAt = now
        }
        plan.isActive = true
        plan.isArchived = false
        plan.updatedAt = now
        try context.save()
    }

    func delete(_ plan: NutritionPlan) throws {
        context.delete(plan)
        try context.save()
    }

    /// Plano cuja vigência cobre a data (ativo ou arquivado). Rascunhos nunca cobrem dia nenhum.
    func plan(covering date: Date) throws -> NutritionPlan? {
        let plans = try context.fetch(FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.isActive || $0.isArchived }))
        let candidates = plans.map {
            NutritionVigency.Candidate(id: $0.id, startDate: $0.startDate, endDate: $0.endDate,
                                       isActive: $0.isActive, updatedAt: $0.updatedAt)
        }
        guard let id = NutritionVigency.resolve(day: date, candidates: candidates, calendar: calendar) else { return nil }
        return plans.first { $0.id == id }
    }

    /// Refeições do plano vigente na data, por horário, com status. Fora de qualquer vigência → vazio.
    func plannedMeals(on date: Date) throws -> [PlannedMealState] {
        plannedMeals(on: date, plan: try plan(covering: date), entries: try entries(on: date))
    }

    func plannedMeals(on date: Date, plan: NutritionPlan?, entries: [FoodEntry]) -> [PlannedMealState] {
        guard let day = plan?.day(for: date, calendar: calendar) else { return [] }
        return day.sortedMeals.map { meal in
            let statuses = entries.filter { $0.mealID == meal.id }.map(\.mealStatus)
            return PlannedMealState(meal: meal, status: NutritionTotals.mealStatus(entryStatuses: statuses),
                                    scheduledAt: meal.time(on: date, calendar: calendar))
        }
    }

    /// Leitura única para a tela do dia.
    func dayState(on date: Date) throws -> NutritionDayState {
        let covering = try plan(covering: date)
        let entries = try entries(on: date)
        let totals = NutritionTotals.totals(entries.map(\.totalsEntry))
        let water = try waterTotal(on: date)
        let progress = covering.map { NutritionTotals.progress(totals: totals, waterMilliliters: water, targets: $0.targets) } ?? [:]
        return NutritionDayState(plan: covering, activePlan: try activePlan(),
                                 planned: plannedMeals(on: date, plan: covering, entries: entries),
                                 entries: entries, totals: totals, waterTotal: water, progress: progress)
    }

    /// Ativa `plan` ao trocar de dieta: a ativa anterior vai para o histórico (`isArchived`) com `endDate`
    /// = ontem; uma dieta anterior reativada passa a valer de hoje em diante.
    func switchActive(to plan: NutritionPlan, now: Date = .now) throws {
        if let current = try activePlan(), current.persistentModelID != plan.persistentModelID {
            current.endDate = NutritionVigency.outgoingEndDate(start: current.startDate, current: current.endDate,
                                                               now: now, calendar: calendar)
            current.isArchived = true
        }
        if plan.isArchived && !plan.isActive {
            plan.startDate = calendar.startOfDay(for: now)
            plan.endDate = nil
        }
        try activate(plan)
    }

    /// Cópia profunda (dias, refeições, itens, substituições), inativa e editável.
    @discardableResult
    func duplicate(_ plan: NutritionPlan) throws -> NutritionPlan {
        let copy = NutritionPlan(name: String(localized: "\(plan.name) (cópia)"), goal: plan.goal,
                                 startDate: .now, author: plan.author)
        copy.notes = plan.notes
        copy.targets = plan.targets
        context.insert(copy)
        for day in plan.sortedDays {
            let newDay = NutritionDay(name: day.name, weekdays: day.weekdays, sortIndex: day.sortIndex)
            context.insert(newDay)
            newDay.plan = copy
            for meal in day.sortedMeals { copyMeal(meal, into: newDay, name: meal.name) }
        }
        try context.save()
        return copy
    }

    /// Copia uma refeição (com itens) para o dia indicado.
    @discardableResult
    func copyMeal(_ meal: Meal, into day: NutritionDay, name: String) -> Meal {
        let next = ((day.meals ?? []).map(\.sortIndex).max() ?? -1) + 1
        let copy = Meal(name: name, minutesFromMidnight: meal.minutesFromMidnight, sortIndex: next,
                        reminderEnabled: meal.reminderEnabled)
        copy.notes = meal.notes
        context.insert(copy)
        copy.day = day
        for item in meal.sortedItems {
            let newItem = MealItem(name: item.name, quantity: item.quantity, unit: item.unit,
                                   values: item.values, sortIndex: item.sortIndex)
            newItem.notes = item.notes
            newItem.substitutions = item.substitutions.map {
                var sub = $0
                sub.id = UUID()
                return sub
            }
            context.insert(newItem)
            newItem.meal = copy
        }
        return copy
    }

    // MARK: Registro

    func entries(on date: Date) throws -> [FoodEntry] {
        let (start, end) = dayBounds(date)
        return try context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        ))
    }

    /// Marca a refeição como feita: 1 entrada por item, como planejado.
    @discardableResult
    func markMealDone(_ meal: Meal, on date: Date, at time: Date? = nil) throws -> [FoodEntry] {
        try clearMeal(meal, on: date, save: false)
        let when = entryTime(time, meal: meal, on: date)
        let entries = meal.sortedItems.map { item in
            let entry = FoodEntry(name: item.name, quantity: item.quantity, unit: item.unit, date: when, values: item.values)
            entry.mealID = meal.id
            entry.mealName = meal.name
            entry.mealStatus = .done
            entry.plannedItemID = item.id
            context.insert(entry)
            return entry
        }
        try context.save()
        return entries
    }

    /// Marca como pulada (um marcador sem valores, que não entra nos totais).
    func skipMeal(_ meal: Meal, on date: Date, at time: Date? = nil) throws {
        try clearMeal(meal, on: date, save: false)
        let marker = FoodEntry(name: meal.name, quantity: 0, unit: .serving, date: entryTime(time, meal: meal, on: date))
        marker.mealID = meal.id
        marker.mealName = meal.name
        marker.mealStatus = .skipped
        context.insert(marker)
        try context.save()
    }

    /// Ajuste: registra os itens efetivamente comidos para a refeição (substitui o registro anterior).
    @discardableResult
    func logAdjustedMeal(_ meal: Meal, on date: Date, items: [(name: String, quantity: Double, unit: FoodUnit, values: NutrientValues)],
                         at time: Date? = nil) throws -> [FoodEntry] {
        try logAdjustedMeal(meal, on: date, adjusted: items.map {
            AdjustedMealItem(name: $0.name, quantity: $0.quantity, unit: $0.unit, values: $0.values)
        }, at: time)
    }

    /// Ajuste preservando grau de estimativa, observação e o item do plano de origem.
    @discardableResult
    func logAdjustedMeal(_ meal: Meal, on date: Date, adjusted: [AdjustedMealItem], at time: Date? = nil) throws -> [FoodEntry] {
        try clearMeal(meal, on: date, save: false)
        let when = entryTime(time, meal: meal, on: date)
        let entries = adjusted.map { item in
            let entry = FoodEntry(name: item.name, quantity: item.quantity, unit: item.unit, date: when,
                                  values: item.values, estimation: item.estimation)
            entry.notes = item.notes
            entry.plannedItemID = item.plannedItemID
            entry.mealID = meal.id
            entry.mealName = meal.name
            entry.mealStatus = .adjusted
            context.insert(entry)
            return entry
        }
        try context.save()
        return entries
    }

    /// Volta a refeição para pendente (apaga as entradas dela no dia).
    func resetMeal(_ meal: Meal, on date: Date) throws {
        try clearMeal(meal, on: date, save: true)
    }

    /// Registro avulso ("+"). Sem `meal` = fora da dieta. Atualiza favoritos/recentes.
    @discardableResult
    func logFood(name: String, quantity: Double, unit: FoodUnit, values: NutrientValues = NutrientValues(),
                 estimation: EstimationSource = .informed, at date: Date = .now, meal: Meal? = nil,
                 notes: String = "") throws -> FoodEntry {
        let entry = FoodEntry(name: name, quantity: quantity, unit: unit, date: date, values: values, estimation: estimation)
        entry.notes = notes
        if let meal {
            entry.mealID = meal.id
            entry.mealName = meal.name
            // Avulso vinculado = registro parcial (sem status): a refeição só vira "ajustada" se já tinha registro.
        }
        context.insert(entry)
        try recordUsage(name: name, quantity: quantity, unit: unit, values: values, estimation: estimation, at: date)
        try context.save()
        return entry
    }

    func delete(_ entry: FoodEntry) throws {
        context.delete(entry)
        try context.save()
    }

    /// Edita uma entrada. Status segue `NutritionEntryRules.statusAfterEdit`.
    func update(_ entry: FoodEntry, name: String, quantity: Double, unit: FoodUnit, values: NutrientValues,
                estimation: EstimationSource, at date: Date, link: NutritionEntryLink, notes: String) throws {
        let oldMealID = entry.mealID
        let newMealID: UUID?
        switch link {
        case .none:
            newMealID = nil
            entry.mealID = nil
            entry.mealName = nil
        case .meal(let meal):
            newMealID = meal.id
            entry.mealID = meal.id
            entry.mealName = meal.name
        case .keep:
            newMealID = oldMealID
        }
        entry.mealStatus = NutritionEntryRules.statusAfterEdit(current: entry.mealStatus, oldMealID: oldMealID, newMealID: newMealID)
        entry.name = name
        entry.quantity = quantity
        entry.unit = unit
        entry.values = values
        entry.estimation = estimation
        entry.date = date
        entry.notes = notes
        entry.updatedAt = .now
        try context.save()
    }

    // MARK: Totais e água

    func totals(on date: Date) throws -> DayNutritionTotals {
        NutritionTotals.totals(try entries(on: date).map(\.totalsEntry))
    }

    func progress(on date: Date) throws -> [Nutrient: TargetProgress] {
        guard let covering = try plan(covering: date) else { return [:] }
        return NutritionTotals.progress(totals: try totals(on: date), waterMilliliters: try waterTotal(on: date),
                                        targets: covering.targets)
    }

    @discardableResult
    func addWater(milliliters: Double, at date: Date = .now) throws -> WaterLog {
        let log = WaterLog(milliliters: milliliters, date: date)
        context.insert(log)
        try context.save()
        return log
    }

    /// Remove o último copo/garrafa do dia (desfazer água). Retorna `false` se não há registro.
    @discardableResult
    func removeLastWater(on date: Date) throws -> Bool {
        let (start, end) = dayBounds(date)
        var descriptor = FetchDescriptor<WaterLog>(predicate: #Predicate { $0.date >= start && $0.date < end },
                                                   sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = try context.fetch(descriptor).first else { return false }
        context.delete(last)
        try context.save()
        return true
    }

    func waterTotal(on date: Date) throws -> Double {
        let (start, end) = dayBounds(date)
        return try context.fetch(FetchDescriptor<WaterLog>(predicate: #Predicate { $0.date >= start && $0.date < end }))
            .reduce(0) { $0 + $1.milliliters }
    }

    // MARK: Favoritos/recentes

    func recentFoods(limit: Int = 20) throws -> [FoodItem] {
        var descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate { $0.lastUsedAt != nil },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func favoriteFoods() throws -> [FoodItem] {
        try context.fetch(FetchDescriptor<FoodItem>(predicate: #Predicate { $0.isFavorite }, sortBy: [SortDescriptor(\.name)]))
    }

    /// Cria/atualiza o `FoodItem` de mesmo nome (sem diferenciar maiúsculas) com os valores da última porção.
    /// Dívida aceita: busca O(n) em todos os `FoodItem` (comparação sem acento não cabe em `#Predicate`);
    /// trocar por uma chave normalizada indexada se a lista crescer.
    private func recordUsage(name: String, quantity: Double, unit: FoodUnit, values: NutrientValues,
                             estimation: EstimationSource, at date: Date) throws {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let all = try context.fetch(FetchDescriptor<FoodItem>())
        let item = all.first { $0.name.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? { let new = FoodItem(name: key, servingQuantity: quantity, unit: unit); context.insert(new); return new }()
        // A porção só muda junto com valores novos, para manter "valores por porção" coerentes.
        if values.kcal != nil || values.protein != nil || values.carbs != nil || values.fat != nil {
            item.servingQuantity = quantity
            item.unit = unit
            item.values = values
            item.estimation = estimation
        }
        item.useCount += 1
        item.lastUsedAt = date
        item.updatedAt = date
    }

    /// Apaga o registro da refeição (feita/ajustada/pulada). Avulsos vinculados (registro parcial) ficam.
    private func clearMeal(_ meal: Meal, on date: Date, save: Bool) throws {
        let mealID: UUID? = meal.id
        let (start, end) = dayBounds(date)
        let existing = try context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.mealID == mealID && $0.mealStatusRaw != nil && $0.date >= start && $0.date < end }
        ))
        for entry in existing { context.delete(entry) }
        if save { try context.save() }
    }

    /// Horário da entrada da refeição sempre dentro do dia alvo: sem `time` → horário do plano;
    /// `time` em outro dia → mesma hora/minuto aplicada ao dia de `date` (as entradas não podem
    /// cair em outro dia, senão o status da refeição do dia ficaria errado).
    private func entryTime(_ time: Date?, meal: Meal, on date: Date) -> Date {
        guard let time else { return meal.time(on: date, calendar: calendar) }
        if calendar.isDate(time, inSameDayAs: date) { return time }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, of: date)
            ?? meal.time(on: date, calendar: calendar)
    }

    private func dayBounds(_ date: Date) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }
}
