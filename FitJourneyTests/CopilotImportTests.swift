import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// Gateway roteirizado para o import: cada chamada devolve a próxima resposta (`submit_extraction` com o JSON
/// dado ou texto). Guarda os pedidos para conferir anexos e reparo.
final class ScriptedImportGateway: ChatGateway, StructuredCompleting, @unchecked Sendable {
    enum Reply {
        case extraction(String)
        case text(String)
        case failure(AIError)
    }

    let provider: AIProviderID
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [ChatRequest] = []
    var requests: [ChatRequest] { lock.withLock { recorded } }

    init(provider: AIProviderID = .anthropic, _ replies: [Reply]) {
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
            case let .extraction(json)?:
                continuation.yield(.toolCall(id: "call_\(UUID().uuidString.prefix(6))", name: "submit_extraction", argumentsJSON: json))
                continuation.yield(.finished(reason: .toolCalls))
                continuation.finish()
            case let .text(text)?:
                continuation.yield(.delta(text))
                continuation.yield(.finished(reason: .stop))
                continuation.finish()
            case let .failure(error)?:
                continuation.finish(throwing: error)
            case nil:
                continuation.finish(throwing: AIError.server(status: 500, message: "sem roteiro"))
            }
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        throw AIError.server(status: 500, message: "não usado")
    }
}

