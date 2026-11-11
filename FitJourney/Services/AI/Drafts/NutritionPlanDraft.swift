import Foundation

// Contrato `contracts/nutrition-plan-draft-v1.schema.json`. Os nomes das propriedades SÃO o
// contrato — não renomeie; crie uma v2.

struct NutritionPlanDraft: Codable, Sendable, Hashable {
    var name: String
    var goal: String?
    var notes: String?
    var targets: TargetsDraft
    var days: [DayDraft]

    struct TargetsDraft: Codable, Sendable, Hashable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var waterMilliliters: Double?

        var targets: NutritionTargets {
            NutritionTargets(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber,
                             waterMilliliters: waterMilliliters)
        }
    }

    struct DayDraft: Codable, Sendable, Hashable {
        var name: String
        var weekdays: [Weekday]
        var meals: [MealDraft]
    }

    struct MealDraft: Codable, Sendable, Hashable {
        var name: String
        /// "HH:MM".
        var time: String
        var notes: String?
        var items: [ItemDraft]

        /// Minutos desde a meia-noite; `nil` se `time` for inválido.
        var minutesFromMidnight: Int? { Self.minutes(from: time) }

        static func minutes(from time: String) -> Int? {
            let parts = time.split(separator: ":")
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]), (0 ..< 24).contains(h), (0 ..< 60).contains(m)
            else { return nil }
            return h * 60 + m
        }
    }

    struct ItemDraft: Codable, Sendable, Hashable {
        var name: String
        var quantity: Double
        var unit: FoodUnit
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var notes: String?
        var substitutions: [SubstitutionDraft]

        var values: NutrientValues { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
    }

    struct SubstitutionDraft: Codable, Sendable, Hashable {
        var name: String
        var quantity: Double
        var unit: FoodUnit
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var notes: String?

        var substitution: MealSubstitution {
            MealSubstitution(name: name, quantity: quantity, unit: unit,
                             values: NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat),
                             notes: notes ?? "")
        }
    }

    /// Regras que o JSON Schema não expressa. Vazio = válido.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("name: vazio") }
        if name.count > 80 { issues.append("name: mais de 80 caracteres") }
        if days.isEmpty { issues.append("days: ao menos um dia") }
        var seen: Set<Weekday> = []
        var allDays = 0
        for (d, day) in days.enumerated() {
            let path = "days[\(d)]"
            if day.weekdays.isEmpty { allDays += 1 }
            for weekday in day.weekdays {
                if !seen.insert(weekday).inserted { issues.append("\(path).weekdays: \(weekday.rawValue) já usado em outro dia") }
            }
            if day.meals.isEmpty { issues.append("\(path).meals: ao menos uma refeição") }
            for (m, meal) in day.meals.enumerated() {
                let mPath = "\(path).meals[\(m)]"
                if meal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(mPath).name: vazio") }
                if meal.minutesFromMidnight == nil { issues.append("\(mPath).time: use HH:MM") }
                if meal.items.isEmpty { issues.append("\(mPath).items: ao menos um item") }
                for (i, item) in meal.items.enumerated() where item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(mPath).items[\(i)].name: vazio")
                }
            }
        }
        if allDays > 1 { issues.append("days: só um dia pode valer para todos os dias (weekdays vazio)") }
        return issues
    }

    var summary: String {
        let meals = days.reduce(0) { $0 + $1.meals.count }
        let kcal = targets.kcal.map { ", meta \(Int($0)) kcal" } ?? ""
        return "\(name): \(days.count) dia(s), \(meals) refeições\(kcal)"
    }
}

/// Proposta validada da IA para a UI ("Revisar e salvar"). Nunca grava nada sozinha.
struct CoachProposal: Codable, Sendable, Hashable, Identifiable {
    enum Content: Codable, Sendable, Hashable {
        case program(ProgramDraft)
        case nutritionPlan(NutritionPlanDraft)
    }

    /// Id da chamada de ferramenta que gerou a proposta.
    var id: String
    var content: Content
    var createdAt: Date

    var summary: String {
        switch content {
        case let .program(draft): draft.summary
        case let .nutritionPlan(draft): draft.summary
        }
    }
}
