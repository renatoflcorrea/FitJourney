import Foundation
import SwiftData

// Tipos públicos do backup (API para a tela de Ajustes) e utilitários compartilhados.

/// Fase e fração (0…1) do trabalho. Chamado fora da main actor: a UI deve pular para a main.
struct BackupProgress: Sendable, Equatable {
    enum Phase: String, Sendable, Equatable {
        case reading, encoding, copyingMedia, extracting, validating, importing, saving, erasing, finished
    }

    var phase: Phase
    var fraction: Double
}

typealias BackupProgressHandler = @Sendable (BackupProgress) -> Void

/// Erros esperados (mensagens prontas para a UI).
enum BackupError: LocalizedError, Equatable, Sendable {
    /// Não é um backup do FitJourney (JSON sem `format`, zip sem `data.json`…).
    case notABackup
    /// Arquivo ilegível/truncado (JSON inválido, zip corrompido, CRC errado).
    case corruptedFile
    /// Criado por versão mais nova do formato: o usuário precisa atualizar o app.
    case newerVersion(found: Int, supported: Int)
    case unsupportedVersion(Int)
    /// Não confere com o schema `fitjourney-export-v1` (lista curta de problemas `caminho: motivo`).
    case invalidContent([String])
    /// Substituir apagaria o treino em andamento: finalize ou descarte antes.
    case activeSessionInProgress
    /// Pacote acima do limite do zip sem Zip64 (4 GB / 65.535 arquivos).
    case archiveTooLarge
    /// `data.json` acima do teto (`BackupDocumentLoader.maxDataBytes`).
    case dataTooLarge(limitMB: Int)
    /// Mídia do pacote acima dos limites (por arquivo ou no total).
    case mediaTooLarge

    var errorDescription: String? {
        switch self {
        case .notABackup:
            String(localized: "Este arquivo não é um backup do FitJourney.")
        case .corruptedFile:
            String(localized: "O arquivo de backup está corrompido ou incompleto.")
        case .newerVersion(let found, _):
            String(localized: "Este backup foi criado por uma versão mais nova do FitJourney (formato v\(found)). Atualize o app para importá-lo.")
        case .unsupportedVersion(let version):
            String(localized: "Versão de backup não suportada (v\(version)).")
        case .invalidContent(let issues):
            String(localized: "O backup tem dados inválidos: \(issues.prefix(3).joined(separator: "; "))")
        case .activeSessionInProgress:
            String(localized: "Há um treino em andamento. Finalize ou descarte o treino antes de substituir os dados.")
        case .archiveTooLarge:
            String(localized: "O backup ficou grande demais (limite de 4 GB). Exporte sem mídia.")
        case .dataTooLarge(let limitMB):
            String(localized: "Os dados do backup passam do limite de \(limitMB) MB e não podem ser importados.")
        case .mediaTooLarge:
            String(localized: "A mídia do backup passa do limite de tamanho e não pode ser importada.")
        }
    }
}

/// Grupos de dados contados nos relatórios.
enum BackupEntity: String, Sendable, Hashable, CaseIterable {
    case exercises, programs, sessions, nutritionPlans, foodEntries, waterLogs, foods, coachConversations
}

/// Contagens por grupo (só raízes: programa conta 1 com suas fichas, sessão conta 1 com suas séries).
struct BackupCounts: Sendable, Equatable {
    private(set) var values: [BackupEntity: Int] = [:]

    subscript(entity: BackupEntity) -> Int {
        get { values[entity] ?? 0 }
        set { values[entity] = newValue }
    }

    var total: Int { values.values.reduce(0, +) }

    init(_ values: [BackupEntity: Int] = [:]) { self.values = values }

    init(_ document: BackupV1.Document) {
        self.init([
            .exercises: document.exercises.count, .programs: document.programs.count,
            .sessions: document.sessions.count, .nutritionPlans: document.nutritionPlans.count,
            .foodEntries: document.foodEntries.count, .waterLogs: document.waterLogs.count,
            .foods: document.foods.count, .coachConversations: document.coachConversations?.count ?? 0,
        ])
    }
}

/// Avisos não fatais da importação.
enum BackupImportWarning: Sendable, Hashable {
    /// Mais de um programa ativo depois de importar: ficou só o mais recente.
    case extraActiveProgramsDeactivated(count: Int)
    case extraActiveNutritionPlansDeactivated(count: Int)
    /// Sessão em andamento no backup com séries feitas: importada como concluída na última série.
    case inProgressSessionFinalized(routineName: String)
    /// Sessão em andamento no backup sem nenhuma série feita: descartada (não importada).
    case inProgressSessionDiscarded(routineName: String)
    /// Arquivos de mídia referenciados que não vieram no backup nem existem no aparelho (referência removida).
    case missingMediaFiles(count: Int)
    /// Fichas apontando para exercício ausente do backup (fica "Exercício removido").
    case unknownExerciseReferences(count: Int)

