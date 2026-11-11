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
        // Domingo 15: semana de segunda ainda inclui; a de domingo já é a próxima.
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: [day(15, monday)], now: now, calendar: monday)?.done == 1)
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: [day(15, monday)], now: now, calendar: sunday)?.done == 0)
    }

    @Test func displayOrderRespectsPreferenceButNotStoredDays() {
        #expect(Weekday.ordered(startingOn: .monday) == Weekday.allCases)
        #expect(Weekday.ordered(startingOn: .sunday) == [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday])
        // Dados gravados não mudam: o raw continua o mesmo, só a ordem de exibição.
        #expect(Weekday.sunday.calendarWeekday == 1)
    }

    @Test func preferenceIsReadFromDefaults() {
        let defaults = UserDefaults(suiteName: "weekstart-\(UUID().uuidString)")!
        #expect(WeekStart(rawValue: defaults.string(forKey: AppPreferenceKeys.weekStart) ?? "") == nil) // ausente → padrão segunda em `current`
        defaults.set("sunday", forKey: AppPreferenceKeys.weekStart)
        #expect(WeekStart(rawValue: defaults.string(forKey: AppPreferenceKeys.weekStart)!) == .sunday)
    }
}

@Suite("Preferências — descanso")
struct RestPreferenceTests {
    @Test func defaultSecondsFallsBackTo90() {
        let defaults = UserDefaults(suiteName: "rest-\(UUID().uuidString)")!
        #expect(RestPreference.defaultSeconds(defaults) == 90)
        defaults.set(120, forKey: AppPreferenceKeys.defaultRestSeconds)
        #expect(RestPreference.defaultSeconds(defaults) == 120)
        defaults.set(0, forKey: AppPreferenceKeys.defaultRestSeconds)
        #expect(RestPreference.defaultSeconds(defaults) == 90)
    }

    @Test func soundDefaultsOn() {
        let defaults = UserDefaults(suiteName: "sound-\(UUID().uuidString)")!
        #expect(RestPreference.soundEnabled(defaults))
        defaults.set(false, forKey: AppPreferenceKeys.restSound)
        #expect(!RestPreference.soundEnabled(defaults))
    }

    @MainActor @Test func notificationContentHasSoundOnlyWhenEnabled() {
        #expect(UserNotificationRestScheduler.content(body: "x", soundEnabled: true).sound == .default)
        #expect(UserNotificationRestScheduler.content(body: "x", soundEnabled: false).sound == nil)
    }

    @MainActor @Test func storeUsesFallbackRestWhenNothingDefinesOne() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = try f.sessions.start(routine: routine, at: t0)
        let exercise = try #require(session.sortedExercises.first)
        exercise.restSeconds = nil
        let logs = exercise.sortedSets
        for log in logs { log.restSeconds = nil }

        var store = f.sessions
        store.fallbackRestSeconds = 75
        try store.completeSet(logs[1], at: t0.addingTimeInterval(10))
        #expect(session.clock.restRemaining(at: t0.addingTimeInterval(10)) == 75)
    }

    @MainActor @Test func routineEditorFallbackUsesPreference() {
        let key = AppPreferenceKeys.defaultRestSeconds
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(105, forKey: key)
        #expect(PrescriptionDefaults.restSeconds == 105)
        #expect(RoutineEditorOps.effectiveRest(SetDraft(repTarget: nil), exerciseRest: nil, catalogRest: nil) == 105)
    }
}

@MainActor
@Suite("Preferências — som da Atividade ao Vivo")
struct LiveActivityRestSoundTests {
    @Test func restFinishedAlertDependsOnSoundPreference() async throws {
        for sound in [true, false] {
            let s = LiveSnapshots()
            let source = FakeSessionSource()
            let client = FakeLiveActivityClient()
            let defaults = UserDefaults(suiteName: "la-sound-\(UUID().uuidString)")!
            defaults.set(sound, forKey: AppPreferenceKeys.restSound)
            let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_500))
            let controller = LiveActivityController(
                engine: source, client: client, gate: nil, defaults: defaults, now: { clock.now }, unit: { .kg },
                routineColorName: { _ in "blue" }, isAppActive: { false }, restDoneHold: .milliseconds(20))
            let end = clock.now.addingTimeInterval(1)
            let resting = s.make(revision: 1, completed: 3, restEndsAt: end, restTotal: 120)
            source.snapshot = resting
            controller.handle(resting)
            await controller.waitUntilIdle()
            controller.handle(.restFinished(at: end))
            await controller.waitUntilIdle()
            let alerted = try #require(client.updates.last)
            #expect(alerted.state.phase == .restDone)
            #expect((alerted.alert != nil) == sound)
        }
    }
}
