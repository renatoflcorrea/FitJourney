import Foundation

// Copiloto de edição (SPEC §7A.2): o modelo propõe mudanças tipadas; o app calcula o diff localmente e mostra um
// cartão. Nada é gravado sem "Aplicar" (`ChangeApplier`).

/// Onde a mudança acontece.
enum CopilotScope: Codable, Sendable, Hashable {
    case routine(id: UUID, name: String)
    case nutritionPlan(id: UUID, name: String)
    /// Registro alimentar (dia do primeiro item).
    case foodLog(day: Date)

    /// Título curto para o cartão.
    var title: String {
        switch self {
        case let .routine(_, name): String(localized: "Ficha \(name)")
        case let .nutritionPlan(_, name): String(localized: "Dieta \(name)")
        case .foodLog: String(localized: "Registro alimentar")
        }
    }
}

/// Alimento numa operação (plano ou registro).
struct CopilotFoodItem: Codable, Sendable, Hashable {
    var name: String
    var quantity: Double
    var unit: FoodUnit
    var values: NutrientValues
}

/// Operação tipada, já resolvida para ids locais.
enum CopilotOperation: Codable, Sendable, Hashable {
    enum LoadTarget: String, Codable, Sendable, Hashable { case current, initial }

    // Ficha. `setIndex` 0-based; `nil` = todas as séries válidas.
    case setLoad(exerciseID: UUID, setIndex: Int?, load: Load, target: LoadTarget)
    case setReps(exerciseID: UUID, setIndex: Int?, reps: RepTarget)
    case setSetCount(exerciseID: UUID, count: Int)
    case setRest(exerciseID: UUID, seconds: Int)
    case replaceExercise(exerciseID: UUID, newExerciseID: UUID, newName: String)
    case addExercise(newExerciseID: UUID, name: String, sets: Int, reps: RepTarget?, load: Load?, restSeconds: Int?, position: Int?)
    case removeExercise(exerciseID: UUID)
    /// `position` 0-based.
    case moveExercise(exerciseID: UUID, position: Int)

    // Plano alimentar.
    case addItem(mealID: UUID, item: CopilotFoodItem)
    case removeItem(itemID: UUID)
    case updateItem(itemID: UUID, item: CopilotFoodItem)
    case addMeal(dayID: UUID, name: String, minutesFromMidnight: Int)
    case removeMeal(mealID: UUID)
    case updateMeal(mealID: UUID, name: String?, minutesFromMidnight: Int?)
    case setTargets(NutritionTargets)

    // Registro alimentar.
    case logFood(item: CopilotFoodItem, date: Date, mealID: UUID?)
}

/// Linha legível do diff (antes → depois). `before == nil` = acrescentado; `after == nil` = removido.
struct CopilotDiffLine: Codable, Sendable, Hashable {
    var context: String
    var before: String?
    var after: String?

    /// "contexto: antes → depois" (resultado da ferramenta e acessibilidade).
    var text: String {
        switch (before, after) {
        case let (b?, a?): "\(context): \(b) → \(a)"
        case let (nil, a?): "\(context): + \(a)"
        case let (b?, nil): "\(context): − \(b)"
        case (nil, nil): context
        }
    }
}

/// Proposta de alteração anexada à mensagem (como a `CoachProposal`), guardada no `CopilotChangeStore` pelo id
/// (= id da chamada de ferramenta = `ChatMessage.toolCallID` da mensagem `tool`).
struct CopilotChangeSet: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var scope: CopilotScope
    var operations: [CopilotOperation]
    var diff: [CopilotDiffLine]
    /// Impressão digital do estado sobre o qual o diff foi calculado (vazio no registro alimentar).
    var baseFingerprint: String
    var createdAt: Date

    var summary: String {
        let lines = diff.prefix(3).map(\.text).joined(separator: "; ")
        return diff.count > 3 ? "\(scope.title): \(lines)… (+\(diff.count - 3))" : "\(scope.title): \(lines)"
    }
}
