import Foundation
import SwiftData
import Testing
@testable import FitJourney

// MARK: - Ambiente

/// Container em memória + pasta de mídia + UserDefaults isolados.
@MainActor
final class BackupFixture {
    let container: ModelContainer
    let media: MediaStore
    let suite: String
    /// UserDefaults não é Sendable: cada ator recebe uma instância nova do mesmo domínio.
    var defaults: UserDefaults { Self.makeDefaults(suite) }
    nonisolated static func makeDefaults(_ suite: String) -> UserDefaults { UserDefaults(suiteName: suite)! }
    let secrets = InMemorySecretStore()
    let workDir: URL

    init(sample: Bool = true) throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        workDir = URL.temporaryDirectory.appending(path: "FJBackupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        media = MediaStore(root: workDir.appending(path: "Media", directoryHint: .isDirectory))
        suite = "fj-backup-tests-\(UUID().uuidString)"
        if sample { try SampleData.insert(into: container.mainContext) } else {
            try ExerciseCatalogSeeder.seedIfNeeded(in: container.mainContext)
        }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: workDir)
    }

    var context: ModelContext { container.mainContext }

    func exporter() -> BackupExporter {
        BackupExporter(modelContainer: container, mediaStore: media, defaults: Self.makeDefaults(suite),
                       appInfo: .init(name: "FitJourney", version: "1.0", build: "1", platform: "iOS",
                                      timeZone: "America/Sao_Paulo", locale: "pt_BR"),
                       timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
    }

    func importer(media: MediaStore? = nil) -> BackupImporter {
        BackupImporter(modelContainer: container, mediaStore: media ?? self.media, defaults: Self.makeDefaults(suite))
    }

    func eraser() -> DataEraser {
        DataEraser(modelContainer: container, mediaStore: media, defaults: Self.makeDefaults(suite), secretStore: secrets)
    }

    /// Contagem por um contexto novo (não usa objetos em cache da main).
    func count<T: PersistentModel>(_: T.Type) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    /// Exercício do usuário com imagem, conversa do Coach, perfil e preferências.
    func addExtras() throws {
        let fileName = "\(UUID().uuidString).jpg"
        try FileManager.default.createDirectory(at: media.root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes".utf8).write(to: media.root.appending(path: fileName))
        let exercise = Exercise(name: "Remada unilateral no banco", primaryMuscles: [.back], equipment: .dumbbell,
                                laterality: .unilateral)
        exercise.media = [.image(fileName: fileName),
                          .externalVideo(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, provider: .youtube,
                                         videoID: "dQw4w9WgXcQ")]
        exercise.notes = "Peito apoiado"
        context.insert(exercise)

        let conversation = ChatConversation(title: "Volume de peito")
        context.insert(conversation)
        let user = ChatMessage(role: .user, content: "Posso subir o volume?", sortIndex: 0)
        let assistant = ChatMessage(role: .assistant, content: "Sim.", sortIndex: 1)
        assistant.toolCalls = [ToolCall(id: "call_1", name: "get_workout_history", argumentsJSON: "{\"days\":30}")]
        assistant.promptTokens = 1000
        assistant.completionTokens = 20
        for message in [user, assistant] {
            context.insert(message)
            message.conversation = conversation
        }
        let entry = FoodEntry(name: "Pão de queijo", quantity: 2, unit: .unit, values: NutrientValues(kcal: nil, protein: 4))
        context.insert(entry)
        try context.save()

        var profile = CoachProfile()
        profile.age = 34
        profile.weightKg = 80.5
        profile.level = .intermediate
        CoachProfileStore(defaults: defaults).save(profile)
        CoachProfileStore(defaults: defaults).grantConsent(sharing: .init(profile: true, workouts: true))
        defaults.set("lb", forKey: WeightUnitPreference.key)
        ProviderSettingsStore(defaults: defaults).save(
            ProviderSettings(provider: .custom, models: [.custom: "llama3"],
                             customBaseURL: URL(string: "http://192.168.0.10:11434/v1"), customContextTokens: 8000))
    }
}

/// Documento comparável: sem `exportedAt` e com listas de topo ordenadas por `id`.
private func normalized(_ document: BackupV1.Document) throws -> String {
    var d = document
    d.exportedAt = Date(timeIntervalSince1970: 0)
    d.exercises.sort { $0.id.uuidString < $1.id.uuidString }
    d.programs.sort { $0.id.uuidString < $1.id.uuidString }
    d.sessions.sort { $0.id.uuidString < $1.id.uuidString }
    d.nutritionPlans.sort { $0.id.uuidString < $1.id.uuidString }
    d.foodEntries.sort { $0.id.uuidString < $1.id.uuidString }
    d.waterLogs.sort { $0.id.uuidString < $1.id.uuidString }
    d.foods.sort { $0.id.uuidString < $1.id.uuidString }
    d.coachConversations?.sort { $0.id.uuidString < $1.id.uuidString }
    d.media.sort { $0.fileName < $1.fileName }
    let encoder = BackupV1.makeEncoder(timeZone: TimeZone(identifier: "UTC")!)
    return String(decoding: try encoder.encode(d), as: UTF8.self)
}

private func contract(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "contracts").appending(path: name)
    return try String(contentsOf: url, encoding: .utf8)
}

