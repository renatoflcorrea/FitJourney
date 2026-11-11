import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import FitJourney

private func baseCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    return cal
}

private func suite(_ name: String) -> UserDefaults {
    UserDefaults(suiteName: "\(name)-\(UUID().uuidString)")!
}

/// 2026-11-11 é quarta; 2026-11-08 é domingo.
private func day(_ d: Int, hour: Int = 9, _ calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
}

@Suite("Preferências — início da semana")
struct WeekStartConsumerTests {
    @Test func appCalendarAppliesFirstWeekday() {
        #expect(AppCalendar.make(base: baseCalendar(), weekStart: .monday).firstWeekday == 2)
        #expect(AppCalendar.make(base: baseCalendar(), weekStart: .sunday).firstWeekday == 1)
    }

    @Test func calendarAndOrderReadInjectedDefaults() {
        let defaults = suite("weekstart")
        #expect(WeekStart.resolved(defaults) == .monday) // ausente = segunda
        #expect(AppCalendar.current(defaults).firstWeekday == 2)
        #expect(Weekday.displayOrder(defaults).first == .monday)
        defaults.set("sunday", forKey: AppPreferenceKeys.weekStart)
        #expect(WeekStart.resolved(defaults) == .sunday)
        #expect(AppCalendar.current(defaults).firstWeekday == 1)
        #expect(Weekday.displayOrder(defaults).first == .sunday)
        defaults.set("lixo", forKey: AppPreferenceKeys.weekStart)
        #expect(WeekStart.resolved(defaults) == .monday)
    }

    @Test func weekIntervalFollowsPreference() throws {
        let monday = AppCalendar.make(base: baseCalendar(), weekStart: .monday)
        let sunday = AppCalendar.make(base: baseCalendar(), weekStart: .sunday)
        let now = day(11, monday)
        #expect(try #require(monday.dateInterval(of: .weekOfYear, for: now)).start == day(9, hour: 0, monday))
        #expect(try #require(sunday.dateInterval(of: .weekOfYear, for: now)).start == day(8, hour: 0, sunday))
    }

    @Test func weeklyAdherenceMondayVersusSunday() {
        let monday = AppCalendar.make(base: baseCalendar(), weekStart: .monday)
        let sunday = AppCalendar.make(base: baseCalendar(), weekStart: .sunday)
        // Treino no domingo 8: fora da semana de segunda (9–15), dentro da de domingo (8–14).
        let dates = [day(8, hour: 22, monday), day(10, monday)]
        let now = day(11, monday)
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: dates, now: now, calendar: monday)?.done == 1)
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: dates, now: now, calendar: sunday)?.done == 2)
        // Domingo 15: a semana de segunda ainda inclui; a de domingo já é a próxima.
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: [day(15, monday)], now: now, calendar: monday)?.done == 1)
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: [day(15, monday)], now: now, calendar: sunday)?.done == 0)
    }

    @Test func displayOrderRespectsPreferenceButNotStoredDays() {
        #expect(Weekday.ordered(startingOn: .monday) == Weekday.allCases)
        #expect(Weekday.ordered(startingOn: .sunday) == [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday])
        #expect(Weekday.sunday.calendarWeekday == 1) // o dado gravado não depende da exibição
    }
}

@Suite("Preferências — descanso")
struct RestPreferenceTests {
    @Test func policyOrderAndExplicitZero() {
        #expect(RestPolicy.effective(set: 10, routineExercise: 20, exercise: 30, fallback: 40) == 10)
        #expect(RestPolicy.effective(set: nil, routineExercise: 20, exercise: 30, fallback: 40) == 20)
        #expect(RestPolicy.effective(set: nil, routineExercise: nil, exercise: 30, fallback: 40) == 30)
        #expect(RestPolicy.effective(set: nil, routineExercise: nil, exercise: nil, fallback: 40) == 40)
        #expect(RestPolicy.effective(set: 0, routineExercise: 20, exercise: 30, fallback: 40) == 0)
    }

