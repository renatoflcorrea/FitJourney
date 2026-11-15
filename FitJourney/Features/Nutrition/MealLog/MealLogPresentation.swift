import Foundation
import SwiftUI

/// Textos e formatação da revisão do registro com IA (proposta `ai-meal-log.md`). Só apresentação: as regras
/// (vínculo, estado, totais, pendências) vêm de `Domain/MealLog.swift`.
enum MealLogPresentation {
    // MARK: Valores estimados

    /// "≈ 545" (sem a unidade) ou "—" quando a kcal é desconhecida (ausente não é zero).
    static func approxNumber(_ value: Double?, maxFractionDigits: Int = 0) -> String {
        guard let value else { return "—" }
        return "≈ \(FJFormat.number(value, maxFractionDigits: maxFractionDigits))"
    }

    /// "≈ 185 kcal" ou "— kcal".
    static func approxKcal(_ value: Double?) -> String {
        guard let value else { return String(localized: "— kcal") }
        return "≈ \(FJFormat.number(value, maxFractionDigits: 0)) kcal"
    }

    /// "entre 450 e 660 kcal" (só quando a faixa tem largura).
    static func rangeText(_ range: MealLogRange?) -> String? {
        guard let range, range.max - range.min >= 1 else { return nil }
        return String(localized: "entre \(FJFormat.number(range.min, maxFractionDigits: 0)) e \(FJFormat.number(range.max, maxFractionDigits: 0)) kcal")
    }

    /// "150 g" ou "—" quando falta a quantidade.
    static func quantity(_ quantity: Double?, unit: FoodUnit) -> String {
        guard let quantity, quantity > 0 else { return "—" }
        return NutritionFormat.quantity(quantity, unit)
    }

    /// Passo do −/+ por unidade.
    static func step(for unit: FoodUnit) -> Double {
        switch unit {
        case .grams: 10
        case .milliliters: 50
        case .unit, .slice, .tablespoon: 1
        case .cup, .serving: 0.5
        }
    }

