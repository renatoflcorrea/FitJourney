import Foundation
import SwiftData

/// Leitura e validação de um `data.json` (sem tocar no banco).
enum BackupDocumentLoader {
    /// Ordem: JSON legível → `format` → `schemaVersion` (mais nova = "atualize o app") → schema → Codable.
    static func load(_ data: Data) throws -> BackupV1.Document {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BackupError.corruptedFile }
        let value = JSONValue.convert(object)
        guard case .object = value, value["format"]?.stringValue == BackupV1.format else { throw BackupError.notABackup }
        guard case let .number(rawVersion)? = value["schemaVersion"], rawVersion.rounded() == rawVersion else {
            throw BackupError.notABackup
        }
        let version = Int(rawVersion)
        if version > BackupV1.schemaVersion { throw BackupError.newerVersion(found: version, supported: BackupV1.schemaVersion) }
        if version < 1 { throw BackupError.unsupportedVersion(version) }

        let validator = try JSONSchemaValidator(schemaJSON: BackupSchema.exportV1)
        let issues = validator.validate(value, limit: 10)
        guard issues.isEmpty else { throw BackupError.invalidContent(issues) }
        do {
            return try BackupV1.makeDecoder().decode(BackupV1.Document.self, from: data)
        } catch {
            throw BackupError.invalidContent([String(describing: error)])
        }
    }
}

/// Opções da importação.
struct BackupImportOptions: Sendable, Equatable {
    var mode: BackupImportMode = .merge
    /// Importa as conversas do Coach quando o backup as tiver.
    var includeCoachConversations = true
    /// Aplica preferências e perfil do Coach do backup (ver `BackupPreferences.apply`).
    var includePreferences = true

    init(mode: BackupImportMode = .merge, includeCoachConversations: Bool = true, includePreferences: Bool = true) {
        self.mode = mode
        self.includeCoachConversations = includeCoachConversations
        self.includePreferences = includePreferences
    }
}

/// Importa um backup `.fitjourney` (zip) ou `data.json` (SPEC §9).
///
/// **Transacional**: tudo é aplicado no `ModelContext` próprio deste ator e salvo uma única vez no
/// fim; qualquer erro desfaz o contexto (`rollback`) e apaga os arquivos de mídia que esta importação
/// copiou — o banco fica exatamente como estava. Preferências (UserDefaults) só são gravadas depois
/// do `save` bem-sucedido.
///
/// **Mesclar** (por `id`): exercício, alimento, registro alimentar e água são comparados registro a
/// registro; programa, plano alimentar, sessão e conversa são comparados como agregado (raiz +
/// descendentes, pelo maior `updatedAt`) e, se o do backup for mais recente, o agregado local é
/// trocado inteiro pelo do backup. Empate = fica o local. Exercícios embutidos são casados pelo
/// `catalogKey` (os IDs dos embutidos mudam entre instalações) e as referências do backup são
/// reapontadas para o ID local.
///
/// **Substituir**: apaga todos os dados e importa; embutidos ausentes do backup são semeados de novo.
/// Conversas locais só são apagadas se o backup trouxer conversas. Recusa se houver treino em andamento.
///
/// **Invariantes** depois de importar: no máximo um programa ativo e um plano alimentar ativo (fica o
/// de `updatedAt` mais recente). Sessões `inProgress` do backup nunca entram em andamento (o motor
/// da sessão e o relógio não as conhecem): com ao menos uma série feita viram `completed` com fim na
/// última série concluída (exercícios em andamento → parcial); sem nenhuma série feita são
/// descartadas (não importadas), como o descarte do app. Se já existir no aparelho uma sessão com o
/// mesmo `id`, a local fica. Mensagens `streaming` viram `stopped`.
actor BackupImporter: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private let mediaStore: MediaStore
    private let defaults: UserDefaults

    init(modelContainer: ModelContainer, mediaStore: MediaStore = .shared, defaults: UserDefaults = .standard) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
        self.mediaStore = mediaStore
        self.defaults = defaults
    }

    /// Lê e valida sem importar (pré-visualização: contagens e data do backup).
    func inspect(fileAt url: URL) throws -> (document: BackupV1.Document, counts: BackupCounts) {
        let staging = try Staging(source: url, extractMedia: false)
        defer { staging.cleanUp() }
        let document = try BackupDocumentLoader.load(staging.json)
        return (document, BackupCounts(document))
    }

    func importBackup(from url: URL, options: BackupImportOptions = .init(),
                      progress: BackupProgressHandler? = nil) async throws -> BackupImportReport {
        progress?(BackupProgress(phase: .extracting, fraction: 0))
        let staging = try Staging(source: url, extractMedia: true)
        defer { staging.cleanUp() }
        try Task.checkCancellation()
        progress?(BackupProgress(phase: .validating, fraction: 0.2))
        let document = try BackupDocumentLoader.load(staging.json)
        try Task.checkCancellation()
        return try apply(document, mediaDirectory: staging.mediaDirectory, options: options, progress: progress)
    }

    /// Importa um documento já carregado. `mediaDirectory` = pasta com os arquivos de `media/`.
    func apply(_ document: BackupV1.Document, mediaDirectory: URL? = nil, options: BackupImportOptions = .init(),
               progress: BackupProgressHandler? = nil) throws -> BackupImportReport {
        let context = modelContext
        var run = ImportRun(context: context, document: document, options: options, mediaStore: mediaStore,
                            mediaDirectory: mediaDirectory)
        do {
            progress?(BackupProgress(phase: .importing, fraction: 0.4))
            try run.execute()
            try Task.checkCancellation()
            progress?(BackupProgress(phase: .saving, fraction: 0.9))
            try context.save()
        } catch {
            context.rollback()
            for name in run.copiedMedia { mediaStore.deleteFile(named: name) }
            throw error
        }
        if options.mode == .replace, let referenced = try? MediaStore.referencedFileNames(in: context) {
            mediaStore.purgeOrphans(keeping: referenced)
        }
        if options.includePreferences {
            BackupPreferences.apply(document.preferences, profile: document.coachProfile, mode: options.mode, to: defaults)
        }
        progress?(BackupProgress(phase: .finished, fraction: 1))
        return run.report
    }
}

