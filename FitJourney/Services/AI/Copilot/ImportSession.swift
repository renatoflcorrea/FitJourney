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
    /// Decisões de exercício por chave estável (`ProgramInterview.exerciseKey`): sobrevivem à revisão pela IA e valem
    /// para o mesmo exercício em outras fichas.
    private(set) var exerciseDecisions: [String: ImportExerciseDecision] = [:]
    private(set) var failureMessage: String?
    /// Programa/plano criado (ou programa que recebeu as fichas).
    private(set) var resultID: UUID?
    /// A sessão foi retomada sem os arquivos (eles não são guardados): escolha de novo para analisar.
    private(set) var needsReattach = false
    private(set) var createdAt: Date
    /// Início da chamada em andamento (análise ou revisão), para o tempo decorrido na tela. Derivado de data, não de
    /// timer; `nil` fora de `analyzing`.
    private(set) var analysisStartedAt: Date?
    /// Medições das chamadas desta sessão (T0: tempo até o primeiro evento, total, tamanho da saída). Sem conteúdo.
    @ObservationIgnored private(set) var callMetrics: [ImportCallMetrics] = []

    /// Respostas a dúvidas da IA ainda não aplicadas (`reviseWithAI()`).
    var hasPendingRevision: Bool { !ambiguityAnswers.isEmpty }
    var canFinishInterview: Bool { phase == .interviewing && !questions.contains(where: \.isRequired) }
    /// Quantidade de fichas/variações detectadas.
    var detectedGroupCount: Int { programImport?.routines.count ?? nutritionImport?.days.count ?? 0 }

    @ObservationIgnored private var prepared: [PreparedAttachment] = []
    @ObservationIgnored private var resolved: Set<String> = []
    @ObservationIgnored private var ambiguityAnswers: [Int: String] = [:]
    /// Repetições/carga por chave estável ("reps|…"/"load|…"), restauradas se a revisão as perder.
    @ObservationIgnored private var exerciseAnswers: [String: ImportAnswer] = [:]
    /// Dúvidas da IA já respondidas e aplicadas (`ImportStableKey.ambiguity`: pergunta + caminho).
    @ObservationIgnored private var answeredAmbiguities: Set<String> = []
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let resolveChat: @MainActor () throws -> ResolvedChat
    @ObservationIgnored private let hasConsented: @MainActor () -> Bool
    @ObservationIgnored private let store: any ImportSessionStoring
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let preparer: AttachmentPreparer
    @ObservationIgnored private let rasterizer: PDFRasterizer
    @ObservationIgnored private let beginBackground: @MainActor (String) -> @MainActor () -> Void
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var isDiscarded = false

    /// - Parameters:
    ///   - resolveChat: em produção `{ try ProviderFactory.makeChat(secrets: KeychainSecretStore()) }`.
    ///   - hasConsented: em produção `{ CoachProfileStore().hasConsented }`.
    init(kind: Kind, context: ModelContext, resolveChat: @escaping @MainActor () throws -> ResolvedChat,
         hasConsented: @escaping @MainActor () -> Bool = { CoachProfileStore().hasConsented },
         store: any ImportSessionStoring = FileImportSessionStore(), now: @escaping @MainActor () -> Date = { .now },
         preparer: AttachmentPreparer = AttachmentPreparer(), rasterizer: PDFRasterizer = PDFRasterizer(), id: UUID = UUID(),
         beginBackground: @escaping @MainActor (String) -> @MainActor () -> Void = ImportSession.backgroundTask) {
        self.beginBackground = beginBackground
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
        session.exerciseDecisions = state.exerciseDecisions ?? [:]
        session.exerciseAnswers = state.exerciseAnswers ?? [:]
        session.answeredAmbiguities = Set(state.answeredAmbiguities ?? [])
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
                               : Dictionary(uniqueKeysWithValues: ambiguityAnswers.map { (String($0.key), $0.value) }),
                           exerciseDecisions: exerciseDecisions.isEmpty ? nil : exerciseDecisions,
                           exerciseAnswers: exerciseAnswers.isEmpty ? nil : exerciseAnswers,
                           answeredAmbiguities: answeredAmbiguities.isEmpty ? nil : answeredAmbiguities.sorted())
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
        analysisStartedAt = now()
        persist()

        let task = Task { @MainActor in
            await self.runExtraction(isRevision: false) { try await self.extract(chat: chat, messages: [user]) }
        }
        await run(task)
    }

    /// Espera a chamada com alguns segundos de folga em segundo plano (sair rápido do app não derruba o stream).
    private func run(_ task: Task<Void, Never>) async {
        analysisTask = task
        let background = beginBackground("FitJourney import")
        await task.value
        background()
        analysisTask = nil
        analysisStartedAt = nil
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
    ///   - answeredAmbiguityKeys: dúvidas respondidas que esta revisão aplica (`ImportStableKey.ambiguity`).
    private func runExtraction(isRevision: Bool, answeredAmbiguityKeys: [String] = [],
                               operation: @MainActor () async throws -> Extracted) async {
        let previousPhase: Phase = (programImport != nil || nutritionImport != nil) ? .interviewing : .selecting
        let previousProgram = programImport
        // Seleção por chave estável (nome normalizado da ficha/variação), não por posição: a revisão pode reordenar.
        let previousKeys = groupKeys()
        let selectedKeys = Set(selected.compactMap { previousKeys.indices.contains($0) ? previousKeys[$0] : nil })
        let allWereSelected = selected.count == previousKeys.count
        do {
            let extracted = try await operation()
            try Task.checkCancellation()
            switch extracted {
            case let .program(value): programImport = value
            case let .nutrition(value): nutritionImport = value
            }
            let keys = groupKeys()
            let kept = Set(keys.indices.filter { selectedKeys.contains(keys[$0]) })
            selected = !isRevision || allWereSelected || kept.isEmpty ? Set(keys.indices) : kept
            if isRevision {
                // Respostas por posição já estão na extração enviada e os índices mudaram: só ficam as sem posição.
                resolved = []
                answers = answers.filter { Self.positionFreeAnswerKeys.contains($0.key) }
                answeredAmbiguities.formUnion(answeredAmbiguityKeys)
                reconcileAfterRevision(previous: previousProgram)
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

    /// Extração validada, já no modelo interno (v1).
    private enum Extracted {
        case program(ProgramImport)
        case nutrition(NutritionImport)
    }

    static let positionFreeAnswerKeys: Set<String> = [
        ImportField.programName.key, ImportField.scheduleMode.key, ImportField.planName.key,
    ]

    /// Chave estável de cada ficha/variação: nome normalizado (ou a posição, sem nome), com sufixo se repetir.
    private func groupKeys() -> [String] {
        ImportStableKey.groupKeys(programImport?.routines.map(\.name) ?? nutritionImport?.days.map(\.name) ?? [])
    }

    /// Depois da revisão pela IA (índices novos): reaplica as decisões de exercício pela chave estável, tira dúvidas
    /// já respondidas ou sobre exercícios decididos e restaura repetições/carga que a IA tenha perdido. Sem isso a
    /// pergunta "Qual exercício é…?" voltava a cada revisão (o exercício novo continua sem casamento no catálogo).
    private func reconcileAfterRevision(previous: ProgramImport?) {
        switch kind {
        case .program:
            guard var extraction = programImport else { return }
            let catalog = (try? catalogEntries()) ?? []
            if let previous { ProgramInterview.rebindDecisions(exerciseDecisions, previous: previous, in: &extraction) }
            ProgramInterview.applyDecisions(&exerciseDecisions, to: &extraction, catalog: catalog)
            ProgramInterview.pruneAmbiguities(&extraction, decisions: exerciseDecisions, answered: answeredAmbiguities)
            if !exerciseAnswers.isEmpty {
                let all = ProgramInterview.gaps(for: extraction, selected: Set(extraction.routines.indices), catalog: catalog,
                                                resolved: [])
                for gap in all {
                    guard let storeKey = Self.exerciseAnswerKey(gap.field, in: extraction),
                          let answer = exerciseAnswers[storeKey] else { continue }
                    if (try? ProgramInterview.apply(answer, to: gap.field, in: &extraction, catalog: catalog)) != nil {
                        resolved.insert(gap.field.key)
                    }
                }
            }
            programImport = extraction
        case .nutrition:
            guard !answeredAmbiguities.isEmpty else { return }
            nutritionImport?.ambiguities.removeAll { answeredAmbiguities.contains(ImportStableKey.ambiguity($0)) }
        }
    }

    /// Nome atual do exercício de uma pergunta de exercício (o efetivamente gravado, para o resumo da resposta).
    func exerciseName(for field: ImportField) -> String? {
        guard case let .exercise(r, e) = field, let extraction = programImport, extraction.routines.indices.contains(r),
              extraction.routines[r].exercises.indices.contains(e) else { return nil }
        return extraction.routines[r].exercises[e].displayName
    }

    /// Chave estável de uma resposta de repetições/carga (`nil` para os outros campos).
    private static func exerciseAnswerKey(_ field: ImportField, in extraction: ProgramImport) -> String? {
        switch field {
        case let .exerciseReps(r, e): ProgramInterview.slotKey(routine: r, exercise: e, in: extraction).map { "reps|\($0)" }
        case let .exerciseLoad(r, e): ProgramInterview.slotKey(routine: r, exercise: e, in: extraction).map { "load|\($0)" }
        default: nil
        }
    }

    /// Uma chamada (contrato v2, esforço baixo) + no máximo um reparo sem reenviar os arquivos. O trivial é
    /// consertado no aparelho; o que decodifica mas quebra regra é reparado por remendo; só o que nem decodifica
    /// pede o objeto inteiro de novo.
    private func extract(chat: ResolvedChat, messages: [LLMMessage]) async throws -> Extracted {
        let first: String
        do {
            first = try await call(chat: chat, stage: .extract, conversation: messages, tool: extractionTool())
        } catch ExtractionFailure.noExtraction {
            first = "{}"
        }
        try Task.checkCancellation()
        switch detailed(first) {
        case let .valid(value):
            return value
        case let .ruleIssues(value, issues):
            let fixed = localFix(value)
            if ruleIssues(fixed).isEmpty { return fixed }
            return try await patchRepair(chat: chat, base: fixed, issues: issues)
        case let .invalid(issues):
            if let base = lenient(first) {
                return try await patchRepair(chat: chat, base: localFix(base), issues: issues)
            }
            let repaired = try await call(chat: chat, stage: .repair,
                                          conversation: [.user(CopilotPrompt.importRepairMessage(json: first, issues: issues))],
                                          tool: extractionTool())
            guard case let .valid(value) = detailed(repaired) else { throw ExtractionFailure.invalid }
            return value
        }
    }

    private func extractionTool() -> ToolSpec {
        let schema = kind == .program ? ImportSchemas.programImportV2 : ImportSchemas.nutritionImportV2
        return ToolSpec(name: CopilotPrompt.submitExtractionTool,
                        description: kind == .program
                            ? "Entrega o programa de treino extraído dos arquivos (JSON do contrato program-import-v2)."
                            : "Entrega o plano alimentar extraído dos arquivos (JSON do contrato nutrition-import-v2).",
                        parametersSchema: DraftValidation.toolParameters(fromContract: schema))
    }

    private func patchTool() -> ToolSpec {
        ToolSpec(name: CopilotPrompt.submitPatchTool,
                 description: kind == .program
                     ? "Entrega só as alterações na extração do programa (operações sobre os ids enviados)."
                     : "Entrega só as alterações na extração da dieta (operações sobre os ids enviados).",
                 parametersSchema: kind == .program ? ProgramImportPatch.toolParameters : NutritionImportPatch.toolParameters)
    }

    /// Uma chamada com a ferramenta pedida; devolve o JSON (argumentos da ferramenta ou objeto no texto). Mede e
    /// registra o tempo até o primeiro evento, o total e o tamanho da saída (sem conteúdo).
    private func call(chat: ResolvedChat, stage: ImportCallMetrics.Stage, conversation: [LLMMessage],
                      tool: ToolSpec) async throws -> String {
        let system = LLMMessage.system(CopilotPrompt.importSystem(kind))
        // Esforço baixo: extrair é transcrever. Sem `maxTokens` (o padrão do gateway não corta a resposta) e sem
        // trocar o modelo escolhido.
        let request = ChatRequest(model: chat.model, messages: [system] + conversation, tools: [tool],
                                  toolChoice: .tool(tool.name), metadata: ["module": "copilot-import"], effort: .low)
        let clock = ContinuousClock()
        let start = clock.now
        var metrics = ImportCallMetrics(stage: stage, model: chat.model, timeToFirstEvent: nil, total: .zero,
                                        inputCharacters: conversation.reduce(0) { $0 + $1.content.count },
                                        outputCharacters: 0, usage: nil)
        defer {
            metrics.total = clock.now - start
            callMetrics.append(metrics)
            metrics.log()
        }
        let (completion, firstEvent) = try await ChatStreamCollector.collectTimed(chat.gateway.stream(request),
                                                                                  model: chat.model, clock: clock)
        metrics.timeToFirstEvent = firstEvent
        metrics.usage = completion.usage
        switch completion.finishReason {
        case .length: throw AIError.incomplete(.length)
        case .refusal: throw AIError.incomplete(.refusal)
        case .contentFilter: throw AIError.incomplete(.contentFilter)
        default: break
        }
        // Qualquer ferramenta: a revisão aceita também o objeto inteiro (modelo que ignore o remendo).
        if let call = completion.toolCalls.first(where: { $0.name == tool.name }) ?? completion.toolCalls.first {
            metrics.outputCharacters = call.argumentsJSON.count
            return call.argumentsJSON
        }
        metrics.outputCharacters = completion.content.count
        if let json = StructuredDecoder.extractJSONObject(from: completion.content) { return json }
        throw ExtractionFailure.noExtraction
    }

    /// Reparo por remendo: manda a extração compacta com ids e os problemas; aplica as operações devolvidas.
    private func patchRepair(chat: ResolvedChat, base: Extracted, issues: [String]) async throws -> Extracted {
        try Task.checkCancellation()
        let message = CopilotPrompt.repairPatchMessage(kind, snapshot: snapshot(base), issues: issues)
        let json = try await call(chat: chat, stage: .repair, conversation: [.user(message)], tool: patchTool())
        return try applyPatchOrObject(json, to: base)
    }

    /// Resposta de revisão/reparo: remendo (`operations`) aplicado sobre `base`, ou o objeto inteiro (v2/v1).
    private func applyPatchOrObject(_ json: String, to base: Extracted) throws -> Extracted {
        let object = StructuredDecoder.extractJSONObject(from: json) ?? json
        if case let .object(root)? = try? JSONValue.parse(object), root["operations"] != nil {
            let result: Extracted
            do {
                switch base {
                case let .program(value):
                    guard case let .valid(patch) = DraftValidation.validate(object, schema: ProgramImportPatch.toolParameters,
                                                                            as: ProgramImportPatch.self, semantic: { _ in [] })
                    else { throw ExtractionFailure.invalid }
                    result = .program(ImportLocalRepair.fix(try patch.applied(to: value)))
                case let .nutrition(value):
                    guard case let .valid(patch) = DraftValidation.validate(object, schema: NutritionImportPatch.toolParameters,
                                                                            as: NutritionImportPatch.self, semantic: { _ in [] })
                    else { throw ExtractionFailure.invalid }
                    result = .nutrition(ImportLocalRepair.fix(try patch.applied(to: value)))
                }
            } catch is ImportPatchError {
                throw ExtractionFailure.invalid
            }
            guard ruleIssues(result).isEmpty else { throw ExtractionFailure.invalid }
            return result
        }
        guard case let .valid(value) = detailed(object) else { throw ExtractionFailure.invalid }
        return value
    }

    private func detailed(_ json: String) -> ImportOutcome<Extracted> {
        switch kind {
        case .program:
            switch ImportValidation.programDetailed(json) {
            case let .valid(value): .valid(.program(value))
            case let .ruleIssues(value, issues): .ruleIssues(.program(value), issues)
            case let .invalid(issues): .invalid(issues)
            }
        case .nutrition:
            switch ImportValidation.nutritionDetailed(json) {
            case let .valid(value): .valid(.nutrition(value))
            case let .ruleIssues(value, issues): .ruleIssues(.nutrition(value), issues)
            case let .invalid(issues): .invalid(issues)
            }
        }
    }

    private func lenient(_ json: String) -> Extracted? {
        switch kind {
        case .program: ImportValidation.lenientProgram(json).map(Extracted.program)
        case .nutrition: ImportValidation.lenientNutrition(json).map(Extracted.nutrition)
        }
    }

    private func localFix(_ value: Extracted) -> Extracted {
        switch value {
        case let .program(value): .program(ImportLocalRepair.fix(value))
        case let .nutrition(value): .nutrition(ImportLocalRepair.fix(value))
        }
    }

    private func ruleIssues(_ value: Extracted) -> [String] {
        switch value {
        case let .program(value): value.validationIssues() + value.compacted().validationIssues()
        case let .nutrition(value): value.validationIssues()
        }
    }

    private func snapshot(_ value: Extracted) -> String {
        switch value {
        case let .program(value): ImportSnapshot.program(value)
        case let .nutrition(value): ImportSnapshot.nutrition(value)
        }
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
                let catalog = (try? catalogEntries()) ?? []
                var original: ProgramImport.ExerciseImport?
                var slot: String?
                if case let .exercise(r, e) = question.field, extraction.routines.indices.contains(r),
                   extraction.routines[r].exercises.indices.contains(e) {
                    original = extraction.routines[r].exercises[e]
                    slot = ProgramInterview.slotKey(routine: r, exercise: e, in: extraction)
                }
                let answerKey = Self.exerciseAnswerKey(question.field, in: extraction)
                try ProgramInterview.apply(answer, to: question.field, in: &extraction, catalog: catalog)
                if case let .exercise(r, e) = question.field, let original {
                    let updated = extraction.routines[r].exercises[e]
                    let decision = ProgramInterview.decision(for: updated, original: original, answer: answer, slot: slot)
                    // Sem `asWritten` a chave é o nome, que a resposta pode mudar: grava sob as duas.
                    for key in Set([original, updated].compactMap(ProgramInterview.exerciseKey)) {
                        var stored = decision
                        if key != ProgramInterview.exerciseKey(original) {
                            stored.slots = ProgramInterview.slotKey(routine: r, exercise: e, in: extraction).map { [$0] } ?? []
                        }
                        exerciseDecisions[key] = stored
                    }
                    // O mesmo exercício nas outras fichas, se estiver sem casamento ou com baixa confiança.
                    ProgramInterview.applyDecisions(&exerciseDecisions, to: &extraction, catalog: catalog)
                }
                if let answerKey { exerciseAnswers[answerKey] = answer }
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

    /// Exercícios sem casamento no catálogo ainda pendentes (a tela mostra todos numa lista só).
    var unmatchedExerciseQuestions: [ImportQuestion] { questions.filter { $0.gapKind == .unmatchedExercise } }

    /// "Criar todos como novos": cada exercício sem casamento vira exercício novo com o nome lido do arquivo (o mesmo
    /// do "Criar como novo" individual). Devolve as perguntas respondidas e o nome gravado, para o histórico.
    @discardableResult
    func createAllUnmatchedAsNew() throws -> [(question: ImportQuestion, name: String)] {
        guard kind == .program, phase == .interviewing || phase == .reviewing else { throw ImportError.wrongPhase }
        var created: [(question: ImportQuestion, name: String)] = []
        var attempted: Set<String> = []
        // Uma resposta pode decidir o mesmo exercício em outras fichas: relê as pendentes a cada passo.
        while let question = unmatchedExerciseQuestions.first(where: { !attempted.contains($0.id) }) {
            attempted.insert(question.id)
            let name = question.suggestedText.nonEmpty ?? exerciseName(for: question.field) ?? question.prompt
            try answer(.text(String(name.prefix(80))), for: question.id)
            created.append((question, exerciseName(for: question.field) ?? name))
        }
        return created
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
        let base: Extracted
        let ambiguities: [ImportAmbiguity]
        switch kind {
        case .program:
            guard let extraction = programImport else { throw ImportError.wrongPhase }
            base = .program(extraction)
            ambiguities = extraction.ambiguities
        case .nutrition:
            guard let extraction = nutritionImport else { throw ImportError.wrongPhase }
            base = .nutrition(extraction)
            ambiguities = extraction.ambiguities
        }
        let pairs = ambiguityAnswers.sorted { $0.key < $1.key }.compactMap { index, answer in
            ambiguities.indices.contains(index) ? (question: ambiguities[index].question, answer: answer) : nil
        }
        let confirmed = programImport.map { ProgramInterview.confirmedExercises(in: $0, decisions: exerciseDecisions) } ?? []
        // Só as alterações voltam (remendo sobre a extração compacta): sem reescrever tudo e sem cortar o JSON.
        let message = CopilotPrompt.reviseMessage(kind, snapshot: snapshot(base), answers: pairs, confirmed: confirmed)
        let answeredKeys = ambiguityAnswers.keys.filter(ambiguities.indices.contains).map { ImportStableKey.ambiguity(ambiguities[$0]) }
        phase = .analyzing
        analysisStartedAt = now()
        persist()
        let task = Task { @MainActor in
            await self.runExtraction(isRevision: true, answeredAmbiguityKeys: answeredKeys) {
                let json = try await self.call(chat: chat, stage: .revise, conversation: [.user(message)], tool: self.patchTool())
                return try self.applyPatchOrObject(json, to: base)
            }
        }
        await run(task)
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
            // Exercício já decidido (por chave estável) não volta a ser perguntado, mesmo com índices novos.
            resolvedNow.formUnion(ProgramInterview.decidedExerciseFields(in: extraction, decisions: exerciseDecisions))
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
        var matches = try DraftApplier(context: context).exerciseMatches(for: try programDraft())
        let pinned = pinnedLibraryExercises()
        for r in matches.indices where pinned.indices.contains(r) {
            for e in matches[r].indices where pinned[r].indices.contains(e) {
                if let exercise = pinned[r][e] { matches[r][e] = exercise }
            }
        }
        return matches
    }

    /// Exercícios da biblioteca escolhidos pelo id (`exercise:<uuid>`), por ficha escolhida/exercício (ordem do
    /// rascunho). O `DraftApplier` casa por nome e, num empate de nome, preferiria outro exercício (o do catálogo
    /// ou o mais antigo).
    private func pinnedLibraryExercises() -> [[Exercise?]] {
        guard let extraction = programImport,
              exerciseDecisions.values.contains(where: { $0.exerciseID != nil }) else { return [] }
        let ids = Set(exerciseDecisions.values.compactMap(\.exerciseID))
        let library = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let byID = Dictionary(library.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return extraction.routines.enumerated().filter { selected.contains($0.offset) }.map { r, routine in
            routine.exercises.indices.map { e in
                ProgramInterview.coveringDecision(routine: r, exercise: e, in: extraction, decisions: exerciseDecisions)?
                    .exerciseID.flatMap { byID[$0] }
            }
        }
    }

    /// Troca, nas fichas recém-criadas (na ordem do rascunho), o exercício casado por nome pelo escolhido pelo id.
    private func pinLibraryExercises(in routines: [Routine]) throws {
        let pinned = pinnedLibraryExercises()
        guard !pinned.isEmpty else { return }
        var changed = false
        for (r, routine) in routines.enumerated() where pinned.indices.contains(r) {
            for item in routine.sortedExercises where pinned[r].indices.contains(item.sortIndex) {
                guard let exercise = pinned[r][item.sortIndex], item.exercise?.id != exercise.id else { continue }
                item.exercise = exercise
                changed = true
            }
        }
        if changed { try context.save() }
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
                try pinLibraryExercises(in: program.sortedRoutines)
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
                try pinLibraryExercises(in: routines)
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

    /// Em produção: `beginBackgroundTask` (alguns segundos a mais se o usuário sair do app durante a chamada).
    static func backgroundTask(_ name: String) -> @MainActor () -> Void {
        let token = BackgroundExecution.begin(name)
        return { token.end() }
    }

    static func importNote(files: Int) -> String {
        files == 1 ? String(localized: "Importado com IA de 1 arquivo.") : String(localized: "Importado com IA de \(files) arquivos.")
    }

    // MARK: - Persistência

    private func persist() {
        guard !restoring, !isDiscarded, phase != .done else { return }
        try? store.save(state)
    }
}

enum ChatCancellation {
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AIError) == .cancelled || (error as? URLError)?.code == .cancelled
    }
}
