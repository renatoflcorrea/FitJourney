import Foundation
import Testing
@testable import FitJourney

// Registro de refeições com IA: apresentação (formatação, textos de estado, resposta rápida) e visibilidade dos
// pontos de entrada com e sem IA configurada.

@MainActor
@Suite("Registro com IA · apresentação")
struct MealLogPresentationTests {
    private func item(quantity: Double? = 150, unit: FoodUnit = .grams, kcal: Double? = 185,
                      confidence: MealLogConfidence = .medium, range: MealLogRange? = MealLogRange(min: 150, max: 235)) -> MealLogReviewItem {
        MealLogReviewItem(name: "Arroz integral", quantity: quantity, unit: unit, values: NutrientValues(kcal: kcal),
                          kcalRange: range, confidence: confidence, note: nil, plannedItemID: nil)
    }

    @Test("kcal estimada leva ≈; ausente vira traço e nunca zero")
    func approximateValues() {
        #expect(MealLogPresentation.approxNumber(545) == "≈ 545")
        #expect(MealLogPresentation.approxNumber(nil) == "—")
        #expect(MealLogPresentation.approxKcal(185).hasPrefix("≈ 185"))
        #expect(!MealLogPresentation.approxKcal(nil).contains("0 kcal"))
    }

    @Test("faixa só aparece quando tem largura")
    func rangeText() {
        let text = MealLogPresentation.rangeText(MealLogRange(min: 450, max: 660))
        #expect(text?.contains("450") == true && text?.contains("660") == true)
        #expect(MealLogPresentation.rangeText(MealLogRange(min: 300, max: 300)) == nil)
        #expect(MealLogPresentation.rangeText(nil) == nil)
    }

    @Test("quantidade ausente é traço; passo por unidade")
    func quantityAndStep() {
        #expect(MealLogPresentation.quantity(nil, unit: .grams) == "—")
        #expect(MealLogPresentation.quantity(0, unit: .grams) == "—")
        #expect(MealLogPresentation.quantity(150, unit: .grams).contains("150"))
        #expect(MealLogPresentation.step(for: .grams) == 10)
        #expect(MealLogPresentation.step(for: .unit) == 1)
        #expect(MealLogPresentation.step(for: .cup) == 0.5)
    }

    @Test("VoiceOver lê o item como frase, com confiança só quando não é alta")
    func accessibility() {
        let medium = MealLogPresentation.itemAccessibilityLabel(item())
        #expect(medium.contains("Arroz integral") && medium.contains("150") && medium.contains("185"))
        #expect(medium.localizedCaseInsensitiveContains("média") || medium.localizedCaseInsensitiveContains("medium"))
        let high = MealLogPresentation.itemAccessibilityLabel(item(confidence: .high, range: nil))
        #expect(!high.localizedCaseInsensitiveContains("confiança") && !high.localizedCaseInsensitiveContains("confidence"))
        let missing = MealLogPresentation.itemAccessibilityLabel(item(quantity: nil, kcal: nil, confidence: .low))
        #expect(missing.contains("Arroz integral") && !missing.contains("185"))
    }

    @Test("rótulo do botão Registrar conta as refeições")
    func registerTitle() {
        #expect(MealLogPresentation.undoMessage(mealCount: 1).contains("1"))
        #expect(MealLogPresentation.undoMessage(mealCount: 4).contains("4"))
    }

    @Test("cada fase sem rascunho tem texto próprio; composing/analyzing/ready não têm")
    func stateCopy() {
        #expect(MealLogPresentation.stateCopy(for: .composing) == nil)
        #expect(MealLogPresentation.stateCopy(for: .analyzing) == nil)
        #expect(MealLogPresentation.stateCopy(for: .ready) == nil)
        #expect(MealLogPresentation.stateCopy(for: .lowConfidence) == nil)
        let noFood = MealLogPresentation.stateCopy(for: .noFood(reason: "É um gato"))
        #expect(noFood?.message == "É um gato" && noFood?.offersRetake == true)
        #expect(MealLogPresentation.stateCopy(for: .noFood(reason: "  "))?.message.isEmpty == false)
        #expect(MealLogPresentation.stateCopy(for: .unreadable(reason: nil))?.offersRetake == true)
        #expect(MealLogPresentation.stateCopy(for: .offline)?.offersRetake == false)
        #expect(MealLogPresentation.stateCopy(for: .timedOut)?.symbol.isEmpty == false)
        #expect(MealLogPresentation.stateCopy(for: .providerError("Erro 503"))?.message == "Erro 503")
    }

