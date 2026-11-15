import Foundation
import Observation
import SwiftData

/// Pré-condições do registro com IA (a UI trata cada uma; falhas do provedor viram `phase`).
enum MealLogError: Error, Sendable, Hashable {
    /// IA não configurada (`AIAvailability`): a tela não deveria nem mostrar a entrada.
    case aiUnavailable
    /// Consentimento do Coach ausente: mostrar o aviso "o texto e as fotos vão ao provedor"
    /// (`MealLogPreferences.grantConsent()` aceita com os compartilhamentos desligados).
    case consentRequired
    case emptyInput
    case textTooLong(max: Int)
    case tooManyPhotos(max: Int)
    /// O arquivo escolhido não é uma foto.
    case notAnImage
    /// O modelo configurado não lê imagens.
    case modelWithoutVision
    /// Registro em dia futuro não é permitido.
    case futureDay
    case wrongPhase
    /// Correção pedida sem rascunho.
    case noDraft
    case attachment(AttachmentError)
}

extension MealLogError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .aiUnavailable: String(localized: "Falta configurar a IA.")
        case .consentRequired: String(localized: "Para analisar, aceite enviar o texto e as fotos ao provedor de IA.")
        case .emptyInput: String(localized: "Escreva o que comeu ou adicione uma foto.")
        case let .textTooLong(max): String(localized: "O texto passa de \(max) caracteres.")
        case let .tooManyPhotos(max): String(localized: "Escolha no máximo \(max) fotos.")
        case .notAnImage: String(localized: "Escolha uma foto.")
        case .modelWithoutVision: String(localized: "O modelo escolhido não lê fotos. Troque o modelo em Ajustes de IA ou descreva por texto.")
        case .futureDay: String(localized: "Não é possível registrar refeições num dia futuro.")
        case .wrongPhase: String(localized: "Aguarde a análise terminar.")
        case .noDraft: String(localized: "Ainda não há rascunho para corrigir.")
        case let .attachment(error): error.localizedDescription
        }
    }
}

/// Foto preparada para a análise (≤ 1.280 px, JPEG sem EXIF/GPS, nome genérico). Só em memória: nunca persistida.
struct MealLogPhoto: Sendable, Hashable, Identifiable {
    var id: UUID
    /// JPEG reduzido que vai ao provedor (serve de miniatura).
    var jpegData: Data
}

/// Registro de refeições com IA (SPEC §7.x, proposta `ai-meal-log.md`): texto do dia e/ou até 4 fotos → uma
/// chamada ao provedor configurado (stream, ferramenta `submit_food_log`, um reparo só de texto) → revisão editável.
///
/// - Nada é gravado aqui: "Registrar" é `MealLogApplier.apply(_:)` sobre `review`.
/// - O plano do dia só vai ao provedor com "Dieta" compartilhada; sem isso o vínculo é feito no aparelho.
/// - As fotos vivem em memória até a análise dar certo (depois são descartadas).
/// - Tempo decorrido sempre a partir de `analysisStartedAt` (nunca timer em memória).
@MainActor
@Observable
final class MealLogSession: Identifiable {
    enum Phase: Sendable, Hashable {
        case composing
        case analyzing
        /// Rascunho pronto em `review`.
        case ready
        /// Rascunho pronto, mas mais da metade das kcal vem de itens de confiança baixa (aviso no topo).
        case lowConfidence
        /// A foto não mostra comida (motivo dito pela IA).
        case noFood(reason: String?)
        /// Foto ou texto ilegível (motivo dito pela IA).
        case unreadable(reason: String?)
        /// Sem internet (antes ou durante o envio). Texto e fotos ficam.
        case offline
        /// O provedor demorou além do limite.
        case timedOut
        /// Erro do provedor ou resposta inválida, já em texto legível. Texto e fotos ficam.
        case providerError(String)

        var hasDraft: Bool { self == .ready || self == .lowConfidence }
    }