    @Test func defaultSecondsFallsBackTo90() {
        let defaults = suite("rest")
        #expect(RestPreference.defaultSeconds(defaults) == 90)
        defaults.set(120, forKey: AppPreferenceKeys.defaultRestSeconds)
        #expect(RestPreference.defaultSeconds(defaults) == 120)
        defaults.set(0, forKey: AppPreferenceKeys.defaultRestSeconds)
        #expect(RestPreference.defaultSeconds(defaults) == 90)
    }

    @Test func soundDefaultsOn() {
        let defaults = suite("sound")
        #expect(RestPreference.soundEnabled(defaults))
        defaults.set(false, forKey: AppPreferenceKeys.restSound)
        #expect(!RestPreference.soundEnabled(defaults))
    }

    @MainActor @Test func notificationContentHasSoundOnlyWhenEnabled() {
        #expect(UserNotificationRestScheduler.content(body: "x", soundEnabled: true).sound == .default)
        #expect(UserNotificationRestScheduler.content(body: "x", soundEnabled: false).sound == nil)
    }

    @MainActor @Test func editorAndEstimateUseInjectedPreference() throws {
        let defaults = suite("editor")
        defaults.set(105, forKey: AppPreferenceKeys.defaultRestSeconds)
        #expect(PrescriptionDefaults.restSeconds(defaults) == 105)
        #expect(RoutineEditorOps.effectiveRest(SetDraft(), exerciseRest: nil, catalogRest: nil, defaults: defaults) == 105)
        #expect(RoutineEditorOps.effectiveRest(SetDraft(), exerciseRest: nil, catalogRest: 60, defaults: defaults) == 60)

        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        for item in routine.sortedExercises {
            item.restSeconds = nil
            item.exercise?.defaultRestSeconds = nil
            for set in item.sortedSets { set.restSeconds = nil }
        }
        let withDefault = routine.estimatedDurationSeconds(fallbackRest: 60)
        let longer = routine.estimatedDurationSeconds(fallbackRest: 180)
        #expect(longer > withDefault)
        let item = try #require(routine.sortedExercises.first)
        #expect(RoutineEditorOps.effectiveRest(of: item, defaults: defaults) == 105)
    }

    @MainActor @Test func exerciseWithoutRestIsOptionalAndWatchGetsEffective() throws {
        let f = try PersistenceFixture()
        let exercise = Exercise(name: "Teste")
        #expect(exercise.defaultRestSeconds == nil)
        let (program, routine, _) = try f.makeProgram()
        _ = program
        for item in routine.sortedExercises {
            item.restSeconds = nil
            item.exercise?.defaultRestSeconds = nil
            for set in item.sortedSets { set.restSeconds = nil }
        }
        try f.context.save()
        let digest = try #require(try ProgramDigestBuilder.make(context: f.context, fallbackRest: 77))
        let rests = digest.routines.flatMap(\.exercises).map(\.restSeconds)
        #expect(!rests.isEmpty)
        #expect(rests.allSatisfy { $0 == 77 })
    }
}

@MainActor
@Suite("Preferências — motor da sessão")
struct SessionRestPreferenceIntegrationTests {
    @Test func completeSetAndStartRestUseSettingsDefault() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        for item in routine.sortedExercises {
            item.restSeconds = nil
            item.exercise?.defaultRestSeconds = nil
            for set in item.sortedSets { set.restSeconds = nil }
        }
        try f.context.save()
        let prefs = suite("engine-rest")
        prefs.set(75, forKey: AppPreferenceKeys.defaultRestSeconds)
        let clock = f.clock
        let engine = SessionEngine(context: f.context, notifications: f.scheduler, tombstoneDefaults: f.defaults,
                                   autoRestTimer: false, now: { clock.now }, preferences: prefs)
        let sessionID = UUID()
        clock.now = f.t0
        #expect(engine.apply(f.command(.start(routineID: routine.id), at: 0, session: sessionID)).isApplied)
        let sets = try #require(engine.snapshot).exercises[0].sets

