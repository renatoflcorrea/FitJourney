import Foundation
import SwiftData
import Testing
@testable import FitJourney

@Suite("Idioma do app e nomes harmonizados")
struct AppLanguageTests {
    @Test func preferenciaGravaAppleLanguages() {
        let suite = "lang-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        // `object(forKey:)` cai no domínio global (AppleLanguages do simulador): olhe só o domínio da suíte.
        func stored(_ key: String) -> Any? { d.persistentDomain(forName: suite)?[key] }
        #expect(AppLanguagePreference.current(d) == .system)

        AppLanguagePreference.portuguese.apply(to: d)
        #expect(stored("AppleLanguages") as? [String] == ["pt-BR"])
        #expect(d.string(forKey: "fj.appLanguage") == "pt-BR")
        #expect(AppLanguagePreference.current(d) == .portuguese)

        AppLanguagePreference.english.apply(to: d)
        #expect(stored("AppleLanguages") as? [String] == ["en"])
        #expect(d.string(forKey: "fj.appLanguage") == "en")
        #expect(AppLanguagePreference.current(d) == .english)

        AppLanguagePreference.system.apply(to: d)
        #expect(stored("AppleLanguages") == nil)
        #expect(stored("fj.appLanguage") == nil)
        #expect(AppLanguagePreference.current(d) == .system)
    }

    @Test func codigosNormalizadosEEfetivos() {
        #expect(AppLanguageCode.normalized("pt") == "pt-BR")
        #expect(AppLanguageCode.normalized("pt_BR") == "pt-BR")
        #expect(AppLanguageCode.normalized("en-US") == "en")
        #expect(AppLanguageCode.normalized("fr") == nil)
        #expect(AppLanguageCode.normalized(nil) == nil)
        #expect(AppLanguageCode.effective(from: ["en"]) == "en")
        #expect(AppLanguageCode.effective(from: ["pt-BR", "en"]) == "pt-BR")
        #expect(AppLanguageCode.effective(from: ["de"]) == "en")
    }

    @MainActor @Test func digestEmInglesTrazNomesDoCatalogoLocalizados() throws {
        let f = try EngineFixture()
        _ = try f.makeRoutine()
        let pt = try #require(try ProgramDigestBuilder.make(context: f.context, now: f.t0, language: "pt-BR"))
        let en = try #require(try ProgramDigestBuilder.make(context: f.context, now: f.t0, language: "en"))
        #expect(pt.language == "pt-BR")
        #expect(en.language == "en")
        let ptNames = pt.routines.flatMap(\.exercises).map(\.name)
        let enNames = en.routines.flatMap(\.exercises).map(\.name)
        #expect(ptNames.contains("Supino reto com barra"))
        #expect(enNames.contains("Barbell Bench Press"))
        #expect(!enNames.contains("Supino reto com barra"))
        #expect(ptNames.count == enNames.count)
    }

    @MainActor @Test func exercicioDoUsuarioMantemOProprioNome() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let custom = Exercise(name: "Meu exercício maluco")
        f.context.insert(custom)
        try f.base.programs.addExercise(custom, to: routine, setCount: 1, repTarget: .fixed(reps: 5), restSeconds: 30)
        try f.context.save()
        let en = try #require(try ProgramDigestBuilder.make(context: f.context, now: f.t0, language: "en"))
        #expect(en.routines.flatMap(\.exercises).map(\.name).contains("Meu exercício maluco"))
    }

    @MainActor @Test func snapshotEmIngles() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let sessionID = try f.start(routine)
        let session = try #require(try f.context.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == sessionID })
        let store = SessionStore(context: f.context)
        let en = SessionSnapshotBuilder.make(session: session, store: store, language: "en")
        let pt = SessionSnapshotBuilder.make(session: session, store: store, language: "pt-BR")
        #expect(en.language == "en")
        #expect(pt.language == "pt-BR")
        #expect(en.exercises.first?.name == "Barbell Bench Press")
        #expect(pt.exercises.first?.name == "Supino reto com barra")
    }

    @Test func campoDeIdiomaAusenteDecodifica() throws {
        let digest = ProgramDigest(generatedAt: Date(timeIntervalSinceReferenceDate: 1), programID: UUID(), name: "P",
                                   scheduleMode: "free", suggestedRoutineIDs: [], routines: [], language: "en")
        let data = try JSONEncoder().encode(digest)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["language"] as? String == "en")
        json.removeValue(forKey: "language")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ProgramDigest.self, from: legacy)
        #expect(decoded.language == nil)
    }

    @MainActor @Test func toolboxUsaNomeLocalizado() {
        // O filtro aceita o nome gravado ou o localizado; a função é a mesma da UI.
        #expect(FitnessToolbox.nameMatches("Supino reto com barra", ExerciseMatcher.normalize("supino")))
        #expect("Supino reto com barra".exerciseDisplayName == ExerciseCatalogIndex.displayName("Supino reto com barra"))
        #expect(ExerciseCatalogIndex.displayName("Supino reto com barra", english: true) == "Barbell Bench Press")
    }
}
