import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
@Suite("Copiloto — correções da revisão")
struct CopilotReviewFixesTests {
    // 1. Sem truncamento silencioso.
    @Test("import grande: nenhuma ficha/exercício/série é cortada")
    func noSilentTruncation() async throws {
        let fixture = try ImportFixture()
        let sets = (0 ..< 11).map { _ in ImportJSON.set() }
        let exercises = (0 ..< 18).map { _ in ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press", sets: sets) }
        let routines = (0 ..< 9).map { ImportJSON.routine("Ficha \($0)", weekdays: [], exercises: exercises) }
        let json = ImportJSON.program(mode: "sequential", routines: routines)
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(json)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        let draft = try session.programDraft()
        #expect(draft.routines.count == 9)
        #expect(draft.routines.allSatisfy { $0.exercises.count == 18 && $0.exercises.allSatisfy { $0.sets.count == 11 } })
        let id = try session.apply(target: .newProgram)
        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        #expect(program.sortedRoutines.count == 9)
        #expect(program.sortedRoutines.last?.sortedExercises.count == 18)
    }

    // 2. Id do cartão gerado pelo app.
    @Test("ids de chamada repetidos (call_0) não colidem nem sobrescrevem cartão aplicado")
    func changeSetIDsAreUnique() async throws {
        let f = try CopilotEditFixture()
        let (_, routine, bench) = try f.toolbox.persistence.makeProgram()
        let first = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 60)]), id: "call_0")
        let firstSet = try #require(first.changeSet)
        #expect(firstSet.id != "call_0")
        #expect(firstSet.toolCallID == "call_0")
        try f.applier().apply(firstSet.id)
        let second = await f.propose("propose_routine_changes", CopilotEditFixture.routineArgs(routine, [
            CopilotEditFixture.op("set_rest", exerciseId: bench.id, rest: 75)]), id: "call_0")
        let secondSet = try #require(second.changeSet)
        #expect(secondSet.id != firstSet.id)
        #expect(f.changes.state(for: firstSet.id) == .applied)
        // Registrar de novo o mesmo cartão já aplicado não o volta para "proposto".
        f.changes.register(firstSet)
        #expect(f.changes.state(for: firstSet.id) == .applied)
        // A mensagem acha o seu cartão pelo messageID.
        let message = ChatMessage(role: .tool, content: "", sortIndex: 0)
        message.toolCallID = "call_0"
        f.changes.attach(messageID: message.id, to: secondSet.id)
        #expect(f.changes.record(for: message)?.changeSet.id == secondSet.id)
    }

    // 3. apply atômico.
    @Test("ativar falha → programa criado é apagado; nova tentativa não duplica")
    func applyIsAtomic() async throws {
        let fixture = try ImportFixture()
        let (_, busyRoutine, _) = try fixture.persistence.makeProgram(name: "Atual", activate: true)
        _ = try fixture.persistence.sessions.start(routine: busyRoutine)
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        session.setSelected(2, included: false)
        for question in session.questions where !question.isRequired { try session.skip(question.id) }
        #expect(throws: ProgramStoreError.self) { try session.apply(target: .newProgram, activate: true) }
        #expect(session.phase == .reviewing)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TrainingProgram>()) == 1)
        try session.apply(target: .newProgram, activate: false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TrainingProgram>()) == 2)
        let created = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.name == "Programa da Ana" })
        #expect(created.notes.contains("Importado com IA"))
    }

    // 4. discard não recria o estado.
    @Test("descartar bloqueia gravações posteriores do estado")
    func discardBlocksPersist() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([]))
        try await session.add([fixture.pdf()])
        #expect(fixture.store.load(id: session.id) != nil)
        session.discard()
        session.note = "depois"
        session.remove(UUID())
        #expect(fixture.store.load(id: session.id) == nil)
    }

    // 5. Registro com refeição removida: nada gravado.
    @Test("food log: refeição apagada antes de aplicar → recusa sem registros parciais")
    func foodLogAllOrNothing() async throws {
        let f = try CopilotEditFixture()
        let (_, meal, _) = try f.makePlan()
        let food: JSONValue = .object(["name": .string("Banana"), "quantity": .number(1), "unit": .string("unit"), "kcal": .number(90),
                                       "protein": .null, "carbs": .null, "fat": .null, "fiber": .null])
        let outcome = await f.propose("propose_food_log", .object(["entries": .array([
            .object(["food": food, "date": .null, "time": .null, "mealId": .null]),
            .object(["food": food, "date": .null, "time": .null, "mealId": .string(meal.id.uuidString)]),
        ])]))
        let id = try #require(outcome.changeSet?.id)
        f.context.delete(meal)
        try f.context.save()
        #expect(throws: ChangeApplierError.targetMissing) { try f.applier().apply(id) }
        #expect(try f.context.fetchCount(FetchDescriptor<FoodEntry>()) == 0)
        #expect(f.changes.state(for: id) == .proposed)
    }

    // 6. Metas mescladas.
    @Test("set_targets muda só os campos informados")
    func setTargetsMerges() async throws {
        let f = try CopilotEditFixture()
        let (plan, _, _) = try f.makePlan()
        plan.targets = NutritionTargets(kcal: 2000, protein: 140, waterMilliliters: 3000)
        try f.context.save()
        let outcome = await f.propose("propose_nutrition_changes", .object([
            "planId": .string(plan.id.uuidString),
            "operations": .array([.object([
                "op": .string("set_targets"), "dayId": .null, "mealId": .null, "itemId": .null, "item": .null, "meal": .null,
                "targets": .object(["kcal": .null, "protein": .number(160), "carbs": .null, "fat": .null, "fiber": .null,
                                    "waterMilliliters": .null]),
            ])]),
        ]))
        try f.applier().apply(try #require(outcome.changeSet?.id))
        #expect(plan.targets == NutritionTargets(kcal: 2000, protein: 160, waterMilliliters: 3000))
    }

    // 7. PDFs grandes e protegidos.
    @Test("PDF acima de 100 páginas vai rasterizado com aviso mesmo com PDF nativo")
    func hugePDFIsRasterized() throws {
        let pdf = try AttachmentPreparer().prepare(RawAttachment(filename: "grande.pdf", data: AttachmentFixtures.pdf(pages: 101)))
        let output = try AttachmentEncoder.encode([pdf], capabilities: AttachmentCapabilities(supportsImages: true, supportsPDF: true),
                                                  rasterizer: PDFRasterizer(maxPages: 2, maxPixels: 200))
        #expect(!output.parts.contains { if case .pdf = $0 { true } else { false } })
        #expect(output.parts.filter { if case .image = $0 { true } else { false } }.count == 2)
        #expect(output.warnings.first?.contains("101") == true)
    }

    private static func protectedPDF(user: String?, owner: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        var info: [CFString: Any] = [kCGPDFContextOwnerPassword: owner, kCGPDFContextAllowsPrinting: false]
        if let user { info[kCGPDFContextUserPassword] = user }
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test("PDF com senha de abertura é recusado; só com senha do dono abre (senha vazia)")
    func protectedPDFs() throws {
        let preparer = AttachmentPreparer()
        #expect(throws: AttachmentError.protectedPDF(filename: "s.pdf")) {
            try preparer.prepare(RawAttachment(filename: "s.pdf", data: Self.protectedPDF(user: "segredo", owner: "dono")))
        }
        let ownerOnly = try preparer.prepare(RawAttachment(filename: "o.pdf", data: Self.protectedPDF(user: nil, owner: "dono")))
        #expect(ownerOnly.pageCount == 1)
        let result = try PDFRasterizer(maxPixels: 100).rasterize(ownerOnly.data)
        #expect(result.pages.count == 1)
    }

    // 8. UTF-8 cortado na amostra.
    @Test("texto sem extensão com caractere multibyte cortado na amostra é reconhecido")
    func utf8CutTolerated() {
        let data = Data((String(repeating: "a", count: 4095) + "é" + String(repeating: "b", count: 10)).utf8)
        #expect(String(data: data.prefix(4096), encoding: .utf8) == nil) // a amostra corta o "é"
        #expect(AttachmentPreparer.detectKind(data: data, filename: "colado", hint: nil) == .text)
    }

    // 9. Unidade ausente e seleção estável na revisão.
    @Test("dieta: quantidade sem unidade vira pergunta obrigatória; pulando, o padrão é porção sinalizada")
    func missingUnitIsAGap() async throws {
        let fixture = try ImportFixture()
        let json = ImportJSON.nutrition().replacingOccurrences(of: #""unit":"unit""#, with: #""unit":null"#)
        let session = fixture.session(.nutrition, gateway: ScriptedImportGateway([.extraction(json)]))
        try await session.add([RawAttachment(filename: "d.txt", data: Data("x".utf8))])
        try await session.analyze()
        let question = try #require(session.questions.first)
        #expect(question.id == "itemQuantity.0.0.0")
        #expect(question.isRequired)
        guard case let .number(_, defaultUnit, suggested) = question.kind else { Issue.record("tipo"); return }
        #expect(defaultUnit == "serving")
        #expect(suggested == 2)
        let item = try #require(session.nutritionImport?.makeDraft().days.first?.meals.first?.items.first)
        #expect(item.unit == .serving)
        #expect(item.quantity == 2)
        #expect(item.notes?.contains("unidade não informada") == true)
    }

    @Test("revisão da IA mantém a seleção pelo nome da ficha, não pela posição")
    func revisionKeepsSelectionByName() async throws {
        let fixture = try ImportFixture()
        let revised = ImportJSON.program(routines: [
            ImportJSON.routine("Costas e bíceps", weekdays: ["friday"], exercises: [ImportJSON.exercise("Puxada", name: "Puxada frontal", key: "lat-pulldown")]),
            ImportJSON.routine("Perna", weekdays: ["thursday"], exercises: [ImportJSON.exercise("Agachamento", name: "Agachamento livre", key: "back-squat")]),
            ImportJSON.routine("Peito e tríceps", weekdays: ["monday"], exercises: [ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press")]),
        ])
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines), .extraction(revised)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.number(8, unit: "kg"), for: "exerciseLoad.1.1")
        session.setSelected(1, included: false) // Ombro
        session.setSelected(2, included: false) // Perna
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()
        #expect(session.selected == [0, 2]) // Costas e bíceps, Peito e tríceps
        #expect(session.answers["exerciseLoad.1.1"] == nil) // resposta por posição já incorporada e descartada
        #expect(try session.programDraft().routines.map(\.name) == ["Costas e bíceps", "Peito e tríceps"])
    }

    // 10. Sem duplicação no list_nutrition_plans.
    @Test("list_nutrition_plans: itens só estruturados (com id)")
    func nutritionPlansItemsStructured() async throws {
        let f = try CopilotEditFixture()
        let (_, _, item) = try f.makePlan()
        let result = await f.toolbox.toolbox().execute(ToolCall(id: "1", name: "list_nutrition_plans", argumentsJSON: "{}"))
        let json = try JSONValue.parse(result.content)
        let items = try #require(json["plans"]?.arrayValue?.first?["days"]?.arrayValue?.first?["meals"]?.arrayValue?.first?["items"]?.arrayValue)
        #expect(items.first?["id"] == .string(item.id.uuidString))
        #expect(!result.content.contains("itemList"))
    }
}
