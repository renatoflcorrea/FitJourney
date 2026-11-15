import Foundation
import Photos
import SwiftData
import Testing
@testable import FitJourney

// Registro de refeições com IA (SPEC §7.x, O6c): contrato, matcher, revisão, applier/Desfazer, disponibilidade da IA
// e sessão com gateway falso.

// MARK: - Fixtures

/// Monta JSON do `food-log-draft-v1` com todas as chaves (null explícito).
enum FoodLogJSON {
    static func item(_ name: String, quantity: Double? = 100, unit: String = "grams", kcal: Double? = 100,
                     min: Double? = nil, max: Double? = nil, confidence: String = "high", plannedItemId: String? = nil) -> String {
        func n(_ v: Double?) -> String { v.map { String($0) } ?? "null" }
        return """
        {"name":"\(name)","quantity":\(n(quantity)),"unit":"\(unit)","kcal":\(n(kcal)),"kcalMin":\(n(min)),"kcalMax":\(n(max)),\
        "protein":null,"carbs":null,"fat":null,"fiber":null,"confidence":"\(confidence)","note":null,\
        "plannedItemId":\(plannedItemId.map { "\"\($0)\"" } ?? "null")}
        """
    }

    static func meal(_ slot: String = "lunch", label: String? = nil, time: String? = nil, plannedMealId: String? = nil,
                     asPlanned: Bool = false, items: [String]) -> String {
        """
        {"slot":"\(slot)","label":\(label.map { "\"\($0)\"" } ?? "null"),"time":\(time.map { "\"\($0)\"" } ?? "null"),\
        "plannedMealId":\(plannedMealId.map { "\"\($0)\"" } ?? "null"),"asPlanned":\(asPlanned),"items":[\(items.joined(separator: ","))]}
        """
    }

    static func draft(status: String = "ok", reason: String? = nil, meals: [String], notSeen: [String] = [],
                      questions: [String] = []) -> String {
        """
        {"status":"\(status)","reason":\(reason.map { "\"\($0)\"" } ?? "null"),"meals":[\(meals.joined(separator: ","))],\
        "notSeen":[\(notSeen.map { "\"\($0)\"" }.joined(separator: ","))],"questions":[\(questions.joined(separator: ","))]}
        """
    }
}

/// Gateway falso do registro com IA: cada chamada consome a próxima resposta.
final class MealLogFakeGateway: ChatGateway, StructuredCompleting, @unchecked Sendable {
    enum Reply {
        case tool(String)
        case failure(AIError)
        /// Nunca termina (cancelamento/timeout).
        case hang
    }

    let provider: AIProviderID
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [ChatRequest] = []
    var requests: [ChatRequest] { lock.withLock { recorded } }

    init(provider: AIProviderID = .openAI, _ replies: [Reply]) {
        self.provider = provider
        self.replies = replies
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let reply: Reply? = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(id: "r", model: request.model))
            switch reply {
            case let .tool(json)?:
                continuation.yield(.toolCall(id: "call_1", name: MealLogPrompt.submitTool, argumentsJSON: json))
                continuation.yield(.finished(reason: .toolCalls))
                continuation.finish()
            case let .failure(error)?:
                continuation.finish(throwing: error)
            case .hang?:
                break
            case nil:
                continuation.finish(throwing: AIError.server(status: 500, message: "sem roteiro"))
            }
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        throw AIError.server(status: 500, message: "não usado")
    }
}

/// Plano ativo de todos os dias: café (07:30), almoço (12:30) e jantar (19:30).
@MainActor
struct MealLogPlanFixture {
    let persistence: PersistenceFixture
    let plan: NutritionPlan
    let breakfast: Meal
    let lunch: Meal
    let dinner: Meal
    var context: ModelContext { persistence.context }
    let calendar = Calendar.current
    var today: Date { calendar.startOfDay(for: .now) }

    init() throws {
        persistence = try PersistenceFixture(seed: false)
        let context = persistence.context
        plan = NutritionPlan(name: "Plano", startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!)
        plan.isActive = true
        context.insert(plan)
        let day = NutritionDay(name: "Todos")
        context.insert(day)
        day.plan = plan
        func meal(_ name: String, _ minutes: Int, _ items: [(String, Double, FoodUnit, Double)]) -> Meal {
            let meal = Meal(name: name, minutesFromMidnight: minutes)
            context.insert(meal)
            meal.day = day
            for (index, item) in items.enumerated() {
                let mealItem = MealItem(name: item.0, quantity: item.1, unit: item.2, values: NutrientValues(kcal: item.3),
                                        sortIndex: index)
                context.insert(mealItem)
                mealItem.meal = meal
            }
            return meal
        }
        breakfast = meal("Café da manhã", 7 * 60 + 30, [("Pão francês", 1, .unit, 140), ("Café", 200, .milliliters, 4)])
        lunch = meal("Almoço", 12 * 60 + 30, [("Arroz", 150, .grams, 195), ("Feijão", 100, .grams, 76), ("Frango grelhado", 120, .grams, 198)])
        dinner = meal("Jantar", 19 * 60 + 30, [("Sopa de legumes", 300, .milliliters, 150)])
        try context.save()
    }

