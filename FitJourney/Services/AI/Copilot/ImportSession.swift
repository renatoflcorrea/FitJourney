import Foundation
import Observation
import SwiftData

/// Erros de pré-condição do import (a UI trata cada um; falhas do provedor viram `phase = .failed`).
enum ImportError: Error, Sendable, Hashable {
    /// Consentimento do Coach ausente (`CoachProfileStore.hasConsented`): mostrar o aviso "o arquivo inteiro vai ao provedor".
    case consentRequired
    case noAttachments
    case wrongPhase
    /// Ainda há perguntas obrigatórias sem resposta.
    case pendingRequiredQuestions
    /// O rascunho final não passou nas regras (lista de problemas, já legível).
    case draftInvalid([String])
    case targetMismatch
    case programNotFound
    case attachment(AttachmentError)
}

extension ImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .consentRequired: String(localized: "Para importar, aceite enviar os arquivos ao provedor de IA.")
        case .noAttachments: String(localized: "Escolha ao menos um arquivo.")
        case .wrongPhase: String(localized: "Esta etapa da importação já passou.")
        case .pendingRequiredQuestions: String(localized: "Responda as perguntas obrigatórias antes de revisar.")
        case let .draftInvalid(issues): String(localized: "Revise a importação: \(issues.prefix(3).joined(separator: "; "))")
        case .targetMismatch: String(localized: "Este destino não combina com o tipo de importação.")
        case .programNotFound: String(localized: "Programa não encontrado.")
        case let .attachment(error): error.localizedDescription
        }
    }
}

/// Importação de treino ou dieta por arquivos com a IA (SPEC §7A.1).
///
/// Fases: `selecting → analyzing → interviewing → reviewing → applying → done` (ou `failed`).
/// - `selecting`: `add(_:)`/`remove(_:)` preparam os anexos (≤ 2048 px, sem EXIF/GPS) **só em memória**.
/// - `analyze()`: exige consentimento; envia anexos + instruções + ferramenta `submit_extraction` (schema
///   estrito), valida localmente (schema → Codable → regras) com **uma** tentativa de reparo sem reenviar os
///   arquivos, e descarta os bytes. Calcula as lacunas.
/// - `interviewing`: `questions` (determinísticas) → `answer(_:for:)` atualiza a extração sem chamar a IA; dúvidas
///   que a própria IA levantou são resolvidas em lote por `reviseWithAI()`. `setSelected(_:included:)` escolhe as
///   fichas/variações a importar.
/// - `reviewing`: `programDraft()`/`nutritionDraft()` para os cartões; `apply(target:activate:)` grava pelo
///   `DraftApplier` (inativo por padrão, `origin = .ai`, nota "Importado de N arquivos").
///
/// O estado (sem bytes) é gravado a cada mudança para retomar com `ImportSession.resume`.
@MainActor
@Observable
final class ImportSession: Identifiable {
    enum Kind: String, Codable, Sendable, Hashable { case program, nutrition }

    enum Phase: String, Codable, Sendable, Hashable {
        case selecting, analyzing, interviewing, reviewing, applying, done, failed
    }

    enum Target: Codable, Sendable, Hashable {
        case newProgram
        case existingProgram(UUID)
        case newNutritionPlan
    }

    let id: UUID
    let kind: Kind
    private(set) var phase: Phase = .selecting
    /// Metadados dos anexos (os bytes ficam em memória só até a análise).
    private(set) var attachments: [AttachmentMetadata] = []
    /// Avisos para a UI (páginas cortadas, custo, arquivos a escolher de novo).
    private(set) var warnings: [String] = []
    /// Observação opcional do usuário enviada junto ("são 4 treinos, ignore o aquecimento").
    var note: String = "" { didSet { persist() } }
    private(set) var programImport: ProgramImport?
    private(set) var nutritionImport: NutritionImport?
    /// Fichas (treino) ou variações (dieta) marcadas para importar.
    private(set) var selected: Set<Int> = []
    /// Lacunas pendentes (só das fichas/variações escolhidas).
    private(set) var gaps: [ImportGap] = []
    /// Perguntas pendentes, na ordem da entrevista (obrigatórias primeiro).
    private(set) var questions: [ImportQuestion] = []
    private(set) var answers: [String: ImportAnswer] = [:]
    private(set) var failureMessage: String?
    /// Programa/plano criado (ou programa que recebeu as fichas).
    private(set) var resultID: UUID?
    /// A sessão foi retomada sem os arquivos (eles não são guardados): escolha de novo para analisar.
    private(set) var needsReattach = false
    private(set) var createdAt: Date

