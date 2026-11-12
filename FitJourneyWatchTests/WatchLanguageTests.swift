import Foundation
import Testing
@testable import FitJourneyWatch

/// O relógio segue o idioma do iPhone (campo opcional do digest/snapshot).
@MainActor
struct WatchLanguageTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func model(defaults: UserDefaults, running: String) -> WatchSessionModel {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest, snapshot: nil)
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { self.t0 })
        model.languageDefaults = defaults
        model.runningLanguage = running
        return model
    }

    @Test func aplicaIdiomaRecebidoEAvisaQuandoMuda() throws {
        let defaults = try #require(UserDefaults(suiteName: "watch-lang-\(UUID().uuidString)"))
        let model = model(defaults: defaults, running: "pt-BR")
        var digest = WatchFixtures.digest(now: t0)
        digest.language = "en"
        model.receive(digest: digest)
        #expect(defaults.string(forKey: "fj.appLanguage") == "en")
        #expect(defaults.string(forKey: "fj.appLanguage") == "en")
        #expect(model.notice != nil)
    }

    @Test func mesmoIdiomaNaoAvisaDeNovo() throws {
        let defaults = try #require(UserDefaults(suiteName: "watch-lang-\(UUID().uuidString)"))
        let model = model(defaults: defaults, running: "en")
        var digest = WatchFixtures.digest(now: t0)
        digest.language = "en"
        model.receive(digest: digest)
        #expect(defaults.string(forKey: "fj.appLanguage") == nil) // já em uso: nada é gravado
        #expect(model.notice == nil)
        model.receive(digest: digest)
        #expect(model.notice == nil)
    }

    @Test func ausenteMantemComportamentoAtual() throws {
        let defaults = try #require(UserDefaults(suiteName: "watch-lang-\(UUID().uuidString)"))
        let model = model(defaults: defaults, running: "pt-BR")
        model.receive(digest: WatchFixtures.digest(now: t0))
        #expect(defaults.string(forKey: "fj.appLanguage") == nil)
        #expect(model.notice == nil)
    }

    @Test func snapshotTambemCarregaIdioma() throws {
        let defaults = try #require(UserDefaults(suiteName: "watch-lang-\(UUID().uuidString)"))
        let model = model(defaults: defaults, running: "pt-BR")
        var snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 60, revision: 1)
        snapshot.language = "en"
        model.receive(snapshot: snapshot)
        #expect(defaults.string(forKey: "fj.appLanguage") == "en")
    }
}
