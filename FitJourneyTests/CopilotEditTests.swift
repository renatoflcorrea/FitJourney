import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct CopilotEditFixture {
    let toolbox: ToolboxFixture
    let changes = CopilotChangeStore()
    var context: ModelContext { toolbox.context }
    var now: Date { toolbox.today }

    init(sharing: CoachProfile.Sharing = CoachProfile.Sharing(profile: true, workouts: true, nutrition: true)) throws {
        var fixture = try ToolboxFixture()
        fixture.profile.sharing = sharing
        toolbox = fixture
    }

    func applier(now: Date? = nil) -> ChangeApplier {
        let date = now ?? self.now
        return ChangeApplier(context: context, store: changes, now: { date }, calendar: toolbox.calendar)
    }

    /// Executa a ferramenta e registra o cartão (como o laço do Coach faz).
    func propose(_ name: String, _ arguments: JSONValue, id: String = "call_\(UUID().uuidString.prefix(6))") async -> ToolOutcome {
        let outcome = await toolbox.toolbox().execute(ToolCall(id: id, name: name, argumentsJSON: arguments.jsonString()))
        if let changeSet = outcome.changeSet { changes.register(changeSet, now: now) }
        return outcome
    }

    static func op(_ op: String, exerciseId: UUID? = nil, set: Int? = nil, load: Double? = nil, loadTarget: String? = nil,
                   reps: (Int, Int)? = nil, sets: Int? = nil, rest: Int? = nil, exercise: String? = nil, position: Int? = nil) -> JSONValue {
        .object([
            "op": .string(op),
            "exerciseId": exerciseId.map { .string($0.uuidString) } ?? .null,
            "set": set.map { .number(Double($0)) } ?? .null,
            "load": load.map { .object(["kind": .string("weight"), "value": .number($0), "unit": .string("kg")]) } ?? .null,
            "loadTarget": loadTarget.map(JSONValue.string) ?? .null,
            "reps": reps.map { .object(["kind": .string("range"), "reps": .null, "min": .number(Double($0.0)), "max": .number(Double($0.1))]) } ?? .null,
            "sets": sets.map { .number(Double($0)) } ?? .null,
            "restSeconds": rest.map { .number(Double($0)) } ?? .null,
            "exercise": exercise.map { .object(["name": .string($0), "catalogKey": .null]) } ?? .null,
            "position": position.map { .number(Double($0)) } ?? .null,
        ])
    }

    static func routineArgs(_ routine: Routine, _ ops: [JSONValue]) -> JSONValue {
        .object(["routineId": .string(routine.id.uuidString), "operations": .array(ops)])
    }

    /// Plano ativo com um dia e uma refeição "Lanche" (iogurte 170 g).
    func makePlan() throws -> (NutritionPlan, Meal, MealItem) {
        let plan = NutritionPlan(name: "Dieta", startDate: now)
        plan.targets = NutritionTargets(kcal: 2000)
        context.insert(plan)
        let day = NutritionDay(name: "Todos os dias")
        context.insert(day)
        day.plan = plan
        let meal = Meal(name: "Lanche", minutesFromMidnight: 16 * 60)
        context.insert(meal)
        meal.day = day
        let item = MealItem(name: "Iogurte", quantity: 170, unit: .grams, values: NutrientValues(kcal: 100))
        context.insert(item)
        item.meal = meal
        try context.save()
        try NutritionStore(context: context).activate(plan)
        return (plan, meal, item)
    }
}

@MainActor
@Suite("Copiloto — ferramentas de escrita propostas e ChangeApplier")
struct CopilotEditTests {
    @Test("ferramentas só aparecem com o compartilhamento correspondente")
    func gatedBySharing() async throws {
        let none = try CopilotEditFixture(sharing: CoachProfile.Sharing(profile: true))
        let names = Set(none.toolbox.toolbox().specs.map(\.name))
        #expect(!names.contains("propose_routine_changes"))
        #expect(!names.contains("propose_nutrition_changes"))
        #expect(!names.contains("propose_food_log"))
        let outcome = await none.propose("propose_routine_changes", .object([:]))
        #expect(outcome.isError)
        #expect(outcome.content.contains("not_shared"))

        let all = try CopilotEditFixture()
        let allNames = Set(all.toolbox.toolbox().specs.map(\.name))
        #expect(allNames.isSuperset(of: ["propose_routine_changes", "propose_nutrition_changes", "propose_food_log"]))
        for spec in all.toolbox.toolbox().specs where spec.name.hasPrefix("propose_") {
            #expect((try? JSONSchemaValidator(schemaJSON: spec.parametersSchema)) != nil, "schema de \(spec.name)")
        }
    }

