import Foundation
import SwiftData

// Extensões do store usadas só pela UI da dieta.
// TODO(supervisor): mover para Persistence/Stores/NutritionStore.swift (e cobrir com testes de store).

@MainActor
extension NutritionStore {
    /// Atualiza uma entrada existente (editar registro). `meal == nil` = fora da dieta.
    func update(_ entry: FoodEntry, name: String, quantity: Double, unit: FoodUnit, values: NutrientValues,
                estimation: EstimationSource, at date: Date, meal: Meal?, notes: String) throws {
        entry.name = name
        entry.quantity = quantity
        entry.unit = unit
        entry.values = values
        entry.estimation = estimation
        entry.date = date
        entry.notes = notes
        if let meal {
            entry.mealID = meal.id
            entry.mealName = meal.name
            if entry.mealStatus == nil { entry.mealStatus = .adjusted }
        } else {
            entry.mealID = nil
            entry.mealName = nil
            entry.mealStatus = nil
        }
        entry.updatedAt = .now
        try context.save()
    }

    /// Remove o último copo/garrafa do dia (desfazer água). Retorna `false` se não há registro.
    @discardableResult
    func removeLastWater(on date: Date) throws -> Bool {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var descriptor = FetchDescriptor<WaterLog>(predicate: #Predicate { $0.date >= start && $0.date < end },
                                                   sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = try context.fetch(descriptor).first else { return false }
        context.delete(last)
        try context.save()
        return true
    }

    /// Todos os planos: ativo primeiro, depois do mais recente ao mais antigo.
    func allPlans() throws -> [NutritionPlan] {
        try context.fetch(FetchDescriptor<NutritionPlan>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
    }

    /// Ativa `plan`; a dieta ativa anterior vai para o histórico (`isArchived`, somente leitura na UI).
    func switchActive(to plan: NutritionPlan) throws {
        if let current = try activePlan(), current.persistentModelID != plan.persistentModelID {
            current.isArchived = true
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
                var s = $0
                s.id = UUID()
                return s
            }
            context.insert(newItem)
            newItem.meal = copy
        }
        return copy
    }
}