    /// Respostas a dúvidas da IA ainda não aplicadas (`reviseWithAI()`).
    var hasPendingRevision: Bool { !ambiguityAnswers.isEmpty }
    var canFinishInterview: Bool { phase == .interviewing && !questions.contains(where: \.isRequired) }
    /// Quantidade de fichas/variações detectadas.
    var detectedGroupCount: Int { programImport?.routines.count ?? nutritionImport?.days.count ?? 0 }

    @ObservationIgnored private var prepared: [PreparedAttachment] = []
    @ObservationIgnored private var resolved: Set<String> = []
    @ObservationIgnored private var ambiguityAnswers: [Int: String] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let resolveChat: @MainActor () throws -> ResolvedChat
    @ObservationIgnored private let hasConsented: @MainActor () -> Bool
    @ObservationIgnored private let store: any ImportSessionStoring
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let preparer: AttachmentPreparer
    @ObservationIgnored private let rasterizer: PDFRasterizer
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var isDiscarded = false

    /// - Parameters:
    ///   - resolveChat: em produção `{ try ProviderFactory.makeChat(secrets: KeychainSecretStore()) }`.
    ///   - hasConsented: em produção `{ CoachProfileStore().hasConsented }`.
    init(kind: Kind, context: ModelContext, resolveChat: @escaping @MainActor () throws -> ResolvedChat,
         hasConsented: @escaping @MainActor () -> Bool = { CoachProfileStore().hasConsented },
         store: any ImportSessionStoring = FileImportSessionStore(), now: @escaping @MainActor () -> Date = { .now },
         preparer: AttachmentPreparer = AttachmentPreparer(), rasterizer: PDFRasterizer = PDFRasterizer(), id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.context = context
        self.resolveChat = resolveChat
        self.hasConsented = hasConsented
        self.store = store
        self.now = now
        self.preparer = preparer
        self.rasterizer = rasterizer
        createdAt = now()
    }

    /// Retoma uma importação gravada. Análise interrompida volta para `selecting` com `needsReattach`
    /// (os arquivos não são guardados); `applying` volta para `reviewing`.
    static func resume(_ state: ImportSessionState, context: ModelContext,
                       resolveChat: @escaping @MainActor () throws -> ResolvedChat,
                       hasConsented: @escaping @MainActor () -> Bool = { CoachProfileStore().hasConsented },
                       store: any ImportSessionStoring = FileImportSessionStore(),
                       now: @escaping @MainActor () -> Date = { .now }) -> ImportSession {
        let session = ImportSession(kind: state.kind, context: context, resolveChat: resolveChat, hasConsented: hasConsented,
                                    store: store, now: now, id: state.id)
        session.restoring = true
        session.createdAt = state.createdAt
        session.attachments = state.attachments
        session.warnings = state.warnings
        session.note = state.note
        session.programImport = state.programImport
        session.nutritionImport = state.nutritionImport
        session.selected = Set(state.selected)
        session.resolved = Set(state.resolvedGapIDs)
        session.answers = state.answers
        session.failureMessage = state.failureMessage
        session.resultID = state.resultID
        for (key, value) in state.pendingAmbiguityAnswers ?? [:] {
            if let index = Int(key) { session.ambiguityAnswers[index] = value }
        }
        switch state.phase {
        case .selecting, .analyzing:
            session.phase = .selecting
            session.needsReattach = !state.attachments.isEmpty
            session.attachments = []
        case .applying:
            session.phase = .reviewing
        case .failed where state.programImport == nil && state.nutritionImport == nil:
            session.phase = .selecting
            session.needsReattach = !state.attachments.isEmpty
            session.attachments = []
        default:
            session.phase = state.phase
        }
        session.restoring = false
        session.refreshGaps()
        session.persist()
        return session
    }