// MARK: - Arquivo de entrada

/// Abre `.fitjourney` (zip) ou JSON puro; extrai a mídia para uma pasta temporária.
private struct Staging {
    let json: Data
    let mediaDirectory: URL?
    private let root: URL?

    init(source: URL, extractMedia: Bool) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard ZipReader.looksLikeZip(source) else {
            guard let data = try? Data(contentsOf: source) else { throw BackupError.corruptedFile }
            json = data
            mediaDirectory = nil
            root = nil
            return
        }
        let reader: ZipReader
        do { reader = try ZipReader(url: source) } catch { throw BackupError.corruptedFile }
        guard let dataEntry = reader.entry(named: BackupV1.dataFileName) else { throw BackupError.notABackup }
        do { json = try reader.data(for: dataEntry) } catch { throw BackupError.corruptedFile }

        let mediaEntries = reader.entries.filter { entry in
            guard !entry.isDirectory, entry.name.hasPrefix(BackupV1.mediaFolder + "/") else { return false }
            return MediaStore.isSafe(fileName: String(entry.name.dropFirst(BackupV1.mediaFolder.count + 1)))
        }
        guard extractMedia, !mediaEntries.isEmpty else {
            mediaDirectory = nil
            root = nil
            return
        }
        let root = URL.temporaryDirectory.appending(path: "FJImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        let media = root.appending(path: BackupV1.mediaFolder, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            for entry in mediaEntries {
                try Task.checkCancellation()
                let name = String(entry.name.dropFirst(BackupV1.mediaFolder.count + 1))
                try reader.extract(entry, to: media.appending(path: name))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            if error is CancellationError { throw error }
            throw BackupError.corruptedFile
        }
        self.root = root
        self.mediaDirectory = media
    }

    func cleanUp() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }
}

// MARK: - Execução

private struct ImportRun {
    let context: ModelContext
    let document: BackupV1.Document
    let options: BackupImportOptions
    let mediaStore: MediaStore
    let mediaDirectory: URL?

    var report: BackupImportReport
    /// Arquivos copiados para a pasta de mídia nesta importação (apagados se der erro).
    var copiedMedia: [String] = []
    /// ID do exercício no backup → exercício local (inclui embutidos casados por `catalogKey`).
    private var exerciseByBackupID: [UUID: Exercise] = [:]
    private var missingMedia = Set<String>()
    private var unknownExerciseReferences = 0
    private var mediaResolved: [String: Bool] = [:]
    /// Exercícios gravados nesta importação e a mídia do backup a resolver no fim.
    private var pendingMedia: [(Exercise, [BackupV1.MediaValue])] = []

