import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import FitJourney

/// Lógica de apresentação das telas do copiloto (C7.3): etapas da análise, controle por tipo de pergunta,
/// cartões de revisão, cartões de alteração e o fluxo arquivos → análise → pergunta → revisão → apply.
@MainActor
@Suite("Copiloto — telas")
struct CopilotScreensTests {
    private func attachments() -> [AttachmentMetadata] {
        [AttachmentMetadata(id: UUID(), filename: "a.pdf", kind: .pdf, mimeType: "application/pdf", pageCount: 2, byteCount: 10),
         AttachmentMetadata(id: UUID(), filename: "b.pdf", kind: .pdf, mimeType: "application/pdf", pageCount: 1, byteCount: 10),
         AttachmentMetadata(id: UUID(), filename: "c.jpg", kind: .image, mimeType: "image/jpeg", pageCount: nil, byteCount: 10)]
    }

    // MARK: Etapas da análise

    @Test("análise inicial: título pelo nº de arquivos, enviados com resumo, lendo em andamento")
    func analysisSteps() {
        let output = ImportAnalysisPresentation.make(kind: .program, attachments: attachments(), providerName: "OpenAI",
                                                     programImport: nil, nutritionImport: nil, slow: false)
        #expect(output.title == "Lendo 3 arquivos…")
        #expect(output.steps.map(\.id) == ["prepare", "sent", "read", "match"])
        #expect(output.steps.map(\.state) == [.done, .done, .active, .pending])
        #expect(output.steps[1].detail == "2 PDFs · 1 foto")
        #expect(output.subtitle?.contains("OpenAI") == true)
        #expect(output.steps.allSatisfy { !$0.isFinding })
    }

    @Test("um arquivo usa o nome; lenta troca o subtítulo")
    func analysisSingleAndSlow() {
        let single = Array(attachments().prefix(1))
        let output = ImportAnalysisPresentation.make(kind: .nutrition, attachments: single, providerName: "X",
                                                     programImport: nil, nutritionImport: nil, slow: true)
        #expect(output.title == "Lendo a.pdf…")
        #expect(output.subtitle?.contains("demorando") == true)
        #expect(output.steps[2].title.contains("refeições"))
    }

    @Test("revisão da IA mostra o achado e a etapa ativa")
    func revisionSteps() throws {
        guard case let .valid(program) = ImportValidation.program(ImportJSON.fourRoutines) else { Issue.record("inválido"); return }
        let output = ImportAnalysisPresentation.make(kind: .program, attachments: [], providerName: "X",
                                                     programImport: program, nutritionImport: nil, slow: false)
        #expect(output.steps.first?.title == "Encontrei 4 fichas")
        #expect(output.steps.first?.isFinding == true)
        #expect(output.steps.last?.state == .active)
    }

    // MARK: Perguntas → controle

    private func question(_ kind: ImportQuestion.Kind, field: ImportField, gap: ImportGapKind = .lowConfidence, required: Bool = false) -> ImportQuestion {
        ImportQuestion(id: field.key, gapKind: gap, field: field, prompt: "P", detail: nil, kind: kind, isRequired: required, source: nil)
    }

    @Test("choice → chips; ambiguidade ganha 'Outra resposta'")
    func choiceControl() {
        let options = [ImportQuestion.Option(id: "a", label: "3 séries de 12", detail: nil), .init(id: "b", label: "12 de 3", detail: nil)]
        let plain = ImportQuestionControl.make(for: question(.choice(options), field: .scheduleMode, gap: .missingRequired, required: true))
        guard case let .chips(replies, free) = plain else { Issue.record("tipo"); return }
        #expect(replies.map(\.id) == ["a", "b"])
        #expect(replies.map(\.title) == ["3 séries de 12", "12 de 3"])
        #expect(!free)
        let ambiguity = ImportQuestionControl.make(for: question(.choice(options), field: .ambiguity(index: 0), gap: .ambiguity))
        guard case let .chips(_, freeText) = ambiguity else { Issue.record("tipo"); return }
        #expect(freeText)
    }

