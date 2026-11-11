import Foundation

/// Autor do plano alimentar (SPEC §5.1).
enum NutritionPlanAuthor: String, Codable, Sendable, Hashable, CaseIterable {
    case me, nutritionist, ai
}

/// Unidade de quantidade de alimento (SPEC §5.1).
enum FoodUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case grams, milliliters, unit, tablespoon, cup, slice, serving

    var symbol: String {
        switch self {
        case .grams: "g"
        case .milliliters: "ml"
        case .unit: String(localized: "un")
        case .tablespoon: String(localized: "colher")
        case .cup: String(localized: "xícara")
        case .slice: String(localized: "fatia")
        case .serving: String(localized: "porção")
        }
    }
}

/// Grau de estimativa do valor nutricional de uma entrada (SPEC §5.2).
enum EstimationSource: String, Codable, Sendable, Hashable, CaseIterable {
    case informed, estimated, ai
}

/// Estado de uma refeição do plano no dia (SPEC §5.2).
enum MealStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending, done, adjusted, skipped
}

/// kcal e macros, todos opcionais (desconhecido ≠ zero). Gramas para macros.
struct NutrientValues: Codable, Sendable, Hashable {
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?

    init(kcal: Double? = nil, protein: Double? = nil, carbs: Double? = nil, fat: Double? = nil, fiber: Double? = nil) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }

    /// Escala todos os valores conhecidos (ex.: porção × quantidade).
    func scaled(by factor: Double) -> NutrientValues {
        NutrientValues(kcal: kcal.map { $0 * factor }, protein: protein.map { $0 * factor },
                       carbs: carbs.map { $0 * factor }, fat: fat.map { $0 * factor },
                       fiber: fiber.map { $0 * factor })
    }
}

/// Alternativa equivalente de um item do plano (SPEC §5.1).
struct MealSubstitution: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var quantity: Double
    var unit: FoodUnit
    var values: NutrientValues = NutrientValues()
    var notes: String = ""
}

/// Metas diárias opcionais do plano.
struct NutritionTargets: Codable, Sendable, Hashable {
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var waterMilliliters: Double?

    init(kcal: Double? = nil, protein: Double? = nil, carbs: Double? = nil, fat: Double? = nil,
         fiber: Double? = nil, waterMilliliters: Double? = nil) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.waterMilliliters = waterMilliliters
    }
}

enum Nutrient: String, Codable, Sendable, Hashable, CaseIterable {
    case kcal, protein, carbs, fat, fiber, water
}

/// Totais do dia: soma dos valores conhecidos + contagem de itens sem kcal.
struct DayNutritionTotals: Sendable, Hashable {
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    /// Entradas contadas (exclui marcadores de refeição pulada).
    var entryCount: Int = 0
    /// "3 itens sem calorias".
    var itemsWithoutKcal: Int = 0

    func value(_ nutrient: Nutrient) -> Double? {
        switch nutrient {
        case .kcal: kcal
        case .protein: protein
        case .carbs: carbs
        case .fat: fat
        case .fiber: fiber
        case .water: nil
        }
    }
}

struct TargetProgress: Sendable, Hashable {
    var consumed: Double
    var target: Double
    /// consumed / target (pode passar de 1).
    var fraction: Double { target > 0 ? consumed / target : 0 }
    /// Quanto falta (nunca negativo).
    var remaining: Double { max(0, target - consumed) }
}

/// Regras puras da dieta (SPEC §5.2). Planejado nunca conta como realizado: só entradas somam.
enum NutritionTotals {
    struct Entry: Sendable, Hashable {
        var values: NutrientValues
        /// Status da refeição planejada que a entrada representa (`nil` = avulsa).
        var mealStatus: MealStatus?

        init(values: NutrientValues, mealStatus: MealStatus? = nil) {
            self.values = values
            self.mealStatus = mealStatus
        }
    }

    static func totals(_ entries: [Entry]) -> DayNutritionTotals {
        var totals = DayNutritionTotals()
        for entry in entries where entry.mealStatus != .skipped {
            totals.entryCount += 1
            let v = entry.values
            if let kcal = v.kcal { totals.kcal += kcal } else { totals.itemsWithoutKcal += 1 }
            totals.protein += v.protein ?? 0
            totals.carbs += v.carbs ?? 0
            totals.fat += v.fat ?? 0
            totals.fiber += v.fiber ?? 0
        }
        return totals
    }

    /// Progresso por nutriente com meta definida (> 0).
    static func progress(totals: DayNutritionTotals, waterMilliliters: Double,
                         targets: NutritionTargets) -> [Nutrient: TargetProgress] {
        let pairs: [(Nutrient, Double, Double?)] = [
            (.kcal, totals.kcal, targets.kcal),
            (.protein, totals.protein, targets.protein),
            (.carbs, totals.carbs, targets.carbs),
            (.fat, totals.fat, targets.fat),
            (.fiber, totals.fiber, targets.fiber),
            (.water, waterMilliliters, targets.waterMilliliters),
        ]
        var result: [Nutrient: TargetProgress] = [:]
        for (nutrient, consumed, target) in pairs {
            if let target, target > 0 { result[nutrient] = TargetProgress(consumed: consumed, target: target) }
        }
        return result
    }

    /// Status de uma refeição do plano a partir dos status das entradas vinculadas a ela no dia.
    /// Sem entradas → pendente. Só avulsos vinculados (status `nil`) = registro parcial: a refeição
    /// continua pendente (o item conta nos totais e aparece dentro da refeição). Avulso vinculado a uma
    /// refeição que já tem registro (feita/ajustada/pulada) → ajustada. Alguma ajustada → ajustada;
    /// só puladas → pulada; feitas → feita.
    static func mealStatus(entryStatuses: [MealStatus?]) -> MealStatus {
        let real = entryStatuses.compactMap { $0 }
        guard !real.isEmpty else { return .pending }
        if real.count < entryStatuses.count { return .adjusted }
        if real.contains(.adjusted) { return .adjusted }
        if real.contains(.done) { return .done }
        if real.allSatisfy({ $0 == .skipped }) { return .skipped }
        return .pending
    }
}

/// Escolhe o dia do plano que vale para uma data (SPEC §5.1).
/// Dia específico do dia da semana vence o "todos os dias" (weekdays vazio).
enum NutritionDayResolver {
    struct DayInfo: Sendable, Hashable {
        var id: UUID
        var sortIndex: Int
        var weekdays: Set<Weekday>
    }

    static func day(for date: Date, days: [DayInfo], calendar: Calendar = .current) -> UUID? {
        let weekday = Weekday(date: date, calendar: calendar)
        let ordered = days.sorted { $0.sortIndex < $1.sortIndex }
        return ordered.first(where: { $0.weekdays.contains(weekday) })?.id
            ?? ordered.first(where: { $0.weekdays.isEmpty })?.id
    }
}
