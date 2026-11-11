import Foundation
import Synchronization
import Testing
@testable import FitJourney

/// Leitor do Saúde por dia, com registro de chamadas (para provar que nada é lido sem consentimento/conexão).
struct ToolboxHealthReader: HealthDataReading {
    final class Calls: Sendable {
        let count = Mutex(0)
        let rawSamples = Mutex(0)
        var total: Int { count.withLock { $0 } }
    }

    var calendar: Calendar
    var workouts: HealthReading<[HealthWorkoutRecord]> = .noData
    var buckets: HealthReading<[HeartRateBucket]> = .noData
    /// Por início do dia; dia ausente = `.noData`. `nil` no dicionário inteiro = `fallback`.
    var energyByDay: [Date: Double] = [:]
    var stepsByDay: [Date: Double] = [:]
    var energyFallback: HealthReading<Double> = .noData
    var stepsFallback: HealthReading<Double> = .noData
    var resting: HealthReading<[HealthDailyValue]> = .noData
    let calls = Calls()

    private func touch() { calls.count.withLock { $0 += 1 } }

    func heartRateSamples(in interval: DateInterval) async throws -> HealthReading<[HeartRateSample]> {
        touch()
        calls.rawSamples.withLock { $0 += 1 }
        return .noData
    }

    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async throws -> HealthReading<[HeartRateBucket]> {
        touch()
        return buckets
    }

    func workouts(in interval: DateInterval) async throws -> HealthReading<[HealthWorkoutRecord]> {
        touch()
        return workouts.map { $0.filter { $0.interval.intersects(interval) } }
    }

    func workoutPauses(workoutID: UUID) async throws -> HealthReading<[DateInterval]> { touch(); return .noData }

    func activeEnergyKcal(in interval: DateInterval) async throws -> HealthReading<Double> {
        touch()
        if let value = energyByDay[calendar.startOfDay(for: interval.start)] { return .available(value) }
        return energyByDay.isEmpty ? energyFallback : .noData
    }

    func steps(in interval: DateInterval) async throws -> HealthReading<Double> {
        touch()
        if let value = stepsByDay[calendar.startOfDay(for: interval.start)] { return .available(value) }
        return stepsByDay.isEmpty ? stepsFallback : .noData
    }

    func restingHeartRate(days interval: DateInterval) async throws -> HealthReading<[HealthDailyValue]> {
        touch()
        return resting.map { $0.filter { $0.day >= interval.start && $0.day < interval.end } }
    }

    func latestBodyMassKg() async throws -> HealthReading<Double> { touch(); return .noData }
}

@Suite("AI · get_health_summary")
@MainActor
struct AIHealthSummaryTests {
    private func makeFixture(_ configure: (inout ToolboxHealthReader) -> Void = { _ in }) throws -> (ToolboxFixture, ToolboxHealthReader) {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        configure(&reader)
        fixture.healthReader = reader
        return (fixture, reader)
    }

    private func startOfDay(_ fixture: ToolboxFixture, _ offset: Int) -> Date {
        fixture.calendar.startOfDay(for: fixture.day(offset))
    }

    private func watchWorkout(start: Date, minutes: Double, category: HealthWorkoutCategory = .strength,
                              type: HealthWorkoutType? = .traditionalStrength, heartRate: Double? = 131) -> HealthWorkoutRecord {
        HealthSampleData.record(start: start, minutes: minutes, category: category, type: type,
                                source: "Apple Watch", averageHeartRate: heartRate, energy: 300)
    }

    @Test("sem consentimento de saúde: não é oferecida nem executada, e nada é lido")
    func requiresConsent() async throws {
        var (fixture, reader) = try makeFixture()
        fixture.profile.sharing.health = false
        #expect(!fixture.toolbox().specs.map(\.name).contains("get_health_summary"))
        let (json, outcome) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":null,"to":null}"#)
        #expect(outcome.isError)
        #expect(json["error"] == .string("not_shared"))
        #expect(reader.calls.total == 0)

        fixture.profile.sharing.health = true
        let spec = try #require(fixture.toolbox().specs.first { $0.name == "get_health_summary" })
        let schema = try JSONValue.parse(spec.parametersSchema)
        #expect(schema["required"] == .array([.string("from"), .string("to")]))
        #expect(schema["properties"]?["from"]?["type"] == .array([.string("string"), .string("null")]))
    }