    @Test("number: carga usa passo 0,5 e 'manter'; reps usa chips de valores comuns; quantidade por unidade")
    func numberControls() {
        let load = ImportQuestionControl.make(for: question(.number(units: ["kg", "lb"], defaultUnit: "kg", suggested: 8),
                                                            field: .exerciseLoad(routine: 0, exercise: 0)))
        guard case let .number(loadSpec) = load else { Issue.record("tipo"); return }
        #expect(loadSpec.step == 0.5)
        #expect(loadSpec.value == 8)
        #expect(loadSpec.offersKeep)
        #expect(loadSpec.units == ["kg", "lb"])

        let reps = ImportQuestionControl.make(for: question(.number(units: ["reps"], defaultUnit: "reps", suggested: nil),
                                                            field: .exerciseReps(routine: 0, exercise: 0), gap: .missingRequired, required: true))
        guard case let .number(repsSpec) = reps else { Issue.record("tipo"); return }
        #expect(repsSpec.quickValues == [8, 10, 12, 15])
        #expect(!repsSpec.offersKeep)
        #expect(repsSpec.range.lowerBound == 1)

        let quantity = ImportQuestionControl.make(for: question(.number(units: ["g", "unit"], defaultUnit: "g", suggested: nil),
                                                                field: .itemQuantity(day: 0, meal: 0, item: 0), gap: .missingRequired))
        guard case let .number(quantitySpec) = quantity else { Issue.record("tipo"); return }
        #expect(quantitySpec.step == 10)
        #expect(quantitySpec.value == 100)
    }

    @Test("exercise, multi e text mapeiam para o controle certo")
    func otherControls() {
        let suggestions = [ImportQuestion.Option(id: "hip-abduction", label: "Abdutora", detail: nil)]
        guard case let .exercise(replies, allowsNew) = ImportQuestionControl.make(
            for: question(.exercise(suggestions: suggestions, allowsNew: true), field: .exercise(routine: 0, exercise: 0), gap: .unmatchedExercise))
        else { Issue.record("tipo"); return }
        #expect(replies.first?.id == "hip-abduction")
        #expect(allowsNew)
        guard case .multi = ImportQuestionControl.make(for: question(.multiChoice(suggestions), field: .routineWeekdays(routine: 0)))
        else { Issue.record("tipo"); return }
        guard case let .text(placeholder) = ImportQuestionControl.make(for: question(.text(placeholder: "07:30"), field: .mealTime(day: 0, meal: 0)))
        else { Issue.record("tipo"); return }
        #expect(placeholder == "07:30")
    }

    @Test("resumo da resposta para a linha recolhida")
    func answerSummary() {
        let options = [ImportQuestion.Option(id: "a", label: "3 séries de 12", detail: nil)]
        let choice = question(.choice(options), field: .scheduleMode)
        #expect(ImportAnswerSummary.text(question: choice, answer: .choice("a")) == "3 séries de 12")
        #expect(ImportAnswerSummary.text(question: choice, answer: .number(8, unit: "kg")) == "8 kg")
        #expect(ImportAnswerSummary.text(question: choice, answer: .text("x")) == "x")
        #expect(ImportAnswerSummary.text(question: choice, answer: .keep) == "Mantido como li")
        #expect(ImportAnswerSummary.text(question: choice, answer: .exercise(ImportQuestion.newExerciseOptionID)) == "Criar como exercício novo")
    }

    // MARK: Cartões de alteração

    @Test("estado do cartão: gravado + transitório")
    func cardState() {
        #expect(CopilotChangePresentation.cardState(.proposed, transient: nil) == .proposed)
        #expect(CopilotChangePresentation.cardState(.needsConfirmation, transient: nil) == .proposed)
        #expect(CopilotChangePresentation.cardState(.applied, transient: nil) == .applied)
        #expect(CopilotChangePresentation.cardState(.undone, transient: nil) == .undone)
        #expect(CopilotChangePresentation.cardState(.discarded, transient: nil) == .discarded)
        #expect(CopilotChangePresentation.cardState(.proposed, transient: .applying) == .applying)
        #expect(CopilotChangePresentation.cardState(.proposed, transient: .failed("x")) == .failed("x"))
        #expect(CopilotChangePresentation.note(for: .needsConfirmation) != nil)
        #expect(CopilotChangePresentation.note(for: .proposed) == nil)
    }

    private func changeSet(operations: [CopilotOperation], scope: CopilotScope) -> CopilotChangeSet {
        CopilotChangeSet(id: "call_1", scope: scope, operations: operations,
                         diff: [CopilotDiffLine(context: "Supino reto · carga", before: "32 kg", after: "34 kg"),
                                CopilotDiffLine(context: "Tríceps corda", before: nil, after: "3 × 12"),
                                CopilotDiffLine(context: "Mergulho", before: "3 × máx.", after: nil)],
                         baseFingerprint: "x", createdAt: .now)
    }