/// Schema com `additionalProperties: false` em todo objeto com `properties` — pega campo exportado
/// que o contrato não documenta.
private func strictSchema() throws -> JSONSchemaValidator {
    func strict(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(var object):
            for (key, child) in object { object[key] = strict(child) }
            if object["properties"] != nil, object["additionalProperties"] == nil {
                object["additionalProperties"] = .bool(false)
            }
            return .object(object)
        case .array(let array):
            return .array(array.map(strict))
        default:
            return value
        }
    }
    return JSONSchemaValidator(schema: strict(try JSONValue.parse(BackupSchema.exportV1)))
}

// MARK: - Contrato

@Suite("Backup · Contrato fitjourney-export-v1")
@MainActor
struct BackupContractTests {
    @Test("schema embutido == arquivo em contracts/")
    func embeddedSchemaMatchesFile() throws {
        let file = try JSONValue.parse(try contract("fitjourney-export-v1.schema.json"))
        #expect(file == (try JSONValue.parse(BackupSchema.exportV1)))
    }

    @Test("enums do schema == allCases do app (rawValues estáveis)")
    func enumsMatchApp() throws {
        let schema = try JSONValue.parse(BackupSchema.exportV1)
        func values(_ name: String) -> [String] {
            schema["$defs"]?[name]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        let expected: [String: [String]] = [
            "muscleGroup": MuscleGroup.allCases.map(\.rawValue), "equipment": Equipment.allCases.map(\.rawValue),
            "laterality": Laterality.allCases.map(\.rawValue), "measurementKind": MeasurementKind.allCases.map(\.rawValue),
            "programGoal": ProgramGoal.allCases.map(\.rawValue), "scheduleMode": ScheduleMode.allCases.map(\.rawValue),
            "programOrigin": ProgramOrigin.allCases.map(\.rawValue), "weekday": Weekday.allCases.map(\.rawValue),
            "setKind": SetKind.allCases.map(\.rawValue), "sessionStatus": SessionStatus.allCases.map(\.rawValue),
            "sessionExerciseStatus": SessionExerciseStatus.allCases.map(\.rawValue),
            "skipReason": SkipReason.allCases.map(\.rawValue), "weightUnit": WeightUnit.allCases.map(\.rawValue),
            "nutritionPlanAuthor": NutritionPlanAuthor.allCases.map(\.rawValue),
            "foodUnit": FoodUnit.allCases.map(\.rawValue), "estimationSource": EstimationSource.allCases.map(\.rawValue),
            "mealStatus": MealStatus.allCases.map(\.rawValue), "messageRole": ["system", "user", "assistant", "tool"],
            "messageState": ChatMessageState.allCases.map(\.rawValue), "aiProvider": AIProviderID.allCases.map(\.rawValue),
            "videoProvider": VideoProvider.allCases.map(\.rawValue), "coachSex": CoachProfile.Sex.allCases.map(\.rawValue),
            "coachLevel": CoachProfile.Level.allCases.map(\.rawValue),
        ]
        #expect(Set(expected.keys) == Set(BackupSchema.enumNames))
        for (name, cases) in expected { #expect(values(name) == cases, "\(name)") }
        #expect(LLMRole(rawValue: "tool") != nil && LLMRole(rawValue: "system") != nil)
    }

    @Test("chaves de preferências espelham as dos stores")
    func preferenceKeysMatchStores() {
        #expect(BackupPreferenceKeys.sessionTombstones == SessionTombstones.key)
        #expect(BackupPreferenceKeys.seededCatalogVersion == ExerciseCatalogSeeder.versionKey)
    }

    @Test("exemplo em contracts/ é válido (schema estrito) e importa")
    func exampleIsValidAndImports() async throws {
        let raw = try contract("fitjourney-export-v1.example.json")
        let issues = try strictSchema().validate(try JSONValue.parse(raw))
        #expect(issues.isEmpty, "\(issues)")
        let document = try BackupDocumentLoader.load(Data(raw.utf8))
        #expect(document.programs.first?.routines.first?.exercises.first?.sets.first?.currentLoad?.value == 62.5)

        let f = try BackupFixture(sample: false)
        let report = try await f.importer().apply(document)
        #expect(report.inserted[.programs] == 1)
        #expect(report.inserted[.sessions] == 1)
        #expect(report.inserted[.exercises] == 1) // o embutido casou com o supino local pelo catalogKey
        #expect(report.keptLocal[.exercises] == 1)
        let ctx = ModelContext(f.container)
        let routineExercise = try #require(try ctx.fetch(FetchDescriptor<RoutineExercise>()).first)
        #expect(routineExercise.exercise?.catalogKey == "bench-press")
        let session = try #require(try ctx.fetch(FetchDescriptor<WorkoutSession>()).first)
        #expect(session.routine?.name == "A — Empurrar")
        // O exerciseID da sessão foi reapontado para o ID local do supino embutido.
        #expect(session.sortedExercises.first?.exerciseID == routineExercise.exercise?.id)
        let entry = try #require(try ctx.fetch(FetchDescriptor<FoodEntry>()).first { $0.name == "Pão de queijo" })
        #expect(entry.kcal == nil) // ausente = não informado
        #expect(entry.isOffPlan)
        #expect(CoachProfileStore(defaults: f.defaults).load().age == 34)
        #expect(CoachProfileStore(defaults: f.defaults).load().sharing == .none) // nunca concedido por importação
    }

    @Test("exportação real passa no schema estrito (todo campo está no contrato)")
    func exportMatchesStrictSchema() async throws {
        let f = try BackupFixture()
        try f.addExtras()
        let exporter = f.exporter()
        let document = try await exporter.makeDocument(options: .init(includeCoachConversations: true))
        let json = try await exporter.encode(document)
        let issues = try strictSchema().validate(try JSONValue.parse(String(decoding: json, as: UTF8.self)))
        #expect(issues.isEmpty, "\(issues)")
        #expect(document.sessions.count == 1)
        #expect(document.coachConversations?.count == 1)
        #expect(document.preferences.weightUnit == "lb")
    }

    @Test("datas ISO-8601 com fuso e ida e volta estável")
    func dates() throws {
        let date = Date(timeIntervalSince1970: 1_762_864_200.123_456)
        let text = BackupV1.formatDate(date, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        #expect(text == "2025-11-11T09:30:00.123-03:00")
        let parsed = try #require(BackupV1.parseDate(text))
        #expect(BackupV1.formatDate(parsed, timeZone: TimeZone(identifier: "America/Sao_Paulo")!) == text)
        #expect(BackupV1.parseDate("2025-11-11T12:30:00Z") == Date(timeIntervalSince1970: 1_762_864_200))
        #expect(BackupV1.parseDate("2025-11-11T09:30:00-0300") == Date(timeIntervalSince1970: 1_762_864_200))
        #expect(BackupV1.parseDate("2025-11-11T12:30:00.5+00:00") == Date(timeIntervalSince1970: 1_762_864_200.5))
        #expect(BackupV1.parseDate("11/11/2025") == nil)
    }
}

// MARK: - Exportar / importar

@Suite("Backup · Exportar e importar")
@MainActor
struct BackupRoundTripTests {
    @Test("ida e volta: exportar pacote → apagar tudo → importar (mesclar) = mesmo conteúdo, mídia inclusa")
    func roundTripMerge() async throws {
        let f = try BackupFixture()
        try f.addExtras()
        let options = BackupExportOptions(format: .package, includeCoachConversations: true)
        let before = try await f.exporter().makeDocument(options: options)
        let result = try await f.exporter().export(options: options, to: f.workDir)
        #expect(result.fileURL.pathExtension == "fitjourney")
        #expect(result.mediaFilesIncluded == 1)
        #expect(ZipReader.looksLikeZip(result.fileURL))

        try await f.eraser().eraseAll(options: .init(keepBuiltInCatalog: false))
        #expect(try f.count(Exercise.self) == 0)
        #expect(try f.count(WorkoutSession.self) == 0)
        #expect(f.media.deleteAllFiles() == 0)
        #expect(CoachProfileStore(defaults: f.defaults).load().isEmpty)

        let report = try await f.importer().importBackup(from: result.fileURL)
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        #expect(report.mediaFilesCopied == 1)
        #expect(report.inserted.total == BackupCounts(before).total)

        let after = try await f.exporter().makeDocument(options: options)
        #expect(try normalized(after) == normalized(before))
        let imageName = try #require(before.media.first?.fileName)
        #expect(f.media.fileExists(named: imageName))
    }

    @Test("ida e volta: apagar (catálogo re-semeado) → importar substituindo = mesmo conteúdo")
    func roundTripReplace() async throws {
        let f = try BackupFixture()
        try f.addExtras()
        let options = BackupExportOptions(format: .package, includeCoachConversations: true)
        let before = try await f.exporter().makeDocument(options: options)
        let result = try await f.exporter().export(options: options, to: f.workDir)
        let erased = try await f.eraser().eraseAll()
        #expect(erased.builtInExercisesSeeded == ExerciseCatalog.all.count)

        let report = try await f.importer().importBackup(from: result.fileURL, options: .init(mode: .replace))
        #expect(report.mode == .replace)
        let after = try await f.exporter().makeDocument(options: options)
        #expect(try normalized(after) == normalized(before))
        #expect(try f.count(Exercise.self) == before.exercises.count)
    }

    @Test("só data.json: sem mídia; importar em outro aparelho remove referências a arquivos ausentes")
    func jsonOnly() async throws {
        let source = try BackupFixture()
        try source.addExtras()
        let result = try await source.exporter().export(options: .init(format: .json), to: source.workDir)
        #expect(result.fileURL.pathExtension == "json")
        #expect(!ZipReader.looksLikeZip(result.fileURL))
        let document = try BackupDocumentLoader.load(try Data(contentsOf: result.fileURL))
        #expect(document.options.includesMedia == false)
        #expect(document.media.allSatisfy { !$0.included })
        #expect(document.coachConversations == nil)

        let target = try BackupFixture(sample: false)
        let report = try await target.importer().importBackup(from: result.fileURL)
        #expect(report.warnings.contains(.missingMediaFiles(count: 1)))
        let ctx = ModelContext(target.container)
        let rowing = try #require(try ctx.fetch(FetchDescriptor<Exercise>()).first { $0.name == "Remada unilateral no banco" })
        #expect(rowing.media.count == 1) // o link externo fica
        if case .externalVideo = rowing.media.first {} else { Issue.record("esperado link externo") }
    }

    @Test("nenhuma chave de API no export")
    func noSecretsInExport() async throws {
        let f = try BackupFixture()
        try f.addExtras()
        let secret = "sk-test-SECRET-1234567890"
        try f.secrets.set(secret, for: .apiKey(.openAI))
        try KeychainSecretStore(service: "fj-backup-tests").set(secret, for: .apiKey(.custom))
        defer { try? KeychainSecretStore(service: "fj-backup-tests").set(nil, for: .apiKey(.custom)) }
        let result = try await f.exporter().export(options: .init(format: .json, includeCoachConversations: true),
                                                   to: f.workDir)
        let text = try String(contentsOf: result.fileURL, encoding: .utf8)
        #expect(!text.contains(secret))
        #expect(!text.lowercased().contains("apikey"))
        #expect(text.contains("\"customBaseURL\" : \"http://192.168.0.10:11434/v1\""))
    }

    @Test("URL com credenciais nunca é exportada")
    func urlWithCredentialsIsDropped() {
        #expect(BackupPreferences.sanitized(URL(string: "https://user:pass@example.com/v1")) == nil)
        #expect(BackupPreferences.sanitized(URL(string: "https://example.com/v1")) != nil)
    }

    @Test("mesclar com conflitos: mais recente vence, novos entram, um só programa ativo")
    func mergeConflicts() async throws {
        let f = try BackupFixture()
        var document = try await f.exporter().makeDocument()
        let ctx = f.context

        // Local mais novo que o backup: o programa local fica.
        let program = try #require(try ctx.fetch(FetchDescriptor<TrainingProgram>()).first)
        program.name = "Renomeado no aparelho"
        program.updatedAt = .now.addingTimeInterval(3_600)
        // Backup mais novo que o local: o registro de água do backup vence.
        let waterIndex = try #require(document.waterLogs.indices.first)
        document.waterLogs[waterIndex].milliliters = 999
        document.waterLogs[waterIndex].updatedAt = .now.addingTimeInterval(7_200)
        // Programa novo e ativo no backup, mais recente que o local → o local deixa de ser ativo.
        var other = try #require(document.programs.first)
        other.id = UUID()
        other.name = "Programa do backup"
        other.isActive = true
        other.updatedAt = .now.addingTimeInterval(10_000)
        other.routines = other.routines.map { routine in
            var r = routine
            r.id = UUID()
            r.exercises = r.exercises.map { e in
                var e = e
                e.id = UUID()
                e.sets = e.sets.map { s in var s = s; s.id = UUID(); return s }
                return e
            }
            return r
        }
        document.programs.append(other)
        // Plano alimentar do backup com o mesmo id e conteúdo mais antigo → fica o local.
        try ctx.save()

        let report = try await f.importer().apply(document)
        #expect(report.keptLocal[.programs] == 1)
        #expect(report.inserted[.programs] == 1)
        #expect(report.updated[.waterLogs] == 1)
        #expect(report.keptLocal[.nutritionPlans] == 1)
        #expect(report.warnings.contains(.extraActiveProgramsDeactivated(count: 1)))

        let fresh = ModelContext(f.container)
        let programs = try fresh.fetch(FetchDescriptor<TrainingProgram>())
        #expect(programs.count == 2)
        #expect(programs.filter(\.isActive).map(\.name) == ["Programa do backup"])
        #expect(programs.contains { $0.name == "Renomeado no aparelho" })
        #expect(try fresh.fetch(FetchDescriptor<WaterLog>()).contains { $0.milliliters == 999 })
        // Nada duplicado: exercícios casados por id/catalogKey.
        #expect(try f.count(Exercise.self) == document.exercises.count)
        #expect(try f.count(WorkoutSession.self) == 1)
    }

    @Test("sessões em andamento no backup: com série feita → concluída; sem série → descartada")
    func inProgressSessionsAreResolved() async throws {
        let f = try BackupFixture()
        var document = try await f.exporter().makeDocument()
        let base = try #require(document.sessions.first)
        func copy(_ session: BackupV1.Session, completed: Bool) -> BackupV1.Session {
            var s = session
            s.id = UUID()
            s.status = "inProgress"
            s.endedAt = nil
            s.pausedAt = s.startedAt.addingTimeInterval(60)
            s.routineName = completed ? "Com séries" : "Sem séries"
            s.exercises = s.exercises.map { e in
                var e = e
                e.id = UUID()
                e.status = "inProgress"
                e.sets = e.sets.map { set in
                    var set = set
                    set.id = UUID()
                    set.isCompleted = completed
                    if !completed { set.completedAt = nil }
                    return set
                }
                return e
            }
            return s
        }
        document.sessions.append(copy(base, completed: true))
        document.sessions.append(copy(base, completed: false))

        let report = try await f.importer().apply(document)
        #expect(report.warnings.contains(.inProgressSessionFinalized(routineName: "Com séries")))
        #expect(report.warnings.contains(.inProgressSessionDiscarded(routineName: "Sem séries")))
        let sessions = try ModelContext(f.container).fetch(FetchDescriptor<WorkoutSession>())
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.status == .completed && $0.endedAt != nil && $0.pausedAt == nil })
        let finalized = try #require(sessions.first { $0.routineName == "Com séries" })
        let lastSet = finalized.sortedExercises.flatMap(\.sortedSets).compactMap(\.completedAt).max()
        #expect(BackupV1.formatDate(finalized.endedAt!) == BackupV1.formatDate(lastSet!))
        #expect(finalized.sortedExercises.allSatisfy { $0.status == .partial })
        #expect(finalized.routine != nil)
    }

    @Test("substituir com treino em andamento é recusado")
    func replaceRefusesActiveSession() async throws {
        let f = try BackupFixture()
        let document = try await f.exporter().makeDocument()
        let routine = try #require(try f.context.fetch(FetchDescriptor<Routine>()).first)
        _ = try SessionStore(context: f.context).start(routine: routine)
        await #expect(throws: BackupError.activeSessionInProgress) {
            try await f.importer().apply(document, options: .init(mode: .replace))
        }
        #expect(try f.count(WorkoutSession.self) == 2)
    }
}