    @Test("desconectado ou aparelho sem Saúde: unavailable com motivo, sem leituras")
    func disconnected() async throws {
        for access in [HealthToolAccess.disconnected, .deviceUnavailable] {
            var (fixture, reader) = try makeFixture()
            fixture.healthAccess = access
            let (json, outcome) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":null,"to":null}"#)
            #expect(!outcome.isError)
            #expect(json["status"] == .string("unavailable"))
            #expect(json["reason"]?.stringValue == access.reason)
            #expect(json["days"] == nil)
            #expect(reader.calls.total == 0)
        }
        // Tudo indisponível (ex.: erro do HealthKit): resposta única "unavailable", não uma tabela de nulls.
        let (fixture, _) = try makeFixture {
            $0.workouts = .unavailable
            $0.resting = .unavailable
            $0.energyFallback = .unavailable
            $0.stepsFallback = .unavailable
        }
        let (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":null,"to":null}"#)
        #expect(json["status"] == .string("unavailable"))
    }

    @Test("dados parciais: null com status no_data/unavailable, nunca zero; médias só dos dias com dado")
    func partialData() async throws {
        var (fixture, reader) = try makeFixture()
        reader.stepsByDay = [startOfDay(fixture, -1): 8_000, startOfDay(fixture, -2): 6_000]
        reader.energyByDay = [startOfDay(fixture, -1): 410.4]
        reader.resting = .unavailable
        fixture.healthReader = reader
        let (json, outcome) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-05","to":"2026-11-11"}"#)
        #expect(!outcome.isError)
        let days = try #require(json["days"]?.arrayValue)
        #expect(days.count == 7)
        let yesterday = try #require(days.first { $0["date"] == .string("2026-11-10") })
        #expect(yesterday["steps"] == .number(8_000))
        #expect(yesterday["activeKcal"] == .number(410))
        #expect(yesterday["restingHR"] == .null)
        #expect(yesterday["status"]?["restingHR"] == .string("unavailable"))
        #expect(yesterday["status"]?["steps"] == nil)
        let today = try #require(days.first { $0["date"] == .string("2026-11-11") })
        #expect(today["steps"] == .null)
        #expect(today["status"]?["steps"] == .string("no_data"))
        #expect(today["activeKcal"] == .null)
        #expect(today["status"]?["activeKcal"] == .string("no_data"))
        #expect(today["workoutMinutes"] == .null)
        #expect(today["workouts"] == .null)
        #expect(today["status"]?["workouts"] == .string("no_data"))
        #expect(today["partial"] == .bool(true))
        #expect(yesterday["partial"] == nil)
        // Nenhum campo de saúde vira zero.
        for day in days {
            for key in ["steps", "activeKcal", "restingHR"] { #expect(day[key] != .number(0), "\(key)") }
        }
        let period = try #require(json["period"])
        #expect(period["avgSteps"] == .number(7_000))
        #expect(period["daysWithData"]?["steps"] == .number(2))
        #expect(period["avgRestingHR"] == .null)
        #expect(period["status"]?["avgRestingHR"] == .string("unavailable"))
        #expect(period["restingHRTrend"]?["status"] == .string("unavailable"))
        #expect(json["note"]?.stringValue?.contains("nunca zero") == true)
        #expect(reader.calls.rawSamples.withLock { $0 } == 0) // nunca amostras individuais
    }

    @Test("período: padrão 7 dias até hoje, máximo 31, futuro cortado em hoje, inválidos recusados")
    func rangeLimits() async throws {
        let (fixture, _) = try makeFixture()
        let box = fixture.toolbox()
        var (json, outcome) = try await fixture.run(box, "get_health_summary", #"{"from":null,"to":null}"#)
        #expect(json["from"] == .string("2026-11-05"))
        #expect(json["to"] == .string("2026-11-11"))
        #expect(json["days"]?.arrayValue?.count == 7)
        #expect(json["adjusted"] == nil)

        (json, _) = try await fixture.run(box, "get_health_summary", #"{"from":null,"to":"2026-10-31"}"#)
        #expect(json["from"] == .string("2026-10-25"))

        (json, _) = try await fixture.run(box, "get_health_summary", #"{"from":"2026-08-01","to":"2026-11-11"}"#)
        #expect(json["from"] == .string("2026-10-12"))
        #expect(json["days"]?.arrayValue?.count == 31)
        #expect(json["period"]?["days"] == .number(31))
        #expect(json["adjusted"]?.stringValue?.contains("31") == true)

        (json, _) = try await fixture.run(box, "get_health_summary", #"{"from":"2026-11-09","to":"2026-12-25"}"#)
        #expect(json["to"] == .string("2026-11-11"))
        #expect(json["days"]?.arrayValue?.count == 3)

        for bad in [#"{"from":"2026-11-10","to":"2026-11-01"}"#, #"{"from":"ontem","to":null}"#,
                    #"{"from":"2026-12-01","to":null}"#, #"{"from":null,"to":"2026-02-30"}"#,
                    #"{"from":"2026-11-5","to":null}"#, #"{"from":" 2026-11-05","to":null}"#,
                    #"{"from":"2026-11-05T00","to":null}"#, #"{"from":"+2026-11-05","to":null}"#,
                    #"{"from":"2026-1-105","to":null}"#] {
            (json, outcome) = try await fixture.run(box, "get_health_summary", bad)
            #expect(outcome.isError, "\(bad)")
            #expect(json["error"] == .string("invalid_arguments"), "\(bad)")
        }
    }

    @Test("treino vinculado aparece uma vez (app+watch); incerto fica separado e marcado; minutos pela união")
    func linkedWorkoutDedupe() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        let linkedSession = try fixture.addSession(daysAgo: 1)          // 10/11 18:00–19:00
        let ownSession = try fixture.addSession(daysAgo: 2)             // 09/11 18:00–19:00
        let uncertainSession = try fixture.addSession(daysAgo: 3)       // 08/11 18:00–19:00
        var own = watchWorkout(start: ownSession.startedAt, minutes: 60, heartRate: 120)
        own.isFromThisApp = true
        own.sourceName = "FitJourney"
        own.sourceBundleID = "br.com.renatocorrea.fitjourney"
        own.externalUUID = ownSession.id.uuidString
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        reader.workouts = .available([
            watchWorkout(start: linkedSession.startedAt.addingTimeInterval(120), minutes: 55),
            own,
            watchWorkout(start: uncertainSession.startedAt.addingTimeInterval(30 * 60), minutes: 60,
                         category: .aerobic, type: .running, heartRate: 150),
        ])
        fixture.healthReader = reader
        let (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-08","to":"2026-11-10"}"#)
        let days = try #require(json["days"]?.arrayValue)

        let linked = try #require(days.first { $0["date"] == .string("2026-11-10") })
        let linkedWorkouts = try #require(linked["workouts"]?.arrayValue)
        #expect(linkedWorkouts.count == 1)
        #expect(linkedWorkouts.first?["origin"] == .string("app+watch"))
        #expect(linkedWorkouts.first?["avgHR"] == .number(131))
        #expect(linkedWorkouts.first?["type"] == .string("strength"))
        #expect(linkedWorkouts.first?["name"] == .string("A"))
        #expect(linked["workoutMinutes"] == .number(60))

        let ownDay = try #require(days.first { $0["date"] == .string("2026-11-09") })
        #expect(ownDay["workouts"]?.arrayValue?.count == 1)
        #expect(ownDay["workouts"]?.arrayValue?.first?["origin"] == .string("app"))
        #expect(ownDay["workouts"]?.arrayValue?.first?["avgHR"] == .number(120))

        let uncertain = try #require(days.first { $0["date"] == .string("2026-11-08") })
        let pair = try #require(uncertain["workouts"]?.arrayValue)
        #expect(pair.count == 2)
        #expect(pair.contains { $0["origin"] == .string("watch") && $0["maybeSameAsAppSession"] == .bool(true) })
        // 18:00–19:00 ∪ 18:30–19:30 = 90 min (sobreposição não soma), por tipo cada um com o seu.
        #expect(uncertain["workoutMinutes"] == .number(90))
        #expect(uncertain["minutesByType"]?["aerobic"] == .number(60))
        #expect(uncertain["minutesByType"]?["strength"] == .number(60))

        // O par incerto conta 1 no total do período (os minutos já são pela união).
        #expect(json["period"]?["workouts"] == .number(3))
        #expect(json["period"]?["workoutMinutes"] == .number(210))
        #expect(json["appSessionsOmitted"] == nil)
    }

    @Test("sem compartilhar treinos: sessões do app e treinos ligados a elas saem; só outras fontes")
    func appSessionsOmittedWithoutWorkoutSharing() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        fixture.profile.sharing.workouts = false
        let linkedSession = try fixture.addSession(daysAgo: 1)
        let ownSession = try fixture.addSession(daysAgo: 2)
        let uncertainSession = try fixture.addSession(daysAgo: 3)
        var own = watchWorkout(start: ownSession.startedAt, minutes: 60, heartRate: 120)
        own.isFromThisApp = true
        own.sourceBundleID = "br.com.renatocorrea.fitjourney"
        own.externalUUID = ownSession.id.uuidString
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        reader.workouts = .available([
            watchWorkout(start: linkedSession.startedAt.addingTimeInterval(120), minutes: 55),
            own,
            watchWorkout(start: uncertainSession.startedAt.addingTimeInterval(30 * 60), minutes: 60,
                         category: .aerobic, type: .running, heartRate: 150),
        ])
        fixture.healthReader = reader
        let (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-08","to":"2026-11-10"}"#)
        let days = try #require(json["days"]?.arrayValue)
        for date in ["2026-11-10", "2026-11-09"] {
            let day = try #require(days.first { $0["date"] == .string(date) })
            #expect(day["workouts"] == .null, "\(date)")
            #expect(day["status"]?["workouts"] == .string("no_data"), "\(date)")
        }
        let other = try #require(days.first { $0["date"] == .string("2026-11-08") })
        let list = try #require(other["workouts"]?.arrayValue)
        #expect(list.count == 1)
        #expect(list.first?["origin"] == .string("watch"))
        #expect(list.first?["maybeSameAsAppSession"] == nil)
        #expect(list.first?["name"] == nil)
        #expect(other["workoutMinutes"] == .number(60))
        #expect(json["period"]?["workouts"] == .number(1))
        #expect(json["appSessionsOmitted"] == .bool(true))
        #expect(json["note"]?.stringValue?.contains("omitidas") == true)
    }

    @Test("leitura de treinos indisponível: sessões do app aparecem com status unavailable; dias vazios não viram 0")
    func workoutsUnavailableWithAppSession() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        try fixture.addSession(daysAgo: 1)
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        reader.workouts = .unavailable
        reader.stepsByDay = [startOfDay(fixture, -1): 5_000]
        fixture.healthReader = reader
        let (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-09","to":"2026-11-10"}"#)
        let days = try #require(json["days"]?.arrayValue)
        let withSession = try #require(days.first { $0["date"] == .string("2026-11-10") })
        #expect(withSession["workouts"]?.arrayValue?.first?["origin"] == .string("app"))
        #expect(withSession["status"]?["workouts"] == .string("unavailable"))
        let empty = try #require(days.first { $0["date"] == .string("2026-11-09") })
        #expect(empty["workouts"] == .null)
        #expect(empty["workoutMinutes"] == .null)
        #expect(empty["status"]?["workouts"] == .string("unavailable"))
        #expect(json["period"]?["workouts"] == .number(1))
        #expect(json["period"]?["status"]?["workouts"] == .string("unavailable"))

        // Sem sessão e sem leitura: agregado null + unavailable (nunca 0 treinos).
        let (none, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-08","to":"2026-11-09"}"#)
        #expect(none["period"]?["workouts"] == .null)
        #expect(none["period"]?["workoutMinutes"] == .null)
        #expect(none["period"]?["status"]?["workouts"] == .string("unavailable"))
    }

    @Test("período sem dado nenhum: agregados null com no_data; hoje parcial fica fora das médias")
    func noDataPeriodAndPartialToday() async throws {
        var (fixture, reader) = try makeFixture()
        var json = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":null,"to":null}"#).0
        var period = try #require(json["period"])
        #expect(period["workouts"] == .null)
        #expect(period["status"]?["workouts"] == .string("no_data"))
        #expect(period["workoutMinutes"] == .null)
        #expect(period["avgSteps"] == .null)
        #expect(period["status"]?["avgSteps"] == .string("no_data"))

        // Só hoje tem passos (parcial): aparece no dia, mas não entra na média.
        reader.stepsByDay = [startOfDay(fixture, 0): 2_000, startOfDay(fixture, -1): 9_000]
        fixture.healthReader = reader
        json = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":null,"to":null}"#).0
        period = try #require(json["period"])
        #expect(period["avgSteps"] == .number(9_000))
        #expect(period["daysWithData"]?["steps"] == .number(1))
        let today = try #require(json["days"]?.arrayValue?.last)
        #expect(today["partial"] == .bool(true))
        #expect(today["steps"] == .number(2_000))
        #expect(json["note"]?.stringValue?.contains("parcial") == true)
    }

    @Test("FC média: gravada no treino; senão estimada pelos baldes (avgHRApprox); falha = null com status")
    func averageHeartRateSources() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        let session = try fixture.addSession(daysAgo: 1)
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        reader.buckets = .available([HeartRateBucket(interval: DateInterval(start: session.startedAt, duration: 3_600),
                                                     average: 118, minimum: 90, maximum: 150)])
        fixture.healthReader = reader
        let args = #"{"from":"2026-11-10","to":"2026-11-10"}"#
        var item = try await fixture.run(fixture.toolbox(), "get_health_summary", args).0["days"]?.arrayValue?.first?["workouts"]?.arrayValue?.first
        #expect(item?["avgHR"] == .number(118))
        #expect(item?["avgHRApprox"] == .bool(true))

        reader.buckets = .unavailable
        fixture.healthReader = reader
        item = try await fixture.run(fixture.toolbox(), "get_health_summary", args).0["days"]?.arrayValue?.first?["workouts"]?.arrayValue?.first
        #expect(item?["avgHR"] == .null)
        #expect(item?["avgHRStatus"] == .string("unavailable"))
        #expect(item?["avgHRApprox"] == nil)
    }

    @Test("tendência da FC em repouso: primeira × segunda metade; poucos dias = null com motivo")
    func restingTrend() async throws {
        var (fixture, reader) = try makeFixture()
        reader.resting = .available((0 ..< 14).map { HealthDailyValue(day: startOfDay(fixture, -$0), value: 55 + Double($0)) })
        fixture.healthReader = reader
        var (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-10-29","to":"2026-11-11"}"#)
        let trend = try #require(json["period"]?["restingHRTrend"])
        #expect(trend["direction"] == .string("down"))
        // Hoje (55) fica fora: 13 dias completos, metades de 6 (62…67 × 56…61).
        #expect(trend["firstHalfAvg"] == .number(65))
        #expect(trend["secondHalfAvg"] == .number(59))
        #expect(json["period"]?["avgRestingHR"] == .number(62))
        #expect(json["period"]?["daysWithData"]?["restingHR"] == .number(13))

        (json, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-08","to":"2026-11-11"}"#)
        #expect(json["period"]?["restingHRTrend"]?["direction"] == .null)
        #expect(json["period"]?["restingHRTrend"]?["status"] == .string("no_data"))
    }

    @Test("31 dias cheios de treinos cabem no limite do resultado, como JSON válido")
    func resultSize() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        var records: [HealthWorkoutRecord] = []
        var steps: [Date: Double] = [:]
        var energy: [Date: Double] = [:]
        for offset in 0 ..< 31 {
            let day = fixture.calendar.startOfDay(for: fixture.day(-offset))
            steps[day] = 9_000 + Double(offset)
            energy[day] = 500
            for index in 0 ..< 14 {
                let start = day.addingTimeInterval(Double(6 * 3_600 + index * 3_600))
                records.append(HealthSampleData.record(start: start, minutes: 40, source: "Strava"))
            }
        }
        var reader = ToolboxHealthReader(calendar: fixture.calendar)
        reader.workouts = .available(records)
        reader.stepsByDay = steps
        reader.energyByDay = energy
        fixture.healthReader = reader
        let (json, outcome) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-10-01","to":"2026-11-11"}"#)
        #expect(outcome.content.count <= CoachConversationService.maxToolResultCharacters)
        #expect(CoachConversationService.limitToolResult(outcome.content) == outcome.content)
        #expect(json["truncated"] != nil)
        #expect(json["period"]?["workouts"] == .number(31 * 14))
        #expect(json["period"]?["avgSteps"] != nil)
        if let days = json["days"]?.arrayValue {
            #expect(days.count == 31)
            #expect(days.first?["workoutCount"] == .number(14)) // só a contagem
            #expect(days.first?["workouts"] == nil)
        }

        // Período curto com a mesma carga: detalhe completo, com o teto de 10 treinos por dia.
        let (short, _) = try await fixture.run(fixture.toolbox(), "get_health_summary", #"{"from":"2026-11-11","to":"2026-11-11"}"#)
        #expect(short["truncated"] == nil)
        #expect(short["days"]?.arrayValue?.first?["workouts"]?.arrayValue?.count == FitnessToolbox.maxHealthWorkoutsPerDay)
        #expect(short["days"]?.arrayValue?.first?["moreWorkouts"] == .number(4))
    }
}
