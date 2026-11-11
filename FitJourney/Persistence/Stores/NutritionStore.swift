import Foundation
import SwiftData

/// Refeição do plano no dia, com o status derivado das entradas.
struct PlannedMealState: Identifiable {
    let meal: Meal
    let status: MealStatus
    let scheduledAt: Date
    var id: UUID { meal.id }
}

/// Dieta: plano ativo, registro do dia, totais, água e favoritos/recentes.
@MainActor
struct NutritionStore {
    let context: ModelContext
    var calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
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

    /// Refeições do plano ativo para a data, por horário, com status.
    func plannedMeals(on date: Date) throws -> [PlannedMealState] {
        guard let day = try activePlan()?.day(for: date, calendar: calendar) else { return [] }
        let entries = try entries(on: date)
        return day.sortedMeals.map { meal in
            let statuses = entries.filter { $0.mealID == meal.id }.map(\.mealStatus)
            return PlannedMealState(meal: meal, status: NutritionTotals.mealStatus(entryStatuses: statuses),
                                    scheduledAt: meal.time(on: date, calendar: calendar))
        }
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
            context.insert(entry)
            return entry
        }
        try context.save()
        return entries
    }

    /// Marca como pulada (um marcador sem valores, que não entra nos totais).
    func skipMeal(_ meal: Meal, on date: Date) throws {
        try clearMeal(meal, on: date, save: false)
        let marker = FoodEntry(name: meal.name, quantity: 0, unit: .serving, date: meal.time(on: date, calendar: calendar))
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
        try clearMeal(meal, on: date, save: false)
        let when = entryTime(time, meal: meal, on: date)
        let entries = items.map { item in
            let entry = FoodEntry(name: item.name, quantity: item.quantity, unit: item.unit, date: when, values: item.values)
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
            entry.mealStatus = .adjusted
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

    // MARK: Totais e água

    func totals(on date: Date) throws -> DayNutritionTotals {
        NutritionTotals.totals(try entries(on: date).map(\.totalsEntry))
    }

    func progress(on date: Date) throws -> [Nutrient: TargetProgress] {
        guard let plan = try activePlan() else { return [:] }
        return NutritionTotals.progress(totals: try totals(on: date), waterMilliliters: try waterTotal(on: date),
                                        targets: plan.targets)
    }

    @discardableResult
    func addWater(milliliters: Double, at date: Date = .now) throws -> WaterLog {
        let log = WaterLog(milliliters: milliliters, date: date)
        context.insert(log)
        try context.save()
        return log
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

    private func clearMeal(_ meal: Meal, on date: Date, save: Bool) throws {
        let mealID: UUID? = meal.id
        let (start, end) = dayBounds(date)
        let existing = try context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.mealID == mealID && $0.date >= start && $0.date < end }
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