    /// Frase lida pelo VoiceOver: "Arroz integral, cerca de 150 gramas, cerca de 185 quilocalorias, confiança média".
    static func itemAccessibilityLabel(_ item: MealLogReviewItem) -> String {
        var parts = [item.name]
        if item.hasQuantity, let quantity = item.quantity {
            parts.append(String(localized: "cerca de \(FJFormat.number(quantity, maxFractionDigits: 1)) \(item.unit.symbol)"))
        } else {
            parts.append(String(localized: "quantidade não informada"))
        }
        if let kcal = item.values.kcal {
            parts.append(String(localized: "cerca de \(FJFormat.number(kcal, maxFractionDigits: 0)) quilocalorias"))
        }
        if item.confidence != .high { parts.append(String(localized: item.confidence.fjValue.title)) }
        if let range = item.kcalRange, let text = rangeText(range) { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    // MARK: Estado de cada refeição

    static func decisionTitle(_ decision: MealLogDecision) -> LocalizedStringKey {
        switch decision {
        case .done: "Feita"
        case .adjusted: "Ajustada"
        case .offPlan: "Fora da dieta"
        }
    }

    static func decisionSymbol(_ decision: MealLogDecision) -> String {
        switch decision {
        case .done: "checkmark"
        case .adjusted: "pencil"
        case .offPlan: "fork.knife"
        }
    }

    /// O que cada estado grava, numa frase.
    static func decisionExplanation(_ decision: MealLogDecision, planned: MealLogPlannedMeal?) -> String {
        switch decision {
        case .done:
            return String(localized: "Marca a refeição como feita, com os itens e valores do plano. A estimativa não é gravada.")
        case .adjusted:
            guard let planned, !planned.items.isEmpty else {
                return String(localized: "Registra o que a IA estimou no lugar dos itens do plano.")
            }
            let names = planned.items.prefix(3).map { "\($0.name) \(NutritionFormat.quantity($0.quantity, $0.unit))" }
                .joined(separator: ", ")
            return String(localized: "Registra o que a IA estimou no lugar dos itens do plano (\(names)).")
        case .offPlan:
            return String(localized: "Registra como comida avulsa, sem marcar nenhuma refeição do plano.")
        }
    }

    /// Título da refeição: nome do plano, rótulo dito, ou a refeição típica.
    static func mealTitle(_ meal: MealLogReviewMeal, planned: MealLogPlannedMeal?) -> String {
        if let planned { return planned.name }
        if let label = meal.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        return slotTitle(meal.slot)
    }

    static func slotTitle(_ slot: MealLogSlot) -> String {
        switch slot {
        case .breakfast: String(localized: "Café da manhã")
        case .morningSnack: String(localized: "Lanche da manhã")
        case .lunch: String(localized: "Almoço")
        case .afternoonSnack: String(localized: "Lanche da tarde")
        case .dinner: String(localized: "Jantar")
        case .supper: String(localized: "Ceia")
        case .other: String(localized: "Refeição")
        }
    }

    /// Horário mostrado: o dito, o do plano (vinculada) ou nenhum.
    static func mealTime(_ meal: MealLogReviewMeal, planned: MealLogPlannedMeal?) -> String? {
        if let minutes = meal.minutesFromMidnight { return NutritionFormat.clock(minutes: minutes) }
        return planned.map { NutritionFormat.clock(minutes: $0.minutesFromMidnight) }
    }

    // MARK: Pendências

    static func issueMessage(_ issue: MealLogIssue) -> String {
        switch issue {
        case let .missingQuantity(_, _, name): String(localized: "Informe a quantidade de \(name).")
        case .emptyMeal: String(localized: "Uma refeição está sem itens. Adicione um item ou tire-a do registro.")
        case .missingLink: String(localized: "Escolha a refeição do plano ou marque Fora da dieta.")
        case .duplicateLink: String(localized: "Duas refeições estão ligadas à mesma refeição do plano.")
        case .nothingToApply: String(localized: "Não há nada para registrar.")
        }
    }

    // MARK: Botões e avisos

    static func registerTitle(mealCount: Int) -> LocalizedStringKey {
        mealCount <= 1 ? "Registrar" : "Registrar \(mealCount) refeições"
    }

    static func undoMessage(mealCount: Int) -> String {
        mealCount == 1 ? String(localized: "1 refeição registrada") : String(localized: "\(mealCount) refeições registradas")
    }

    /// "04:12" a partir de um instante de início.
    static func elapsed(since start: Date?, now: Date) -> String {
        guard let start else { return "0:00" }
        return FJFormat.clock(max(0, Int(now.timeIntervalSince(start))))
    }

    static func selectedPlannedMeal(_ meal: MealLogReviewMeal, in review: MealLogReview) -> MealLogPlannedMeal? {
        review.planned.first { $0.id == meal.plannedMealID }
    }

    // MARK: Estados sem rascunho

    struct StateCopy: Equatable {
        var title: String
        var message: String
        var symbol: String
        /// Oferece "Tirar outra foto" / "Descrever por texto".
        var offersRetake: Bool
    }

    /// Texto de cada fase sem rascunho (proposta §7). `nil` para composing, analyzing e as com rascunho.
    /// - Parameter canRetakePhoto: houve foto na análise e o modelo lê imagens; senão "Tirar outra" não aparece.
    static func stateCopy(for phase: MealLogSession.Phase, canRetakePhoto: Bool = true) -> StateCopy? {
        switch phase {
        case let .noFood(reason):
            StateCopy(title: String(localized: "Não encontrei comida nesta foto"),
                      message: cleaned(reason) ?? String(localized: "Tente uma foto do prato inteiro, de cima e com boa luz, ou descreva por texto."),
                      symbol: "fork.knife.circle", offersRetake: canRetakePhoto)
        case let .unreadable(reason):
            StateCopy(title: String(localized: "Não consegui ler o que você enviou"),
                      message: cleaned(reason) ?? String(localized: "A foto está escura, tremida ou cortada. Tire outra ou descreva por texto."),
                      symbol: "eye.slash", offersRetake: canRetakePhoto)
        case .offline:
            StateCopy(title: String(localized: "Sem internet"),
                      message: String(localized: "O texto e as fotos continuam aqui. Tente de novo quando voltar a conexão ou registre à mão."),
                      symbol: "wifi.slash", offersRetake: false)
        case .timedOut:
            StateCopy(title: String(localized: "A análise demorou demais"),
                      message: String(localized: "O provedor não respondeu a tempo. O texto e as fotos continuam aqui."),
                      symbol: "clock.badge.exclamationmark", offersRetake: false)
        case let .providerError(message):
            StateCopy(title: String(localized: "Não foi possível analisar"), message: message,
                      symbol: "exclamationmark.triangle", offersRetake: false)
        case .composing, .analyzing, .ready, .lowConfidence:
            nil
        }
    }

    static func lowConfidenceWarning() -> (title: String, message: String) {
        (String(localized: "Estimativa incerta"),
         String(localized: "Mais da metade das calorias vem de itens que a IA leu com pouca confiança. Confira as quantidades antes de registrar."))
    }
}

private func cleaned(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

extension MealLogConfidence {
    /// Confiança do DesignSystem (mesmos três níveis).
    var fjValue: FJConfidence {
        switch self {
        case .high: .high
        case .medium: .medium
        case .low: .low
        }
    }
}
