import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
@Suite("Metas diárias — soma dos alimentos e estimativa da IA")
struct NutritionTargetsTests {
    // MARK: Soma no aparelho

    @Test("soma um dia completo e arredonda")
    func sumCompleteDay() {
        let sum = PlannedTargetsSum.targets(days: [[
            NutrientValues(kcal: 140.4, protein: 12, carbs: 1, fat: 10),
            NutrientValues(kcal: 300, protein: 8.6, carbs: 60, fat: 2),
        ]])
        #expect(sum.kcal == 440)
        #expect(sum.protein == 21)
        #expect(sum.carbs == 61)
        #expect(sum.fat == 12)
        #expect(sum.fiber == nil) // nenhum item tem fibra
    }

    @Test("nutriente faltando num item → sem soma desse nutriente")
    func sumNeedsEveryItem() {
        let sum = PlannedTargetsSum.targets(days: [[
            NutrientValues(kcal: 200, protein: 10),
            NutrientValues(kcal: 100),
        ]])
        #expect(sum.kcal == 300)
        #expect(sum.protein == nil)
        #expect(sum.hasAny)
    }

    @Test("várias variações → média dos dias completos; dia vazio não conta")
    func sumAveragesDays() {
        let sum = PlannedTargetsSum.targets(days: [
            [NutrientValues(kcal: 2000)],
            [NutrientValues(kcal: 1500), NutrientValues(kcal: 1000)],
            [],
            [NutrientValues(protein: 50)], // sem kcal: fica fora da média de kcal
        ])
        #expect(sum.kcal == 2250)
        #expect(sum.protein == 50)
    }

    @Test("sem valores → vazio")
    func sumEmpty() {
        let sum = PlannedTargetsSum.targets(days: [[NutrientValues(), NutrientValues()]])
        #expect(!sum.hasAny)
    }

    // MARK: Leitura da resposta da IA

    @Test("resposta da IA: arredonda e descarta o implausível")
    func decodeTargets() throws {
        let values = try #require(ImportSession.decodeTargets(#"{"kcal":2150.6,"protein":9000,"carbs":240,"fat":null,"fiber":28}"#))
        #expect(values.kcal == 2151)
        #expect(values.protein == nil)
        #expect(values.carbs == 240)
        #expect(values.fat == nil)
        #expect(values.fiber == 28)
        #expect(ImportSession.decodeTargets(#"{"kcal":null,"protein":null,"carbs":null,"fat":null,"fiber":20}"#) == nil)
        #expect(ImportSession.decodeTargets("sem json") == nil)
    }

    // MARK: Importação

    /// Dieta com kcal e proteína escritas; carboidrato e gordura ausentes.
    private func analyzedSession(_ fixture: ImportFixture, extra replies: [ScriptedImportGateway.Reply] = [])
        async throws -> (ImportSession, ScriptedImportGateway) {
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.nutrition())] + replies)
        let session = fixture.session(.nutrition, gateway: gateway)
        try await session.add([RawAttachment(filename: "dieta.txt", data: Data("Café 07:30 ovos".utf8))])
        try await session.analyze()
        return (session, gateway)
    }

    @Test("sem estimativa: o escrito vale e a falta aparece")
    func originBeforeEstimate() async throws {
        let fixture = try ImportFixture()
        let (session, _) = try await analyzedSession(fixture)
        let draft = try session.nutritionDraft()
        #expect(draft.targets.kcal == 2200)
        #expect(draft.targets.protein == 150)
        #expect(draft.targets.carbs == nil)
        let origin = try #require(session.nutritionTargetsOrigin())
        #expect(origin.missing)
        #expect(!origin.estimated)
    }

    @Test("estimar: uma chamada só de texto; preenche só o que falta; remover volta ao escrito")
    func estimateFillsMissingOnly() async throws {
        let fixture = try ImportFixture()
        let estimate = #"{"kcal":1900,"protein":120,"carbs":230,"fat":65,"fiber":25}"#
        let (session, gateway) = try await analyzedSession(fixture, extra: [.extraction(estimate)])
        try await session.estimateTargets()

        let request = try #require(gateway.requests.last)
        #expect(request.tools.map(\.name) == [CopilotPrompt.submitTargetsTool])
        #expect(request.messages.first?.content == CopilotPrompt.targetsEstimateSystem)
        #expect(request.messages.allSatisfy { $0.parts.isEmpty }) // os arquivos não vão de novo
        #expect(request.messages.last?.content.contains("Ovo mexido") == true)

        let draft = try session.nutritionDraft()
        #expect(draft.targets.kcal == 2200) // escrito no arquivo vence
        #expect(draft.targets.protein == 150)
        #expect(draft.targets.carbs == 230)
        #expect(draft.targets.fat == 65)
        #expect(draft.targets.fiber == 25)
        let origin = try #require(session.nutritionTargetsOrigin())
        #expect(origin.estimated)
        #expect(!origin.missing)

        session.clearEstimatedTargets()
        #expect(try session.nutritionDraft().targets.carbs == nil)
    }

    @Test("estimativa vai para o plano criado e sobrevive à retomada")
    func estimateAppliedAndPersisted() async throws {
        let fixture = try ImportFixture()
        let estimate = #"{"kcal":1900,"protein":120,"carbs":230,"fat":65,"fiber":null}"#
        let (session, _) = try await analyzedSession(fixture, extra: [.extraction(estimate)])
        try await session.estimateTargets()
        #expect(fixture.store.load(id: session.id)?.estimatedTargets?.carbs == 230)

        if session.phase == .interviewing { try session.finishInterview() }
        let id = try session.apply(target: .newNutritionPlan)
        let plan = try #require(try fixture.context.fetch(FetchDescriptor<NutritionPlan>()).first { $0.id == id })
        #expect(plan.targetKcal == 2200)
        #expect(plan.targetCarbs == 230)
        #expect(plan.targetFat == 65)
    }

    @Test("resposta inútil → erro claro, nada muda")
    func estimateUnusable() async throws {
        let fixture = try ImportFixture()
        let (session, _) = try await analyzedSession(fixture, extra: [.extraction(#"{"kcal":null,"protein":null,"carbs":null,"fat":null,"fiber":null}"#)])
        await #expect(throws: ImportError.targetsUnavailable) { try await session.estimateTargets() }
        #expect(session.estimatedTargets == nil)
        #expect(!session.isEstimatingTargets)
    }
}