    @Test("pendências viram frases; a de quantidade diz qual item")
    func issues() {
        let id = UUID()
        #expect(MealLogPresentation.issueMessage(.missingQuantity(mealID: id, itemID: id, name: "Manteiga")).contains("Manteiga"))
        #expect(!MealLogPresentation.issueMessage(.missingLink(mealID: id)).isEmpty)
        #expect(!MealLogPresentation.issueMessage(.nothingToApply).isEmpty)
    }

    @Test("resposta rápida vira quantidade e unidade")
    func quickAnswer() {
        let ml = MealLogAnswer.parse("300 ml")
        #expect(ml?.quantity == 300 && ml?.unit == .milliliters)
        let cup = MealLogAnswer.parse("1,5 xícara")
        #expect(cup?.quantity == 1.5 && cup?.unit == .cup)
        #expect(MealLogAnswer.parse("2")?.unit == nil)
        #expect(MealLogAnswer.parse("Outro") == nil)
        #expect(MealLogAnswer.parse("0 g") == nil)
    }

    @Test("título da refeição: plano, rótulo dito, refeição típica")
    func mealTitle() {
        let meal = MealLogReviewMeal(slot: .lunch, label: nil, minutesFromMidnight: nil, plannedMealID: nil, decision: .offPlan,
                                     alreadyLogged: false, isIncluded: true, items: [])
        let planned = MealLogPlannedMeal(id: UUID(), name: "Almoço do plano", minutesFromMidnight: 750, status: .pending, items: [])
        #expect(MealLogPresentation.mealTitle(meal, planned: planned) == "Almoço do plano")
        #expect(MealLogPresentation.mealTime(meal, planned: planned) == "12:30")
        var labelled = meal
        labelled.label = "Açaí"
        #expect(MealLogPresentation.mealTitle(labelled, planned: nil) == "Açaí")
        #expect(MealLogPresentation.mealTitle(meal, planned: nil) == MealLogPresentation.slotTitle(.lunch))
        #expect(MealLogPresentation.mealTime(meal, planned: nil) == nil)
    }
}

@MainActor
@Suite("Registro com IA · visibilidade dos pontos de entrada")
struct AIVisibilityTests {
    private func defaults() -> UserDefaults {
        let name = "fj.test.vis.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("sem AIAvailability no ambiente, sem chave e com chave")
    func visibility() {
        let missing: AIAvailability? = nil
        #expect(!missing.isOn && !missing.canReadImages)

        let off = AIAvailability(defaults: defaults(), secrets: InMemorySecretStore(), center: NotificationCenter())
        let offOptional: AIAvailability? = off
        #expect(!offOptional.isOn && !offOptional.canReadImages)

        let on = AIAvailability(defaults: defaults(), secrets: InMemorySecretStore([.apiKey(.openAI): "sk-test-0123456789"]),
                                center: NotificationCenter())
        let onOptional: AIAvailability? = on
        #expect(onOptional.isOn && onOptional.canReadImages)
    }

    @Test("modelo sem visão mantém a barra de texto e esconde a câmera")
    func noVisionModel() {
        let defaults = defaults()
        var settings = ProviderSettings(provider: .openAI)
        settings.model = "gpt-3.5-turbo"
        ProviderSettingsStore(defaults: defaults).save(settings)
        let availability = AIAvailability(defaults: defaults, secrets: InMemorySecretStore([.apiKey(.openAI): "sk-test-0123456789"]),
                                          center: NotificationCenter())
        let optional: AIAvailability? = availability
        #expect(optional.isOn)
        #expect(!optional.canReadImages)
    }
}