// MARK: - Erros e transação

@Suite("Backup · Erros e transação")
@MainActor
struct BackupFailureTests {
    @Test("versão mais nova → erro 'atualize o app'")
    func newerVersion() async throws {
        let f = try BackupFixture(sample: false)
        var raw = try contract("fitjourney-export-v1.example.json")
        raw = raw.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        let url = f.workDir.appending(path: "future.json")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: BackupError.newerVersion(found: 2, supported: 1)) {
            try await f.importer().importBackup(from: url)
        }
        #expect(BackupError.newerVersion(found: 2, supported: 1).errorDescription?.contains("Atualize o app") == true)
        #expect(try f.count(TrainingProgram.self) == 0)
    }

    @Test("arquivos corrompidos ou que não são backup")
    func corruptedFiles() async throws {
        let f = try BackupFixture()
        let importer = f.importer()

        let garbage = f.workDir.appending(path: "garbage.fitjourney")
        try Data((0 ..< 512).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        await #expect(throws: BackupError.corruptedFile) { try await importer.importBackup(from: garbage) }

        let notBackup = f.workDir.appending(path: "other.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: notBackup)
        await #expect(throws: BackupError.notABackup) { try await importer.importBackup(from: notBackup) }

        let invalid = f.workDir.appending(path: "invalid.json")
        let example = try contract("fitjourney-export-v1.example.json")
        try example.replacingOccurrences(of: "\"goal\": \"strength\"", with: "\"goal\": \"flying\"")
            .write(to: invalid, atomically: true, encoding: .utf8)
        await #expect { try await importer.importBackup(from: invalid) } throws: { error in
            guard case .invalidContent(let issues)? = error as? BackupError else { return false }
            return issues.contains { $0.contains("goal") }
        }

        // Pacote truncado (zip sem diretório central).
        let full = try await f.exporter().export(to: f.workDir)
        let data = try Data(contentsOf: full.fileURL)
        let truncated = f.workDir.appending(path: "truncated.fitjourney")
        try data.prefix(data.count / 2).write(to: truncated)
        await #expect(throws: BackupError.corruptedFile) { try await importer.importBackup(from: truncated) }

        // Zip sem data.json.
        let empty = f.workDir.appending(path: "empty.fitjourney")
        let writer = try ZipWriter(url: empty)
        try writer.add(name: "readme.txt", data: Data("oi".utf8), compress: false)
        try writer.finish()
        await #expect(throws: BackupError.notABackup) { try await importer.importBackup(from: empty) }

        // Byte trocado no meio do data.json comprimido → CRC/inflate falha.
        var flipped = data
        flipped[60] ^= 0xFF
        let flippedURL = f.workDir.appending(path: "flipped.fitjourney")
        try flipped.write(to: flippedURL)
        await #expect(throws: BackupError.corruptedFile) { try await importer.importBackup(from: flippedURL) }
    }

    @Test("falha no meio da importação não deixa estado parcial")
    func failureIsTransactional() async throws {
        let source = try BackupFixture()
        try source.addExtras()
        let package = try await source.exporter().export(to: source.workDir)

        let target = try BackupFixture(sample: false)
        let before = try target.count(Exercise.self)
        // A pasta de mídia é um arquivo: copiar a imagem falha depois de vários registros já aplicados.
        let blocked = target.workDir.appending(path: "blocked")
        try Data("x".utf8).write(to: blocked)
        let brokenMedia = MediaStore(root: blocked)
        await #expect(throws: (any Error).self) {
            try await target.importer(media: brokenMedia).importBackup(from: package.fileURL)
        }
        #expect(try target.count(Exercise.self) == before)
        #expect(try target.count(TrainingProgram.self) == 0)
        #expect(try target.count(WorkoutSession.self) == 0)
        #expect(try target.count(FoodEntry.self) == 0)
        #expect(UserDefaults(suiteName: target.suite)?.string(forKey: WeightUnitPreference.key) == nil)

        // O mesmo importador funciona depois (contexto desfeito, sem lixo pendente).
        let report = try await target.importer().importBackup(from: package.fileURL)
        #expect(report.inserted[.programs] == 1)
    }
}

