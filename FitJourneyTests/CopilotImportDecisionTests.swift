import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// C7.4: decisões de exercício que sobrevivem à revisão pela IA (sem loop de "Qual exercício é…?").
@MainActor
@Suite("Copiloto — decisões de exercício no import")
struct CopilotImportDecisionTests {
    /// O que a IA devolve na revisão das quatro fichas: reordena (Perna primeiro), renomeia a abdutora, perde as
    /// repetições dela e a carga "8?" já respondida, reabre a dúvida respondida e cria uma dúvida sobre o exercício novo.
    private static var revisedFourRoutines: String {
        ImportJSON.program(routines: [
            ImportJSON.routine("Perna", weekdays: ["thursday"], exercises: [
                ImportJSON.exercise("Agachamento", name: "Agachamento livre", key: "back-squat"),
                ImportJSON.exercise("Cadeira abdutora máq. 3", name: "Cadeira abdutora", key: nil,
                                    sets: [ImportJSON.set(reps: nil), ImportJSON.set(reps: nil)], confidence: "medium"),
            ]),
            ImportJSON.routine("Peito e tríceps", weekdays: ["monday"], exercises: [
                ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press"),
            ]),
            ImportJSON.routine("Ombro", weekdays: ["tuesday"], exercises: [
                ImportJSON.exercise("Elev lateral", name: "Elevação lateral", key: "lateral-raise",
                                    sets: [ImportJSON.set(load: nil, loadAsWritten: "8?", confidence: "low")]),
            ]),
        ], ambiguities: [
            ImportJSON.ambiguity("\"3x12\" na Perna é 3 séries de 12?", options: ["3 séries de 12", "12 séries de 3"]),
            .object(["path": .string("routines[0].exercises[1].name"),
                     "question": .string("“Cadeira abdutora máq. 3” não está no catálogo. Qual é?"),
                     "options": .array([.string("Cadeira abdutora")])]),
        ])
    }

