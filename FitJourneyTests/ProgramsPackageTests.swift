import Foundation
import SwiftData
import Testing
@testable import FitJourney

private var calendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    cal.firstWeekday = 2
    return cal
}

/// 2026-11-11 é quarta-feira.
private func date(_ day: Int, month: Int = 11, hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

struct NextWorkoutTests {
    let a = UUID(), b = UUID()

    @Test func findsNextMarkedDayAfterToday() {
        let routines = [
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, weekdays: [.monday]),
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, weekdays: [.thursday]),
        ]
        let fromWednesday = ScheduleResolver.nextWorkout(after: date(11), routines: routines, calendar: calendar)
        #expect(fromWednesday?.weekday == .thursday)
        #expect(fromWednesday?.routineID == b)
        // Quinta → próxima é segunda (A), cruzando o fim da semana.
        let fromThursday = ScheduleResolver.nextWorkout(after: date(12), routines: routines, calendar: calendar)
        #expect(fromThursday?.weekday == .monday)
        #expect(fromThursday?.routineID == a)
    }

    @Test func onlyTodayMarkedMeansNextWeek() {
        let routines = [ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, weekdays: [.wednesday])]
        #expect(ScheduleResolver.nextWorkout(after: date(11), routines: routines, calendar: calendar)?.weekday == .wednesday)
    }

    @Test func sameDayPicksLowestSortIndexAndNoneIsNil() {
        let routines = [
            ScheduleResolver.RoutineInfo(id: b, sortIndex: 1, weekdays: [.friday]),
            ScheduleResolver.RoutineInfo(id: a, sortIndex: 0, weekdays: [.friday]),
        ]
        #expect(ScheduleResolver.nextWorkout(after: date(11), routines: routines, calendar: calendar)?.routineID == a)
        #expect(ScheduleResolver.nextWorkout(after: date(11), routines: [.init(id: a, sortIndex: 0)], calendar: calendar) == nil)
    }
}

struct WeeklyAdherenceTests {
    @Test func countsOnlyThisWeekAndCapsAtPlanned() {
        // Semana de 9 a 15 de novembro (segunda a domingo).
        let dates = [date(8, hour: 22), date(9), date(10), date(11), date(12), date(15, hour: 23)]
        let result = ScheduleResolver.weeklyAdherence(plannedDays: 3, completedDates: dates, now: date(11), calendar: calendar)
        #expect(result?.planned == 3)
        #expect(result?.done == 3) // 5 na semana, limitado ao previsto; o de domingo 8 não entra
    }

    @Test func mondayBoundaryAndNoPlan() {
        let result = ScheduleResolver.weeklyAdherence(plannedDays: 4, completedDates: [date(8, hour: 23)], now: date(9), calendar: calendar)
        #expect(result?.done == 0)
        #expect(ScheduleResolver.weeklyAdherence(plannedDays: 0, completedDates: [date(9)], now: date(9), calendar: calendar) == nil)
    }

    @MainActor
    @Test func storeIgnoresSessionsWithoutRoutine() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly, activate: true)
        let routine = try f.programs.addRoutine(to: program, name: "A", symbol: "A", weekdays: [.monday, .wednesday, .friday])

        func completed(routineID: UUID?, at day: Int) {
            let s = WorkoutSession(routineName: "x", startedAt: date(day))
            s.programID = program.id
            s.routineID = routineID
            s.statusRaw = SessionStatus.completed.rawValue
            s.endedAt = date(day).addingTimeInterval(3_600)
            f.context.insert(s)
        }
        completed(routineID: routine.id, at: 9)
        completed(routineID: nil, at: 10) // treino livre dentro do programa: não conta
        completed(routineID: routine.id, at: 11)
        try f.context.save()

        let adherence = try #require(try f.programs.weeklyAdherence(for: program, now: date(11), calendar: calendar))
        #expect(adherence.done == 2)
        #expect(adherence.planned == 3)

        program.scheduleMode = .sequential
        #expect(try f.programs.weeklyAdherence(for: program, now: date(11), calendar: calendar) == nil)
    }
}

