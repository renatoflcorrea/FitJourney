import Foundation
import Testing
@testable import FitJourney

struct ScheduleResolverTests {
    let a = UUID(), b = UUID(), c = UUID()
    var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return cal
    }
    /// 2026-11-11 é quarta-feira.
    var wednesday: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))! }
    func daysAgo(_ n: Double) -> Date { wednesday.addingTimeInterval(-n * 86_400) }

    @Test func weekdayMapping() {
        #expect(Weekday(date: wednesday, calendar: calendar) == .wednesday)
        #expect(Weekday.allCases.first == .monday)
        for day in Weekday.allCases { #expect(Weekday(calendarWeekday: day.calendarWeekday) == day) }
    }

    @Test func emptyProgram() {
        #expect(ScheduleResolver.suggestion(mode: .free, routines: [], today: wednesday) == .noRoutines)
    }

    @Test func freePicksNeverDoneFirstThenLeastRecent() {
        let routines = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, lastCompletedAt: daysAgo(1)),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, lastCompletedAt: nil),
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2, lastCompletedAt: nil),
        ]
        #expect(ScheduleResolver.suggestion(mode: .free, routines: routines, today: wednesday) == .routine(b))

        let allDone = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, lastCompletedAt: daysAgo(1)),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, lastCompletedAt: daysAgo(5)),
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2, lastCompletedAt: daysAgo(3)),
        ]
        #expect(ScheduleResolver.suggestion(mode: .free, routines: allDone, today: wednesday) == .routine(b))
    }

    @Test func sequentialStartsAtFirstAndRotatesCircularly() {
        let none = [a, b, c].enumerated().map { ScheduleResolver.RoutineInfo(id: $1, sortIndex: $0) }
        #expect(ScheduleResolver.suggestion(mode: .sequential, routines: none, today: wednesday) == .routine(a))

        let afterB = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, lastCompletedAt: daysAgo(3)),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, lastCompletedAt: daysAgo(1)),
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2, lastCompletedAt: daysAgo(5)),
        ]
        #expect(ScheduleResolver.suggestion(mode: .sequential, routines: afterB, today: wednesday) == .routine(c))

        let afterC = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, lastCompletedAt: daysAgo(3)),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, lastCompletedAt: daysAgo(2)),
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2, lastCompletedAt: daysAgo(1)),
        ]
        #expect(ScheduleResolver.suggestion(mode: .sequential, routines: afterC, today: wednesday) == .routine(a))
    }

    @Test func sequentialUsesSortIndexNotInputOrder() {
        let shuffled = [
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2),
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, lastCompletedAt: daysAgo(1)),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1),
        ]
        #expect(ScheduleResolver.suggestion(mode: .sequential, routines: shuffled, today: wednesday) == .routine(b))
    }

    @Test func weeklyReturnsRoutinesOfTheDayOrRest() {
        let routines = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, weekdays: [.monday, .thursday]),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, weekdays: [.wednesday]),
            ScheduleResolver.RoutineInfo(id: c, sortIndex: 2, weekdays: [.wednesday, .friday]),
        ]
        #expect(ScheduleResolver.suggestion(mode: .weekly, routines: routines, today: wednesday, calendar: calendar)
            == .routines([b, c]))
        let tuesday = daysAgo(1)
        #expect(ScheduleResolver.suggestion(mode: .weekly, routines: routines, today: tuesday, calendar: calendar) == .rest)
        #expect(ScheduleSuggestion.rest.routineIDs.isEmpty)
    }
}