    static let maxPhotos = 4
    static let maxTextLength = 2_000
    static let photoMaxPixels = 1_280
    static let defaultTimeout: Duration = .seconds(120)

    let id: UUID
    /// Dia do registro (início do dia).
    let day: Date
    /// Texto livre do usuário (até `maxTextLength`).
    var text: String = ""
    private(set) var photos: [MealLogPhoto] = []
    private(set) var phase: Phase = .composing
    /// Rascunho revisável; a UI edita (itens, quantidade, vínculo, estado) antes de "Registrar".
    var review: MealLogReview?
    /// Início da análise em andamento (tempo decorrido = agora − isto).
    private(set) var analysisStartedAt: Date?

    var isAnalyzing: Bool { phase == .analyzing }
    var canAnalyze: Bool {
        phase != .analyzing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
    }

    @ObservationIgnored private var prepared: [PreparedAttachment] = []
    @ObservationIgnored private var lastDraft: FoodLogDraft?
    /// Texto e quantidade de fotos da última análise, para refazer a mensagem na correção.
    @ObservationIgnored private var lastInput: (text: String, photoCount: Int)?
    /// Muda a cada `discard()`: uma análise antiga que termina depois não mexe mais no estado.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let resolveChat: @MainActor () throws -> ResolvedChat
    @ObservationIgnored private let isAIAvailable: @MainActor () -> Bool
    @ObservationIgnored private let hasConsented: @MainActor () -> Bool
    @ObservationIgnored private let sharesNutrition: @MainActor () -> Bool
    @ObservationIgnored private let isOnline: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let preparer: AttachmentPreparer
    @ObservationIgnored private let language: String

    /// - Parameters:
    ///   - day: dia do registro (padrão na tela: o dia aberto na Dieta).
    ///   - resolveChat: em produção `{ try ProviderFactory.makeChat(secrets: KeychainSecretStore()) }`.
    ///   - isAIAvailable: em produção `{ availability.isAvailable }` (`AIAvailability`).
    ///   - hasConsented: em produção `{ CoachProfileStore().hasConsented }`.
    ///   - sharesNutrition: em produção `{ MealLogPreferences().sharesNutrition }` — "Dieta" em Coach e IA.
    ///   - isOnline: em produção `{ network.isOnline }` (`ImportNetworkMonitor`).
    init(day: Date, context: ModelContext, resolveChat: @escaping @MainActor () throws -> ResolvedChat,
         isAIAvailable: @escaping @MainActor () -> Bool,
         hasConsented: @escaping @MainActor () -> Bool = { CoachProfileStore().hasConsented },
         sharesNutrition: @escaping @MainActor () -> Bool = { MealLogPreferences().sharesNutrition },
         isOnline: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> Date = { .now }, calendar: Calendar = .autoupdatingCurrent,
         timeout: Duration = MealLogSession.defaultTimeout,
         language: String = AppLanguageCode.current, id: UUID = UUID()) {
        self.id = id
        self.calendar = calendar
        self.day = calendar.startOfDay(for: day)
        self.context = context
        self.resolveChat = resolveChat
        self.isAIAvailable = isAIAvailable
        self.hasConsented = hasConsented
        self.sharesNutrition = sharesNutrition
        self.isOnline = isOnline
        self.now = now
        self.timeout = timeout
        self.language = language
        preparer = AttachmentPreparer(maxImagePixels: Self.photoMaxPixels)
    }

    // MARK: Fotos