    func planned() throws -> [MealLogPlannedMeal] {
        try NutritionStore(context: context).plannedMeals(on: today).map { state in
            MealLogPlannedMeal(id: state.meal.id, name: state.meal.name, minutesFromMidnight: state.meal.minutesFromMidnight,
                               status: state.status,
                               items: state.meal.sortedItems.map {
                                   MealLogPlannedItem(id: $0.id, name: $0.name, quantity: $0.quantity, unit: $0.unit, values: $0.values)
                               })
        }
    }

    func entries() throws -> [FoodEntry] { try NutritionStore(context: context).entries(on: today) }
}

// MARK: - Contrato

@Suite("Registro com IA · contrato food-log-draft-v1")
struct FoodLogDraftContractTests {
    private static func contract() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "contracts").appending(path: "food-log-draft-v1.schema.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("schema embutido == arquivo em contracts/")
    func embeddedMatchesFile() throws {
        #expect(try JSONValue.parse(try Self.contract()) == (try JSONValue.parse(DraftSchemas.foodLogDraftV1)))
    }

    @Test("todo objeto é estrito: additionalProperties false e todas as chaves obrigatórias")
    func strict() throws {
        func walk(_ value: JSONValue, path: String) {
            switch value {
            case let .object(object):
                if object["type"] == .string("object") {
                    #expect(object["additionalProperties"] == .bool(false), "\(path)")
                    let keys = Set(object["properties"]?.objectValue?.keys.map { $0 } ?? [])
                    let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                    #expect(keys == required, "\(path)")
                }
                for (key, child) in object { walk(child, path: "\(path).\(key)") }
            case let .array(array):
                for (index, child) in array.enumerated() { walk(child, path: "\(path)[\(index)]") }
            default: break
            }
        }
        walk(try JSONValue.parse(DraftSchemas.foodLogDraftV1), path: "foodLog")
    }

    @Test("rascunho válido decodifica com unidades, faixa, confiança e perguntas")
    func valid() throws {
        let json = FoodLogJSON.draft(meals: [
            FoodLogJSON.meal("lunch", label: "Almoço", time: "12:40",
                             items: [FoodLogJSON.item("Arroz", quantity: 150, kcal: 185, min: 150, max: 235, confidence: "medium"),
                                     FoodLogJSON.item("Suco", quantity: nil, unit: "milliliters", kcal: nil, confidence: "low")]),
        ], notSeen: ["óleo de preparo"],
           questions: [#"{"mealIndex":0,"itemIndex":1,"text":"Tamanho do copo?","options":["200 ml","300 ml","500 ml"]}"#])
        guard case let .valid(draft) = DraftValidation.foodLog(json) else {
            Issue.record("deveria ser válido: \(DraftValidation.foodLog(json))")
            return
        }
        #expect(draft.meals[0].slot == .lunch)
        #expect(draft.meals[0].minutesFromMidnight == 12 * 60 + 40)
        #expect(draft.meals[0].items[0].kcalMin == 150)
        #expect(draft.meals[0].items[1].unit == .milliliters)
        #expect(draft.meals[0].items[1].quantity == nil)
        #expect(draft.meals[0].items[1].confidence == .low)
        #expect(draft.questions[0].options.count == 3)
        #expect(draft.notSeen == ["óleo de preparo"])
    }

    @Test("status no_food sem refeições é válido")
    func noFood() {
        guard case let .valid(draft) = DraftValidation.foodLog(FoodLogJSON.draft(status: "no_food", reason: "É um teclado", meals: [])) else {
            Issue.record("deveria ser válido")
            return
        }
        #expect(draft.status == .noFood)
        #expect(draft.reason == "É um teclado")
    }

    @Test("inválidos: chave faltando, enum, ok sem itens, horário, pergunta fora do rascunho", arguments: [
        #"{"status":"ok","reason":null,"meals":[],"notSeen":[]}"#,
        FoodLogJSON.draft(meals: [FoodLogJSON.meal(items: [FoodLogJSON.item("Arroz", unit: "kg")])]),
        FoodLogJSON.draft(meals: []),
        FoodLogJSON.draft(meals: [FoodLogJSON.meal(time: "25:00", items: [FoodLogJSON.item("Arroz")])]),
        FoodLogJSON.draft(meals: [FoodLogJSON.meal(items: [FoodLogJSON.item("Arroz")])],
                          questions: [#"{"mealIndex":0,"itemIndex":3,"text":"?","options":[]}"#]),
        FoodLogJSON.draft(meals: [FoodLogJSON.meal(items: [FoodLogJSON.item("  ")])]),
    ])
    func invalid(json: String) {
        guard case let .invalid(issues) = DraftValidation.foodLog(json) else {
            Issue.record("deveria ser inválido: \(json)")
            return
        }
        #expect(!issues.isEmpty)
    }
}

// MARK: - Matcher

@Suite("Registro com IA · vínculo ao plano")
struct MealLogMatcherTests {
    private static let breakfast = MealLogPlannedMeal(
        id: UUID(), name: "Café da manhã", minutesFromMidnight: 450, status: .pending,
        items: [MealLogPlannedItem(id: UUID(), name: "Pão francês", quantity: 1, unit: .unit),
                MealLogPlannedItem(id: UUID(), name: "Café", quantity: 200, unit: .milliliters)])
    private static let lunch = MealLogPlannedMeal(
        id: UUID(), name: "Almoço", minutesFromMidnight: 750, status: .pending,
        items: [MealLogPlannedItem(id: UUID(), name: "Arroz", quantity: 150, unit: .grams),
                MealLogPlannedItem(id: UUID(), name: "Frango", quantity: 120, unit: .grams)])
    private static let snack = MealLogPlannedMeal(id: UUID(), name: "Lanche da tarde", minutesFromMidnight: 960, status: .pending, items: [])
    private static let plan = [breakfast, lunch, snack]

    private func candidate(_ slot: MealLogSlot = .other, label: String? = nil, minutes: Int? = nil, plannedID: UUID? = nil,
                           asPlanned: Bool = false, items: [(String, Double?, FoodUnit)]) -> MealLogCandidate {
        MealLogCandidate(slot: slot, label: label, minutesFromMidnight: minutes, plannedMealID: plannedID, asPlanned: asPlanned,
                         items: items.map { .init(name: $0.0, quantity: $0.1, unit: $0.2) })
    }

    @Test("sem plano no dia: tudo fora da dieta")
    func noPlan() {
        let result = MealLogMatcher.match([candidate(.lunch, label: "Almoço", items: [("Arroz", 100, .grams)])], planned: [])
        #expect(result[0].decision == .offPlan)
        #expect(result[0].plannedMealID == nil)
    }

    @Test("nome dito pelo usuário casa sem acento e sem caixa; itens diferentes → ajustada")
    func byLabel() {
        let result = MealLogMatcher.match([candidate(label: "almoco", items: [("Arroz integral", 200, .grams), ("Salada", 50, .grams)])],
                                          planned: Self.plan)
        #expect(result[0].plannedMealID == Self.lunch.id)
        #expect(result[0].basis == .name)
        #expect(result[0].decision == .adjusted)
        #expect(result[0].plannedItemIDs[0] == Self.lunch.items[0].id) // "arroz" ⊂ "arroz integral"
        #expect(result[0].plannedItemIDs[1] == nil)
    }

    @Test("refeição típica (slot) casa com o nome do plano; lanche da tarde não pega o café")
    func bySlot() {
        let result = MealLogMatcher.match([candidate(.afternoonSnack, items: [("Iogurte", 170, .grams)]),
                                           candidate(.breakfast, items: [("Ovo", 2, .unit)])], planned: Self.plan)
        #expect(result[0].plannedMealID == Self.snack.id)
        #expect(result[1].plannedMealID == Self.breakfast.id)
    }

    @Test("horário: pendente a até 90 min vincula; mais longe fica fora da dieta")
    func byTime() {
        let near = MealLogMatcher.match([candidate(minutes: 13 * 60 + 30, items: [("Pizza", 2, .slice)])], planned: Self.plan)
        #expect(near[0].plannedMealID == Self.lunch.id)
        #expect(near[0].basis == .time)
        #expect(near[0].decision == .adjusted)
        let far = MealLogMatcher.match([candidate(minutes: 22 * 60 + 30, items: [("Pizza", 2, .slice)])], planned: Self.plan)
        #expect(far[0].decision == .offPlan)
        #expect(far[0].plannedMealID == nil)
    }

    @Test("foto sem horário usa a hora de agora (hoje)")
    func referenceMinutes() {
        let result = MealLogMatcher.match([candidate(items: [("Prato", 1, .serving)])], planned: Self.plan, referenceMinutes: 7 * 60)
        #expect(result[0].plannedMealID == Self.breakfast.id)
    }

    @Test("horário não vincula refeição já registrada; o nome vincula e marca já registrada")
    func alreadyLogged() {
        var logged = Self.lunch
        logged.status = .done
        let plan = [Self.breakfast, logged]
        let byTime = MealLogMatcher.match([candidate(minutes: 12 * 60 + 30, items: [("Pizza", 2, .slice)])], planned: plan)
        #expect(byTime[0].plannedMealID == nil)
        let byName = MealLogMatcher.match([candidate(label: "Almoço", items: [("Pizza", 2, .slice)])], planned: plan)
        #expect(byName[0].plannedMealID == logged.id)
        #expect(byName[0].alreadyLogged)
    }

    @Test("itens iguais ao plano (±25%, mesma unidade, sem extra) → feita; com extra → ajustada; 'como no plano' → feita")
    func doneRule() {
        let same = MealLogMatcher.match([candidate(.lunch, items: [("arroz", 170, .grams), ("Frango", 100, .grams)])], planned: Self.plan)
        #expect(same[0].decision == .done)
        let off = MealLogMatcher.match([candidate(.lunch, items: [("arroz", 250, .grams), ("Frango", 120, .grams)])], planned: Self.plan)
        #expect(off[0].decision == .adjusted)
        let extra = MealLogMatcher.match([candidate(.lunch, items: [("arroz", 150, .grams), ("Frango", 120, .grams), ("Refri", 350, .milliliters)])],
                                         planned: Self.plan)
        #expect(extra[0].decision == .adjusted)
        let asPlanned = MealLogMatcher.match([candidate(.lunch, asPlanned: true, items: [("Prato", 1, .serving)])], planned: Self.plan)
        #expect(asPlanned[0].decision == .done)
    }

    @Test("id sugerido pela IA vence e cada refeição do plano recebe no máximo uma do rascunho")
    func providerAndUniqueness() {
        let result = MealLogMatcher.match([candidate(label: "Almoço", plannedID: Self.breakfast.id, items: [("Pão", 1, .unit)]),
                                           candidate(label: "Café da manhã", items: [("Pão", 1, .unit)])], planned: Self.plan)
        #expect(result[0].plannedMealID == Self.breakfast.id)
        #expect(result[0].basis == .provider)
        #expect(result[1].plannedMealID != Self.breakfast.id)
    }

    @Test("id inexistente da IA é ignorado (cai no nome)")
    func invalidProviderID() {
        let result = MealLogMatcher.match([candidate(label: "Almoço", plannedID: UUID(), items: [("Pão", 1, .unit)])], planned: Self.plan)
        #expect(result[0].plannedMealID == Self.lunch.id)
        #expect(result[0].basis == .name)
    }
}

// MARK: - Revisão

@Suite("Registro com IA · revisão")
struct MealLogReviewTests {
    private func review(_ meals: [MealLogReviewMeal], planned: [MealLogPlannedMeal] = []) -> MealLogReview {
        MealLogReview(day: .now, meals: meals, planned: planned, notSeen: [], questions: [], planWasShared: false)
    }

    private func item(_ name: String, quantity: Double? = 100, kcal: Double? = 100, confidence: MealLogConfidence = .high,
                      range: MealLogRange? = nil) -> MealLogReviewItem {
        MealLogReviewItem(name: name, quantity: quantity, unit: .grams, values: NutrientValues(kcal: kcal, protein: 10),
                          kcalRange: range, confidence: confidence)
    }

    private func meal(_ items: [MealLogReviewItem], decision: MealLogDecision = .offPlan, plannedID: UUID? = nil) -> MealLogReviewMeal {
        MealLogReviewMeal(slot: .lunch, plannedMealID: plannedID, decision: decision, alreadyLogged: false, isIncluded: true, items: items)
    }

    @Test("mudar a quantidade recalcula kcal, macros e faixa na proporção")
    func scaling() {
        var value = item("Arroz", quantity: 150, kcal: 185, range: MealLogRange(min: 150, max: 235))
        value.setQuantity(300)
        #expect(value.quantity == 300)
        #expect(value.values.kcal == 370)
        #expect(value.values.protein == 20)
        #expect(value.kcalRange == MealLogRange(min: 300, max: 470))
    }

    @Test("item sem quantidade bloqueia; sem kcal não vira zero")
    func issues() {
        let missing = item("Suco", quantity: nil, kcal: nil)
        let draft = review([meal([item("Arroz"), missing])])
        #expect(!draft.canApply)
        #expect(draft.issues.contains { if case .missingQuantity(_, missing.id, "Suco") = $0 { true } else { false } })
        #expect(review([]).issues == [.nothingToApply])
    }

    @Test("baixa confiança: mais da metade das kcal de itens low")
    func lowConfidence() {
        #expect(review([meal([item("A", kcal: 400, confidence: .low), item("B", kcal: 100)])]).isLowConfidence)
        #expect(!review([meal([item("A", kcal: 100, confidence: .low), item("B", kcal: 400)])]).isLowConfidence)
    }

    @Test("faixa total soma as faixas; item sem faixa entra com o valor")
    func totalRange() {
        let draft = review([meal([item("A", kcal: 100, range: MealLogRange(min: 80, max: 130)), item("B", kcal: 50)])])
        #expect(draft.kcalRange == MealLogRange(min: 130, max: 180))
        #expect(draft.totals.kcal == 150)
        #expect(draft.estimatedItemCount == 2)
    }

    @Test("trocar o vínculo recalcula estado, já registrada e itens do plano")
    func relink() {
        let plannedItem = MealLogPlannedItem(id: UUID(), name: "Arroz", quantity: 100, unit: .grams)
        let logged = MealLogPlannedMeal(id: UUID(), name: "Almoço", minutesFromMidnight: 750, status: .adjusted, items: [plannedItem])
        var draft = review([meal([item("Arroz")])], planned: [logged])
        let mealID = draft.meals[0].id
        draft.relink(mealID: mealID, to: logged.id)
        #expect(draft.meals[0].decision == .done)
        #expect(draft.meals[0].alreadyLogged)
        #expect(!draft.meals[0].isIncluded)
        #expect(draft.meals[0].items[0].plannedItemID == plannedItem.id)
        draft.relink(mealID: mealID, to: nil)
        #expect(draft.meals[0].decision == .offPlan)
        #expect(draft.meals[0].items[0].plannedItemID == nil)
    }
}

// MARK: - Applier e Desfazer

@MainActor
@Suite("Registro com IA · registrar e desfazer")
struct MealLogApplierTests {
    private func review(_ fixture: MealLogPlanFixture, meals: [MealLogReviewMeal]) throws -> MealLogReview {
        MealLogReview(day: fixture.today, meals: meals, planned: try fixture.planned(), notSeen: [], questions: [], planWasShared: false)
    }

    private func item(_ name: String, quantity: Double = 100, kcal: Double = 100, plannedItemID: UUID? = nil) -> MealLogReviewItem {
        MealLogReviewItem(name: name, quantity: quantity, unit: .grams, values: NutrientValues(kcal: kcal), confidence: .medium,
                          note: "porção estimada", plannedItemID: plannedItemID)
    }

    /// Conta os saves do contexto durante `body`.
    private func countSaves(_ context: ModelContext, _ body: () throws -> Void) rethrows -> Int {
        final class Counter: @unchecked Sendable { var value = 0 }
        let saves = Counter()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
            saves.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try body()
        return saves.value
    }

    @Test("Feita grava os itens do plano (grau informado); Ajustada grava a estimativa (IA); Fora da dieta é avulso — um save")
    func applyAllDecisions() throws {
        let fixture = try MealLogPlanFixture()
        let draft = try review(fixture, meals: [
            MealLogReviewMeal(slot: .breakfast, plannedMealID: fixture.breakfast.id, decision: .done, alreadyLogged: false,
                              isIncluded: true, items: [item("Pão com manteiga", kcal: 999)]),
            MealLogReviewMeal(slot: .lunch, minutesFromMidnight: 13 * 60, plannedMealID: fixture.lunch.id, decision: .adjusted,
                              alreadyLogged: false, isIncluded: true,
                              items: [item("Arroz integral", quantity: 200, kcal: 250, plannedItemID: fixture.lunch.sortedItems[0].id),
                                      item("Ovo", quantity: 50, kcal: 70)]),
            MealLogReviewMeal(slot: .other, minutesFromMidnight: 16 * 60, decision: .offPlan, alreadyLogged: false, isIncluded: true,
                              items: [item("Açaí", quantity: 300, kcal: 400)]),
        ])
        var undo: MealLogUndo?
        let saves = try countSaves(fixture.context) {
            undo = try MealLogApplier(context: fixture.context).apply(draft)
        }
        #expect(saves == 1)
        let entries = try fixture.entries()
        #expect(entries.count == 5)
        let breakfast = entries.filter { $0.mealID == fixture.breakfast.id }
        #expect(Set(breakfast.map(\.name)) == ["Pão francês", "Café"])
        #expect(breakfast.allSatisfy { $0.mealStatus == .done && $0.estimation == .informed })
        #expect(breakfast.compactMap(\.kcal).reduce(0, +) == 144) // valores do plano, estimativa descartada
        let lunch = entries.filter { $0.mealID == fixture.lunch.id }
        #expect(lunch.count == 2)
        #expect(lunch.allSatisfy { $0.mealStatus == .adjusted && $0.estimation == .ai })
        #expect(lunch.first { $0.name == "Arroz integral" }?.plannedItemID == fixture.lunch.sortedItems[0].id)
        #expect(lunch.first?.notes == "porção estimada")
        #expect(Calendar.current.component(.hour, from: lunch[0].date) == 13)
        let offPlan = try #require(entries.first { $0.name == "Açaí" })
        #expect(offPlan.mealID == nil)
        #expect(offPlan.mealStatus == nil)
        #expect(offPlan.estimation == .ai)
        #expect(undo?.mealCount == 3)
        #expect(undo?.estimatedItemCount == 3)
        #expect(undo?.createdEntryIDs.count == 5)
        // Favoritos/recentes não são tocados.
        #expect(try fixture.persistence.count(FoodItem.self) == 0)
    }

    @Test("Desfazer apaga o criado e restaura exatamente o registro substituído — um save")
    func undoRestoresReplaced() throws {
        let fixture = try MealLogPlanFixture()
        let store = NutritionStore(context: fixture.context)
        let previous = try store.markMealDone(fixture.lunch, on: fixture.today)
        let previousIDs = Set(previous.map(\.id))
        let draft = try review(fixture, meals: [
            MealLogReviewMeal(slot: .lunch, plannedMealID: fixture.lunch.id, decision: .adjusted, alreadyLogged: true,
                              isIncluded: true, items: [item("Lasanha", quantity: 350, kcal: 600)]),
        ])
        let applier = MealLogApplier(context: fixture.context)
        let undo = try applier.apply(draft)
        #expect(try fixture.entries().map(\.name) == ["Lasanha"])
        #expect(undo.removedEntries.count == 3)
        let saves = try countSaves(fixture.context) { try applier.undo(undo) }
        #expect(saves == 1)
        let restored = try fixture.entries()
        #expect(Set(restored.map(\.id)) == previousIDs)
        #expect(restored.allSatisfy { $0.mealStatus == .done && $0.mealID == fixture.lunch.id })
        #expect(restored.compactMap(\.kcal).reduce(0, +) == 469)
    }

    @Test("refeição registrada depois da análise não é substituída sem a revisão saber")
    func changedSinceReview() throws {
        let fixture = try MealLogPlanFixture()
        let draft = try review(fixture, meals: [
            MealLogReviewMeal(slot: .lunch, plannedMealID: fixture.lunch.id, decision: .adjusted, alreadyLogged: false,
                              isIncluded: true, items: [item("Lasanha")]),
        ])
        try NutritionStore(context: fixture.context).skipMeal(fixture.lunch, on: fixture.today)
        #expect(throws: MealLogApplyError.mealChangedSinceReview(fixture.lunch.id)) {
            try MealLogApplier(context: fixture.context).apply(draft)
        }
        #expect(try fixture.entries().map(\.mealStatus) == [.skipped])
    }

    @Test("pendências bloqueiam sem gravar nada; refeição fora do rascunho não é tocada")
    func invalidAndExcluded() throws {
        let fixture = try MealLogPlanFixture()
        let missing = MealLogReviewItem(name: "Suco", quantity: nil, unit: .milliliters, values: NutrientValues(), confidence: .low)
        let draft = try review(fixture, meals: [MealLogReviewMeal(slot: .other, decision: .offPlan, alreadyLogged: false,
                                                                  isIncluded: true, items: [missing])])
        #expect(throws: MealLogApplyError.self) { try MealLogApplier(context: fixture.context).apply(draft) }
        #expect(try fixture.entries().isEmpty)

        let excluded = try review(fixture, meals: [
            MealLogReviewMeal(slot: .lunch, plannedMealID: fixture.lunch.id, decision: .done, alreadyLogged: true, isIncluded: false, items: []),
            MealLogReviewMeal(slot: .other, decision: .offPlan, alreadyLogged: false, isIncluded: true, items: [item("Maçã")]),
        ])
        try MealLogApplier(context: fixture.context).apply(excluded)
        #expect(try fixture.entries().map(\.name) == ["Maçã"])
    }
}

// MARK: - Disponibilidade da IA

@MainActor
@Suite("Registro com IA · AIAvailability")
struct AIAvailabilityTests {
    private func defaults() -> UserDefaults {
        let name = "fj.test.ai.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("sem chave não está disponível; com chave e modelo está; mudança de ajustes reavalia pela notificação")
    func readinessAndChanges() async throws {
        let defaults = defaults()
        let secrets = InMemorySecretStore()
        let center = NotificationCenter()
        let availability = AIAvailability(defaults: defaults, secrets: secrets, center: center)
        #expect(!availability.isAvailable)
        #expect(availability.readiness == .missingAPIKey(.openAI))

        try secrets.set("sk-test-0123456789", for: .apiKey(.openAI))
        AIAvailability.postChange(center: center)
        await waitUntil { availability.isAvailable }
        #expect(availability.isAvailable)
        #expect(availability.supportsImages)

        // Trocar para a URL própria sem endereço: deixa de estar pronta.
        ProviderSettingsStore(defaults: defaults).save(ProviderSettings(provider: .custom))
        AIAvailability.postChange(center: center)
        await waitUntil { !availability.isAvailable }
        #expect(availability.readiness == .invalidEndpoint)
        #expect(availability.provider == .custom)
    }

    @Test("ProviderSettingsStore.save avisa pela notificação padrão")
    func settingsSavePosts() async {
        let defaults = defaults()
        let secrets = InMemorySecretStore([.apiKey(.anthropic): "sk-ant-0123456789"])
        let availability = AIAvailability(defaults: defaults, secrets: secrets)
        #expect(!availability.isAvailable)
        ProviderSettingsStore(defaults: defaults).save(ProviderSettings(provider: .anthropic))
        await waitUntil { availability.isAvailable }
        #expect(availability.isAvailable)
        #expect(availability.provider == .anthropic)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Preferências

@Suite("Registro com IA · liberar Dieta")
struct MealLogPreferencesTests {
    @Test("oferece uma vez; liberar liga só Dieta com consentimento")
    func offerOnce() {
        let name = "fj.test.meallog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let prefs = MealLogPreferences(defaults: defaults)
        #expect(!prefs.shouldOfferDietSharing(hasPlan: false))
        #expect(prefs.shouldOfferDietSharing(hasPlan: true))
        prefs.markDietSharingOffered()
        #expect(!prefs.shouldOfferDietSharing(hasPlan: true))
        #expect(!prefs.sharesNutrition)
        prefs.enableDietSharing()
        #expect(prefs.sharesNutrition)
        let sharing = CoachProfileStore(defaults: defaults).load().sharing
        #expect(sharing.nutrition && !sharing.health && !sharing.profile && !sharing.workouts)
    }
}

// MARK: - Sessão

@MainActor
@Suite("Registro com IA · sessão")
struct MealLogSessionTests {
    private func session(_ fixture: MealLogPlanFixture, gateway: MealLogFakeGateway, available: Bool = true, consented: Bool = true,
                         shares: Bool = false, online: Bool = true, timeout: Duration = .seconds(30),
                         nowAt minutes: Int = 13 * 60) -> MealLogSession {
        let now = fixture.calendar.date(byAdding: .minute, value: minutes, to: fixture.today)!
        return MealLogSession(day: fixture.today, context: fixture.context,
                              resolveChat: { ResolvedChat(gateway: gateway, model: "gpt-5") },
                              isAIAvailable: { available }, hasConsented: { consented }, sharesNutrition: { shares },
                              isOnline: { online }, now: { now }, calendar: fixture.calendar, timeout: timeout,
                              language: AppLanguageCode.portuguese)
    }

    private func photo() -> RawAttachment {
        RawAttachment(filename: "IMG_0001.HEIC", data: AttachmentFixtures.jpegWithMetadata(width: 3000, height: 2000))
    }

    private var lunchJSON: String {
        FoodLogJSON.draft(meals: [FoodLogJSON.meal("lunch", label: "Almoço", items: [
            FoodLogJSON.item("Arroz integral", quantity: 150, kcal: 185, min: 150, max: 235, confidence: "medium"),
            FoodLogJSON.item("Bife", quantity: 120, kcal: 260),
        ])])
    }

    @Test("sucesso: rascunho pronto, vinculado ao plano no aparelho, plano não enviado sem Dieta, fotos descartadas")
    func success() async throws {
        let fixture = try MealLogPlanFixture()
        let gateway = MealLogFakeGateway([.tool(lunchJSON)])
        let session = session(fixture, gateway: gateway)
        session.text = "almocei arroz integral e bife"
        try await session.addPhotos([photo()])
        #expect(session.photos.count == 1)
        try await session.analyze()
        #expect(session.phase == .ready)
        let review = try #require(session.review)
        #expect(review.meals.count == 1)
        #expect(review.meals[0].plannedMealID == fixture.lunch.id)
        #expect(review.meals[0].decision == .adjusted)
        #expect(!review.planWasShared)
        #expect(session.photos.isEmpty)
        #expect(session.analysisStartedAt == nil)
        let request = try #require(gateway.requests.first)
        #expect(request.toolChoice == .tool(MealLogPrompt.submitTool))
        let user = try #require(request.messages.last)
        #expect(!user.content.contains(fixture.lunch.id.uuidString))
        #expect(!user.content.contains("Frango grelhado"))
        #expect(user.content.contains("Plano: não enviado"))
        // Foto com nome genérico, reduzida.
        #expect(user.parts.contains { if case let .text(label) = $0 { label.contains("foto-1.jpg") } else { false } })
        #expect(!user.parts.contains { if case let .text(label) = $0 { label.contains("IMG_0001") } else { false } })
    }

    @Test("com Dieta liberada o plano do dia vai ao provedor e o id sugerido vincula")
    func sharedPlan() async throws {
        let fixture = try MealLogPlanFixture()
        let json = FoodLogJSON.draft(meals: [FoodLogJSON.meal("other", plannedMealId: fixture.dinner.id.uuidString, asPlanned: true,
                                                              items: [FoodLogJSON.item("Sopa", quantity: 300, unit: "milliliters")])])
        let gateway = MealLogFakeGateway([.tool(json)])
        let session = session(fixture, gateway: gateway, shares: true)
        session.text = "jantei a sopa do plano"
        try await session.analyze()
        let review = try #require(session.review)
        #expect(review.planWasShared)
        #expect(review.meals[0].plannedMealID == fixture.dinner.id)
        #expect(review.meals[0].decision == .done)
        #expect(gateway.requests[0].messages.last?.content.contains(fixture.dinner.id.uuidString) == true)
    }

    @Test("baixa confiança, foto sem comida e ilegível viram estados")
    func statusPhases() async throws {
        let fixture = try MealLogPlanFixture()
        let low = FoodLogJSON.draft(meals: [FoodLogJSON.meal(items: [FoodLogJSON.item("Algo", kcal: 500, confidence: "low"),
                                                                     FoodLogJSON.item("Salada", kcal: 30)])])
        let gateway = MealLogFakeGateway([.tool(low), .tool(FoodLogJSON.draft(status: "no_food", reason: "É um gato", meals: [])),
                                          .tool(FoodLogJSON.draft(status: "unreadable", reason: "Muito escura", meals: []))])
        let first = session(fixture, gateway: gateway)
        first.text = "comi algo"
        try await first.analyze()
        #expect(first.phase == .lowConfidence)
        let second = session(fixture, gateway: gateway)
        second.text = "foto"
        try await second.analyze()
        #expect(second.phase == .noFood(reason: "É um gato"))
        let third = session(fixture, gateway: gateway)
        third.text = "foto"
        try await third.analyze()
        #expect(third.phase == .unreadable(reason: "Muito escura"))
    }

    @Test("resposta inválida tem um reparo só de texto")
    func repair() async throws {
        let fixture = try MealLogPlanFixture()
        let gateway = MealLogFakeGateway([.tool(#"{"status":"ok"}"#), .tool(lunchJSON)])
        let session = session(fixture, gateway: gateway)
        session.text = "almoço"
        try await session.analyze()
        #expect(session.phase == .ready)
        #expect(gateway.requests.count == 2)
        #expect(gateway.requests[1].messages.allSatisfy { $0.parts.isEmpty })
    }

    @Test("erro do provedor e sem internet preservam o texto")
    func failures() async throws {
        let fixture = try MealLogPlanFixture()
        let gateway = MealLogFakeGateway([.failure(.server(status: 503, message: "overloaded")),
                                          .failure(.network(code: URLError.notConnectedToInternet.rawValue, retryable: true))])
        let session = session(fixture, gateway: gateway)
        session.text = "almoço"
        try await session.analyze()
        guard case .providerError = session.phase else { Issue.record("esperado erro do provedor: \(session.phase)"); return }
        #expect(session.text == "almoço")
        session.retry()
        #expect(session.phase == .composing)
        try await session.analyze()
        #expect(session.phase == .offline)

        let offline = self.session(fixture, gateway: gateway, online: false)
        offline.text = "almoço"
        try await offline.analyze()
        #expect(offline.phase == .offline)
        #expect(gateway.requests.count == 2) // nada enviado offline
    }

    @Test("cancelar volta para a composição sem perder nada")
    func cancellation() async throws {
        let fixture = try MealLogPlanFixture()
        let gateway = MealLogFakeGateway([.hang])
        let session = session(fixture, gateway: gateway)
        session.text = "almoço"
        let task = Task { try await session.analyze() }
        for _ in 0 ..< 200 where gateway.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.phase == .analyzing)
        #expect(session.analysisStartedAt != nil)
        session.cancel()
        try await task.value
        #expect(session.phase == .composing)
        #expect(session.text == "almoço")
        #expect(session.review == nil)
    }

    @Test("demora além do limite vira timedOut")
    func timeout() async throws {
        let fixture = try MealLogPlanFixture()
        let session = session(fixture, gateway: MealLogFakeGateway([.hang]), timeout: .milliseconds(150))
        session.text = "almoço"
        try await session.analyze()
        #expect(session.phase == .timedOut)
    }

    @Test("pré-condições: IA indisponível, consentimento, vazio, dia futuro, fotos demais, modelo sem visão")
    func preconditions() async throws {
        let fixture = try MealLogPlanFixture()
        let gateway = MealLogFakeGateway([])
        let unavailable = session(fixture, gateway: gateway, available: false)
        unavailable.text = "x"
        await #expect(throws: MealLogError.aiUnavailable) { try await unavailable.analyze() }
        let noConsent = session(fixture, gateway: gateway, consented: false)
        noConsent.text = "x"
        await #expect(throws: MealLogError.consentRequired) { try await noConsent.analyze() }
        await #expect(throws: MealLogError.emptyInput) { try await session(fixture, gateway: gateway).analyze() }
        let future = MealLogSession(day: fixture.calendar.date(byAdding: .day, value: 1, to: fixture.today)!, context: fixture.context,
                                    resolveChat: { ResolvedChat(gateway: gateway, model: "gpt-5") }, isAIAvailable: { true },
                                    hasConsented: { true }, sharesNutrition: { false })
        future.text = "x"
        await #expect(throws: MealLogError.futureDay) { try await future.analyze() }
        let many = session(fixture, gateway: gateway)
        await #expect(throws: MealLogError.tooManyPhotos(max: 4)) { try await many.addPhotos(Array(repeating: photo(), count: 5)) }
        let blind = MealLogSession(day: fixture.today, context: fixture.context,
                                   resolveChat: { ResolvedChat(gateway: MealLogFakeGateway(provider: .openAI, []), model: "gpt-3.5-turbo") },
                                   isAIAvailable: { true }, hasConsented: { true }, sharesNutrition: { false })
        try await blind.addPhotos([photo()])
        await #expect(throws: MealLogError.modelWithoutVision) { try await blind.analyze() }
        #expect(gateway.requests.isEmpty)
    }

    @Test("correção por texto refaz o rascunho sem reenviar fotos")
    func correction() async throws {
        let fixture = try MealLogPlanFixture()
        let corrected = FoodLogJSON.draft(meals: [FoodLogJSON.meal("lunch", label: "Almoço",
                                                                   items: [FoodLogJSON.item("Arroz branco", quantity: 150, kcal: 195)])])
        let gateway = MealLogFakeGateway([.tool(lunchJSON), .tool(corrected)])
        let session = session(fixture, gateway: gateway)
        session.text = "almoço"
        try await session.addPhotos([photo()])
        try await session.analyze()
        try await session.correct("era arroz branco, sem bife")
        #expect(session.review?.meals[0].items.map(\.name) == ["Arroz branco"])
        #expect(gateway.requests[1].messages.allSatisfy { $0.parts.isEmpty })
        #expect(gateway.requests[1].messages.last?.content.contains("era arroz branco") == true)
    }
}

// MARK: - Fotos

@Suite("Registro com IA · salvar em Fotos")
struct PhotoLibrarySaverTests {
    final class FakeLibrary: PhotoLibraryAdding, @unchecked Sendable {
        var status: PHAuthorizationStatus
        var requested = false
        var saved: [Data] = []
        init(_ status: PHAuthorizationStatus) { self.status = status }
        func addOnlyAuthorizationStatus() -> PHAuthorizationStatus { status }
        func requestAddOnlyAuthorization() async -> PHAuthorizationStatus { requested = true; status = .authorized; return status }
        func addPhoto(_ data: Data) async throws { saved.append(data) }
    }

    @Test("pede a permissão de adicionar só quando não decidida; negada não grava")
    func authorization() async throws {
        let fresh = FakeLibrary(.notDetermined)
        #expect(try await PhotoLibrarySaver(library: fresh).save(imageData: Data([1])) == .saved)
        #expect(fresh.requested && fresh.saved.count == 1)
        let denied = FakeLibrary(.denied)
        #expect(try await PhotoLibrarySaver(library: denied).save(imageData: Data([1])) == .notAuthorized)
        #expect(!denied.requested && denied.saved.isEmpty)
    }
}