    @Test("CopilotChangeSet → FJChange: modificado, acrescentado, removido; título, área e Ajustar")
    func changeMapping() {
        let routineID = UUID()
        let set = changeSet(operations: [.setRest(exerciseID: UUID(), seconds: 90)], scope: .routine(id: routineID, name: "A"))
        let changes = CopilotChangePresentation.changes(set)
        #expect(changes.map(\.kind) == [.modified, .added, .removed])
        #expect(changes[0].label == "Supino reto · carga")
        #expect(changes[0].before == "32 kg" && changes[0].after == "34 kg")
        #expect(Set(changes.map(\.id)).count == 3)
        #expect(CopilotChangePresentation.title(set) == "Mudar o descanso")
        #expect(CopilotChangePresentation.area(for: set.scope) == .training)
        #expect(CopilotChangePresentation.adjustPrompt(set).contains("Mudar o descanso"))

        let multi = changeSet(operations: [.setRest(exerciseID: UUID(), seconds: 90), .removeExercise(exerciseID: UUID())],
                              scope: .nutritionPlan(id: UUID(), name: "Cut"))
        #expect(CopilotChangePresentation.title(multi) == "2 alterações")
        #expect(CopilotChangePresentation.area(for: multi.scope) == .nutrition)

        let food = CopilotScope.foodLog(day: .now)
        #expect(CopilotChangePresentation.isFoodLog(food))
        #expect(CopilotChangePresentation.area(for: food) == .nutrition)
    }