        // completeSet sem descanso definido → 75 s de Ajustes; total coerente.
        clock.now = f.t0.addingTimeInterval(60)
        let done = engine.apply(f.command(.completeSet(setID: sets[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                                          at: 60, session: sessionID))
        #expect(done.events.contains(.restStarted(endsAt: f.t0.addingTimeInterval(135))))
        #expect(engine.activeSession?.restTotalSeconds == 75)

        // Preferência muda: vale a partir do próximo descanso; `.startRest(nil)` usa o novo valor.
        prefs.set(120, forKey: AppPreferenceKeys.defaultRestSeconds)
        clock.now = f.t0.addingTimeInterval(70)
        #expect(engine.apply(f.command(.skipRest, at: 70, session: sessionID)).isApplied)
        clock.now = f.t0.addingTimeInterval(80)
        let started = engine.apply(f.command(.startRest(seconds: nil), at: 80, session: sessionID))
        #expect(started.isApplied)
        #expect(try #require(engine.snapshot).restEndsAt == f.t0.addingTimeInterval(80 + 120))
        #expect(engine.activeSession?.restTotalSeconds == 120)
    }

    @Test func explicitZeroIsKept() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        for item in routine.sortedExercises {
            item.restSeconds = nil
            item.exercise?.defaultRestSeconds = nil
            for set in item.sortedSets { set.restSeconds = 0 }
        }
        try f.context.save()
        let prefs = suite("engine-zero")
        prefs.set(75, forKey: AppPreferenceKeys.defaultRestSeconds)
        let clock = f.clock
        let engine = SessionEngine(context: f.context, notifications: f.scheduler, tombstoneDefaults: f.defaults,
                                   autoRestTimer: false, now: { clock.now }, preferences: prefs)
        let sessionID = UUID()
        clock.now = f.t0
        #expect(engine.apply(f.command(.start(routineID: routine.id), at: 0, session: sessionID)).isApplied)
        let sets = try #require(engine.snapshot).exercises[0].sets
        clock.now = f.t0.addingTimeInterval(60)
        _ = engine.apply(f.command(.completeSet(setID: sets[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                                   at: 60, session: sessionID))
        let snap = try #require(engine.snapshot)
        #expect((snap.restRemaining(at: f.t0.addingTimeInterval(60)) ?? 0) == 0)
        // `.startRest(nil)`: o último descanso concluído foi 0 explícito → 0 (não vira 75).
        clock.now = f.t0.addingTimeInterval(61)
        _ = engine.apply(f.command(.startRest(seconds: nil), at: 61, session: sessionID))
        #expect((try #require(engine.snapshot).restRemaining(at: f.t0.addingTimeInterval(61)) ?? 0) == 0)
    }
}

@MainActor
@Suite("Preferências — som da Atividade ao Vivo")
struct LiveActivityRestSoundTests {
    @Test func soundOnAlertsAndSuppressesNotification_soundOffDoesNot() async throws {
        for sound in [true, false] {
            let s = LiveSnapshots()
            let source = FakeSessionSource()
            let client = FakeLiveActivityClient()
            let notifications = FakeRestScheduler()
            let gate = LiveActivityRestNotificationGate(wrapping: notifications)
            let defaults = suite("la-sound")
            defaults.set(sound, forKey: AppPreferenceKeys.restSound)
            let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_500))
            let controller = LiveActivityController(
                engine: source, client: client, gate: gate, defaults: defaults, now: { clock.now }, unit: { .kg },
                routineColorName: { _ in "blue" }, isAppActive: { false }, restDoneHold: .milliseconds(20))
            let end = clock.now.addingTimeInterval(60)
            let resting = s.make(revision: 1, completed: 3, restEndsAt: end, restTotal: 90)
            source.snapshot = resting
            controller.handle(resting)
            await controller.waitUntilIdle()
            gate.scheduleRestEnd(at: end, nextExerciseName: nil)
            clock.now = end
            controller.handle(.restFinished(at: end))
            await controller.waitUntilIdle()
            let alerted = try #require(client.updates.last)
            #expect(alerted.state.phase == .restDone)
            #expect((alerted.alert != nil) == sound)
            // Com som: a atividade alertou e a notificação local sai; sem som: a notificação silenciosa segue.
            #expect(notifications.cancelCount == (sound ? 1 : 0))
        }
    }
}
