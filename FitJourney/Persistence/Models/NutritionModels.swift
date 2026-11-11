import Foundation
import SwiftData

// Dieta (SPEC §5). Mesmas regras CloudKit dos modelos de treino.

@Model
final class NutritionPlan {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var goal: String = ""
    var startDate: Date = Date()
    var endDate: Date?
    var authorRaw: String = NutritionPlanAuthor.me.rawValue
    var isActive: Bool = false
    var isArchived: Bool = false
    var notes: String = ""

    // Metas diárias opcionais
    var targetKcal: Double?
    var targetProtein: Double?
    var targetCarbs: Double?
    var targetFat: Double?
    var targetFiber: Double?
    var targetWaterMilliliters: Double?

    @Relationship(deleteRule: .cascade, inverse: \NutritionDay.plan)
    var days: [NutritionDay]? = []

    init(name: String, goal: String = "", startDate: Date = .now, author: NutritionPlanAuthor = .me) {
        self.name = name
        self.goal = goal
        self.startDate = startDate
        self.authorRaw = author.rawValue
    }

    var author: NutritionPlanAuthor {
        get { NutritionPlanAuthor(rawValue: authorRaw) ?? .me }
        set { authorRaw = newValue.rawValue }
    }

    var targets: NutritionTargets {
        get {
            NutritionTargets(kcal: targetKcal, protein: targetProtein, carbs: targetCarbs, fat: targetFat,
                             fiber: targetFiber, waterMilliliters: targetWaterMilliliters)
        }
        set {
            targetKcal = newValue.kcal
            targetProtein = newValue.protein
            targetCarbs = newValue.carbs
            targetFat = newValue.fat
            targetFiber = newValue.fiber
            targetWaterMilliliters = newValue.waterMilliliters
        }
    }