    var state: ImportSessionState {
        ImportSessionState(id: id, kind: kind, phase: phase, createdAt: createdAt, updatedAt: now(), attachments: attachments,
                           warnings: warnings, note: note, programImport: programImport, nutritionImport: nutritionImport,
                           selected: selected.sorted(), resolvedGapIDs: resolved.sorted(), answers: answers,
                           failureMessage: failureMessage, resultID: resultID,
                           pendingAmbiguityAnswers: ambiguityAnswers.isEmpty ? nil
                               : Dictionary(uniqueKeysWithValues: ambiguityAnswers.map { (String($0.key), $0.value) }))
    }

    // MARK: - Seleção de arquivos

    /// Prepara e acrescenta arquivos (fora da main). Lança `AttachmentError` sem acrescentar nada.
    func add(_ raws: [RawAttachment]) async throws {
        guard phase == .selecting else { throw ImportError.wrongPhase }
        let preparer = preparer
        let existing = prepared
        let new = try await Task.detached(priority: .userInitiated) {
            try preparer.prepare(raws, existing: existing)
        }.value
        prepared += new
        attachments = prepared.map(\.metadata)
        needsReattach = false
        persist()
    }

    /// Texto colado vira um anexo de texto.
    func addPastedText(_ text: String) throws {
        guard phase == .selecting else { throw ImportError.wrongPhase }
        guard prepared.count < AttachmentPreparer.maxFiles else {
            throw ImportError.attachment(.tooManyFiles(max: AttachmentPreparer.maxFiles))
        }
        let attachment = try preparer.preparePastedText(text)
        prepared.append(attachment)
        attachments = prepared.map(\.metadata)
        persist()
    }

    func remove(_ attachmentID: UUID) {
        guard phase == .selecting else { return }
        prepared.removeAll { $0.id == attachmentID }
        attachments = prepared.map(\.metadata)
        persist()
    }

    // MARK: - Análise

    /// Envia os arquivos e extrai. Lança só pré-condições (consentimento, sem arquivos, provedor não
    /// configurado, modelo sem imagens); erros do provedor/validação viram `phase = .failed` com `failureMessage`.
    func analyze() async throws {
        guard phase == .selecting else { throw ImportError.wrongPhase }
        guard hasConsented() else { throw ImportError.consentRequired }
        guard !prepared.isEmpty else { throw ImportError.noAttachments }
        let chat = try resolveChat()
        let capabilities = AttachmentCapabilities.resolve(provider: chat.gateway.provider, model: chat.model)
        let attachmentsToSend = prepared
        let rasterizer = rasterizer
        let encoded: AttachmentEncoder.Output
        do {
            encoded = try await Task.detached(priority: .userInitiated) {
                try AttachmentEncoder.encode(attachmentsToSend, capabilities: capabilities, rasterizer: rasterizer)
            }.value
        } catch let error as AttachmentError {
            throw ImportError.attachment(error)
        }
        let catalog = (try? catalogEntries()) ?? []
        let user = LLMMessage.user(CopilotPrompt.importUserMessage(kind, files: attachments, note: note, catalog: catalog),
                                   parts: encoded.parts)
        warnings = encoded.warnings
        failureMessage = nil
        phase = .analyzing
        persist()

        let task = Task { @MainActor in
            await self.runExtraction(chat: chat, messages: [user], isRevision: false)
        }
        analysisTask = task
        await task.value
        analysisTask = nil
    }

    /// Cancela a análise/revisão em andamento: volta para a fase anterior sem perder os arquivos em memória.
    func cancel() {
        analysisTask?.cancel()
    }