    var message: String {
        switch self {
        case .extraActiveProgramsDeactivated(let count):
            String(localized: "\(count) programa(s) deixaram de ser ativos: só um programa fica ativo.")
        case .extraActiveNutritionPlansDeactivated(let count):
            String(localized: "\(count) plano(s) alimentares deixaram de ser ativos: só um plano fica ativo.")
        case .inProgressSessionFinalized(let name):
            String(localized: "O treino em andamento “\(name)” foi importado como concluído na última série feita.")
        case .inProgressSessionDiscarded(let name):
            String(localized: "O treino em andamento “\(name)” não tinha séries feitas e foi descartado.")
        case .missingMediaFiles(let count):
            String(localized: "\(count) arquivo(s) de mídia não estavam no backup e foram removidos dos exercícios.")
        case .unknownExerciseReferences(let count):
            String(localized: "\(count) exercício(s) de fichas não foram encontrados no catálogo.")
        }
    }
}

enum BackupImportMode: String, Sendable, Hashable, CaseIterable {
    /// Junta com os dados do aparelho: mesmo `id` → fica a versão com `updatedAt` mais recente.
    case merge
    /// Apaga os dados do aparelho e importa o backup.
    case replace
}

struct BackupImportReport: Sendable, Equatable {
    var mode: BackupImportMode
    var exportedAt: Date
    /// Criados no aparelho.
    var inserted = BackupCounts()
    /// Já existiam e foram sobrescritos pela versão do backup (mais recente).
    var updated = BackupCounts()
    /// Já existiam e a versão local (mais recente ou igual) foi mantida.
    var keptLocal = BackupCounts()
    var mediaFilesCopied = 0
    var warnings: [BackupImportWarning] = []

    /// Texto para a pré-visualização e o relatório: como "mesclar" decide conflitos.
    static var mergeSemantics: String {
        String(localized: "Ao mesclar, registros com o mesmo identificador ficam com a versão alterada mais recentemente. Programas, planos alimentares, treinos e conversas são comparados inteiros: se a versão do backup for mais nova, ela substitui a do aparelho por completo (fichas, refeições e séries incluídas).")
    }
}

// MARK: - Preferências e perfil (UserDefaults)

/// Chaves de preferências do app (não secretas). Chaves de API ficam no Keychain e nunca entram aqui.
enum BackupPreferenceKeys {
    static let weightUnit = WeightUnitPreference.key
    static let providerSettings = ProviderSettingsStore.key
    static let coachProfile = CoachProfileStore.key
    static let coachConsent = CoachProfileStore.consentKey
    /// = `SessionTombstones.key` e `ExerciseCatalogSeeder.versionKey` (tipos `@MainActor`; conferido nos testes).
    static let sessionTombstones = "sessionEngine.tombstones"
    static let seededCatalogVersion = "seededCatalogVersion"

    /// Tudo o que "apagar tudo" remove dos UserDefaults (exceto a versão do catálogo, tratada à parte).
    static let erasable = [weightUnit, providerSettings, coachProfile, coachConsent, sessionTombstones]
    /// Prefixos de chaves do app (novas preferências devem seguir um deles para serem apagadas).
    static let erasablePrefixes = ["fj.", "coach.", "sessionEngine.", "health.", "backup."]
}

enum BackupPreferences {
    static func collect(from defaults: UserDefaults) -> BackupV1.Preferences {
        var prefs = BackupV1.Preferences()
        if let unit = defaults.string(forKey: BackupPreferenceKeys.weightUnit), WeightUnit(rawValue: unit) != nil {
            prefs.weightUnit = unit
        }
        if defaults.data(forKey: BackupPreferenceKeys.providerSettings) != nil {
            let settings = ProviderSettingsStore(defaults: defaults).load()
            prefs.coachProvider = BackupV1.CoachProvider(
                provider: settings.provider.rawValue,
                models: Dictionary(uniqueKeysWithValues: settings.models.map { ($0.key.rawValue, $0.value) }),
                customBaseURL: sanitized(settings.customBaseURL)?.absoluteString,
                customContextTokens: settings.customContextTokens)
        }
        return prefs
    }

    static func collectProfile(from defaults: UserDefaults) -> BackupV1.CoachProfileInfo? {
        let store = CoachProfileStore(defaults: defaults)
        let consentedAt = defaults.object(forKey: BackupPreferenceKeys.coachConsent) as? Date
        guard defaults.data(forKey: BackupPreferenceKeys.coachProfile) != nil || consentedAt != nil else { return nil }
        return BackupV1.CoachProfileInfo(store.load(), consentedAt: consentedAt)
    }