/// Monta JSON de extração que passa no schema estrito (todas as chaves, `null` explícito).
enum ImportJSON {
    static func n(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func n(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
    static func source(_ file: String = "ficha.pdf", page: Int? = 1) -> JSONValue {
        .object(["file": .string(file), "page": page.map { .number(Double($0)) } ?? .null])
    }

    static func set(reps: Int? = 12, load: Double? = 30, loadAsWritten: String? = nil, kind: String? = "working",
                    confidence: String = "high") -> JSONValue {
        .object([
            "kind": n(kind),
            "repTarget": reps.map { .object(["kind": .string("fixed"), "reps": .number(Double($0)), "min": .null, "max": .null]) } ?? .null,
            "holdSeconds": .null,
            "load": load.map { .object(["kind": .string("weight"), "value": .number($0), "unit": .string("kg")]) } ?? .null,
            "loadAsWritten": n(loadAsWritten), "restSeconds": .null, "tempo": .null, "rir": .null, "rpe": .null, "cardio": .null,
            "notes": .null, "confidence": .string(confidence), "source": .null,
        ])
    }

    static func exercise(_ asWritten: String, name: String? = nil, key: String? = nil, sets: [JSONValue]? = nil,
                         confidence: String = "high") -> JSONValue {
        .object([
            "asWritten": .string(asWritten), "name": n(name), "catalogKey": n(key), "restSeconds": .number(90),
            "groupLabel": .null, "notes": .null, "confidence": .string(confidence), "source": source(),
            "sets": .array(sets ?? [set(), set(), set()]),
        ])
    }

    static func routine(_ name: String?, weekdays: [String] = [], exercises: [JSONValue]) -> JSONValue {
        .object([
            "name": n(name), "symbol": .null, "weekdays": .array(weekdays.map(JSONValue.string)), "notes": .null,
            "confidence": .string("high"), "source": source(), "exercises": .array(exercises),
        ])
    }

    static func program(name: String? = "Programa da Ana", mode: String? = "weekly", routines: [JSONValue],
                        ambiguities: [JSONValue] = []) -> String {
        JSONValue.object([
            "name": n(name), "goal": .string("hypertrophy"), "goalText": .null, "scheduleMode": n(mode), "durationWeeks": .number(8),
            "notes": .null, "confidence": .string("high"), "source": source(), "routines": .array(routines),
            "ambiguities": .array(ambiguities),
        ]).jsonString()
    }

    static func ambiguity(_ question: String, options: [String]) -> JSONValue {
        .object(["path": .string("routines[0]"), "question": .string(question), "options": .array(options.map(JSONValue.string))])
    }

    /// Quatro fichas (o caso do personal com "Peito e tríceps", "Ombro", "Perna", "Costas e bíceps").
    static var fourRoutines: String {
        program(routines: [
            routine("Peito e tríceps", weekdays: ["monday"], exercises: [
                exercise("Supino reto", name: "Supino reto com barra", key: "bench-press"),
                exercise("Tríceps corda", name: "Tríceps na polia (corda)", key: "triceps-pushdown"),
            ]),
            routine("Ombro", weekdays: ["tuesday"], exercises: [
                exercise("Desenv. halteres", name: "Desenvolvimento com halteres", key: "dumbbell-shoulder-press"),
                exercise("Elev lateral", name: "Elevação lateral", key: "lateral-raise",
                         sets: [set(load: nil, loadAsWritten: "8?", confidence: "low"), set(load: nil, loadAsWritten: "8?", confidence: "low")]),
            ]),
            routine("Perna", weekdays: ["thursday"], exercises: [
                exercise("Agachamento", name: "Agachamento livre", key: "back-squat"),
                exercise("Cadeira abdutora máq. 3", name: nil, key: nil, sets: [set(reps: nil), set(reps: nil)]),
            ]),
            routine("Costas e bíceps", weekdays: ["friday"], exercises: [
                exercise("Puxada", name: "Puxada frontal", key: "lat-pulldown"),
                exercise("Rosca direta", name: "Rosca direta com barra", key: "barbell-curl"),
            ]),
        ], ambiguities: [ambiguity("\"3x12\" na Perna é 3 séries de 12?", options: ["3 séries de 12", "12 séries de 3"])])
    }

    static func nutrition(name: String? = "Dieta da nutri", time: String? = "07:30", quantity: Double? = 2) -> String {
        JSONValue.object([
            "name": n(name), "goal": .null, "notes": .null, "confidence": .string("high"), "source": source("dieta.jpg", page: nil),
            "targets": .object(["kcal": .number(2200), "protein": .number(150), "carbs": .null, "fat": .null, "fiber": .null,
                                "waterMilliliters": .null, "confidence": .string("high"), "source": .null]),
            "days": .array([.object([
                "name": .string("Todos os dias"), "weekdays": .array([]), "notes": .null, "confidence": .string("high"), "source": .null,
                "meals": .array([.object([
                    "name": .string("Café da manhã"), "time": n(time), "notes": .null, "confidence": .string("high"), "source": .null,
                    "items": .array([.object([
                        "asWritten": .string("2 ovos mexidos"), "name": .string("Ovo mexido"), "quantity": n(quantity),
                        "unit": quantity == nil ? .null : .string("unit"), "kcal": .number(140), "protein": .number(12), "carbs": .null,
                        "fat": .null, "fiber": .null, "notes": .null, "confidence": .string("high"), "source": .null,
                        "substitutions": .array([.object(["name": .string("Tofu"), "quantity": .number(100), "unit": .string("grams"),
                                                          "kcal": .null, "protein": .null, "carbs": .null, "fat": .null, "notes": .null])]),
                    ])]),
                ])]),
            ])]),
            "ambiguities": .array([]),
        ]).jsonString()
    }
}

@MainActor
struct ImportFixture {
    let persistence: PersistenceFixture
    let store = InMemoryImportSessionStore()
    var consented = true
    var context: ModelContext { persistence.context }

    init() throws { persistence = try PersistenceFixture(seed: true) }

    func session(_ kind: ImportSession.Kind, gateway: ScriptedImportGateway, model: String = "claude-opus-5-5") -> ImportSession {
        let consented = consented
        return ImportSession(kind: kind, context: context, resolveChat: { ResolvedChat(gateway: gateway, model: model) },
                             hasConsented: { consented }, store: store)
    }

    func pdf() -> RawAttachment { RawAttachment(filename: "ficha.pdf", data: AttachmentFixtures.pdf(pages: 2)) }
}

@MainActor
@Suite("Copiloto — importar treino/dieta")
struct CopilotImportTests {
    private static func contract(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "contracts").appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("schemas embutidos == arquivos em contracts/", arguments: [
        ("program-import-v1.schema.json", ImportSchemas.programImportV1),
        ("nutrition-import-v1.schema.json", ImportSchemas.nutritionImportV1),
    ])
    func embeddedMatchesFile(pair: (String, String)) throws {
        #expect(try JSONValue.parse(try Self.contract(pair.0)) == (try JSONValue.parse(pair.1)))
    }

    @Test("exemplos válidos passam no schema + Codable + regras")
    func examplesValidate() {
        guard case let .valid(program) = ImportValidation.program(ImportJSON.fourRoutines) else {
            Issue.record("programa inválido: \(ImportValidation.program(ImportJSON.fourRoutines))"); return
        }
        #expect(program.routines.count == 4)
        guard case .valid = ImportValidation.nutrition(ImportJSON.nutrition()) else { Issue.record("dieta inválida"); return }
        guard case .invalid = ImportValidation.program(#"{"name":"x"}"#) else { Issue.record("deveria falhar"); return }
    }

    @Test("consentimento obrigatório antes de enviar")
    func requiresConsent() async throws {
        var fixture = try ImportFixture()
        fixture.consented = false
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        await #expect(throws: ImportError.consentRequired(AIRecipientResolver.resolve(settings: ProviderSettingsStore().load()))) { try await session.analyze() }
        #expect(gateway.requests.isEmpty)
        #expect(session.phase == .selecting)
    }

    @Test("análise: envia PDF + submit_extraction, detecta 4 fichas, descarta os bytes")
    func analyzeDetectsFourRoutines() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()

        #expect(session.phase == .interviewing)
        #expect(session.detectedGroupCount == 4)
        #expect(session.selected == [0, 1, 2, 3])
        let request = try #require(gateway.requests.first)
        #expect(request.tools.map(\.name) == ["submit_extraction"])
        #expect(request.toolChoice == .tool("submit_extraction"))
        let user = try #require(request.messages.last)
        #expect(user.parts.contains { if case .pdf("ficha.pdf", _) = $0 { true } else { false } })
        #expect(user.content.contains("bench-press=Supino reto com barra")) // catálogo para casar
        // O estado gravado não tem bytes: só metadados.
        let saved = try #require(fixture.store.load(id: session.id))
        #expect(saved.attachments.first?.filename == "ficha.pdf")
        #expect(saved.attachments.first?.pageCount == 2)
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains(AttachmentFixtures.pdf(pages: 2).base64EncodedString().prefix(40)))
    }

    @Test("provedor sem PDF nativo recebe as páginas como imagens")
    func chatGPTGetsRasterizedPages() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway(provider: .chatGPT, [.extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway, model: "gpt-6")
        try await session.add([fixture.pdf()])
        try await session.analyze()
        let parts = try #require(gateway.requests.first?.messages.last?.parts)
        #expect(parts.filter { if case .image = $0 { true } else { false } }.count == 2)
        #expect(!parts.contains { if case .pdf = $0 { true } else { false } })
    }

    @Test("lacunas e perguntas: obrigatórias primeiro, exercício sem casamento, carga ilegível, ambiguidade")
    func gapsAndQuestions() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()

        let ids = session.questions.map(\.id)
        #expect(ids.first == "exerciseReps.2.1") // reps ausentes na cadeira abdutora: obrigatória
        #expect(ids.contains("exercise.2.1")) // "Cadeira abdutora máq. 3" sem casamento
        #expect(ids.contains("exerciseLoad.1.1")) // "8?" ilegível
        #expect(ids.contains("ambiguity.0"))
        #expect(!session.canFinishInterview)

        let exercise = try #require(session.questions.first { $0.id == "exercise.2.1" })
        guard case let .exercise(suggestions, allowsNew) = exercise.kind else { Issue.record("tipo errado"); return }
        #expect(allowsNew)
        #expect(suggestions.first?.id == "hip-abduction") // "Cadeira abdutora" sugerida
        #expect(exercise.gapKind == .unmatchedExercise)
        let load = try #require(session.questions.first { $0.id == "exerciseLoad.1.1" })
        guard case let .number(units, _, _) = load.kind else { Issue.record("tipo errado"); return }
        #expect(units == ["kg", "lb"])
        #expect(load.detail?.contains("8?") == true)
        #expect(load.detail?.contains("ficha.pdf, p. 1") == true)
    }