    /// Depois de `failed`: volta para escolher arquivos (mantém os que ainda estão em memória).
    func retry() {
        guard phase == .failed else { return }
        failureMessage = nil
        if programImport != nil || nutritionImport != nil {
            phase = .interviewing
            refreshGaps()
        } else {
            phase = .selecting
            needsReattach = prepared.isEmpty && !attachments.isEmpty
            if prepared.isEmpty { attachments = [] }
        }
        persist()
    }

    /// Descarta a importação (apaga o estado gravado).
    func discard() {
        isDiscarded = true // bloqueia `persist()`: a análise cancelada não recria o arquivo
        analysisTask?.cancel()
        prepared = []
        store.delete(id: id)
    }

    /// - Parameter isRevision: revisão das dúvidas (a extração muda e os índices antigos deixam de valer);
    ///   senão, análise inicial (os bytes dos anexos são descartados ao terminar).
    private func runExtraction(chat: ResolvedChat, messages: [LLMMessage], isRevision: Bool) async {
        let previousPhase: Phase = (programImport != nil || nutritionImport != nil) ? .interviewing : .selecting
        // Seleção por chave estável (nome normalizado da ficha/variação), não por posição: a revisão pode reordenar.
        let previousKeys = groupKeys()
        let selectedKeys = Set(selected.compactMap { previousKeys.indices.contains($0) ? previousKeys[$0] : nil })
        let allWereSelected = selected.count == previousKeys.count
        do {
            let json = try await extract(chat: chat, messages: messages)
            try Task.checkCancellation()
            switch kind {
            case .program:
                guard case let .valid(value) = ImportValidation.program(json) else { throw ExtractionFailure.invalid }
                programImport = value
            case .nutrition:
                guard case let .valid(value) = ImportValidation.nutrition(json) else { throw ExtractionFailure.invalid }
                nutritionImport = value
            }
            let keys = groupKeys()
            let kept = Set(keys.indices.filter { selectedKeys.contains(keys[$0]) })
            selected = !isRevision || allWereSelected || kept.isEmpty ? Set(keys.indices) : kept
            if isRevision {
                // Respostas por posição já estão na extração enviada e os índices mudaram: só ficam as sem posição.
                resolved = []
                answers = answers.filter { Self.positionFreeAnswerKeys.contains($0.key) }
            } else {
                prepared = []
            }
            ambiguityAnswers = [:]
            refreshGaps()
            phase = questions.isEmpty ? .reviewing : .interviewing
        } catch {
            if ChatCancellation.isCancellation(error) {
                phase = previousPhase
            } else {
                failureMessage = Self.message(for: error)
                phase = .failed
            }
        }
        persist()
    }

    private enum ExtractionFailure: Error { case invalid, noExtraction }

    static let positionFreeAnswerKeys: Set<String> = [
        ImportField.programName.key, ImportField.scheduleMode.key, ImportField.planName.key,
    ]

