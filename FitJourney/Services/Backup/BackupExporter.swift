import Foundation
import SwiftData

/// Opções da exportação.
struct BackupExportOptions: Sendable, Equatable {
    enum Format: String, Sendable, Equatable, CaseIterable {
        /// `.fitjourney`: zip com `data.json` + `media/` (backup completo).
        case package
        /// Só `data.json` (sem mídia) — para outras ferramentas (HealthProject, ChatGPT…).
        case json
    }

    var format: Format = .package
    /// Inclui as conversas do Coach (desligado por padrão: podem conter dados pessoais de saúde).
    var includeCoachConversations = false

    init(format: Format = .package, includeCoachConversations: Bool = false) {
        self.format = format
        self.includeCoachConversations = includeCoachConversations
    }
}

struct BackupExportResult: Sendable, Equatable {
    /// Arquivo gerado (num diretório temporário se nenhum foi indicado). A UI compartilha/move e pode apagar.
    var fileURL: URL
    var counts: BackupCounts
    var mediaFilesIncluded: Int
    /// Arquivos referenciados que não existiam no aparelho (ficam no manifesto com `included: false`).
    var mediaFilesMissing: Int
    var byteCount: Int
}

/// Exporta todos os dados (SPEC §9) lendo por um `ModelContext` próprio, fora da main actor.
///
/// Nunca acessa o Keychain: o formato não tem campo para segredos e as preferências exportadas
/// são só as não secretas (`BackupPreferences`).
///
/// ```swift
/// let exporter = BackupExporter(modelContainer: container)
/// let result = try await exporter.export(options: .init(format: .package)) { progress in … }
/// ```
actor BackupExporter: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private let mediaStore: MediaStore
    private let defaults: UserDefaults
    private let appInfo: BackupV1.AppInfo
    private let timeZone: TimeZone

    init(modelContainer: ModelContainer, mediaStore: MediaStore = .shared, defaults: UserDefaults = .standard,
         appInfo: BackupV1.AppInfo = BackupExporter.currentAppInfo(), timeZone: TimeZone = .current) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
        self.mediaStore = mediaStore
        self.defaults = defaults
        self.appInfo = appInfo
        self.timeZone = timeZone
    }

    static func currentAppInfo(bundle: Bundle = .main) -> BackupV1.AppInfo {
        BackupV1.AppInfo(
            name: "FitRoute",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            platform: "iOS",
            timeZone: TimeZone.current.identifier,
            locale: Locale.current.identifier)
    }

    /// Monta o documento (sem gravar arquivo). Útil para testes e para integrações em memória.
    func makeDocument(options: BackupExportOptions = .init(), now: Date = .now) throws -> BackupV1.Document {
        let context = modelContext
        func all<T: PersistentModel>(_: T.Type) throws -> [T] { try context.fetch(FetchDescriptor<T>()) }

        let exercises = try all(Exercise.self).sorted { Self.order($0.createdAt, $0.id) < Self.order($1.createdAt, $1.id) }
        var document = BackupV1.Document(
            exportedAt: now,
            app: BackupV1.AppInfo(name: appInfo.name, version: appInfo.version, build: appInfo.build,
                                  platform: appInfo.platform, timeZone: timeZone.identifier, locale: appInfo.locale),
            options: .init(includesMedia: options.format == .package,
                           includesCoachConversations: options.includeCoachConversations))
        document.exercises = exercises.map(BackupV1.Exercise.init)
        document.programs = try all(TrainingProgram.self).sorted { Self.order($0.createdAt, $0.id) < Self.order($1.createdAt, $1.id) }.map(BackupV1.Program.init)
        document.sessions = try all(WorkoutSession.self).sorted { Self.order($0.startedAt, $0.id) < Self.order($1.startedAt, $1.id) }.map(BackupV1.Session.init)
        document.nutritionPlans = try all(NutritionPlan.self).sorted { Self.order($0.createdAt, $0.id) < Self.order($1.createdAt, $1.id) }
            .map(BackupV1.NutritionPlan.init)
        document.foodEntries = try all(FoodEntry.self).sorted { Self.order($0.date, $0.id) < Self.order($1.date, $1.id) }.map(BackupV1.FoodEntry.init)
        document.waterLogs = try all(WaterLog.self).sorted { Self.order($0.date, $0.id) < Self.order($1.date, $1.id) }.map(BackupV1.WaterLog.init)
        document.foods = try all(FoodItem.self).sorted { Self.order($0.createdAt, $0.id) < Self.order($1.createdAt, $1.id) }.map(BackupV1.Food.init)
        if options.includeCoachConversations {
            document.coachConversations = try all(ChatConversation.self).sorted { Self.order($0.createdAt, $0.id) < Self.order($1.createdAt, $1.id) }
                .map(BackupV1.Conversation.init)
        }
        document.coachProfile = BackupPreferences.collectProfile(from: defaults)
        document.preferences = BackupPreferences.collect(from: defaults)

        var seen = Set<String>()
        let names = exercises.flatMap { $0.media.flatMap(MediaStore.fileNames(of:)) }.filter { seen.insert($0).inserted }
        document.media = names.map { name in
            let size = mediaStore.byteCount(of: name)
            return BackupV1.MediaFile(fileName: name, byteCount: size,
                                      included: options.format == .package && size != nil)
        }
        return document
    }

    /// JSON do documento (datas com o fuso do exportador).
    func encode(_ document: BackupV1.Document) throws -> Data {
        try BackupV1.makeEncoder(timeZone: timeZone).encode(document)
    }

    /// Gera o arquivo. `directory == nil` → pasta temporária `FJExports`. Em erro ou cancelamento,
    /// o arquivo parcial é apagado.
    func export(options: BackupExportOptions = .init(), to directory: URL? = nil, now: Date = .now,
                progress: BackupProgressHandler? = nil) async throws -> BackupExportResult {
        progress?(BackupProgress(phase: .reading, fraction: 0))
        if directory == nil { BackupMaintenance.runAtLaunch() } // exportações antigas (> 24 h)
        var document = try makeDocument(options: options, now: now)
        try Task.checkCancellation()

        let folder = directory ?? BackupMaintenance.exportsDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = options.format == .package ? BackupV1.packageExtension : "json"
        let url = folder.appending(path: Self.fileName(for: now, timeZone: timeZone, ext: ext))
        try? FileManager.default.removeItem(at: url)

        do {
            var included = 0
            let json: Data
            switch options.format {
            case .json:
                progress?(BackupProgress(phase: .encoding, fraction: 0.2))
                json = try encode(document)
                try json.write(to: url, options: .atomic)
            case .package:
                // Mídia primeiro: um arquivo que sumir no meio vira `included: false` no manifesto,
                // que só é escrito (em `data.json`) no fim.
                let writer = try ZipWriter(url: url, date: now)
                let files = document.media.filter(\.included)
                let totalBytes = max(1, files.reduce(0) { $0 + ($1.byteCount ?? 0) })
                var copied = 0
                var written = Set<String>()
                for file in files {
                    try Task.checkCancellation()
                    guard let source = mediaStore.url(for: file.fileName), mediaStore.fileExists(named: file.fileName) else {
                        continue
                    }
                    try writer.add(name: "\(BackupV1.mediaFolder)/\(file.fileName)", contentsOf: source) { bytes in
                        copied += bytes
                        progress?(BackupProgress(phase: .copyingMedia, fraction: 0.1 + 0.8 * Double(copied) / Double(totalBytes)))
                    }
                    written.insert(file.fileName)
                    included += 1
                }
                document.media = document.media.map { file in
                    var f = file
                    f.included = written.contains(file.fileName)
                    return f
                }
                progress?(BackupProgress(phase: .encoding, fraction: 0.92))
                json = try encode(document)
                try writer.add(name: BackupV1.dataFileName, data: json, compress: true)
                try writer.finish()
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? json.count
            progress?(BackupProgress(phase: .finished, fraction: 1))
            return BackupExportResult(fileURL: url, counts: BackupCounts(document), mediaFilesIncluded: included,
                                      mediaFilesMissing: document.media.filter { options.format == .package && !$0.included }.count,
                                      byteCount: size)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if let zip = error as? ZipError, zip == .tooLarge { throw BackupError.archiveTooLarge }
            throw error
        }
    }

    /// Ordem estável: data em milissegundos (a precisão do formato) e depois o `id`.
    private static func order(_ date: Date, _ id: UUID) -> (Int64, String) {
        (Int64((date.timeIntervalSince1970 * 1000).rounded()), id.uuidString)
    }

    /// "FitRoute-2026-11-11-0930.fitjourney"
    static func fileName(for date: Date, timeZone: TimeZone, ext: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "FitRoute-\(stamp).\(ext)"
    }
}