    /// Prepara e acrescenta fotos (fora da main): reduz a ≤ 1.280 px, reencoda em JPEG sem EXIF/GPS e troca o nome
    /// por um genérico. Lança sem acrescentar nada.
    func addPhotos(_ raws: [RawAttachment]) async throws {
        guard phase != .analyzing else { throw MealLogError.wrongPhase }
        guard photos.count + raws.count <= Self.maxPhotos else { throw MealLogError.tooManyPhotos(max: Self.maxPhotos) }
        let start = prepared.count
        let renamed = raws.enumerated().map { index, raw in
            RawAttachment(filename: "foto-\(start + index + 1).jpg", data: raw.data, typeHint: raw.typeHint)
        }
        let preparer = preparer
        let new: [PreparedAttachment]
        do {
            new = try await Task.detached(priority: .userInitiated) { try renamed.map { try preparer.prepare($0) } }.value
        } catch let error as AttachmentError {
            if case .unsupportedType = error { throw MealLogError.notAnImage }
            throw MealLogError.attachment(error)
        }
        guard new.allSatisfy({ $0.kind == .image }) else { throw MealLogError.notAnImage }
        guard photos.count + new.count <= Self.maxPhotos else { throw MealLogError.tooManyPhotos(max: Self.maxPhotos) }
        prepared += new
        photos = prepared.map { MealLogPhoto(id: $0.id, jpegData: $0.data) }
    }

    func removePhoto(_ id: UUID) {
        guard phase != .analyzing else { return }
        prepared.removeAll { $0.id == id }
        photos = prepared.map { MealLogPhoto(id: $0.id, jpegData: $0.data) }
    }

    // MARK: Análise

    /// Envia texto e fotos e monta o rascunho. Lança só pré-condições (`MealLogError`, ou `AIError` da configuração do
    /// provedor); sem internet, demora, erro do provedor, foto ilegível e baixa confiança viram `phase`.
    func analyze() async throws {
        guard phase != .analyzing else { throw MealLogError.wrongPhase }
        guard isAIAvailable() else { throw MealLogError.aiUnavailable }
        guard hasConsented() else { throw MealLogError.consentRequired }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !prepared.isEmpty else { throw MealLogError.emptyInput }
        guard trimmed.count <= Self.maxTextLength else { throw MealLogError.textTooLong(max: Self.maxTextLength) }
        let today = calendar.startOfDay(for: now())
        guard day <= today else { throw MealLogError.futureDay }
        let chat = try resolveChat()
        let toSend = prepared
        if !toSend.isEmpty {
            let capabilities = AttachmentCapabilities.resolve(provider: chat.gateway.provider, model: chat.model)
            guard capabilities.supportsImages else { throw MealLogError.modelWithoutVision }
        }
        guard isOnline() else {
            phase = .offline
            return
        }
        // Já em análise antes do primeiro `await`: `canAnalyze` fica falso e um segundo toque não dispara outra chamada.
        let previous = phase
        phase = .analyzing
        analysisStartedAt = now()
        let generation = generation
        let parts: [LLMContentPart]
        do {
            parts = try await Task.detached(priority: .userInitiated) {
                try AttachmentEncoder.encode(toSend, capabilities: AttachmentCapabilities(supportsImages: true, supportsPDF: false)).parts
            }.value
        } catch {
            if generation == self.generation {
                phase = previous
                analysisStartedAt = nil
            }
            if let error = error as? AttachmentError { throw MealLogError.attachment(error) }
            throw error
        }
        guard generation == self.generation else { return } // descartada enquanto preparava as fotos

        let planned = (try? plannedMeals()) ?? []
        let shared = sharesNutrition()
        let userText = userMessage(text: trimmed, photoCount: toSend.count, plan: shared ? planned : nil)
        lastInput = (trimmed, toSend.count)
        await run(chat: chat, messages: [.user(userText, parts: parts)], planned: planned, shared: shared,
                  referenceMinutes: referenceMinutes(), previous: previous, isCorrection: false)
    }