    var sortedDays: [NutritionDay] { (days ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Dia do plano que vale para a data (específico do dia da semana vence "todos os dias").
    func day(for date: Date, calendar: Calendar = .current) -> NutritionDay? {
        let all = days ?? []
        let infos = all.map { NutritionDayResolver.DayInfo(id: $0.id, sortIndex: $0.sortIndex, weekdays: $0.weekdays) }
        guard let id = NutritionDayResolver.day(for: date, days: infos, calendar: calendar) else { return nil }
        return all.first { $0.id == id }
    }
}

/// Variação do plano por dia; `weekdays` vazio = todos os dias.
@Model
final class NutritionDay {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var weekdaysRaw: String = ""
    var sortIndex: Int = 0

    var plan: NutritionPlan?

    @Relationship(deleteRule: .cascade, inverse: \Meal.day)
    var meals: [Meal]? = []

    init(name: String = "", weekdays: Set<Weekday> = [], sortIndex: Int = 0) {
        self.name = name
        self.weekdaysRaw = StorageCoding.encodeWeekdays(weekdays)
        self.sortIndex = sortIndex
    }

    var weekdays: Set<Weekday> {
        get { StorageCoding.decodeWeekdays(weekdaysRaw) }
        set { weekdaysRaw = StorageCoding.encodeWeekdays(newValue) }
    }

    var appliesToAllDays: Bool { weekdaysRaw.isEmpty }

    /// Refeições por horário.
    var sortedMeals: [Meal] {
        (meals ?? []).sorted { ($0.minutesFromMidnight, $0.sortIndex) < ($1.minutesFromMidnight, $1.sortIndex) }
    }
}

@Model
final class Meal {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    /// Horário como minutos desde a meia-noite (0…1439), independente de fuso.
    var minutesFromMidnight: Int = 0
    var reminderEnabled: Bool = false
    var sortIndex: Int = 0
    var notes: String = ""

    var day: NutritionDay?

    @Relationship(deleteRule: .cascade, inverse: \MealItem.meal)
    var items: [MealItem]? = []

    init(name: String, minutesFromMidnight: Int, sortIndex: Int = 0, reminderEnabled: Bool = false) {
        self.name = name
        self.minutesFromMidnight = minutesFromMidnight
        self.sortIndex = sortIndex
        self.reminderEnabled = reminderEnabled
    }

    var sortedItems: [MealItem] { (items ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Horário da refeição numa data.
    func time(on date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minutesFromMidnight * 60))
    }

    /// Soma planejada (só para exibir o plano — nunca conta como realizado).
    var plannedValues: NutrientValues {
        let entries = (items ?? []).map { NutritionTotals.Entry(values: $0.values) }
        let t = NutritionTotals.totals(entries)
        return NutrientValues(kcal: t.kcal, protein: t.protein, carbs: t.carbs, fat: t.fat, fiber: t.fiber)
    }
}

@Model
final class MealItem {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var quantity: Double = 0
    var unitRaw: String = FoodUnit.grams.rawValue
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var notes: String = ""
    var substitutionsData: Data?
    var sortIndex: Int = 0

    var meal: Meal?

    init(name: String, quantity: Double, unit: FoodUnit, values: NutrientValues = NutrientValues(), sortIndex: Int = 0) {
        self.name = name
        self.quantity = quantity
        self.unitRaw = unit.rawValue
        self.sortIndex = sortIndex
        self.values = values
    }

    var unit: FoodUnit {
        get { FoodUnit(rawValue: unitRaw) ?? .grams }
        set { unitRaw = newValue.rawValue }
    }

    var values: NutrientValues {
        get { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
        set {
            kcal = newValue.kcal
            protein = newValue.protein
            carbs = newValue.carbs
            fat = newValue.fat
            fiber = newValue.fiber
        }
    }

    var substitutions: [MealSubstitution] {
        get { StorageCoding.decode([MealSubstitution].self, from: substitutionsData) ?? [] }
        set { substitutionsData = newValue.isEmpty ? nil : StorageCoding.encode(newValue) }
    }
}

/// Alimento favorito/recente com valores por porção (SPEC §5.1).
@Model
final class FoodItem {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var servingQuantity: Double = 100
    var unitRaw: String = FoodUnit.grams.rawValue
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var isFavorite: Bool = false
    var lastUsedAt: Date?
    var useCount: Int = 0
    var estimationRaw: String = EstimationSource.informed.rawValue

    init(name: String, servingQuantity: Double, unit: FoodUnit, values: NutrientValues = NutrientValues()) {
        self.name = name
        self.servingQuantity = servingQuantity
        self.unitRaw = unit.rawValue
        self.values = values
    }

    var unit: FoodUnit {
        get { FoodUnit(rawValue: unitRaw) ?? .grams }
        set { unitRaw = newValue.rawValue }
    }

    var estimation: EstimationSource {
        get { EstimationSource(rawValue: estimationRaw) ?? .informed }
        set { estimationRaw = newValue.rawValue }
    }

    /// Valores por porção (`servingQuantity` `unit`).
    var values: NutrientValues {
        get { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
        set {
            kcal = newValue.kcal
            protein = newValue.protein
            carbs = newValue.carbs
            fat = newValue.fat
            fiber = newValue.fiber
        }
    }

    /// Valores para uma quantidade na mesma unidade.
    func values(forQuantity quantity: Double) -> NutrientValues {
        servingQuantity > 0 ? values.scaled(by: quantity / servingQuantity) : values
    }
}

/// Algo comido (SPEC §5.2): vinculado a uma refeição do plano ou avulso ("fora da dieta").
@Model
final class FoodEntry {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Quando foi comido.
    var date: Date = Date()
    /// Refeição do plano vinculada; `nil` = fora da dieta.
    var mealID: UUID?
    /// Snapshot do nome da refeição.
    var mealName: String?
    var name: String = ""
    var quantity: Double = 0
    var unitRaw: String = FoodUnit.grams.rawValue
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var estimationRaw: String = EstimationSource.informed.rawValue
    /// Status para entradas de refeição planejada (done/adjusted/skipped); `nil` em avulsas.
    var mealStatusRaw: String?
    var notes: String = ""

    init(name: String, quantity: Double, unit: FoodUnit, date: Date = .now,
         values: NutrientValues = NutrientValues(), estimation: EstimationSource = .informed) {
        self.name = name
        self.quantity = quantity
        self.unitRaw = unit.rawValue
        self.date = date
        self.estimationRaw = estimation.rawValue
        self.values = values
    }

    var isOffPlan: Bool { mealID == nil }

    var unit: FoodUnit {
        get { FoodUnit(rawValue: unitRaw) ?? .grams }
        set { unitRaw = newValue.rawValue }
    }

    var estimation: EstimationSource {
        get { EstimationSource(rawValue: estimationRaw) ?? .informed }
        set { estimationRaw = newValue.rawValue }
    }

    var mealStatus: MealStatus? {
        get { mealStatusRaw.flatMap(MealStatus.init(rawValue:)) }
        set { mealStatusRaw = newValue?.rawValue }
    }

    var values: NutrientValues {
        get { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
        set {
            kcal = newValue.kcal
            protein = newValue.protein
            carbs = newValue.carbs
            fat = newValue.fat
            fiber = newValue.fiber
        }
    }

    var totalsEntry: NutritionTotals.Entry { NutritionTotals.Entry(values: values, mealStatus: mealStatus) }
}

/// Água ingerida (um registro por copo/garrafa).
@Model
final class WaterLog {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var date: Date = Date()
    var milliliters: Double = 0

    init(milliliters: Double, date: Date = .now) {
        self.milliliters = milliliters
        self.date = date
    }
}
