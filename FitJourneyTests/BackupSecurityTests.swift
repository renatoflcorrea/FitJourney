import Foundation
import SwiftData
import Testing
@testable import FitJourney

private func example() throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "contracts").appending(path: "fitjourney-export-v1.example.json")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Backup · Segurança")
@MainActor
struct BackupSecurityTests {
    private func write(_ text: String, _ name: String, in f: BackupFixture) throws -> URL {
        let url = f.workDir.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("schemaVersion fora de faixa ou fracionário não derruba o app")
    func schemaVersionRange() async throws {
        let f = try BackupFixture(sample: false)
        let raw = try example()
        for bad in ["1e300", "1.5", "-1e300", "9007199254740993"] {
            let url = try write(raw.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": \(bad)"),
                                "v.json", in: f)
            await #expect(throws: BackupError.self, "\(bad)") { try await f.importer().importBackup(from: url) }
        }
        let zero = try write(raw.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 0"), "z.json", in: f)
        await #expect(throws: BackupError.unsupportedVersion(0)) { try await f.importer().importBackup(from: zero) }
        #expect(throws: BackupError.notABackup) {
            try BackupDocumentLoader.load(Data(raw.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1e300").utf8))
        }
    }

    @Test("bomba de descompressão em data.json é abortada")
    func decompressionBomb() async throws {
        let f = try BackupFixture(sample: false)
        let zeros = Data(count: 20 * 1024 * 1024)
        let deflated = try (zeros as NSData).compressed(using: .zlib) as Data
        #expect(deflated.count < 100_000)
        let url = f.workDir.appending(path: "bomb.fitjourney")
        let writer = try ZipWriter(url: url)
        try writer.addRaw(name: "data.json", payload: deflated, method: 8, crc: 0, size: 1_000)
        try writer.finish()
        await #expect(throws: BackupError.corruptedFile) { try await f.importer().importBackup(from: url) }
        #expect(throws: ZipError.corrupted("x")) { try ZipReader.inflate(deflated, limit: 1_000, name: "x") }
    }

    @Test("data.json acima do teto → erro claro (zip e JSON puro)")
    func dataTooLarge() async throws {
        let f = try BackupFixture(sample: false)
        let zip = f.workDir.appending(path: "huge.fitjourney")
        let writer = try ZipWriter(url: zip)
        try writer.addRaw(name: "data.json", payload: Data("{}".utf8), method: 8, crc: 0, size: 200 * 1024 * 1024)
        try writer.finish()
        await #expect(throws: BackupError.dataTooLarge(limitMB: 96)) { try await f.importer().importBackup(from: zip) }

        let json = f.workDir.appending(path: "huge.json")
        FileManager.default.createFile(atPath: json.path(percentEncoded: false), contents: Data("{".utf8))
        let handle = try FileHandle(forWritingTo: json)
        try handle.truncate(atOffset: UInt64(BackupDocumentLoader.maxDataBytes + 1))
        try handle.close()
        await #expect(throws: BackupError.dataTooLarge(limitMB: 96)) { try await f.importer().importBackup(from: json) }
        #expect(BackupError.dataTooLarge(limitMB: 96).errorDescription?.contains("96 MB") == true)
    }

    @Test("mídia comprimida, nomes repetidos e mídia não referenciada")
    func mediaEntries() async throws {
        let source = try BackupFixture()
        try source.addExtras()
        let document = try await source.exporter().makeDocument()
        let json = try await source.exporter().encode(document)
        let image = try #require(document.media.first?.fileName)
        let target = try BackupFixture(sample: false)

        // DEFLATE em media/ → recusado.
        let deflatedMedia = target.workDir.appending(path: "deflated.fitjourney")
        var writer = try ZipWriter(url: deflatedMedia)
        try writer.add(name: "data.json", data: json, compress: true)
        let bytes = Data(repeating: 7, count: 4096)
        try writer.addRaw(name: "media/\(image)", payload: try (bytes as NSData).compressed(using: .zlib) as Data,
                          method: 8, crc: CRC32.checksum(bytes), size: UInt32(bytes.count))
        try writer.finish()
        await #expect(throws: BackupError.corruptedFile) { try await target.importer().importBackup(from: deflatedMedia) }
        #expect(try target.count(TrainingProgram.self) == 0)

        // Nome repetido no zip → corrompido.
        let duplicated = target.workDir.appending(path: "dup.fitjourney")
        writer = try ZipWriter(url: duplicated)
        try writer.add(name: "data.json", data: json, compress: true)
        try writer.add(name: "data.json", data: Data("{}".utf8), compress: false)
        try writer.finish()
        await #expect(throws: BackupError.corruptedFile) { try await target.importer().importBackup(from: duplicated) }

        // Só a mídia referenciada é extraída/copiada.
        let extra = target.workDir.appending(path: "extra.fitjourney")
        writer = try ZipWriter(url: extra)
        try writer.add(name: "media/\(image)", data: Data("fake-jpeg-bytes".utf8), compress: false)
        try writer.add(name: "media/intruso.jpg", data: Data("x".utf8), compress: false)
        try writer.add(name: "data.json", data: json, compress: true)
        try writer.finish()
        let report = try await target.importer().importBackup(from: extra)
        #expect(report.mediaFilesCopied == 1)
        #expect(target.media.fileExists(named: image))
        #expect(!target.media.fileExists(named: "intruso.jpg"))
    }

    @Test("provedor e URL do Coach nunca vêm do backup")
    func providerIsNeverImported() async throws {
        let f = try BackupFixture(sample: false)
        var document = try BackupDocumentLoader.load(Data(try example().utf8))
        document.preferences.coachProvider = .init(provider: "custom", models: ["custom": "evil-model", "openAI": "gpt-x"],
                                                   customBaseURL: "https://attacker.example/v1", customContextTokens: 16000)
        for mode in BackupImportMode.allCases {
            _ = try await f.importer().apply(document, options: .init(mode: mode))
            let settings = ProviderSettingsStore(defaults: f.defaults).load()
            #expect(settings.provider == .openAI, "\(mode)")
            #expect(settings.customBaseURL == nil, "\(mode)")
        }
        let settings = ProviderSettingsStore(defaults: f.defaults).load()
        #expect(settings.models[.openAI] == "gpt-x")
        #expect(settings.customContextTokens == 16000)
    }

    @Test("links de vídeo com usuário/senha são descartados na exportação e na importação")
    func credentialLinksAreDropped() async throws {
        let f = try BackupFixture()
        let evil = URL(string: "https://user:secret@videos.example/v.mp4")!
        let exercise = Exercise(name: "Com link perigoso")
        exercise.media = [.externalVideo(url: evil, provider: .other, videoID: nil)]
        f.context.insert(exercise)
        try f.context.save()
        let document = try await f.exporter().makeDocument()
        let exported = try #require(document.exercises.first { $0.name == "Com link perigoso" })
        #expect(exported.media.isEmpty)
        let text = String(decoding: try await f.exporter().encode(document), as: UTF8.self)
        #expect(!text.contains("secret"))

        var tampered = document
        let index = try #require(tampered.exercises.firstIndex { $0.name == "Com link perigoso" })
        tampered.exercises[index].media = [.init(kind: "externalVideo", url: evil.absoluteString, provider: "other")]
        tampered.exercises[index].updatedAt = .now.addingTimeInterval(60)
        _ = try await f.importer().apply(tampered)
        let imported = try #require(try ModelContext(f.container).fetch(FetchDescriptor<Exercise>())
            .first { $0.name == "Com link perigoso" })
        #expect(imported.media.isEmpty)
    }

    @Test("tetos do schema e datas futuras limitadas, IDs repetidos ignorados")
    func limitsAndFutureDates() async throws {
        let f = try BackupFixture(sample: false)
        let raw = try example()
        let huge = raw.replacingOccurrences(of: "\"milliliters\": 500", with: "\"milliliters\": 1e12")
        #expect(throws: BackupError.self) { try BackupDocumentLoader.load(Data(huge.utf8)) }
        let longName = raw.replacingOccurrences(of: "\"name\": \"AB Força\"",
                                                with: "\"name\": \"\(String(repeating: "x", count: 600))\"")
        #expect(throws: BackupError.self) { try BackupDocumentLoader.load(Data(longName.utf8)) }

        var document = try BackupDocumentLoader.load(Data(raw.utf8))
        document.waterLogs[0].updatedAt = Date(timeIntervalSinceNow: 10 * 365 * 86_400)
        document.waterLogs.append(document.waterLogs[0])
        let report = try await f.importer().apply(document)
        #expect(report.inserted[.waterLogs] == 1)
        let water = try #require(try ModelContext(f.container).fetch(FetchDescriptor<WaterLog>()).first)
        #expect(water.updatedAt <= Date.now.addingTimeInterval(86_400 + 5))
    }

    @Test("sessões: tombstone local não volta; concluída é normalizada")
    func sessionsTombstonesAndNormalization() async throws {
        let f = try BackupFixture(sample: false)
        var document = try BackupDocumentLoader.load(Data(try example().utf8))
        var ghost = document.sessions[0]
        ghost.id = UUID()
        ghost.exercises = []
        document.sessions[0].endedAt = nil
        document.sessions[0].pausedAt = document.sessions[0].startedAt.addingTimeInterval(600)
        document.sessions[0].restEndsAt = .now
        document.sessions.append(ghost)
        let tombstones = [SessionTombstone(sessionID: ghost.id, lastRevision: 3, commandIDs: [], discardedAt: .now)]
        f.defaults.set(try JSONEncoder().encode(tombstones), forKey: BackupPreferenceKeys.sessionTombstones)

        let report = try await f.importer().apply(document)
        #expect(report.inserted[.sessions] == 1)
        let session = try #require(try ModelContext(f.container).fetch(FetchDescriptor<WorkoutSession>()).first)
        #expect(session.id == document.sessions[0].id)
        #expect(session.endedAt != nil && session.pausedAt == nil && session.restEndsAt == nil)
    }

    @Test("apagar tudo recusa treino em andamento e limpa temporários e notificações")
    func eraserGuardsAndCleansUp() async throws {
        let f = try BackupFixture()
        let routine = try #require(try f.context.fetch(FetchDescriptor<Routine>()).first)
        let session = try SessionStore(context: f.context).start(routine: routine)
        await #expect(throws: BackupError.activeSessionInProgress) { try await f.eraser().eraseAll() }
        #expect(try f.count(TrainingProgram.self) == 1)
        try SessionStore(context: f.context).discard(session)

        let exports = f.workDir.appending(path: "FJExports")
        let staging = f.workDir.appending(path: "FJImport-\(UUID().uuidString)")
        for dir in [exports, staging] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try await f.eraser().eraseAll()
        #expect(!FileManager.default.fileExists(atPath: exports.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
        #expect(f.notificationsCleared.count == 1)
    }

    @Test("limpeza de lançamento apaga só temporários antigos")
    func launchCleanup() throws {
        let dir = URL.temporaryDirectory.appending(path: "FJMaint-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exports = dir.appending(path: "FJExports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = exports.appending(path: "old.fitjourney")
        let fresh = exports.appending(path: "new.fitjourney")
        try Data("a".utf8).write(to: old)
        try Data("b".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                                              ofItemAtPath: old.path(percentEncoded: false))
        #expect(BackupMaintenance.runAtLaunch(temporaryDirectory: dir) == 1)
        #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    }

    @Test("texto de semântica da mesclagem para a pré-visualização")
    func mergeSemanticsText() {
        #expect(BackupImportReport.mergeSemantics.contains("substitui"))
    }
}