    @Test("criar novo com nome digitado → revisão por IA: a pergunta não volta e o nome digitado fica")
    func newExerciseSurvivesRevision() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines), .extraction(Self.revisedFourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()

        let question = try #require(session.questions.first { $0.id == "exercise.2.1" })
        #expect(question.suggestedText == "Cadeira abdutora máq. 3") // pré-preenche o campo de "Criar como novo"
        try session.answer(.text("10-15"), for: "exerciseReps.2.1")
        try session.answer(.number(8, unit: "kg"), for: "exerciseLoad.1.1")
        try session.answer(.text("Abdutora sentado"), for: "exercise.2.1")
        try session.answer(.choice("0"), for: "ambiguity.0")
        let decision = try #require(session.exerciseDecisions["cadeira abdutora maq 3"])
        #expect(decision.name == "Abdutora sentado")
        #expect(decision.isNew)
        #expect(decision.slots == ["perna|cadeira abdutora maq 3#0"])

        try await session.reviseWithAI()

        #expect(session.questions.map(\.id) == [])
        #expect(session.phase == .reviewing)
        let draft = try session.programDraft()
        #expect(draft.routines.map(\.name) == ["Perna", "Peito e tríceps", "Ombro"])
        let abductor = draft.routines[0].exercises[1]
        #expect(abductor.name == "Abdutora sentado") // não "Cadeira abdutora", que a IA devolveu
        #expect(abductor.catalogKey == nil)
        #expect(abductor.sets.allSatisfy { $0.repTarget == ProgramDraft.RepTargetDraft(kind: .range, reps: nil, min: 10, max: 15) })
        #expect(draft.routines[2].exercises[0].sets.allSatisfy { $0.load?.value == 8 }) // carga restaurada

        let revise = try #require(gateway.requests.last?.messages.last?.content)
        #expect(revise.contains("Exercícios já confirmados"))
        #expect(revise.contains("\"Cadeira abdutora máq. 3\" → name \"Abdutora sentado\", catalogKey null"))
        let system = try #require(gateway.requests.first?.messages.first?.content)
        #expect(system.contains("não registre ambiguity por isso"))

        let id = try session.apply(target: .newProgram)
        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        let created = try #require(program.sortedRoutines[0].sortedExercises[1].exercise)
        #expect(created.name == "Abdutora sentado")
        #expect(created.catalogKey == nil)
    }

    @Test("escolha do catálogo vale para o mesmo exercício em outra ficha e sobrevive à revisão")
    func catalogDecisionSurvivesRevision() async throws {
        let ambiguity = ImportJSON.ambiguity("Descanso de 60 s?", options: ["Sim", "Não"])
        let initial = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Cadeira abdutora máq. 3")]),
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Supino reto", key: "bench-press"),
                                                ImportJSON.exercise("cadeira abdutora maq 3")]),
        ], ambiguities: [ambiguity])
        let revised = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Supino reto", key: "bench-press"),
                                                ImportJSON.exercise("cadeira abdutora maq 3", name: "Abdutora máquina 3")]),
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Cadeira abdutora máq. 3", name: "Abdutora máquina 3")]),
        ])
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(initial), .extraction(revised)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(Set(session.questions.map(\.id)) == ["exercise.0.0", "exercise.1.1", "ambiguity.0"])

        try session.answer(.exercise("hip-abduction"), for: "exercise.0.0")
        #expect(session.questions.map(\.id) == ["ambiguity.0"]) // a repetição na ficha B também foi decidida
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()

        #expect(session.questions.isEmpty)
        let draft = try session.programDraft()
        for exercise in [draft.routines[0].exercises[1], draft.routines[1].exercises[0]] {
            #expect(exercise.catalogKey == "hip-abduction")
            #expect(exercise.name == "Cadeira abdutora")
        }
    }

    @Test("exercício da biblioteca escolhido pelo id não casa com outro de mesmo nome ao gravar")
    func libraryExerciseIsPinned() async throws {
        let fixture = try ImportFixture()
        let mine = Exercise(name: "Supino reto com barra") // mesmo nome do catálogo (bench-press)
        fixture.context.insert(mine)
        try fixture.context.save()
        let json = ImportJSON.program(mode: "sequential", routines: [ImportJSON.routine("A", exercises: [ImportJSON.exercise("Supino da academia")])])
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(json)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.exercise("exercise:\(mine.id.uuidString)"), for: "exercise.0.0")
        #expect(session.exerciseDecisions["supino da academia"]?.exerciseID == mine.id)
        #expect(try session.exerciseMatches()[0][0]?.id == mine.id)

        let id = try session.apply(target: .newProgram)
        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        #expect(program.sortedRoutines[0].sortedExercises[0].exercise?.id == mine.id)
    }

    @Test("estado salvo antigo (sem os campos novos) decodifica; decisões gravadas voltam ao retomar")
    func stateCompatibility() async throws {
        let id = UUID()
        let old = """
        {"id":"\(id.uuidString)","kind":"program","phase":"interviewing","createdAt":"2026-11-01T10:00:00Z",
         "updatedAt":"2026-11-01T10:05:00Z","attachments":[],"warnings":[],"note":"","selected":[0],
         "resolvedGapIDs":["programName"],"answers":{"programName":{"text":{"_0":"X"}}},"pendingAmbiguityAnswers":{"0":"sim"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(ImportSessionState.self, from: Data(old.utf8))
        #expect(state.id == id)
        #expect(state.exerciseDecisions == nil)
        #expect(state.exerciseAnswers == nil)
        #expect(state.answeredAmbiguities == nil)

        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.text("Abdutora sentado"), for: "exercise.2.1")
        let saved = try #require(fixture.store.load(id: session.id))
        #expect(saved.exerciseDecisions?.count == 1)
        let resumed = ImportSession.resume(saved, context: fixture.context, resolveChat: { throw AIError.notConfigured(reason: "x") },
                                           hasConsented: { true }, store: fixture.store)
        #expect(resumed.exerciseDecisions == session.exerciseDecisions)
        #expect(!resumed.questions.contains { $0.id == "exercise.2.1" })
    }

    @Test("caminho de dúvida sobre o nome de um exercício (o exercício inteiro ou as séries não contam)")
    func exerciseNamePath() {
        #expect(ProgramInterview.exerciseNamePath(" routines[0].exercises[3].name ").map { [$0.0, $0.1] } == [0, 3])
        #expect(ProgramInterview.exerciseNamePath("$.routines[1].exercises[0].catalogKey").map { [$0.0, $0.1] } == [1, 0])
        #expect(ProgramInterview.exerciseNamePath("routines[2].exercises[1].asWritten").map { [$0.0, $0.1] } == [2, 1])
        #expect(ProgramInterview.exerciseNamePath("routines[2].exercises[1]") == nil)
        #expect(ProgramInterview.exerciseNamePath("routines[0].exercises[3].sets[0]") == nil)
        #expect(ProgramInterview.exerciseNamePath("routines[0]") == nil)
    }

    @Test("IA reescreve asWritten na revisão: a decisão casa pela posição anterior e a pergunta não volta")
    func rewrittenAsWritten() async throws {
        let revised = ImportJSON.program(routines: [
            ImportJSON.routine("Peito e tríceps", weekdays: ["monday"], exercises: [
                ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press"),
            ]),
            ImportJSON.routine("Perna", weekdays: ["thursday"], exercises: [
                ImportJSON.exercise("Agachamento", name: "Agachamento livre", key: "back-squat"),
                ImportJSON.exercise("Cadeira abdutora (máquina 3)", name: "Cadeira abdutora", key: nil,
                                    sets: [ImportJSON.set(reps: nil)], confidence: "low"),
            ]),
        ])
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines), .extraction(revised)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.text("10-15"), for: "exerciseReps.2.1")
        try session.answer(.text("Abdutora sentado"), for: "exercise.2.1")
        try session.skip("exerciseLoad.1.1")
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()

        #expect(session.questions.isEmpty)
        let abductor = try #require(session.programImport?.routines[1].exercises[1])
        #expect(abductor.asWritten == "Cadeira abdutora máq. 3") // restaurado
        #expect(abductor.name == "Abdutora sentado")
        #expect(abductor.catalogKey == nil)
        #expect(abductor.sets.allSatisfy { $0.repTarget == ProgramDraft.RepTargetDraft(kind: .range, reps: nil, min: 10, max: 15) })
    }

    @Test("decisão não sobrescreve o mesmo exercício que a IA já casou com confiança alta em outra ficha")
    func propagationRespectsConfidentMatch() async throws {
        let json = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Abdutora")]),
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Abdutora", name: "Cadeira abdutora", key: "hip-abduction")]),
            ImportJSON.routine("C", exercises: [ImportJSON.exercise("Abdutora", confidence: "low")]),
        ])
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(json)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(session.questions.map(\.id) == ["exercise.0.0", "exercise.2.0"])
        try session.answer(.text("Abdutora sentado"), for: "exercise.0.0")
        #expect(session.questions.isEmpty) // C (sem casamento) herdou a resposta
        let draft = try session.programDraft()
        #expect(draft.routines.map { $0.exercises[0].name } == ["Abdutora sentado", "Cadeira abdutora", "Abdutora sentado"])
        #expect(draft.routines[1].exercises[0].catalogKey == "hip-abduction")
    }

    @Test("dúvida respondida some só no mesmo caminho; dúvida sobre o exercício inteiro decidido fica")
    func answeredAmbiguityKeyIncludesPath() async throws {
        let question = "Descanso de 60 s?"
        func doubt(_ path: String, _ text: String = question) -> JSONValue {
            .object(["path": .string(path), "question": .string(text), "options": .array([.string("Sim"), .string("Não")])])
        }
        let initial = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Abdutora máq. 3")]),
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Supino reto", key: "bench-press")]),
        ], ambiguities: [doubt("routines[0]"), doubt("routines[1]")])
        let revised = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Abdutora máq. 3", name: "Abdutora sentado")]),
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Supino reto", key: "bench-press")]),
        ], ambiguities: [doubt("routines[0]"), doubt("routines[1]"),
                         doubt("routines[0].exercises[0]", "São 3 ou 4 séries?"),
                         doubt("routines[0].exercises[0].name", "Qual é esse exercício?")])
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(initial), .extraction(revised)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.text("Abdutora sentado"), for: "exercise.0.0")
        try session.answer(.choice("0"), for: "ambiguity.0") // só a da ficha A
        try await session.reviseWithAI()

        let remaining = try #require(session.programImport?.ambiguities)
        #expect(remaining.map(\.path) == ["routines[1]", "routines[0].exercises[0]"])
    }

    @Test("resumo da resposta de exercício novo com nome")
    func answerSummary() {
        let question = ImportQuestion(id: "exercise.0.0", gapKind: .unmatchedExercise, field: .exercise(routine: 0, exercise: 0),
                                      prompt: "P", detail: nil, kind: .exercise(suggestions: [], allowsNew: true),
                                      isRequired: false, source: nil)
        #expect(ImportAnswerSummary.text(question: question, answer: .text("Abdutora sentado")) == "Exercício novo: Abdutora sentado")
    }
}