    @Test("respostas atualizam o rascunho sem nova chamada")
    func answersUpdateDraftLocally() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()

        try session.answer(.text("10-15"), for: "exerciseReps.2.1")
        try session.answer(.number(8, unit: "kg"), for: "exerciseLoad.1.1")
        try session.answer(.exercise(ImportQuestion.newExerciseOptionID), for: "exercise.2.1")
        #expect(throws: ImportAnswerError.self) { try session.answer(.text("x"), for: "inexistente") }
        #expect(session.canFinishInterview)
        try session.skip("ambiguity.0")
        #expect(session.questions.isEmpty)
        try session.finishInterview()
        #expect(session.phase == .reviewing)
        #expect(gateway.requests.count == 1)

        let draft = try session.programDraft()
        let abductor = draft.routines[2].exercises[1]
        #expect(abductor.name == "Cadeira abdutora máq. 3")
        #expect(abductor.sets.allSatisfy { $0.repTarget == ProgramDraft.RepTargetDraft(kind: .range, reps: nil, min: 10, max: 15) })
        #expect(draft.routines[1].exercises[1].sets.allSatisfy { $0.load?.value == 8 })
        #expect(draft.scheduleMode == .weekly)
        #expect(draft.routines.map(\.weekdays) == [[.monday], [.tuesday], [.thursday], [.friday]])
    }

    @Test("escolher fichas: só as marcadas entram e as lacunas das outras somem")
    func selectRoutines() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        session.setSelected(2, included: false)
        #expect(!session.questions.contains { $0.id.hasPrefix("exerciseReps.2") })
        try session.skip("exerciseLoad.1.1")
        try session.skip("ambiguity.0")
        try session.finishInterview()
        #expect(try session.programDraft().routines.map(\.name) == ["Peito e tríceps", "Ombro", "Costas e bíceps"])
    }

    @Test("apply → novo programa inativo, origin .ai, nota de importação")
    func applyNewProgram() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        session.setSelected(2, included: false)
        for question in session.questions where !question.isRequired { try session.skip(question.id) }
        try session.finishInterview()
        let id = try session.apply(target: .newProgram)

        let program = try #require(try fixture.context.fetch(FetchDescriptor<TrainingProgram>()).first { $0.id == id })
        #expect(!program.isActive)
        #expect(program.origin == .ai)
        #expect(program.notes.contains("Importado com IA de 1 arquivo"))
        #expect(program.sortedRoutines.count == 3)
        #expect(program.sortedRoutines[0].sortedExercises[0].exercise?.catalogKey == "bench-press")
        #expect(session.phase == .done)
        #expect(fixture.store.load(id: session.id) == nil) // nada a retomar
    }

    @Test("apply → adicionar fichas a um programa existente (e ativar)")
    func applyToExistingProgram() async throws {
        let fixture = try ImportFixture()
        let (existing, _, _) = try fixture.persistence.makeProgram(name: "Meu", activate: false)
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        for index in [1, 2, 3] { session.setSelected(index, included: false) }
        for question in session.questions where !question.isRequired { try session.skip(question.id) }
        try session.apply(target: .existingProgram(existing.id), activate: true)

        #expect(existing.sortedRoutines.map(\.name) == ["A", "Peito e tríceps"])
        #expect(existing.sortedRoutines[1].sortIndex == 1)
        #expect(existing.isActive)
        #expect(existing.sortedRoutines[1].weekdays.isEmpty) // programa sequencial: dias ignorados
        #expect(existing.sortedRoutines[1].notes.contains("Importado com IA"))
    }

    @Test("apply → nova dieta inativa, author .ai; destino errado é recusado")
    func applyNutritionPlan() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.nutrition, gateway: ScriptedImportGateway([.extraction(ImportJSON.nutrition(quantity: nil))]))
        try await session.add([RawAttachment(filename: "dieta.txt", data: Data("Café 07:30 ovos".utf8))])
        try await session.analyze()
        #expect(session.questions.map(\.id) == ["itemQuantity.0.0.0"])
        try session.answer(.number(3, unit: "unit"), for: "itemQuantity.0.0.0")
        try session.finishInterview()
        #expect(throws: ImportError.targetMismatch) { try session.apply(target: .newProgram) }
        let id = try session.apply(target: .newNutritionPlan)

        let plan = try #require(try fixture.context.fetch(FetchDescriptor<NutritionPlan>()).first { $0.id == id })
        #expect(!plan.isActive)
        #expect(plan.author == .ai)
        #expect(plan.targets.kcal == 2200)
        let item = try #require(plan.sortedDays.first?.sortedMeals.first?.sortedItems.first)
        #expect(item.quantity == 3)
        #expect(item.unit == .unit)
        #expect(item.substitutions.first?.name == "Tofu")
        #expect(plan.sortedDays.first?.sortedMeals.first?.minutesFromMidnight == 7 * 60 + 30)
    }

    @Test("extração inválida → um reparo só de texto (sem reenviar arquivos)")
    func repairOnce() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(#"{"name":"x","routines":[]}"#), .extraction(ImportJSON.fourRoutines)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(session.phase == .interviewing)
        #expect(gateway.requests.count == 2)
        let repair = try #require(gateway.requests.last?.messages.last)
        #expect(repair.parts.isEmpty)
        #expect(repair.content.contains("não passou na validação"))
    }

    @Test("inválida duas vezes → failed com mensagem; retry volta para escolher arquivos")
    func failsAfterRepair() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.text("não sei"), .extraction(#"{"name":1}"#)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(session.phase == .failed)
        #expect(session.failureMessage?.isEmpty == false)
        session.retry()
        #expect(session.phase == .selecting)
        #expect(session.attachments.count == 1) // bytes ainda em memória: dá para tentar de novo
    }

    @Test("erro do provedor → failed com a mensagem do AIError")
    func providerError() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.failure(.rateLimited(retryAfter: 3))]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(session.phase == .failed)
        #expect(session.failureMessage == AIError.rateLimited(retryAfter: 3).localizedDescription)
    }

    @Test("ambiguidade respondida → revisão com IA só com texto")
    func reviseAmbiguity() async throws {
        let fixture = try ImportFixture()
        let revised = ImportJSON.program(routines: [ImportJSON.routine("Peito e tríceps", weekdays: ["monday"], exercises: [
            ImportJSON.exercise("Supino reto", name: "Supino reto com barra", key: "bench-press"),
        ])])
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines), .extraction(revised)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.choice("0"), for: "ambiguity.0")
        #expect(session.hasPendingRevision)
        try await session.reviseWithAI()
        #expect(!session.hasPendingRevision)
        #expect(session.detectedGroupCount == 1)
        let message = try #require(gateway.requests.last?.messages.last)
        #expect(message.parts.isEmpty)
        #expect(message.content.contains("3 séries de 12"))
        #expect(session.phase == .reviewing)
    }

    @Test("retomar: análise interrompida pede os arquivos de novo; entrevista continua de onde parou")
    func resume() async throws {
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.text("12"), for: "exerciseReps.2.1")
        try session.answer(.choice("1"), for: "ambiguity.0")

        let saved = try #require(fixture.store.load(id: session.id))
        let resumed = ImportSession.resume(saved, context: fixture.context,
                                           resolveChat: { throw AIError.notConfigured(reason: "x") },
                                           hasConsented: { true }, store: fixture.store)
        #expect(resumed.phase == .interviewing)
        #expect(!resumed.questions.contains { $0.id == "exerciseReps.2.1" })
        #expect(resumed.answers["exerciseReps.2.1"] == .text("12"))
        #expect(resumed.hasPendingRevision) // resposta à dúvida da IA sobrevive ao fechar o app

        var interrupted = saved
        interrupted.phase = .analyzing
        let again = ImportSession.resume(interrupted, context: fixture.context, resolveChat: { throw AIError.notConfigured(reason: "x") },
                                         hasConsented: { true }, store: fixture.store)
        #expect(again.phase == .selecting)
        #expect(again.needsReattach)
        await #expect(throws: ImportError.noAttachments) { try await again.analyze() }
    }

    @Test("arquivo de estado em disco: grava, lista e apaga")
    func fileStore() throws {
        let directory = URL.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileImportSessionStore(directory: directory)
        let state = ImportSessionState(id: UUID(), kind: .nutrition, phase: .interviewing, createdAt: .now, updatedAt: .now,
                                       attachments: [], warnings: [], note: "", programImport: nil, nutritionImport: nil,
                                       selected: [0], resolvedGapIDs: [], answers: ["planName": .text("X")],
                                       failureMessage: nil, resultID: nil, pendingAmbiguityAnswers: ["0": "sim"])
        try store.save(state)
        #expect(store.pending().map(\.id) == [state.id])
        #expect(store.load(id: state.id)?.answers["planName"] == .text("X"))
        #expect(store.load(id: state.id)?.pendingAmbiguityAnswers == ["0": "sim"])
        store.delete(id: state.id)
        #expect(store.pending().isEmpty)
    }

    @Test("parsing de respostas livres")
    func parsing() {
        #expect(InterviewText.parseReps("8 a 12") == ProgramDraft.RepTargetDraft(kind: .range, reps: nil, min: 8, max: 12))
        #expect(InterviewText.parseReps("10")?.reps == 10)
        #expect(InterviewText.parseReps("até a falha")?.kind == .amrap)
        #expect(InterviewText.parseReps("abc") == nil)
        #expect(InterviewText.parseTime("7h30") == 450)
        #expect(InterviewText.parseTime("19:05") == 1145)
        #expect(InterviewText.parseTime("25:00") == nil)
    }
}
