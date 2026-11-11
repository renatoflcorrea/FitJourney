import Foundation
import SwiftData
import Testing
@testable import FitJourney

@Suite("Ajustes — apresentação")
struct SettingsPresentationTests {
    // MARK: kg ↔ lb só na exibição

    @Test func conversaoKgParaLbArredondaAoPasso() {
        // 100 kg = 220,46 lb → passo 1 lb = 220
        #expect(LoadDisplay.value(100, from: .kg, to: .lb, step: 1) == 220)
        // 32,5 kg = 71,65 lb → 72
        #expect(LoadDisplay.value(32.5, from: .kg, to: .lb, step: 1) == 72)
        // passo 5 lb: 71,65 → 70
        #expect(LoadDisplay.value(32.5, from: .kg, to: .lb, step: 5) == 70)
    }

    @Test func conversaoLbParaKgEMesmaUnidadeNaoMuda() {
        #expect(LoadDisplay.value(45, from: .lb, to: .kg, step: 0.5) == 20.5) // 20,41 kg → 20,5
        #expect(LoadDisplay.value(32.25, from: .kg, to: .kg, step: 0.5) == 32.25)
    }

    @Test func textoDaCargaUsaUnidadeDeExibicao() {
        let load = Load.weight(value: 100, unit: .kg)
        #expect(PrescriptionFormat.loadText(load, displayUnit: .kg) == "100 kg")
        #expect(PrescriptionFormat.loadText(load, displayUnit: .lb) == "220 lb")
        #expect(PrescriptionFormat.loadText(.bodyweight(delta: 0, unit: .kg), displayUnit: .lb) == "PC")
        #expect(PrescriptionFormat.loadText(.bodyweight(delta: 10, unit: .kg), displayUnit: .lb).hasPrefix("PC +22"))
    }

    @Test func passoPadraoPorUnidade() {
        #expect(LoadDisplay.step(for: .kg, stored: 0) == 0.5)
        #expect(LoadDisplay.step(for: .lb, stored: 0) == 1)
        #expect(LoadDisplay.step(for: .kg, stored: 2.5) == 2.5)
        #expect(LoadDisplay.step(for: .kg, stored: 3) == 0.5) // inválido = padrão
    }

    // MARK: Estados das integrações

    @Test func estadoDasNotificacoes() {
        #expect(SettingsPresentation.NotificationState(.authorized) == .allowed)
        #expect(SettingsPresentation.NotificationState(.denied) == .denied)
        #expect(SettingsPresentation.NotificationState(.notDetermined) == .notRequested)
        #expect(SettingsPresentation.NotificationState(nil) == .notRequested)
        #expect(!SettingsPresentation.NotificationState.denied.togglesEnabled)
        #expect(SettingsPresentation.NotificationState.allowed.togglesEnabled)
    }

    @Test func estadoDoSaudeEDaIA() {
        #expect(SettingsPresentation.healthTitle(.connected(canWrite: true)) == "Conectado")
        #expect(SettingsPresentation.healthTitle(.notConnected) == "Não conectado")
        var settings = ProviderSettings.default
        #expect(SettingsPresentation.aiTitle(settings: settings, hasAPIKey: false) == "Não configurado")
        settings.models[.openAI] = "gpt-test"
        #expect(SettingsPresentation.aiTitle(settings: settings, hasAPIKey: true) == "OpenAI · gpt-test")
    }

    @Test func resumoDoPerfilEFCMaxima() {
        #expect(SettingsPresentation.profileSummary(CoachProfile()) == nil)
        var profile = CoachProfile()
        profile.age = 34
        profile.weightKg = 78
        profile.level = .intermediate
        #expect(SettingsPresentation.profileSummary(profile) == "34 anos · 78 kg · intermediário")
        #expect(SettingsPresentation.maxHeartRateSummary(stored: 0, age: 34) == "Pela idade (186 bpm)")
        #expect(SettingsPresentation.maxHeartRateSummary(stored: 190, age: 34) == "Manual (190 bpm)")
        #expect(SettingsPresentation.maxHeartRateSummary(stored: 0, age: nil).hasPrefix("Informe"))
    }

    @Test func contagensEResumoDeImportacao() {
        let counts = BackupCounts([.programs: 3, .sessions: 142, .foodEntries: 1204])
        let lines = SettingsPresentation.countsLines(counts)
        #expect(lines.count == 3)
        #expect(lines.contains { $0.contains("142") })
        var report = BackupImportReport(mode: .merge, exportedAt: .now)
        #expect(SettingsPresentation.importSummary(report).hasPrefix("Nada novo"))
        report.inserted = BackupCounts([.sessions: 140, .programs: 3])
        report.updated = BackupCounts([.sessions: 2])
        #expect(SettingsPresentation.importSummary(report).contains("142"))
    }

    @Test func descansoEmTexto() {
        #expect(SettingsPresentation.restText(45) == "45 s")
        #expect(SettingsPresentation.restText(90) == "1 min 30 s")
        #expect(SettingsPresentation.restText(120) == "2 min")
    }

    @Test func tamanhoDaMidia() throws {
        let dir = URL.temporaryDirectory.appending(path: "FJMediaSize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 1500).write(to: dir.appending(path: "a.bin"))
        try Data(count: 500).write(to: dir.appending(path: "b.bin"))
        #expect(SettingsPresentation.mediaByteCount(in: dir) == 2000)
        #expect(SettingsPresentation.mediaByteCount(in: dir.appending(path: "nao-existe")) == 0)
    }

    @Test func coresDeFichaDoRelogioEspelhamOTemaEscuro() {
        // Os 8 nomes existem e `WatchRoutineColor` usa os mesmos valores `dark` (conferido por hex no relógio).
        #expect(FJRoutineColor.allCases.count == 8)
        #expect(FJRoutineColor.teal.dark.fill == 0x5AD1D6)
        #expect(FJRoutineColor(name: "").rawValue == "orange")
    }
}

@Suite("Ajustes — fluxo de importação", .serialized)
@MainActor
struct DataTransferFlowTests {
    private func waitIdle(_ model: DataTransferModel) async {
        for _ in 0..<400 where model.activity.isBusy { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func inspecionaEImportaMesclando() async throws {
        let fixture = try BackupFixture()
        let result = try await fixture.exporter().export(options: .init(format: .json), to: fixture.workDir)
        let model = DataTransferModel(container: fixture.container)

        model.inspect(.success(result.fileURL))
        await waitIdle(model)
        let pending = try #require(model.pendingImport)
        #expect(pending.counts[.programs] > 0)
        #expect(pending.schemaVersion == BackupV1.schemaVersion)

        model.performImport(pending, includeCoachConversations: false)
        await waitIdle(model)
        let report = try #require(model.report)
        #expect(report.mode == .merge)
        #expect(model.errorMessage == nil)
        #expect(SettingsPresentation.importSummary(report).isEmpty == false)
    }

    @Test func arquivoInvalidoMostraErroENaoAltera() async throws {
        let fixture = try BackupFixture(sample: false)
        let url = fixture.workDir.appending(path: "lixo.json")
        try Data("{\"nao\":\"backup\"}".utf8).write(to: url)
        let model = DataTransferModel(container: fixture.container)
        model.inspect(.success(url))
        await waitIdle(model)
        #expect(model.pendingImport == nil)
        #expect(model.errorMessage?.contains("backup") == true)
    }
}