// MARK: - Apagar tudo

@Suite("Backup · Apagar tudo")
@MainActor
struct DataEraserTests {
    @Test("apaga modelos, mídia, preferências e tombstones; chaves só se pedido")
    func eraseAll() async throws {
        let f = try BackupFixture()
        try f.addExtras()
        f.defaults.set(Data("[]".utf8), forKey: BackupPreferenceKeys.sessionTombstones)
        f.defaults.set(true, forKey: "fj.someFuturePreference")
        try f.secrets.set("sk-1", for: .apiKey(.openAI))

        let result = try await f.eraser().eraseAll()
        #expect(result.mediaFilesDeleted == 1)
        #expect(!result.secretsDeleted)
        for count in [try f.count(TrainingProgram.self), try f.count(Routine.self), try f.count(RoutineExercise.self),
                      try f.count(SetPrescription.self), try f.count(WorkoutSession.self), try f.count(SessionExercise.self),
                      try f.count(SetLog.self), try f.count(NutritionPlan.self), try f.count(NutritionDay.self),
                      try f.count(Meal.self), try f.count(MealItem.self), try f.count(FoodItem.self),
                      try f.count(FoodEntry.self), try f.count(WaterLog.self), try f.count(ChatConversation.self),
                      try f.count(ChatMessage.self)] {
            #expect(count == 0)
        }
        #expect(try f.count(Exercise.self) == ExerciseCatalog.all.count) // catálogo re-semeado
        #expect(f.defaults.object(forKey: BackupPreferenceKeys.sessionTombstones) == nil)
        #expect(f.defaults.object(forKey: "fj.someFuturePreference") == nil)
        #expect(f.defaults.object(forKey: WeightUnitPreference.key) == nil)
        #expect(f.defaults.object(forKey: CoachProfileStore.key) == nil)
        #expect(f.defaults.object(forKey: CoachProfileStore.consentKey) == nil)
        #expect(f.defaults.object(forKey: ProviderSettingsStore.key) == nil)
        #expect(f.defaults.integer(forKey: ExerciseCatalogSeeder.versionKey) == ExerciseCatalog.version)
        #expect(f.secrets.contains(.apiKey(.openAI)))

        let again = try await f.eraser().eraseAll(options: .init(keepBuiltInCatalog: false, includingSecrets: true))
        #expect(again.secretsDeleted)
        #expect(!f.secrets.contains(.apiKey(.openAI)))
        #expect(try f.count(Exercise.self) == 0)
        // O seed do lançamento não traz o catálogo de volta.
        #expect(try ExerciseCatalogSeeder.seedIfNeeded(in: ModelContext(f.container), defaults: f.defaults) == 0)
    }
}

// MARK: - Zip

@Suite("Backup · Zip")
struct ZipArchiveTests {
    @Test("escreve e lê entradas deflate e stored, com CRC conferido")
    func roundTrip() throws {
        let dir = URL.temporaryDirectory.appending(path: "FJZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = Data(String(repeating: "FitJourney ação ", count: 2_000).utf8)
        let binary = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 3) })
        let source = dir.appending(path: "video.mov")
        try binary.write(to: source)

        let zip = dir.appending(path: "a.fitjourney")
        let writer = try ZipWriter(url: zip)
        try writer.add(name: "data.json", data: text, compress: true)
        try writer.add(name: "media/video.mov", contentsOf: source)
        try writer.finish()

        let reader = try ZipReader(url: zip)
        #expect(reader.entries.map(\.name) == ["data.json", "media/video.mov"])
        let json = try #require(reader.entry(named: "data.json"))
        #expect(json.method == 8)
        #expect(json.compressedSize < json.size)
        #expect(try reader.data(for: json) == text)
        let out = dir.appending(path: "out.mov")
        try reader.extract(try #require(reader.entry(named: "media/video.mov")), to: out)
        #expect(try Data(contentsOf: out) == binary)
    }

    @Test("CRC-32 de referência")
    func crc() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }
}
