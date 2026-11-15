import Foundation
import SwiftData
import Testing
@testable import FitJourney

// Correções da revisão da importação v2: cabeçalho do remendo não apaga (M1), extração decodificada sobrevive a
// reparo que falha (M3), versão do contrato pela estrutura (M4), expiração do segundo plano (M5), conflitos (B1).

@MainActor
@Suite("Importação v2 · correções da revisão")
struct ImportV2ReviewFixTests {
    private func program() throws -> ProgramImport {
        try #require(ImportValidation.lenientProgram(ImportJSON.program(routines: [
            ImportJSON.routine("A", weekdays: ["monday"], exercises: [ImportJSON.exercise("Supino reto", key: "bench-press")]),
        ])))
    }

    private func patch<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("M1: null no cabeçalho mantém o valor atual; weekdays vazio mantém os dias")
    func headerNullKeeps() throws {
        let base = try program()
        let json = #"""
        {"operations":[
          {"op":"updateProgram","id":null,"after":null,"program":{"name":null,"goal":null,"goalText":null,"scheduleMode":null,"durationWeeks":12,"notes":null},"routine":null,"exercise":null},
          {"op":"updateRoutine","id":"r0","after":null,"program":null,"routine":{"name":null,"symbol":"B","weekdays":[],"notes":null},"exercise":null}
        ],"newAmbiguities":[]}
        """#
        let result = try patch(json, as: ProgramImportPatch.self).applied(to: base)
        #expect(result.name == base.name && result.name != nil)
        #expect(result.scheduleMode == base.scheduleMode)
        #expect(result.durationWeeks == 12)
        #expect(result.routines[0].name == "A")
        #expect(result.routines[0].symbol == "B")
        #expect(result.routines[0].weekdays == [.monday])
    }

    @Test("M1: dieta — updatePlan, updateTargets e updateDay com null mantêm o que foi lido")
    func nutritionHeaderNullKeeps() throws {
        var base = TypicalImports.nutrition(macros: true)
        base.targets.kcal = 2000
        base.targets.protein = 150
        base.days[0].weekdays = [.monday, .tuesday]
        let json = #"""
        {"operations":[
          {"op":"updatePlan","id":null,"after":null,"plan":{"name":null,"goal":"Emagrecer","notes":null},"targets":null,"day":null,"meal":null},
          {"op":"updateTargets","id":null,"after":null,"plan":null,"targets":{"kcal":1800,"protein":null,"carbs":null,"fat":null,"fiber":null,"waterMilliliters":null,"confidence":"high","source":null},"day":null,"meal":null},
          {"op":"updateDay","id":"d0","after":null,"plan":null,"targets":null,"day":{"name":null,"weekdays":[],"notes":null},"meal":null}
        ],"newAmbiguities":[]}
        """#
        let result = try patch(json, as: NutritionImportPatch.self).applied(to: base)
        #expect(result.name == base.name)
        #expect(result.goal == "Emagrecer")
        #expect(result.targets.kcal == 1800)
        #expect(result.targets.protein == 150)
        #expect(result.days[0].name == base.days[0].name)
        #expect(result.days[0].weekdays == [.monday, .tuesday])
    }

    @Test("B1: o mesmo id em operações conflitantes é recusado")
    func conflictingIDs() throws {
        let base = try program()
        let json = #"""
        {"operations":[
          {"op":"removeExercise","id":"r0e0","after":null,"program":null,"routine":null,"exercise":null},
          {"op":"removeExercise","id":"R0E0","after":null,"program":null,"routine":null,"exercise":null}
        ],"newAmbiguities":[]}
        """#
        #expect(throws: ImportPatchError.self) { try patch(json, as: ProgramImportPatch.self).applied(to: base) }
    }

    @Test("M3: remendo que falha não descarta a extração que já decodificou")
    func failedRepairKeepsBase() async throws {
        let broken = ImportJSON.program(routines: [ImportJSON.routine("A", weekdays: ["monday"], exercises: [
            ImportJSON.exercise("Supino reto", key: "bench-press"),
            ImportJSON.exercise("   "),
        ])])
        for reply in [ScriptedImportGateway.Reply.failure(.server(status: 503, message: "x")), .text("não sei")] {
            let fixture = try ImportFixture()
            let gateway = ScriptedImportGateway([.extraction(broken), reply])
            let session = fixture.session(.program, gateway: gateway)
            try await session.add([fixture.pdf()])
            try await session.analyze()
            #expect(gateway.requests.count == 2)
            #expect(session.phase != .failed)
            #expect(session.programImport?.routines[0].exercises.count == 2)
        }
    }

    @Test("M3/M2: reparo de extração sem fichas pede só o objeto inteiro")
    func emptyRoutinesAskWholeObject() async throws {
        let empty = ImportJSON.program(routines: [])
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(empty), .extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        if gateway.requests.count == 2 {
            #expect(gateway.requests[1].tools.map(\.name) == [CopilotPrompt.submitExtractionTool])
            #expect(session.programImport?.routines.count == 4)
        }
    }

    @Test("M4: versão pela estrutura do JSON, não por texto solto")
    func wireVersion() {
        let v1Program = #"{"routines":[{"exercises":[{"asWritten":"Supino \"setGroups\"","sets":[]}]}]}"#
        let v2Program = #"{"routines":[{"exercises":[{"asWritten":"Supino \"sets\"","setGroups":[]}]}]}"#
        #expect(ImportWireVersion.detect(v1Program, kind: .program) == .v1)
        #expect(ImportWireVersion.detect(v2Program, kind: .program) == .v2)
        // Nota com "kcal" no texto num item v2 (macros) não vira v1; item com kcal direto é v1.
        let v2Nutrition = #"{"days":[{"meals":[{"items":[{"name":"Arroz","notes":"\"kcal\" ilegível","macros":null}]}]}]}"#
        let v1Nutrition = #"{"days":[{"meals":[{"items":[{"name":"Arroz","notes":"\"macros\"","kcal":130,"protein":null}]}]}]}"#
        #expect(ImportWireVersion.detect(v2Nutrition, kind: .nutrition) == .v2)
        #expect(ImportWireVersion.detect(v1Nutrition, kind: .nutrition) == .v1)
        #expect(ImportWireVersion.detect("{}", kind: .nutrition) == .v2)
    }

    @Test("B7: reps normalizado (caixa e espaços) na validação do v2")
    func repsNormalized() throws {
        var compact = TypicalImports.program(setSource: false).compacted()
        compact.routines[0].exercises[0].setGroups[0].reps = " AMRAP "
        compact.routines[0].exercises[1].setGroups[0].reps = "8 - 12"
        #expect(compact.validationIssues().isEmpty)
    }

    @Test("M5: expiração do segundo plano cancela, grava falha segura e a restauração não fica em análise")
    func backgroundExpiry() async throws {
        let fixture = try ImportFixture()
        final class Box: @unchecked Sendable { var expire: (@MainActor () -> Void)? }
        let box = Box()
        let gateway = MealLogFakeGateway([.hang])
        let session = ImportSession(kind: .program, context: fixture.context,
                                    resolveChat: { ResolvedChat(gateway: gateway, model: "m") }, hasConsented: { true },
                                    store: fixture.store, beginBackground: { _, onExpire in
                                        box.expire = onExpire
                                        return {}
                                    })
        try await session.add([fixture.pdf()])
        let task = Task { try await session.analyze() }
        for _ in 0 ..< 400 where gateway.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.phase == .analyzing)
        box.expire?()
        // Gravado na hora (o app pode ser suspenso logo depois).
        #expect(session.phase == .failed)
        #expect(fixture.store.load(id: session.id)?.phase == .failed)
        try await task.value
        #expect(session.phase == .failed)
        #expect(session.failureMessage == ImportSession.backgroundExpiredMessage)
        let stored = try #require(fixture.store.load(id: session.id))
        let restored = ImportSession.resume(stored, context: fixture.context, resolveChat: { ResolvedChat(gateway: gateway, model: "m") },
                                            hasConsented: { true }, store: fixture.store)
        #expect(restored.phase != .analyzing)
    }
}