    /// Mesclar: só preenche o que não existe no aparelho. Substituir: sobrescreve o que veio no backup e
    /// mantém as preferências locais que o backup não trouxer.
    /// **Nunca** vêm do backup: o compartilhamento com o provedor de IA, o consentimento, o provedor e a
    /// URL do Coach (o destino da chave de API não pode ser escolhido por um arquivo importado). Do Coach
    /// só entram os modelos escolhidos por provedor e a janela de contexto do `custom`.
    static func apply(_ prefs: BackupV1.Preferences, profile: BackupV1.CoachProfileInfo?, mode: BackupImportMode,
                      to defaults: UserDefaults) {
        let overwrite = mode == .replace
        if let unit = prefs.weightUnit, WeightUnit(rawValue: unit) != nil,
           overwrite || defaults.string(forKey: BackupPreferenceKeys.weightUnit) == nil {
            defaults.set(unit, forKey: BackupPreferenceKeys.weightUnit)
        }
        if let provider = prefs.coachProvider,
           overwrite || defaults.data(forKey: BackupPreferenceKeys.providerSettings) == nil {
            let store = ProviderSettingsStore(defaults: defaults)
            var settings = store.load() // provedor e URL locais ficam como estão
            for (key, value) in provider.models {
                guard let id = AIProviderID(rawValue: key) else { continue }
                let model = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                if !model.isEmpty { settings.models[id] = model }
            }
            if let tokens = provider.customContextTokens { settings.customContextTokens = tokens }
            store.save(settings)
        }
        if let profile {
            let store = CoachProfileStore(defaults: defaults)
            let local = store.load()
            if overwrite || local.isEmpty {
                store.save(profile.profile(keepingSharing: local.sharing))
            }
        }
    }

    /// URL sem credenciais embutidas (nunca exporta/importa usuário/senha de URL).
    static func sanitized(_ url: URL?) -> URL? {
        guard let url, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// MARK: - Catálogo embutido (fora da main actor)

enum BackupCatalog {
    /// Insere os exercícios embutidos cujo `catalogKey` não existe no contexto (não salva).
    @discardableResult
    static func insertMissingBuiltIns(in context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.catalogKey != nil }))
        let keys = Set(existing.filter { !$0.isDeleted }.compactMap(\.catalogKey))
        var inserted = 0
        for item in ExerciseCatalog.all where !keys.contains(item.key) {
            context.insert(Exercise(name: item.name, primaryMuscles: item.primary, secondaryMuscles: item.secondary,
                                    equipment: item.equipment, laterality: item.laterality,
                                    measurementKind: item.kind, defaultRestSeconds: item.rest,
                                    isBuiltIn: true, catalogKey: item.key))
            inserted += 1
        }
        return inserted
    }
}

// MARK: - Apagar todos os modelos

enum BackupWipe {
    /// Há treino em andamento no banco (contando o que este contexto ainda não salvou).
    static func hasSessionInProgress(in context: ModelContext) throws -> Bool {
        let raw = SessionStatus.inProgress.rawValue
        return try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == raw }))
            .contains { !$0.isDeleted && $0.status == .inProgress }
    }

    /// Marca para exclusão todos os registros (não salva). `keepConversations` preserva o Coach.
    static func deleteAllModels(in context: ModelContext, keepConversations: Bool = false) throws {
        func wipe<T: PersistentModel>(_: T.Type) throws {
            for model in try context.fetch(FetchDescriptor<T>()) { context.delete(model) }
        }
        try wipe(SetLog.self)
        try wipe(SessionExercise.self)
        try wipe(WorkoutSession.self)
        try wipe(SetPrescription.self)
        try wipe(RoutineExercise.self)
        try wipe(Routine.self)
        try wipe(TrainingProgram.self)
        try wipe(Exercise.self)
        try wipe(MealItem.self)
        try wipe(Meal.self)
        try wipe(NutritionDay.self)
        try wipe(NutritionPlan.self)
        try wipe(FoodItem.self)
        try wipe(FoodEntry.self)
        try wipe(WaterLog.self)
        if !keepConversations {
            try wipe(ChatMessage.self)
            try wipe(ChatConversation.self)
        }
    }
}

// MARK: - Temporários

/// Limpeza dos temporários do backup. **O App chama `runAtLaunch()` no lançamento** (não está ligado aqui).
enum BackupMaintenance {
    /// Pasta das exportações geradas (a UI compartilha daqui).
    static var exportsDirectory: URL { URL.temporaryDirectory.appending(path: "FJExports", directoryHint: .isDirectory) }
    static let importPrefix = "FJImport-"

    /// Apaga exportações e pastas de importação com mais de `maxAge` (padrão 24 h). Devolve quantos itens apagou.
    @discardableResult
    static func runAtLaunch(maxAge: TimeInterval = 24 * 3600, now: Date = .now,
                            temporaryDirectory: URL = URL.temporaryDirectory) -> Int {
        var removed = MediaMaintenance.cleanTemporary(in: temporaryDirectory.appending(path: "FJExports"),
                                                      olderThan: maxAge, now: now)
        removed += removeImportDirectories(in: temporaryDirectory, olderThan: maxAge, now: now)
        return removed
    }

    /// Apaga tudo: exportações e importações temporárias ("apagar tudo").
    @discardableResult
    static func removeAll(temporaryDirectory: URL = URL.temporaryDirectory) -> Int {
        var removed = 0
        if (try? FileManager.default.removeItem(at: temporaryDirectory.appending(path: "FJExports"))) != nil { removed += 1 }
        removed += removeImportDirectories(in: temporaryDirectory, olderThan: -1, now: .distantFuture)
        return removed
    }

    private static func removeImportDirectories(in directory: URL, olderThan maxAge: TimeInterval, now: Date) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in urls where url.lastPathComponent.hasPrefix(importPrefix) {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
