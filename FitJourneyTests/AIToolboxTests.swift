import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct ToolboxFixture {
    let persistence: PersistenceFixture
    let calendar: Calendar
    let today: Date
    var profile = CoachProfile()

    var context: ModelContext { persistence.context }

    init(seed: Bool = true) throws {
        persistence = try PersistenceFixture(seed: seed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        self.calendar = calendar
        today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        profile.sharing = CoachProfile.Sharing(profile: true, workouts: true, nutrition: true, health: false)
    }

    func toolbox() -> FitnessToolbox {
        let profile = profile
        let today = today
        return FitnessToolbox(context: context, profile: { profile }, now: { today }, calendar: calendar)
    }

    func day(_ offset: Int, hour: Int = 18) -> Date {
        let base = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today))!
        return calendar.date(byAdding: .hour, value: hour, to: base)!
    }

    /// Sessão concluída com um exercício de 3 séries feitas.
    @discardableResult
    func addSession(daysAgo: Int, exercise: String = "Supino reto com barra", load: Double = 40, reps: Int? = 10) throws -> WorkoutSession {
        let start = day(-daysAgo)
        let session = WorkoutSession(routineName: "A", startedAt: start)
        session.status = .completed
        session.endedAt = start.addingTimeInterval(3600)
        session.sessionRPE = 7
        context.insert(session)
        let item = SessionExercise(name: exercise)
        item.status = .completed
        context.insert(item)
        item.session = session
        for index in 0 ..< 3 {
            let log = SetLog(sortIndex: index, kind: .working, repTarget: .range(min: 8, max: 12), plannedLoad: .kg(load))
            log.reps = reps
            log.load = .kg(load)
            log.isCompleted = true
            log.completedAt = start.addingTimeInterval(Double(index) * 120)
            context.insert(log)
            log.sessionExercise = item
        }
        try context.save()
        return session
    }

    func run(_ box: FitnessToolbox, _ name: String, _ args: String = "{}") throws -> (JSONValue, ToolOutcome) {
        let outcome = box.execute(ToolCall(id: "call_\(name)", name: name, argumentsJSON: args))
        return (try JSONValue.parse(outcome.content), outcome)
    }
}