    /// Chave estável de cada ficha/variação: nome normalizado (ou a posição, sem nome), com sufixo se repetir.
    private func groupKeys() -> [String] {
        let names: [String?] = programImport?.routines.map(\.name) ?? nutritionImport?.days.map(\.name) ?? []
        var seen: [String: Int] = [:]
        return names.enumerated().map { index, name in
            let base = name.nonEmpty.map(ExerciseMatcher.normalize) ?? "#\(index)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }
    }

    /// Uma chamada + no máximo um reparo (sem reenviar os arquivos). Devolve o JSON validado.
    private func extract(chat: ResolvedChat, messages: [LLMMessage]) async throws -> String {
        let schema = kind == .program ? ImportSchemas.programImportV1 : ImportSchemas.nutritionImportV1
        let tool = ToolSpec(name: CopilotPrompt.submitExtractionTool,
                            description: kind == .program
                                ? "Entrega o programa de treino extraído dos arquivos (JSON do contrato program-import-v1)."
                                : "Entrega o plano alimentar extraído dos arquivos (JSON do contrato nutrition-import-v1).",
                            parametersSchema: DraftValidation.toolParameters(fromContract: schema))
        let system = LLMMessage.system(CopilotPrompt.importSystem(kind))
        func call(_ conversation: [LLMMessage]) async throws -> String {
            let request = ChatRequest(model: chat.model, messages: [system] + conversation, tools: [tool],
                                      toolChoice: .tool(tool.name), metadata: ["module": "copilot-import"])
            let completion = try await ChatStreamCollector.collect(chat.gateway.stream(request), model: chat.model)
            switch completion.finishReason {
            case .length: throw AIError.incomplete(.length)
            case .refusal: throw AIError.incomplete(.refusal)
            case .contentFilter: throw AIError.incomplete(.contentFilter)
            default: break
            }
            if let call = completion.toolCalls.first(where: { $0.name == tool.name }) { return call.argumentsJSON }
            if let json = StructuredDecoder.extractJSONObject(from: completion.content) { return json }
            throw ExtractionFailure.noExtraction
        }
        func issues(_ json: String) -> [String] {
            switch kind {
            case .program: if case let .invalid(list) = ImportValidation.program(json) { return list }
            case .nutrition: if case let .invalid(list) = ImportValidation.nutrition(json) { return list }
            }
            return []
        }
        let first: String
        do {
            first = try await call(messages)
        } catch ExtractionFailure.noExtraction {
            first = "{}"
        }
        let problems = issues(first)
        guard !problems.isEmpty else { return first }
        try Task.checkCancellation()
        let repaired = try await call([.user(CopilotPrompt.repairMessage(json: first, issues: problems))])
        guard issues(repaired).isEmpty else { throw ExtractionFailure.invalid }
        return repaired
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as AIError: error.localizedDescription
        case is ExtractionFailure:
            String(localized: "A IA não conseguiu extrair um treino ou dieta válido desses arquivos. Tente outra foto ou outro modelo.")
        case let error as AttachmentError: error.localizedDescription
        default: String(localized: "Não foi possível analisar os arquivos.")
        }
    }

    // MARK: - Entrevista

    /// Responde uma pergunta pendente. Respostas determinísticas atualizam a extração na hora; dúvidas da IA
    /// ficam guardadas para `reviseWithAI()`.
    func answer(_ answer: ImportAnswer, for questionID: String) throws {
        guard phase == .interviewing || phase == .reviewing else { throw ImportError.wrongPhase }
        guard let question = questions.first(where: { $0.id == questionID }) else { throw ImportAnswerError.unknownQuestion }
        if case let .ambiguity(index) = question.field {
            let text: String
            switch (question.kind, answer) {
            case let (.choice(options), .choice(id)):
                guard let option = options.first(where: { $0.id == id }) else {
                    throw ImportAnswerError.invalid(String(localized: "Escolha uma opção."))
                }
                text = option.label
            case let (_, .text(value)):
                text = try InterviewText.requireText(value, max: 300)
            default:
                throw ImportAnswerError.invalid(String(localized: "Resposta não combina com a pergunta."))
            }
            ambiguityAnswers[index] = text
        } else {
            switch kind {
            case .program:
                guard var extraction = programImport else { throw ImportError.wrongPhase }
                try ProgramInterview.apply(answer, to: question.field, in: &extraction, catalog: (try? catalogEntries()) ?? [])
                programImport = extraction
            case .nutrition:
                guard var extraction = nutritionImport else { throw ImportError.wrongPhase }
                try NutritionInterview.apply(answer, to: question.field, in: &extraction)
                nutritionImport = extraction
            }
        }
        answers[questionID] = answer
        resolved.insert(questionID)
        refreshGaps()
        persist()
    }

    /// Pula uma pergunta opcional (fica o valor atual/padrão).
    func skip(_ questionID: String) throws {
        guard let question = questions.first(where: { $0.id == questionID }) else { throw ImportAnswerError.unknownQuestion }
        guard !question.isRequired else { throw ImportError.pendingRequiredQuestions }
        resolved.insert(questionID)
        refreshGaps()
        persist()
    }

