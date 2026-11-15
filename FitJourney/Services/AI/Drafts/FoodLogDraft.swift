import Foundation

/// Saída da IA no registro de refeições (contrato `food-log-draft-v1`, SPEC §7.x). Curta de propósito: a faixa
/// total e as somas são calculadas no aparelho. Desconhecido = `nil` (nunca 0).
struct FoodLogDraft: Codable, Sendable, Hashable {
    enum Status: String, Codable, Sendable, Hashable {
        case ok
        case noFood = "no_food"
        case unreadable
    }

    struct Item: Codable, Sendable, Hashable {
        var name: String
        var quantity: Double?
        var unit: FoodUnit
        var kcal: Double?
        var kcalMin: Double?
        var kcalMax: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var confidence: MealLogConfidence
        var note: String?
        var plannedItemId: String?

        var values: NutrientValues { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
    }

    struct Meal: Codable, Sendable, Hashable {
        var slot: MealLogSlot
        var label: String?
        var time: String?
        var plannedMealId: String?
        var asPlanned: Bool
        var items: [Item]

        var minutesFromMidnight: Int? { MealLogText.minutes(fromTime: time) }
    }

    struct Question: Codable, Sendable, Hashable {
        var mealIndex: Int?
        var itemIndex: Int?
        var text: String
        var options: [String]
    }

    var status: Status
    var reason: String?
    var meals: [Meal]
    var notSeen: [String]
    var questions: [Question]

    static let maxNameLength = 80
    static let maxNoteLength = 200

    /// Regras além do schema. Textos longos não reprovam (são cortados na revisão); só o que tornaria o
    /// rascunho incoerente.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if status == .ok, !meals.contains(where: { !$0.items.isEmpty }) {
            issues.append("$.meals: status ok exige ao menos uma refeição com itens")
        }
        for (m, meal) in meals.enumerated() {
            if let time = meal.time, MealLogText.minutes(fromTime: time) == nil {
                issues.append("$.meals[\(m)].time: use HH:MM")
            }
            for (i, item) in meal.items.enumerated()
            where item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("$.meals[\(m)].items[\(i)].name: vazio")
            }
        }
        for (q, question) in questions.enumerated() {
            if let m = question.mealIndex {
                if !meals.indices.contains(m) {
                    issues.append("$.questions[\(q)].mealIndex: refeição inexistente")
                } else if let i = question.itemIndex, !meals[m].items.indices.contains(i) {
                    issues.append("$.questions[\(q)].itemIndex: item inexistente")
                }
            } else if question.itemIndex != nil {
                issues.append("$.questions[\(q)].itemIndex: exige mealIndex")
            }
        }
        return issues
    }
}

extension DraftValidation {
    static func foodLog(_ json: String) -> Outcome<FoodLogDraft> {
        validate(json, schema: DraftSchemas.foodLogDraftV1, as: FoodLogDraft.self) { $0.validationIssues() }
    }
}