    /// Refaz só o rascunho a partir de uma correção por texto ("o arroz era integral, sem feijão"), sem reenviar fotos.
    func correct(_ instruction: String) async throws {
        guard phase.hasDraft, var draft = lastDraft, let input = lastInput else { throw MealLogError.noDraft }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MealLogError.emptyInput }
        guard trimmed.count <= Self.maxTextLength else { throw MealLogError.textTooLong(max: Self.maxTextLength) }
        guard isAIAvailable() else { throw MealLogError.aiUnavailable }
        let chat = try resolveChat()
        guard isOnline() else {
            phase = .offline
            return
        }
        // "Dieta" reavaliada agora: revogada depois da análise, a correção não leva plano nem ids do plano.
        let shared = sharesNutrition()
        let planned = (try? plannedMeals()) ?? review?.planned ?? []
        if !shared {
            for m in draft.meals.indices {
                draft.meals[m].plannedMealId = nil
                for i in draft.meals[m].items.indices { draft.meals[m].items[i].plannedItemId = nil }
            }
        }
        let message = userMessage(text: input.text, photoCount: input.photoCount, plan: shared ? planned : nil) + "\n\n"
            + MealLogPrompt.correctionMessage(draftJSON: Self.encode(draft), instruction: trimmed, language: language)
        await run(chat: chat, messages: [.user(message)], planned: planned, shared: shared,
                  referenceMinutes: referenceMinutes(), previous: phase, isCorrection: true)
    }

    private func userMessage(text: String, photoCount: Int, plan: [MealLogPlannedMeal]?) -> String {
        let isToday = day == calendar.startOfDay(for: now())
        return MealLogPrompt.userMessage(text: text, day: day, now: isToday ? now() : nil, photoCount: photoCount, plan: plan,
                                         language: language, calendar: calendar)
    }

    private func referenceMinutes() -> Int? {
        day == calendar.startOfDay(for: now()) ? minutes(of: now()) : nil
    }

    /// Cancela a análise em andamento: volta para a composição (ou para o rascunho, numa correção) sem perder nada.
    func cancel() {
        analysisTask?.cancel()
    }

    /// Depois de um erro/aviso: volta para o rascunho (se houver) ou para a composição, com texto e fotos.
    func retry() {
        guard phase != .analyzing else { return }
        if let review { phase = review.isLowConfidence ? .lowConfidence : .ready } else { phase = .composing }
    }

    /// Larga as fotos e o rascunho (fechar a folha com "Descartar").
    func discard() {
        generation += 1 // a análise/correção cancelada não volta a mexer no estado (ex.: `.ready` sem `review`)
        analysisTask?.cancel()
        analysisTask = nil
        prepared = []
        photos = []
        review = nil
        lastDraft = nil
        lastInput = nil
        text = ""
        analysisStartedAt = nil
        phase = .composing
    }

    private func run(chat: ResolvedChat, messages: [LLMMessage], planned: [MealLogPlannedMeal], shared: Bool,
                     referenceMinutes: Int?, previous: Phase, isCorrection: Bool) async {
        phase = .analyzing
        if analysisStartedAt == nil { analysisStartedAt = now() }
        let language = language
        let timeout = timeout
        let generation = generation
        let task = Task { @MainActor in
            do {
                let draft = try await Self.withTimeout(timeout) {
                    try await Self.extract(chat: chat, messages: messages, language: language)
                }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                self.accept(draft, planned: planned, shared: shared, referenceMinutes: referenceMinutes)
            } catch {
                guard generation == self.generation else { return }
                if ChatCancellation.isCancellation(error) {
                    self.phase = isCorrection && self.review != nil ? previous : .composing
                } else {
                    self.phase = Self.phase(for: error)
                }
            }
            self.analysisStartedAt = nil
        }
        analysisTask = task
        await task.value
        if generation == self.generation { analysisTask = nil }
    }

    private func accept(_ draft: FoodLogDraft, planned: [MealLogPlannedMeal], shared: Bool, referenceMinutes: Int?) {
        switch draft.status {
        case .noFood:
            phase = .noFood(reason: draft.reason)
            return
        case .unreadable:
            phase = .unreadable(reason: draft.reason)
            return
        case .ok:
            break
        }
        let built = MealLogReviewBuilder.review(from: draft, day: day, planned: planned, planWasShared: shared,
                                                referenceMinutes: referenceMinutes)
        guard !built.meals.isEmpty else {
            phase = .noFood(reason: draft.reason)
            return
        }
        lastDraft = draft
        review = built
        // As fotos só servem para a análise: descartadas assim que há rascunho.
        prepared = []
        photos = []
        phase = built.isLowConfidence ? .lowConfidence : .ready
    }

    private func plannedMeals() throws -> [MealLogPlannedMeal] {
        try NutritionStore(context: context, calendar: calendar).plannedMeals(on: day).map { state in
            MealLogPlannedMeal(id: state.meal.id, name: state.meal.name, minutesFromMidnight: state.meal.minutesFromMidnight,
                               status: state.status,
                               items: state.meal.sortedItems.map {
                                   MealLogPlannedItem(id: $0.id, name: $0.name, quantity: $0.quantity, unit: $0.unit, values: $0.values)
                               })
        }
    }

    private func minutes(of date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Chamada (fora da main)

    private struct Timeout: Error {}
    private enum ExtractionFailure: Error { case invalid, noExtraction }

    nonisolated private static func withTimeout<T: Sendable>(_ duration: Duration,
                                                             _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    /// Uma chamada + no máximo um reparo (sem reenviar as fotos). Devolve o rascunho validado.
    nonisolated private static func extract(chat: ResolvedChat, messages: [LLMMessage], language: String) async throws -> FoodLogDraft {
        let tool = ToolSpec(name: MealLogPrompt.submitTool, description: MealLogPrompt.toolDescription(language: language),
                            parametersSchema: DraftValidation.toolParameters(fromContract: DraftSchemas.foodLogDraftV1))
        let system = LLMMessage.system(MealLogPrompt.system(language: language))
        func call(_ conversation: [LLMMessage]) async throws -> String {
            let request = ChatRequest(model: chat.model, messages: [system] + conversation, tools: [tool],
                                      toolChoice: .tool(tool.name), metadata: ["module": "meal-log"])
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
        // Sem ferramenta nem JSON: falha direto (um reparo de "{}" sem o texto do usuário só inventaria um registro).
        let first = try await call(messages)
        switch DraftValidation.foodLog(first) {
        case let .valid(draft): return draft
        case let .invalid(problems):
            try Task.checkCancellation()
            let repaired = try await call([.user(CopilotPrompt.repairMessage(json: first, issues: problems))])
            guard case let .valid(draft) = DraftValidation.foodLog(repaired) else { throw ExtractionFailure.invalid }
            return draft
        }
    }

    /// Códigos de `URLError` que significam "sem internet".
    static let offlineCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue, URLError.dataNotAllowed.rawValue,
        URLError.internationalRoamingOff.rawValue, URLError.cannotFindHost.rawValue, URLError.cannotConnectToHost.rawValue,
        URLError.dnsLookupFailed.rawValue,
    ]

    static func phase(for error: any Error) -> Phase {
        switch error {
        case is Timeout:
            return .timedOut
        case let AIError.network(code, _):
            if offlineCodes.contains(code) { return .offline }
            if code == URLError.timedOut.rawValue { return .timedOut }
            return .providerError(AIError.network(code: code, retryable: true).localizedDescription)
        case let error as URLError:
            if offlineCodes.contains(error.code.rawValue) { return .offline }
            if error.code == .timedOut { return .timedOut }
            return .providerError(String(localized: "Não foi possível analisar. Tente de novo."))
        case let error as AIError:
            return .providerError(error.localizedDescription)
        case is ExtractionFailure:
            return .providerError(String(localized: "A IA não devolveu um registro válido. Tente de novo ou descreva por texto."))
        default:
            return .providerError(String(localized: "Não foi possível analisar. Tente de novo."))
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