    @Test("erros do ChangeApplier: sessão em andamento vira conflito com a mensagem do design")
    func errorMapping() {
        #expect(CopilotChangePresentation.transient(for: ChangeApplierError.sessionInProgress(routineName: "A"))
            == .conflict(CopilotChangePresentation.sessionConflictMessage))
        #expect(CopilotChangePresentation.transient(for: ChangeApplierError.targetMissing)
            == .conflict(ChangeApplierError.targetMissing.localizedDescription))
        #expect(CopilotChangePresentation.transient(for: ChangeApplierError.undoExpired)
            == .failed(ChangeApplierError.undoExpired.localizedDescription))
    }

    @Test("mensagem tool com cartão aparece na conversa; sem cartão continua escondida")
    func toolMessageVisibility() throws {
        let fixture = try PersistenceFixture(seed: false)
        let conversation = ChatConversation()
        fixture.context.insert(conversation)
        let user = ChatMessage(role: .user, content: "sobe o supino", sortIndex: 0)
        let tool = ChatMessage(role: .tool, content: "{}", sortIndex: 1)
        tool.toolCallID = "call_1"
        let plainTool = ChatMessage(role: .tool, content: "{}", sortIndex: 2)
        plainTool.toolCallID = "call_2"
        for message in [user, tool, plainTool] {
            message.conversation = conversation
            fixture.context.insert(message)
        }
        let store = CopilotChangeStore()
        #expect(conversation.visibleMessages(including: store).count == 1)
        store.register(changeSet(operations: [.setRest(exerciseID: UUID(), seconds: 60)], scope: .routine(id: UUID(), name: "A")))
        let visible = conversation.visibleMessages(including: store)
        #expect(visible.map(\.sortIndex) == [0, 1])
    }

    // MARK: Prescrição e revisão

    @Test("prescrição: séries × reps · carga · descanso")
    func prescriptionText() {
        let set = ProgramDraft.SetDraft(kind: .working, repTarget: .init(kind: .range, reps: nil, min: 8, max: 12),
                                        holdSeconds: nil, load: .init(kind: .weight, value: 32.5, unit: .kg), restSeconds: nil,
                                        tempo: nil, rir: nil, rpe: nil, cardio: nil, notes: nil)
        let exercise = ProgramDraft.ExerciseDraft(name: "Supino", catalogKey: nil, restSeconds: 90, groupLabel: nil, notes: nil,
                                                  sets: [set, set, set, set])
        #expect(ImportReviewBuilder.prescription(exercise) == "4 × 8–12 · \(FJFormat.number(32.5, maxFractionDigits: 1)) kg · 90 s")
        var noLoad = exercise
        noLoad.sets = [ProgramDraft.SetDraft(kind: .working, repTarget: .init(kind: .amrap, reps: nil, min: nil, max: nil),
                                             holdSeconds: nil, load: nil, restSeconds: nil, tempo: nil, rir: nil, rpe: nil,
                                             cardio: nil, notes: nil)]
        noLoad.restSeconds = nil
        #expect(ImportReviewBuilder.prescription(noLoad) == "1 × máx. · — kg")
    }

    // MARK: Fluxo

    @Test("fluxo: arquivos → análise → 1 pergunta → revisão → apply cria o programa e os ajustes de tela valem")
    func fullFlow() async throws {
        let fixture = try ImportFixture()
        let json = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("Peito", exercises: [
                ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press"),
                ImportJSON.exercise("Crucifixo", name: "Crucifixo", key: nil, sets: [ImportJSON.set(load: nil, loadAsWritten: "8?", confidence: "low")],
                                    confidence: "medium"),
            ]),
        ])
        let gateway = ScriptedImportGateway([.extraction(json)])
        let session = fixture.session(.program, gateway: gateway)

        // Arquivos
        try await session.add([fixture.pdf()])
        #expect(session.attachments.count == 1)
        #expect(ImportAnalysisPresentation.kindSummary(session.attachments) == "1 PDF")

        // Análise
        try await session.analyze()
        #expect(session.phase == .interviewing)
        #expect(session.detectedGroupCount == 1) // uma ficha: a tela de fichas não aparece

        // Pergunta: só a carga ilegível (o exercício sem casamento é opcional e vem depois)
        let loadQuestion = try #require(session.questions.first { $0.id == "exerciseLoad.0.1" })
        guard case let .number(spec) = ImportQuestionControl.make(for: loadQuestion) else { Issue.record("controle errado"); return }
        #expect(spec.offersKeep)
        try session.answer(.number(12, unit: "kg"), for: loadQuestion.id)
        for question in session.questions where !question.isRequired { try session.skip(question.id) }
        #expect(ImportOverview.summary(kind: .program, programImport: session.programImport, nutritionImport: nil,
                                       selected: session.selected, pending: 0).contains("1 ficha"))
        try session.finishInterview()

        // Revisão
        let draft = try session.programDraft()
        let extraction = try #require(session.programImport)
        let matches = try session.exerciseMatches().map { $0.map { $0 != nil } }
        let cards = ImportReviewBuilder.programCards(draft: draft, extraction: extraction, selected: session.selected, matches: matches,
                                                     overrides: [0: .init(name: "Peito e tríceps", symbol: "P", colorName: "blue")],
                                                     colorOffset: 0)
        #expect(cards.count == 1)
        #expect(cards[0].name == "Peito e tríceps")
        #expect(cards[0].exercises.count == 2)
        #expect(cards[0].exercises[0].confidence == .high)
        #expect(cards[0].exercises[0].isNew == false)
        #expect(cards[0].exercises[1].isNew) // Crucifixo sem casamento → será criado

        // Aplicar (+ ajustes de tela)
        let ui = ImportUIState(target: .newProgram)
        ui.name = "Meu ABC"
        ui.routines[0] = .init(name: "Peito e tríceps", symbol: "P", colorName: "blue")
        let id = try session.apply(target: ui.target)
        let name = try ImportOverrides.apply(ui: ui, session: session, resultID: id, context: fixture.context)
        #expect(name == "Meu ABC")
        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        #expect(program.name == "Meu ABC")
        #expect(program.origin == .ai)
        #expect(!program.isActive)
        let routine = try #require(program.sortedRoutines.first)
        #expect(routine.name == "Peito e tríceps")
        #expect(routine.symbol == "P")
        #expect(routine.colorName == "blue")
        #expect(gateway.requests.count == 1)

        // Desfazer do aviso apaga o que foi criado.
        try ImportOverrides.undo(ImportCompletion(kind: .program, resultID: id, createdNew: true, name: name), context: fixture.context)
        #expect(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).contains { $0.id == id } == false)
    }

    @Test("fichas ganham a cor sugerida em sequência quando o usuário não escolhe")
    func defaultRoutineColors() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        for question in session.questions where !question.isRequired { try session.skip(question.id) }
        try session.answer(.text("10"), for: "exerciseReps.2.1")
        try session.finishInterview()
        let ui = ImportUIState(target: .newProgram)
        let id = try session.apply(target: .newProgram)
        try ImportOverrides.apply(ui: ui, session: session, resultID: id, context: fixture.context)
        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        #expect(program.sortedRoutines.map(\.colorName) == ["orange", "blue", "green", "purple"])
        #expect(program.sortedRoutines.map(\.symbol) == ["A", "B", "C", "D"])
    }

    @Test("pendências: sessão viva e gravada aparecem uma vez, a concluída não")
    func pendingCards() throws {
        let fixture = try ImportFixture()
        let coordinator = ImportCoordinator(context: fixture.context, defaults: UserDefaults(suiteName: "cs-\(UUID())")!,
                                            secrets: InMemorySecretStore(), store: fixture.store)
        #expect(coordinator.pending(kind: .program).isEmpty)
        let session = coordinator.start(kind: .program)
        #expect(coordinator.presented?.id == session.id)
        #expect(coordinator.pending(kind: .program).isEmpty) // aberta na folha: não é "continuar"
        coordinator.closeSheet()
        #expect(coordinator.pending(kind: .program).map(\.id) == [session.id])
        #expect(coordinator.pending(kind: .nutrition).isEmpty)
        coordinator.discard(session.id)
        #expect(coordinator.pending(kind: .program).isEmpty)
    }
}