    init(context: ModelContext, document: BackupV1.Document, options: BackupImportOptions, mediaStore: MediaStore,
         mediaDirectory: URL?) {
        self.context = context
        self.document = document
        self.options = options
        self.mediaStore = mediaStore
        self.mediaDirectory = mediaDirectory
        self.report = BackupImportReport(mode: options.mode, exportedAt: document.exportedAt)
    }

    private func fetch<T: PersistentModel>(_: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>()).filter { !$0.isDeleted }
    }

    private func byID<T: PersistentModel>(_ models: [T], _ id: (T) -> UUID) -> [UUID: T] {
        Dictionary(models.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func execute() throws {
        let importConversations = options.includeCoachConversations && document.coachConversations != nil
        if options.mode == .replace {
            let active = try context.fetch(FetchDescriptor<WorkoutSession>()).contains { $0.status == .inProgress }
            if active { throw BackupError.activeSessionInProgress }
            try BackupWipe.deleteAllModels(in: context, keepConversations: !importConversations)
        }
        try importExercises()
        if options.mode == .replace { try BackupCatalog.insertMissingBuiltIns(in: context) }
        try importPrograms()
        try importSessions()
        try importNutritionPlans()
        try importFlat()
        if importConversations { try importConversationsList() }
        try relinkSessions()
        try enforceSingleActive()
        // Mídia por último: nada é copiado se os dados falharem antes; se a cópia falhar, tudo é desfeito.
        for (exercise, values) in pendingMedia {
            try Task.checkCancellation()
            exercise.mediaData = StorageCoding.encodeList(try resolveMedia(values), preservingUnknownIn: nil)
        }
        if !missingMedia.isEmpty { report.warnings.append(.missingMediaFiles(count: missingMedia.count)) }
        if unknownExerciseReferences > 0 {
            report.warnings.append(.unknownExerciseReferences(count: unknownExerciseReferences))
        }
    }

    // MARK: Mídia

    /// Mantém só as referências cujos arquivos existem no aparelho ou vieram no pacote (copiados agora).
    private mutating func resolveMedia(_ values: [BackupV1.MediaValue]) throws -> [MediaRef] {
        var result: [MediaRef] = []
        for value in values {
            guard let ref = value.domain else { continue }
            switch ref {
            case .externalVideo:
                result.append(ref)
            case .image(let fileName):
                if try ensureFile(fileName) { result.append(ref) }
            case .localVideo(let fileName, let thumbnail):
                guard try ensureFile(fileName) else { continue }
                let thumb = try thumbnail.flatMap { try ensureFile($0) ? $0 : nil }
                result.append(.localVideo(fileName: fileName, thumbnailFileName: thumb))
            }
        }
        return result
    }

    private mutating func ensureFile(_ name: String) throws -> Bool {
        if let known = mediaResolved[name] { return known }
        var available = mediaStore.fileExists(named: name)
        if !available, let source = mediaDirectory?.appending(path: name),
           FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
            if try mediaStore.importFile(at: source, named: name) {
                copiedMedia.append(name)
                report.mediaFilesCopied += 1
            }
            available = true
        }
        if !available { missingMedia.insert(name) }
        mediaResolved[name] = available
        return available
    }

    // MARK: Exercícios

    private mutating func importExercises() throws {
        let local = try fetch(Exercise.self)
        var localByID = byID(local, \.id)
        var localByKey = Dictionary(local.compactMap { ex in ex.catalogKey.map { ($0, ex) } }, uniquingKeysWith: { a, _ in a })
        for item in document.exercises {
            let match = localByID[item.id] ?? item.catalogKey.flatMap { localByKey[$0] }
            if let match {
                exerciseByBackupID[item.id] = match
                if item.updatedAt > match.updatedAt {
                    match.apply(item, media: [], keepID: match.id != item.id)
                    pendingMedia.append((match, item.media))
                    report.updated[.exercises] += 1
                } else {
                    report.keptLocal[.exercises] += 1
                }
            } else {
                let exercise = Exercise(name: item.name)
                exercise.apply(item, media: [])
                pendingMedia.append((exercise, item.media))
                context.insert(exercise)
                exerciseByBackupID[item.id] = exercise
                localByID[item.id] = exercise
                if let key = item.catalogKey { localByKey[key] = exercise }
                report.inserted[.exercises] += 1
            }
        }
    }

    /// ID local de um exercício referenciado no backup (embutidos podem ter outro ID aqui).
    private func localExerciseID(_ backupID: UUID?) -> UUID? {
        guard let backupID else { return nil }
        return exerciseByBackupID[backupID]?.id ?? backupID
    }

    // MARK: Programas

    private mutating func importPrograms() throws {
        let localByID = byID(try fetch(TrainingProgram.self), \.id)
        let allExercises = byID(try fetch(Exercise.self), \.id)
        for item in document.programs {
            let program: TrainingProgram
            if let local = localByID[item.id] {
                guard item.latestUpdate > local.latestUpdate else { report.keptLocal[.programs] += 1; continue }
                for routine in local.routines ?? [] { context.delete(routine) }
                local.routines = []
                program = local
                report.updated[.programs] += 1
            } else {
                program = TrainingProgram(name: item.name)
                context.insert(program)
                report.inserted[.programs] += 1
            }
            program.apply(item)
            for r in item.routines {
                let routine = Routine(name: r.name)
                routine.apply(r)
                context.insert(routine)
                routine.program = program
                for e in r.exercises {
                    let re = RoutineExercise()
                    re.apply(e)
                    context.insert(re)
                    re.routine = routine
                    if let backupID = e.exerciseID {
                        if let exercise = exerciseByBackupID[backupID] ?? allExercises[backupID] {
                            re.exercise = exercise
                        } else {
                            unknownExerciseReferences += 1
                        }
                    }
                    for s in e.sets {
                        let set = SetPrescription()
                        set.apply(s)
                        context.insert(set)
                        set.routineExercise = re
                    }
                }
            }
        }
    }

    // MARK: Sessões

    private mutating func importSessions() throws {
        let localByID = byID(try fetch(WorkoutSession.self), \.id)
        for item in document.sessions {
            let status = SessionStatus(rawValue: item.status) ?? .completed
            if let local = localByID[item.id] {
                // Sessão em andamento no aparelho nunca é tocada; backup em andamento nunca sobrescreve.
                guard local.status != .inProgress, status == .completed, item.latestUpdate > local.latestUpdate else {
                    report.keptLocal[.sessions] += 1
                    continue
                }
                for exercise in local.exercises ?? [] { context.delete(exercise) }
                local.exercises = []
                local.apply(item)
                insertSessionChildren(item, into: local)
                report.updated[.sessions] += 1
                continue
            }
            switch status {
            case .discarded:
                continue
            case .inProgress:
                let lastSet = item.exercises.flatMap(\.sets).filter(\.isCompleted).compactMap(\.completedAt).max()
                guard let lastSet else {
                    report.warnings.append(.inProgressSessionDiscarded(routineName: item.routineName))
                    continue
                }
                let session = insertSession(item)
                var clock = session.clock
                clock.finish(at: max(lastSet, session.startedAt))
                session.clock = clock
                session.status = .completed
                for exercise in session.exercises ?? [] where exercise.status == .inProgress {
                    exercise.status = .partial
                }
                report.warnings.append(.inProgressSessionFinalized(routineName: item.routineName))
            case .completed:
                insertSession(item)
            }
            report.inserted[.sessions] += 1
        }
    }

    @discardableResult
    private mutating func insertSession(_ item: BackupV1.Session) -> WorkoutSession {
        let session = WorkoutSession(routineName: item.routineName)
        session.apply(item)
        context.insert(session)
        insertSessionChildren(item, into: session)
        return session
    }

    private mutating func insertSessionChildren(_ item: BackupV1.Session, into session: WorkoutSession) {
        for e in item.exercises {
            let exercise = SessionExercise(name: e.name)
            exercise.apply(e)
            exercise.exerciseID = localExerciseID(e.exerciseID)
            exercise.substitutedFromExerciseID = localExerciseID(e.substitutedFromExerciseID)
            context.insert(exercise)
            exercise.session = session
            for s in e.sets {
                let set = SetLog()
                set.apply(s)
                context.insert(set)
                set.sessionExercise = exercise
            }
        }
    }

    /// Reata `WorkoutSession.routine` pelo `routineID` (fichas recriadas perdem o vínculo antigo).
    private func relinkSessions() throws {
        let routines = byID(try fetch(Routine.self), \.id)
        for session in try fetch(WorkoutSession.self) {
            guard let routineID = session.routineID, let routine = routines[routineID],
                  session.routine?.persistentModelID != routine.persistentModelID else { continue }
            session.routine = routine
        }
    }

    // MARK: Dieta

    private mutating func importNutritionPlans() throws {
        let localByID = byID(try fetch(NutritionPlan.self), \.id)
        for item in document.nutritionPlans {
            let plan: NutritionPlan
            if let local = localByID[item.id] {
                guard item.latestUpdate > local.latestUpdate else { report.keptLocal[.nutritionPlans] += 1; continue }
                for day in local.days ?? [] { context.delete(day) }
                local.days = []
                plan = local
                report.updated[.nutritionPlans] += 1
            } else {
                plan = NutritionPlan(name: item.name)
                context.insert(plan)
                report.inserted[.nutritionPlans] += 1
            }
            plan.apply(item)
            for d in item.days {
                let day = NutritionDay()
                day.apply(d)
                context.insert(day)
                day.plan = plan
                for m in d.meals {
                    let meal = Meal(name: m.name, minutesFromMidnight: m.minutesFromMidnight)
                    meal.apply(m)
                    context.insert(meal)
                    meal.day = day
                    for i in m.items {
                        let mealItem = MealItem(name: i.name, quantity: i.quantity, unit: .grams)
                        mealItem.apply(i)
                        context.insert(mealItem)
                        mealItem.meal = meal
                    }
                }
            }
        }
    }

    /// Registro a registro: mesmo `id` → vence o `updatedAt` mais recente.
    private mutating func importFlat() throws {
        try mergeRecords(document.foods, entity: .foods, local: try fetch(FoodItem.self), id: \.id,
                         make: { FoodItem(name: $0.name, servingQuantity: $0.servingQuantity, unit: .grams) },
                         apply: { $0.apply($1) })
        try mergeRecords(document.foodEntries, entity: .foodEntries, local: try fetch(FoodEntry.self), id: \.id,
                         make: { FoodEntry(name: $0.name, quantity: $0.quantity, unit: .grams) },
                         apply: { $0.apply($1) })
        try mergeRecords(document.waterLogs, entity: .waterLogs, local: try fetch(WaterLog.self), id: \.id,
                         make: { WaterLog(milliliters: $0.milliliters) }, apply: { $0.apply($1) })
    }

    private mutating func mergeRecords<D: BackupRecord, M: PersistentModel & BackupTimestamped>(
        _ items: [D], entity: BackupEntity, local: [M], id: (M) -> UUID,
        make: (D) -> M, apply: (M, D) -> Void) throws {
        let localByID = byID(local, id)
        for item in items {
            if let existing = localByID[item.id] {
                if item.updatedAt > existing.updatedAtValue {
                    apply(existing, item)
                    report.updated[entity] += 1
                } else {
                    report.keptLocal[entity] += 1
                }
            } else {
                let model = make(item)
                apply(model, item)
                context.insert(model)
                report.inserted[entity] += 1
            }
        }
    }

    // MARK: Coach

    private mutating func importConversationsList() throws {
        let localByID = byID(try fetch(ChatConversation.self), \.id)
        for item in document.coachConversations ?? [] {
            let conversation: ChatConversation
            if let local = localByID[item.id] {
                guard item.latestUpdate > local.latestUpdate else { report.keptLocal[.coachConversations] += 1; continue }
                for message in local.messages ?? [] { context.delete(message) }
                local.messages = []
                conversation = local
                report.updated[.coachConversations] += 1
            } else {
                conversation = ChatConversation()
                context.insert(conversation)
                report.inserted[.coachConversations] += 1
            }
            conversation.apply(item)
            for m in item.messages {
                let message = ChatMessage(role: .user, content: "", sortIndex: m.sortIndex)
                message.apply(m)
                context.insert(message)
                message.conversation = conversation
            }
        }
    }

    // MARK: Invariantes

    private mutating func enforceSingleActive() throws {
        let programs = try fetch(TrainingProgram.self).filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        if programs.count > 1 {
            for program in programs.dropFirst() { program.isActive = false }
            report.warnings.append(.extraActiveProgramsDeactivated(count: programs.count - 1))
        }
        let plans = try fetch(NutritionPlan.self).filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        if plans.count > 1 {
            for plan in plans.dropFirst() { plan.isActive = false }
            report.warnings.append(.extraActiveNutritionPlansDeactivated(count: plans.count - 1))
        }
    }
}

// MARK: - Registros planos

protocol BackupRecord {
    var id: UUID { get }
    var updatedAt: Date { get }
}

extension BackupV1.Food: BackupRecord {}
extension BackupV1.FoodEntry: BackupRecord {}
extension BackupV1.WaterLog: BackupRecord {}

protocol BackupTimestamped {
    var updatedAtValue: Date { get }
}

extension FoodItem: BackupTimestamped { var updatedAtValue: Date { updatedAt } }
extension FoodEntry: BackupTimestamped { var updatedAtValue: Date { updatedAt } }
extension WaterLog: BackupTimestamped { var updatedAtValue: Date { updatedAt } }