@Suite("AI · FitnessToolbox")
@MainActor
struct AIToolboxTests {
    @Test("specs: nomes, schemas estritos e filtro pelo que o usuário compartilha")
    func specsRespectSharing() throws {
        var fixture = try ToolboxFixture(seed: false)
        let all = Set(fixture.toolbox().specs.map(\.name))
        #expect(all.contains("get_workout_history"))
        #expect(!all.contains("get_health_summary")) // saúde desligada por padrão
        for spec in fixture.toolbox().specs {
            let schema = try JSONValue.parse(spec.parametersSchema)
            #expect(schema["type"] == .string("object"), "\(spec.name)")
            #expect(schema["additionalProperties"] == .bool(false), "\(spec.name)")
        }
        fixture.profile.sharing.workouts = false
        fixture.profile.sharing.nutrition = false
        fixture.profile.sharing.health = true
        let names = Set(fixture.toolbox().specs.map(\.name))
        for hidden in ["get_workout_history", "get_exercise_progress", "list_programs", "get_program",
                       "list_nutrition_plans", "get_nutrition_log"] {
            #expect(!names.contains(hidden), "\(hidden)")
        }
        #expect(names.contains("get_health_summary"))
        #expect(names.isSuperset(of: ["list_exercises", "propose_program", "propose_nutrition_plan"]))
        #expect(try fixture.run(fixture.toolbox(), "list_programs", #"{"include_archived":false}"#).0["error"] == .string("not_shared"))
        #expect(try fixture.run(fixture.toolbox(), "list_nutrition_plans").0["error"] == .string("not_shared"))

        // Padrão sem consentimento: nada pessoal é oferecido.
        fixture.profile.sharing = .none
        #expect(Set(fixture.toolbox().specs.map(\.name)) == ["list_exercises", "propose_program", "propose_nutrition_plan"])
        let (json, outcome) = try fixture.run(fixture.toolbox(), "get_workout_history", #"{"from":"2026-11-01","to":"2026-11-10","exercise":null}"#)
        #expect(outcome.isError)
        #expect(json["error"] == .string("not_shared"))
    }

    @Test("get_profile: vazio diz available=false e traz a data de hoje")
    func profile() throws {
        var fixture = try ToolboxFixture(seed: false)
        var (json, _) = try fixture.run(fixture.toolbox(), "get_profile")
        #expect(json["available"] == .bool(false))
        #expect(json["today"] == .string("2026-11-11"))
        fixture.profile.age = 34
        fixture.profile.restrictions = "Dor no ombro esquerdo"
        (json, _) = try fixture.run(fixture.toolbox(), "get_profile")
        #expect(json["available"] == .bool(true))
        #expect(json["age"] == .number(34))
        #expect(json["restrictions"] == .string("Dor no ombro esquerdo"))
        #expect(json["weightKg"] == .null)
    }

    @Test("get_workout_history: corta em 90 dias e 50 sessões, mais recentes primeiro")
    func historyLimits() throws {
        let fixture = try ToolboxFixture(seed: false)
        for daysAgo in 1 ... 60 { try fixture.addSession(daysAgo: daysAgo, load: Double(daysAgo)) }
        try fixture.addSession(daysAgo: 120) // fora dos 90 dias
        let (json, outcome) = try fixture.run(fixture.toolbox(), "get_workout_history",
                                              #"{"from":"2026-01-01","to":"2026-11-11","exercise":null}"#)
        #expect(!outcome.isError)
        #expect(json["clamped"] != nil)
        #expect(json["from"] == .string("2026-08-14"))
        let sessions = try #require(json["sessions"]?.arrayValue)
        #expect(sessions.count == FitnessToolbox.maxHistorySessions)
        #expect(json["totalInRange"] == .number(60))
        #expect(json["truncated"] != nil)
        #expect(sessions.first?["date"] == .string("2026-11-10"))
        let first = try #require(sessions.first?["exercises"]?.arrayValue?.first)
        #expect(first["sets"] == .string("10×1kg, 10×1kg, 10×1kg"))
        #expect(sessions.first?["durationMin"] == .number(60))
    }

    @Test("get_workout_history: filtro por exercício, reps ausentes = alvo, datas inválidas")
    func historyFilter() throws {
        let fixture = try ToolboxFixture(seed: false)
        try fixture.addSession(daysAgo: 2, exercise: "Agachamento livre", reps: nil)
        try fixture.addSession(daysAgo: 3, exercise: "Supino reto com barra")
        let box = fixture.toolbox()
        let (json, _) = try fixture.run(box, "get_workout_history", #"{"from":"2026-11-01","to":"2026-11-11","exercise":"agachamento"}"#)
        let sessions = try #require(json["sessions"]?.arrayValue)
        #expect(sessions.count == 1)
        #expect(sessions[0]["exercises"]?.arrayValue?.first?["sets"] == .string("alvo(8–12)×40kg, alvo(8–12)×40kg, alvo(8–12)×40kg"))
        let (bad, outcome) = try fixture.run(box, "get_workout_history", #"{"from":"2026-11-10","to":"2026-11-01","exercise":null}"#)
        #expect(outcome.isError)
        #expect(bad["error"] == .string("invalid_arguments"))
        #expect(try fixture.run(box, "get_workout_history", #"{"from":"2026-02-30","to":"2026-03-01","exercise":null}"#).1.isError)
    }

    @Test("get_exercise_progress: até 20 sessões e melhores marcas")
    func exerciseProgress() throws {
        let fixture = try ToolboxFixture()
        for daysAgo in 1 ... 25 { try fixture.addSession(daysAgo: daysAgo * 2, load: Double(100 - daysAgo)) }
        let (json, _) = try fixture.run(fixture.toolbox(), "get_exercise_progress", #"{"exercise":"supino reto com barra"}"#)
        #expect(json["sessions"]?.arrayValue?.count == FitnessToolbox.maxProgressSessions)
        #expect(json["totalSessions"] == .number(25))
        #expect(json["bests"]?["heaviestKg"] == .number(99))
        #expect(json["exercise"] == .string("Supino reto com barra"))
        let (none, _) = try fixture.run(fixture.toolbox(), "get_exercise_progress", #"{"exercise":"Remada"}"#)
        #expect(none["sessions"] == .array([]))
    }

    @Test("list_programs e get_program")
    func programs() throws {
        let fixture = try ToolboxFixture()
        let (program, _, _) = try fixture.persistence.makeProgram(name: "Força", activate: true)
        let archived = try fixture.persistence.programs.createProgram(name: "Velho")
        try fixture.persistence.programs.archive(archived)
        let box = fixture.toolbox()
        var (json, _) = try fixture.run(box, "list_programs", #"{"include_archived":false}"#)
        #expect(json["programs"]?.arrayValue?.map { $0["name"] } == [.string("Força")])
        (json, _) = try fixture.run(box, "list_programs", #"{"include_archived":true}"#)
        #expect(json["total"] == .number(2))
        (json, _) = try fixture.run(box, "get_program", #"{"id":"\#(program.id.uuidString)"}"#)
        let exercise = try #require(json["routines"]?.arrayValue?.first?["exercises"]?.arrayValue?.first)
        #expect(exercise["catalogKey"] == .string("bench-press"))
        #expect(exercise["sets"]?.arrayValue?.first?["kind"] == .string("warmup"))
        #expect(exercise["sets"]?.arrayValue?.last?["reps"] == .string("8–12"))
        #expect(exercise["sets"]?.arrayValue?.last?["load"] == .string("30kg"))
        #expect(try fixture.run(box, "get_program", #"{"id":"nope"}"#).1.isError)
        #expect(try fixture.run(box, "get_program", #"{"id":"\#(UUID().uuidString)"}"#).0["error"] == .string("not_found"))
    }

    @Test("list_exercises: consulta pt/en e limite de 50")
    func exercises() throws {
        let fixture = try ToolboxFixture()
        let box = fixture.toolbox()
        var (json, _) = try fixture.run(box, "list_exercises", #"{"query":null}"#)
        #expect((json["exercises"]?.arrayValue?.count ?? 0) <= FitnessToolbox.maxListItems)
        (json, _) = try fixture.run(box, "list_exercises", #"{"query":"bench press"}"#)
        #expect(json["exercises"]?.arrayValue?.contains { $0["catalogKey"] == .string("bench-press") } == true)
        (json, _) = try fixture.run(box, "list_exercises", #"{"query":"SUPINO"}"#)
        #expect((json["exercises"]?.arrayValue?.count ?? 0) >= 2)
    }

    @Test("get_nutrition_log: corta em 31 dias, totais e fora do plano")
    func nutritionLog() throws {
        let fixture = try ToolboxFixture(seed: false)
        let store = NutritionStore(context: fixture.context, calendar: fixture.calendar)
        try store.logFood(name: "Banana", quantity: 1, unit: .unit, values: NutrientValues(kcal: 90, protein: 1), at: fixture.day(-1, hour: 10))
        try store.logFood(name: "Pão", quantity: 2, unit: .slice, at: fixture.day(-1, hour: 8))
        try store.logFood(name: "Antigo", quantity: 1, unit: .unit, values: NutrientValues(kcal: 500), at: fixture.day(-40))
        try store.addWater(milliliters: 500, at: fixture.day(-1, hour: 9))
        let (json, outcome) = try fixture.run(fixture.toolbox(), "get_nutrition_log", #"{"from":"2026-09-01","to":"2026-11-11"}"#)
        #expect(!outcome.isError)
        #expect(json["clamped"] != nil)
        #expect(json["from"] == .string("2026-10-12"))
        let days = try #require(json["days"]?.arrayValue)
        #expect(days.count == 1)
        #expect(days[0]["date"] == .string("2026-11-10"))
        #expect(days[0]["totals"]?["kcal"] == .number(90))
        #expect(days[0]["totals"]?["itemsWithoutKcal"] == .number(1))
        #expect(days[0]["waterMl"] == .number(500))
        #expect(days[0]["entries"]?.arrayValue?.first?["name"] == .string("Pão"))
        #expect(days[0]["entries"]?.arrayValue?.first?["meal"] == .string("fora do plano"))
    }

    @Test("get_health_summary é stub unavailable (quando compartilhado)")
    func health() throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        let (json, outcome) = try fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-01","to":"2026-11-10"}"#)
        #expect(!outcome.isError)
        #expect(json["status"] == .string("unavailable"))
    }

    @Test("propose_program: válido devolve proposta sem gravar; inválido devolve issues")
    func proposeProgram() throws {
        let fixture = try ToolboxFixture()
        let programsBefore = try fixture.persistence.count(TrainingProgram.self)
        let box = fixture.toolbox()
        let (json, outcome) = try fixture.run(box, "propose_program", DraftExamples.program)
        #expect(!outcome.isError)
        #expect(json["status"] == .string("proposed"))
        #expect(outcome.proposal?.id == "call_propose_program")
        guard case let .program(draft)? = outcome.proposal?.content else { Issue.record("sem proposta"); return }
        #expect(draft.name == "ABC Hipertrofia 4x")
        #expect(try fixture.persistence.count(TrainingProgram.self) == programsBefore) // nada gravado

        let (bad, badOutcome) = try fixture.run(box, "propose_program", #"{"name":"x"}"#)
        #expect(badOutcome.isError)
        #expect(badOutcome.proposal == nil)
        #expect(bad["status"] == .string("invalid"))
        #expect((bad["issues"]?.arrayValue?.count ?? 0) > 0)
    }

    @Test("propose_nutrition_plan e ferramenta desconhecida")
    func proposeNutrition() throws {
        let fixture = try ToolboxFixture(seed: false)
        let box = fixture.toolbox()
        let (_, outcome) = try fixture.run(box, "propose_nutrition_plan", DraftExamples.nutrition)
        guard case .nutritionPlan? = outcome.proposal?.content else { Issue.record("sem proposta"); return }
        let (json, unknown) = try fixture.run(box, "delete_everything")
        #expect(unknown.isError)
        #expect(json["error"] == .string("unknown_tool"))
        #expect(try fixture.run(box, "list_programs", "[1,2]").1.isError)
    }
}