    /// Marca/desmarca uma ficha (treino) ou variação (dieta) para importar.
    func setSelected(_ index: Int, included: Bool) {
        guard index >= 0, index < detectedGroupCount else { return }
        if included { selected.insert(index) } else { selected.remove(index) }
        refreshGaps()
        persist()
    }

    /// Aplica as respostas às dúvidas da IA numa chamada só de texto (os arquivos não são reenviados).
    func reviseWithAI() async throws {
        guard phase == .interviewing || phase == .reviewing else { throw ImportError.wrongPhase }
        guard hasConsented() else { throw ImportError.consentRequired }
        guard !ambiguityAnswers.isEmpty else { return }
        let chat = try resolveChat()
        let json: String
        let ambiguities: [ImportAmbiguity]
        switch kind {
        case .program:
            guard let extraction = programImport else { throw ImportError.wrongPhase }
            json = Self.encode(extraction)
            ambiguities = extraction.ambiguities
        case .nutrition:
            guard let extraction = nutritionImport else { throw ImportError.wrongPhase }
            json = Self.encode(extraction)
            ambiguities = extraction.ambiguities
        }
        let pairs = ambiguityAnswers.sorted { $0.key < $1.key }.compactMap { index, answer in
            ambiguities.indices.contains(index) ? (question: ambiguities[index].question, answer: answer) : nil
        }
        phase = .analyzing
        persist()
        let task = Task { @MainActor in
            await self.runExtraction(chat: chat, messages: [.user(CopilotPrompt.reviseMessage(json: json, answers: pairs))],
                                     isRevision: true)
        }
        analysisTask = task
        await task.value
        analysisTask = nil
    }

    /// Vai para a revisão final (perguntas opcionais não respondidas ficam com o padrão).
    func finishInterview() throws {
        guard phase == .interviewing else { throw ImportError.wrongPhase }
        guard !questions.contains(where: \.isRequired) else { throw ImportError.pendingRequiredQuestions }
        phase = .reviewing
        persist()
    }

    /// Volta da revisão para a entrevista.
    func backToInterview() {
        guard phase == .reviewing else { return }
        phase = .interviewing
        persist()
    }

    private func refreshGaps() {
        let catalog = (try? catalogEntries()) ?? []
        var resolvedNow = resolved
        // Dúvidas da IA respondidas continuam resolvidas até a revisão.
        for index in ambiguityAnswers.keys { resolvedNow.insert(ImportField.ambiguity(index: index).key) }
        switch kind {
        case .program:
            guard let extraction = programImport else { gaps = []; questions = []; return }
            gaps = ProgramInterview.gaps(for: extraction, selected: selected, catalog: catalog, resolved: resolvedNow)
            questions = gaps.compactMap { ProgramInterview.question(for: $0, in: extraction, catalog: catalog) }
        case .nutrition:
            guard let extraction = nutritionImport else { gaps = []; questions = []; return }
            gaps = NutritionInterview.gaps(for: extraction, selected: selected, resolved: resolvedNow)
            questions = gaps.compactMap { NutritionInterview.question(for: $0, in: extraction) }
        }
        questions = questions.enumerated().sorted { ($0.element.isRequired ? 0 : 1, $0.offset) < ($1.element.isRequired ? 0 : 1, $1.offset) }
            .map(\.element)
    }