    @Test("get_program e list_nutrition_plans expõem os ids que as propostas usam")
    func readToolsExposeIDs() async throws {
        let f = try CopilotEditFixture()
        let (program, routine, bench) = try f.toolbox.persistence.makeProgram()
        let (_, meal, item) = try f.makePlan()
        let detail = await f.toolbox.toolbox().execute(ToolCall(id: "1", name: "get_program",
                                                                argumentsJSON: #"{"id":"\#(program.id.uuidString)"}"#))
        #expect(detail.content.contains(routine.id.uuidString))
        #expect(detail.content.contains(bench.id.uuidString))
        let plans = await f.toolbox.toolbox().execute(ToolCall(id: "2", name: "list_nutrition_plans", argumentsJSON: "{}"))
        #expect(plans.content.contains(meal.id.uuidString))
        #expect(plans.content.contains(item.id.uuidString))
    }

    @Test("propose_routine_changes: diff legível, nada gravado, carga vai para a atual")
    func routineDiff() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_load", exerciseId: bench.id, load: 34),
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 120),
            CopilotEditFixture.op("add_exercise", reps: (10, 12), sets: 3, exercise: "Voador (peck deck)"),
        ]))
        #expect(!outcome.isError, "\(outcome.content)")
        let changeSet = try #require(outcome.changeSet)
        #expect(outcome.content.contains("proposed"))
        #expect(outcome.content.contains("não diga que foi"))
        let lines = changeSet.diff.map(\.text)
        #expect(lines.contains("Supino reto com barra · carga atual (séries 2, 3, 4): 30 kg → 34 kg"))
        #expect(lines.contains("Supino reto com barra · descanso: 90 s → 120 s"))
        #expect(lines.contains { $0.hasPrefix("Voador (peck deck): + 3 séries × 10–12") })
        // Nada gravado.
        #expect(bench.sortedSets.allSatisfy { $0.currentLoad == nil })
        #expect(routine.sortedExercises.count == 1)
        guard case .routine(routine.id, "A") = changeSet.scope else { Issue.record("escopo"); return }
    }

    @Test("proposta inválida volta para o modelo corrigir")
    func invalidProposal() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let unknown = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("replace_exercise", exerciseId: bench.id, exercise: "Exercício que não existe"),
        ]))
        #expect(unknown.isError)
        #expect(unknown.changeSet == nil)
        #expect(unknown.content.contains("list_exercises"))
        let noop = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 90),
        ]))
        #expect(noop.isError)
    }

    @Test("ChangeApplier: aplica pelo store e desfaz")
    func applyAndUndoRoutine() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_load", exerciseId: bench.id, set: 2, load: 34),
            CopilotEditFixture.op("replace_exercise", exerciseId: bench.id, exercise: "Supino inclinado com barra"),
            CopilotEditFixture.op("add_exercise", sets: 2, exercise: "Crucifixo com halteres", position: 1),
        ]))
        let id = try #require(outcome.changeSet?.id)
        let setIDs = bench.sortedSets.map(\.id)

        #expect(try f.applier().apply(id) == .applied)
        #expect(f.changes.state(for: id) == .applied)
        let items = routine.sortedExercises
        #expect(items.map(\.displayName) == ["Crucifixo com halteres", "Supino inclinado com barra"])
        #expect(items[1].id == bench.id)
        #expect(items[1].sortedSets.map(\.id) == setIDs) // séries preservadas no lugar
        #expect(items[1].sortedSets[1].currentLoad == .kg(34))
        #expect(items[1].sortedSets[1].initialLoad == .kg(30)) // inicial intacta
        #expect(f.applier().canUndo(id))
        #expect(throws: ChangeApplierError.notPending(.applied)) { try f.applier().apply(id) }

        try f.applier().undo(id)
        #expect(f.changes.state(for: id) == .undone)
        #expect(routine.sortedExercises.map(\.displayName) == ["Supino reto com barra"])
        #expect(bench.sortedSets.allSatisfy { $0.currentLoad == nil })
        #expect(try f.context.fetchCount(FetchDescriptor<RoutineExercise>()) == 1)
    }

    @Test("loadTarget initial só quando pedido")
    func initialLoadOnlyWhenExplicit() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_load", exerciseId: bench.id, load: 25, loadTarget: "initial"),
        ]))
        try f.applier().apply(try #require(outcome.changeSet?.id))
        let working = bench.sortedSets.filter { $0.kind.isWorking }
        #expect(working.allSatisfy { $0.initialLoad == .kg(25) && $0.currentLoad == nil })
        #expect(bench.sortedSets.first?.initialLoad == .kg(20)) // aquecimento não muda
    }

    @Test("conflito: estado mudou → diff recalculado e reconfirmação")
    func conflictNeedsConfirmation() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_load", exerciseId: bench.id, load: 34),
        ]))
        let id = try #require(outcome.changeSet?.id)
        // O usuário mexe na ficha pelo editor antes de aplicar.
        for set in bench.sortedSets where set.kind.isWorking { set.currentLoad = .kg(32) }
        try f.context.save()

        guard case let .needsConfirmation(updated) = try f.applier().apply(id) else { Issue.record("deveria pedir confirmação"); return }
        #expect(updated.diff.map(\.text).contains("Supino reto com barra · carga atual (séries 2, 3, 4): 32 kg → 34 kg"))
        #expect(f.changes.state(for: id) == .needsConfirmation)
        #expect(bench.sortedSets.filter { $0.kind.isWorking }.allSatisfy { $0.currentLoad == .kg(32) })
        #expect(try f.applier().apply(id) == .applied)
        #expect(bench.sortedSets.filter { $0.kind.isWorking }.allSatisfy { $0.currentLoad == .kg(34) })
    }

    @Test("treino em andamento na ficha: recusa aplicar")
    func refusesDuringSession() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_sets", exerciseId: bench.id, sets: 5),
        ]))
        let id = try #require(outcome.changeSet?.id)
        _ = try f.toolbox.persistence.sessions.start(routine: routine)
        #expect(throws: ChangeApplierError.sessionInProgress(routineName: "A")) { try f.applier().apply(id) }
        #expect(bench.sortedSets.count == 4)
        #expect(f.changes.state(for: id) == .proposed)
    }

    @Test("desfazer: expira em 24 h e é invalidado por mudança posterior")
    func undoLimits() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let first = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 60),
        ]))
        let firstID = try #require(first.changeSet?.id)
        try f.applier().apply(firstID)
        #expect(throws: ChangeApplierError.undoExpired) { try f.applier(now: f.now.addingTimeInterval(25 * 3600)).undo(firstID) }

        // Mudança manual depois de aplicar → conflito ao desfazer.
        bench.notes = "pegada fechada"
        try f.context.save()
        #expect(throws: ChangeApplierError.undoConflict) { try f.applier().undo(firstID) }
        bench.notes = ""
        try f.context.save()
        #expect(f.applier().canUndo(firstID))

        // Nova alteração aplicada no mesmo escopo invalida o desfazer da anterior.
        let second = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 75),
        ]))
        try f.applier().apply(try #require(second.changeSet?.id))
        #expect(!f.applier().canUndo(firstID))
        #expect(f.applier().canUndo(try #require(second.changeSet?.id)))
    }

    @Test("descartar")
    func discard() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let outcome = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("remove_exercise", exerciseId: bench.id),
        ]))
        let id = try #require(outcome.changeSet?.id)
        try f.applier().discard(id)
        #expect(f.changes.state(for: id) == .discarded)
        #expect(throws: ChangeApplierError.notPending(.discarded)) { try f.applier().apply(id) }
        #expect(routine.sortedExercises.count == 1)
    }

    @Test("propose_nutrition_changes: adicionar item, mudar quantidade, metas; aplicar e desfazer")
    func nutritionChanges() async throws {
        let f = try CopilotEditFixture()
        let (plan, meal, item) = try f.makePlan()
        let food: JSONValue = .object(["name": .string("Whey"), "quantity": .number(30), "unit": .string("grams"), "kcal": .number(120),
                                       "protein": .number(24), "carbs": .null, "fat": .null, "fiber": .null])
        let yogurt: JSONValue = .object(["name": .string("Iogurte"), "quantity": .number(200), "unit": .string("grams"), "kcal": .number(118),
                                         "protein": .null, "carbs": .null, "fat": .null, "fiber": .null])
        func op(_ name: String, meal: UUID? = nil, item: UUID? = nil, food: JSONValue = .null, targets: JSONValue = .null) -> JSONValue {
            .object(["op": .string(name), "dayId": .null, "mealId": meal.map { .string($0.uuidString) } ?? .null,
                     "itemId": item.map { .string($0.uuidString) } ?? .null, "item": food, "meal": .null, "targets": targets])
        }
        let outcome = await f.propose("propose_nutrition_changes", .object([
            "planId": .string(plan.id.uuidString),
            "operations": .array([
                op("add_item", meal: meal.id, food: food),
                op("update_item", item: item.id, food: yogurt),
                op("set_targets", targets: .object(["kcal": .number(2200), "protein": .number(160), "carbs": .null, "fat": .null,
                                                    "fiber": .null, "waterMilliliters": .null])),
            ]),
        ]))
        let changeSet = try #require(outcome.changeSet, "\(outcome.content)")
        let lines = changeSet.diff.map(\.text)
        #expect(lines.contains("Lanche: + 30 g Whey · 120 kcal"))
        #expect(lines.contains("Lanche: 170 g Iogurte · 100 kcal → 200 g Iogurte · 118 kcal"))
        #expect(lines.contains("Metas: 2000 kcal → 2200 kcal, P 160 g"))

        try f.applier().apply(changeSet.id)
        #expect(meal.sortedItems.map(\.name) == ["Iogurte", "Whey"])
        #expect(item.quantity == 200)
        #expect(plan.targets.kcal == 2200)
        try f.applier().undo(changeSet.id)
        #expect(meal.sortedItems.map(\.name) == ["Iogurte"])
        #expect(item.quantity == 170)
        #expect(plan.targets == NutritionTargets(kcal: 2000))
    }

    @Test("propose_food_log: horário, vínculo à refeição, aplicar e desfazer")
    func foodLog() async throws {
        let f = try CopilotEditFixture()
        let (_, meal, _) = try f.makePlan()
        let acai: JSONValue = .object(["name": .string("Açaí"), "quantity": .number(300), "unit": .string("milliliters"),
                                       "kcal": .number(350), "protein": .null, "carbs": .null, "fat": .null, "fiber": .null])
        let outcome = await f.propose("propose_food_log", .object(["entries": .array([
            .object(["food": acai, "date": .null, "time": .null, "mealId": .null]),
            .object(["food": acai, "date": .string("2026-11-10"), "time": .string("16:10"), "mealId": .string(meal.id.uuidString)]),
        ])]))
        let changeSet = try #require(outcome.changeSet, "\(outcome.content)")
        #expect(changeSet.diff.map(\.text) == [
            "Registro hoje 12:00 · fora do plano: + 300 ml Açaí · 350 kcal",
            "Registro ontem 16:10 · Lanche: + 300 ml Açaí · 350 kcal",
        ])
        #expect(try f.context.fetchCount(FetchDescriptor<FoodEntry>()) == 0)

        try f.applier().apply(changeSet.id)
        let entries = try f.context.fetch(FetchDescriptor<FoodEntry>(sortBy: [SortDescriptor(\.date)]))
        #expect(entries.count == 2)
        #expect(entries[0].mealID == meal.id)
        #expect(entries[0].estimation == .ai)
        #expect(entries[1].mealID == nil)
        #expect(entries[1].date == f.now)
        try f.applier().undo(changeSet.id)
        #expect(try f.context.fetchCount(FetchDescriptor<FoodEntry>()) == 0)

        let future = await f.propose("propose_food_log", .object(["entries": .array([
            .object(["food": acai, "date": .string("2026-11-12"), "time": .string("10:00"), "mealId": .null]),
        ])]))
        #expect(future.isError)
    }

    @Test("o laço do Coach registra o cartão no CopilotChangeStore")
    func coachLoopRegistersChangeSet() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let args = CopilotEditFixture.routineArgs(routine, [CopilotEditFixture.op("set_load", exerciseId: bench.id, load: 34)]).jsonString()
        let gateway = ScriptedCoachGateway([
            [.toolCall(id: "call_edit", name: "propose_routine_changes", argumentsJSON: args), .finished(reason: .toolCalls)],
            [.delta("Preparei a alteração para você aplicar."), .finished(reason: .stop)],
        ])
        let service = CoachConversationService(context: f.context, toolbox: f.toolbox.toolbox(),
                                               resolveChat: { ResolvedChat(gateway: gateway, model: "m") }, changeStore: f.changes)
        let conversation = try service.createConversation()
        #expect(await service.send("sobe o supino para 34 kg", in: conversation))
        let tool = try #require(conversation.sortedMessages.first { $0.role == .tool })
        let record = try #require(f.changes.record(for: tool))
        #expect(record.messageID == tool.id)
        #expect(record.state == .proposed)
        #expect(bench.sortedSets.allSatisfy { $0.currentLoad == nil })
        #expect(CoachPrompt.system.contains("Nunca diga que gravou"))
    }
}

/// Gateway com roteiro de eventos por volta (laço do Coach).
final class ScriptedCoachGateway: ChatGateway, StructuredCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[ChatEvent]]
    var provider: AIProviderID { .openAI }

    init(_ rounds: [[ChatEvent]]) { self.rounds = rounds }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let events: [ChatEvent]? = lock.withLock { rounds.isEmpty ? nil : rounds.removeFirst() }
        return AsyncThrowingStream { continuation in
            guard let events else {
                continuation.finish(throwing: AIError.server(status: 500, message: "sem roteiro"))
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        throw AIError.server(status: 500, message: "não usado")
    }
}