struct WeekProgressTests {
    @Test func eightWeekProgramIsWeekOneOfEight() {
        let program = TrainingProgram(name: "P", startDate: date(1))
        program.endDate = calendar.date(byAdding: .weekOfYear, value: 8, to: date(1))
        let first = program.weekProgress(on: date(1), calendar: calendar)
        #expect(first?.week == 1)
        #expect(first?.of == 8)
        #expect(program.weekProgress(on: date(22), calendar: calendar)?.week == 4) // dia 21 → semana 4
        // Último dia e depois do fim ficam na última semana.
        #expect(program.weekProgress(on: date(1, month: 12), calendar: calendar)?.week == 5)
        let afterEnd = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1))!
        let late = program.weekProgress(on: afterEnd, calendar: calendar)
        #expect(late?.week == 8)
        #expect(late?.of == 8)
    }

    @Test func noEndDateMeansNoProgress() {
        #expect(TrainingProgram(name: "P").weekProgress() == nil)
    }
}

@MainActor
struct ProgramSessionGuardTests {
    @Test func sessionInProgressBlocksSwitchArchiveDeleteDeactivate() throws {
        let f = try PersistenceFixture()
        let (current, routine, _) = try f.makeProgram(name: "Atual")
        let other = try f.programs.createProgram(name: "Outro")
        let session = try f.sessions.start(routine: routine)

        #expect(throws: ProgramStoreError.sessionInProgress(routineName: session.routineName)) { try f.programs.activate(other) }
        #expect(throws: ProgramStoreError.self) { try f.programs.archive(current) }
        #expect(throws: ProgramStoreError.self) { try f.programs.delete(current) }
        #expect(throws: ProgramStoreError.self) { try f.programs.deactivate(current) }
        #expect(current.isActive && !other.isActive)

        // Programa sem relação com a sessão pode ser apagado; reativar o próprio programa é permitido.
        try f.programs.activate(current)
        try f.programs.delete(other)

        try f.sessions.finish(session)
        let another = try f.programs.createProgram(name: "Novo")
        try f.programs.activate(another)
        #expect(another.isActive && !current.isActive)
        try f.programs.archive(current)
        #expect(current.isArchived)
    }

    @Test func freeWorkoutDoesNotBlockProgramChanges() throws {
        let f = try PersistenceFixture()
        let (current, _, _) = try f.makeProgram(name: "Atual")
        let other = try f.programs.createProgram(name: "Outro")
        _ = try f.sessions.start(routine: nil)
        try f.programs.activate(other)
        #expect(other.isActive && !current.isActive)
    }

    @Test func nextWeeklyWorkoutFromStore() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly, activate: true)
        _ = try f.programs.addRoutine(to: program, name: "A", symbol: "A", weekdays: [.monday])
        let b = try f.programs.addRoutine(to: program, name: "B", symbol: "B", weekdays: [.thursday])
        let next = try #require(f.programs.nextWeeklyWorkout(for: program, after: date(11), calendar: calendar))
        #expect(next.weekday == .thursday)
        #expect(next.routine === b)
    }
}

@MainActor
struct ProgramRenameTests {
    @Test func renameTrimsAndPersists() throws {
        let f = try PersistenceFixture()
        let (program, _, _) = try f.makeProgram(name: "ABC")
        let before = program.updatedAt

        try f.programs.rename(program, to: "  Força 5x5 \n")
        #expect(program.name == "Força 5x5")
        #expect(program.updatedAt >= before)

        // Persistido: relido do banco.
        let id = program.id
        let fetched = try #require(try f.context.fetch(FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == id })).first)
        #expect(fetched.name == "Força 5x5")
        #expect(!f.context.hasChanges)
    }

    @Test func emptyOrBlankNameIsRefusedAndKeepsOldName() throws {
        let f = try PersistenceFixture()
        let (program, _, _) = try f.makeProgram(name: "ABC")

        #expect(throws: ProgramStoreError.emptyName) { try f.programs.rename(program, to: "") }
        #expect(throws: ProgramStoreError.emptyName) { try f.programs.rename(program, to: "   \n\t ") }
        #expect(program.name == "ABC")
        #expect(ProgramStore.normalizedName("  ") == nil)
        #expect(ProgramStore.normalizedName(" x ") == "x")
    }

    @Test func renameReachesTheWatchDigest() throws {
        let f = try PersistenceFixture()
        let (program, _, _) = try f.makeProgram(name: "ABC")
        try f.programs.rename(program, to: "Novo nome")
        #expect(try ProgramDigestBuilder.make(context: f.context)?.name == "Novo nome")
    }

    @Test func renameWorksDuringAnActiveSession() throws {
        let f = try PersistenceFixture()
        let (program, routine, _) = try f.makeProgram(name: "ABC")
        let session = try f.sessions.start(routine: routine)
        try f.programs.rename(program, to: "Depois")
        #expect(program.name == "Depois")
        #expect(session.routineName == "A")
    }
}