    private func catalogEntries() throws -> [ImportCatalogEntry] {
        try context.fetch(FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.name)])).map { exercise in
            ImportCatalogEntry(id: exercise.id, name: exercise.name, catalogKey: exercise.catalogKey,
                               englishName: exercise.catalogKey.flatMap { ExerciseCatalog.entry(forKey: $0)?.nameEN })
        }
    }

    // MARK: - Revisão e aplicação

    /// Rascunho final das fichas escolhidas (para os cartões e para aplicar).
    func programDraft() throws -> ProgramDraft {
        guard kind == .program, let extraction = programImport else { throw ImportError.targetMismatch }
        guard !selected.isEmpty else { throw ImportError.draftInvalid([String(localized: "escolha ao menos uma ficha")]) }
        let draft = extraction.makeDraft(selected: selected)
        let issues = draft.validationIssues()
        guard issues.isEmpty else { throw ImportError.draftInvalid(issues) }
        return draft
    }

    func nutritionDraft() throws -> NutritionPlanDraft {
        guard kind == .nutrition, let extraction = nutritionImport else { throw ImportError.targetMismatch }
        guard !selected.isEmpty else { throw ImportError.draftInvalid([String(localized: "escolha ao menos uma variação")]) }
        let draft = extraction.makeDraft(selected: selected)
        let issues = draft.validationIssues()
        guard issues.isEmpty else { throw ImportError.draftInvalid(issues) }
        return draft
    }

    /// Prévia do casamento com o catálogo (por ficha/exercício; `nil` = exercício novo).
    func exerciseMatches() throws -> [[Exercise?]] {
        try DraftApplier(context: context).exerciseMatches(for: try programDraft())
    }

    /// Grava. Novo programa/plano nasce **inativo** salvo `activate`; "adicionar ao programa" acrescenta as fichas
    /// ao fim. Devolve o id do programa/plano. Em erro, nada fica gravado e a sessão volta para `reviewing`.
    @discardableResult
    func apply(target: Target, activate: Bool = false) throws -> UUID {
        guard phase == .reviewing || (phase == .interviewing && canFinishInterview) else {
            throw phase == .interviewing ? ImportError.pendingRequiredQuestions : ImportError.wrongPhase
        }
        let applier = DraftApplier(context: context)
        let note = Self.importNote(files: attachments.count)
        func withNote(_ text: String?) -> String { [text.nonEmpty, note].compactMap { $0 }.joined(separator: "\n") }
        phase = .applying
        // Nota já no rascunho → o `DraftApplier` grava tudo num save só. Se ativar falhar, o que foi criado é
        // apagado: nada fica pela metade e uma nova tentativa não duplica.
        var cleanup: (() -> Void)?
        do {
            let resultID: UUID
            switch (kind, target) {
            case (.program, .newProgram):
                var draft = try programDraft()
                draft.notes = withNote(draft.notes)
                let program = try applier.makeProgram(from: draft, startDate: now())
                cleanup = { [context] in context.delete(program) }
                if activate { try ProgramStore(context: context).activate(program) }
                resultID = program.id
            case let (.program, .existingProgram(programID)):
                var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == programID })
                descriptor.fetchLimit = 1
                guard let program = try context.fetch(descriptor).first else { throw ImportError.programNotFound }
                var draft = try programDraft()
                draft.routines = draft.routines.map { var routine = $0; routine.notes = withNote(routine.notes); return routine }
                let routines = try applier.addRoutines(from: draft, to: program)
                cleanup = { [context] in for routine in routines { context.delete(routine) } }
                if activate, !program.isActive { try ProgramStore(context: context).activate(program) }
                resultID = program.id
            case (.nutrition, .newNutritionPlan):
                var draft = try nutritionDraft()
                draft.notes = withNote(draft.notes)
                let plan = try applier.makeNutritionPlan(from: draft, startDate: now())
                cleanup = { [context] in context.delete(plan) }
                if activate { try NutritionStore(context: context).switchActive(to: plan, now: now()) }
                resultID = plan.id
            default:
                throw ImportError.targetMismatch
            }
            self.resultID = resultID
            phase = .done
            store.delete(id: id)
            return resultID
        } catch {
            context.rollback()
            if let cleanup {
                cleanup()
                try? context.save()
            }
            phase = .reviewing
            persist()
            throw error
        }
    }

    static func importNote(files: Int) -> String {
        files == 1 ? String(localized: "Importado com IA de 1 arquivo.") : String(localized: "Importado com IA de \(files) arquivos.")
    }

    // MARK: - Persistência

    private func persist() {
        guard !restoring, !isDiscarded, phase != .done else { return }
        try? store.save(state)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

enum ChatCancellation {
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AIError) == .cancelled || (error as? URLError)?.code == .cancelled
    }
}
