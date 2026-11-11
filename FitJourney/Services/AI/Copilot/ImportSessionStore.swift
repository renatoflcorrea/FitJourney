import Foundation

/// Estado persistível de uma importação (retomável se o app fechar). **Sem bytes de anexos**: só metadados,
/// a extração, as respostas e a seleção. Nunca vai para o backup.
struct ImportSessionState: Codable, Sendable, Hashable {
    var id: UUID
    var kind: ImportSession.Kind
    var phase: ImportSession.Phase
    var createdAt: Date
    var updatedAt: Date
    var attachments: [AttachmentMetadata]
    var warnings: [String]
    var note: String
    var programImport: ProgramImport?
    var nutritionImport: NutritionImport?
    /// Índices das fichas (treino) ou variações (dieta) escolhidas.
    var selected: [Int]
    var resolvedGapIDs: [String]
    /// Respostas dadas (por id de lacuna), para mostrar o histórico da entrevista e revisar ambiguidades.
    var answers: [String: ImportAnswer]
    var failureMessage: String?
    var resultID: UUID?
    /// Respostas às dúvidas da IA ainda não aplicadas por `reviseWithAI()` (índice da dúvida → resposta).
    var pendingAmbiguityAnswers: [String: String]?
}

/// Onde as importações em andamento ficam.
@MainActor
protocol ImportSessionStoring: AnyObject {
    func save(_ state: ImportSessionState) throws
    func load(id: UUID) -> ImportSessionState?
    /// Importações não concluídas, mais recentes primeiro.
    func pending() -> [ImportSessionState]
    func delete(id: UUID)
}

/// Um JSON por importação em `Application Support/ImportSessions/` (protegido até o primeiro desbloqueio,
/// fora do backup do iCloud). Estados com mais de 7 dias são descartados ao listar.
@MainActor
final class FileImportSessionStore: ImportSessionStoring {
    static let maxAge: TimeInterval = 7 * 24 * 3600
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "ImportSessions", directoryHint: .isDirectory)
    }

    private func url(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    func save(_ state: ImportSessionState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url(state.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(id: UUID) -> ImportSessionState? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportSessionState.self, from: data)
    }

    func pending() -> [ImportSessionState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let now = Date.now
        var result: [ImportSessionState] = []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let state = load(id: id) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if now.timeIntervalSince(state.updatedAt) > Self.maxAge || state.phase == .done {
                delete(id: id)
                continue
            }
            result.append(state)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}

/// Para testes e previews.
@MainActor
final class InMemoryImportSessionStore: ImportSessionStoring {
    private(set) var states: [UUID: ImportSessionState] = [:]

    init() {}

    func save(_ state: ImportSessionState) throws { states[state.id] = state }
    func load(id: UUID) -> ImportSessionState? { states[id] }
    func pending() -> [ImportSessionState] {
        states.values.filter { $0.phase != .done }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func delete(id: UUID) { states.removeValue(forKey: id) }
}
