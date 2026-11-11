import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct StorageToleranceTests {
    @Test func corruptedJSONFieldsReadAsEmptyWithoutCrash() throws {
        let f = try PersistenceFixture()
        let e = try f.exercise("bench-press")
        e.mediaData = Data("not json".utf8)
        #expect(e.media.isEmpty)

        let set = SetPrescription(initialLoad: .kg(30))
        set.currentLoadData = Data("{oops".utf8)
        set.repTargetData = Data([0xFF, 0x00])
        f.context.insert(set)
        try f.context.save()
        #expect(set.currentLoad == nil)
        #expect(set.repTarget == nil)
        #expect(set.effectiveLoad == .kg(30))
    }

    @Test func rewritingListPreservesUnreadableBlob() throws {
        let f = try PersistenceFixture()
        let e = try f.exercise("bench-press")
        let corrupt = Data("not json".utf8)
        e.mediaData = corrupt
        e.media = [.image(fileName: "a.jpg")]
        #expect(e.media == [.image(fileName: "a.jpg")])
        let raw = String(decoding: try #require(e.mediaData), as: UTF8.self)
        #expect(raw.contains(StorageCoding.corruptBlobKey))
        #expect(raw.contains(corrupt.base64EncodedString()))
        // Regravar de novo continua preservando.
        e.media = []
        #expect(String(decoding: try #require(e.mediaData), as: UTF8.self).contains(corrupt.base64EncodedString()))
    }

    @Test func unknownListElementsSurviveRewrite() throws {
        let f = try PersistenceFixture()
        let e = try f.exercise("bench-press")
        let valid = String(decoding: try #require(StorageCoding.encode([MediaRef.image(fileName: "a.jpg")])), as: UTF8.self)
        let mixed = "[" + valid.dropFirst().dropLast() + #",{"hologram":{"id":"x"}}]"#
        e.mediaData = Data(mixed.utf8)
        #expect(e.media == [.image(fileName: "a.jpg")]) // válidos preservados elemento a elemento
        e.media = e.media + [.image(fileName: "b.jpg")]
        #expect(e.media == [.image(fileName: "a.jpg"), .image(fileName: "b.jpg")])
        #expect(String(decoding: try #require(e.mediaData), as: UTF8.self).contains("hologram"))

        let item = MealItem(name: "Arroz", quantity: 100, unit: .grams)
        item.substitutionsData = Data(#"[{"future":true}]"#.utf8)
        #expect(item.substitutions.isEmpty)
        item.substitutions = [MealSubstitution(name: "Macarrão", quantity: 80, unit: .grams)]
        #expect(item.substitutions.map(\.name) == ["Macarrão"])
        #expect(String(decoding: try #require(item.substitutionsData), as: UTF8.self).contains("future"))
    }

    @Test func unknownCommaTokensSurviveRewrite() throws {
        let f = try PersistenceFixture()
        let e = try f.exercise("bench-press")
        e.primaryMusclesRaw = "chest,neck"
        #expect(e.primaryMuscles == [.chest])
        e.primaryMuscles = [.back]
        #expect(e.primaryMusclesRaw == "back,neck")

        let routine = Routine(name: "R", weekdays: [.monday])
        routine.weekdaysRaw = "monday,holiday"
        #expect(routine.weekdays == [.monday])
        routine.weekdays = [.friday]
        #expect(routine.weekdaysRaw == "friday,holiday")
    }
}

@MainActor
struct CatalogSeedVersionTests {
    func freshDefaults() -> UserDefaults {
        let name = "fitjourney.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func deletedBuiltInIsNotResurrected() throws {
        let f = try PersistenceFixture(seed: false)
        let defaults = freshDefaults()
        #expect(try ExerciseCatalogSeeder.seedIfNeeded(in: f.context, defaults: defaults) == ExerciseCatalog.all.count)
        #expect(defaults.integer(forKey: ExerciseCatalogSeeder.versionKey) == ExerciseCatalog.version)
        f.context.delete(try f.exercise("bench-press"))
        try f.context.save()
        #expect(try ExerciseCatalogSeeder.seedIfNeeded(in: f.context, defaults: defaults) == 0)
        #expect(try f.count(Exercise.self) == ExerciseCatalog.all.count - 1)
    }

    @Test func versionBumpInsertsOnlyNewKeys() throws {
        let f = try PersistenceFixture(seed: false)
        let defaults = freshDefaults()
        try ExerciseCatalogSeeder.seedIfNeeded(in: f.context, defaults: defaults)
        f.context.delete(try f.exercise("bench-press"))
        try f.context.save()

        let newItem = CatalogExercise(key: "sled-push", name: "Empurrar trenó", nameEN: "Sled Push",
                                      primary: [.quads], equipment: .other, addedInVersion: ExerciseCatalog.version + 1)
        let inserted = try ExerciseCatalogSeeder.seedIfNeeded(in: f.context, defaults: defaults,
                                                              catalog: ExerciseCatalog.all + [newItem],
                                                              version: ExerciseCatalog.version + 1)
        #expect(inserted == 1)
        #expect(try f.count(Exercise.self) == ExerciseCatalog.all.count) // -1 apagado +1 novo
        #expect(defaults.integer(forKey: ExerciseCatalogSeeder.versionKey) == ExerciseCatalog.version + 1)
    }
}

@MainActor
struct ReviewFixesStoreTests {
    @Test func personalRecordsUseRealHistoryAndSubstitution() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // 1ª sessão: supino 3×10×30 (+ aquecimento).
        let s1 = try f.sessions.start(routine: routine, at: t0)
        for log in try #require(s1.sortedExercises.first).sortedSets { try f.sessions.completeSet(log, reps: 10) }
        try f.sessions.finish(s1, at: t0.addingTimeInterval(1_800))

        // 2ª: supino trocado por halteres, carga alta — não pode contar como histórico do supino.
        let s2 = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(86_400))
        let swapped = try #require(s2.sortedExercises.first)
        try f.sessions.substitute(swapped, with: try f.exercise("dumbbell-bench-press"))
        for log in swapped.sortedSets { try f.sessions.completeSet(log, reps: 10, load: .kg(50)) }
        #expect(try f.sessions.summary(for: s2).personalRecords.isEmpty) // halteres sem histórico
        try f.sessions.finish(s2, at: t0.addingTimeInterval(88_000))

        // 3ª: supino a 31 kg → recorde vs. 30 (não vs. 50 dos halteres).
        let s3 = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(2 * 86_400))
        for log in try #require(s3.sortedExercises.first).sortedSets.dropFirst() {
            try f.sessions.completeSet(log, reps: 10, load: .kg(31))
        }
        let records = try f.sessions.summary(for: s3).personalRecords
        let heaviest = try #require(records.first { $0.kind == .heaviestLoad })
        #expect(heaviest.valueKg == 31 && heaviest.previousKg == 30)
        let bench = try f.exercise("bench-press").id
        #expect(try f.sessions.lastPerformance(exerciseID: bench)?.session?.id == s1.id)
        #expect(try f.sessions.lastPerformance(exerciseID: bench, before: t0)?.session == nil)
    }

    @Test func sameExerciseTwiceInOneSessionCountsAsOneSessionVolume() throws {
        let f = try PersistenceFixture()
        let bench = try f.exercise("bench-press")
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let s1 = try f.sessions.start(routine: nil, at: t0)
        for _ in 0..<2 {
            let item = try f.sessions.addExercise(bench, to: s1, setCount: 1)
            for log in item.sortedSets { try f.sessions.completeSet(log, reps: 10, load: .kg(30)) }
        }
        try f.sessions.finish(s1, at: t0.addingTimeInterval(600))

        let s2 = try f.sessions.start(routine: nil, at: t0.addingTimeInterval(86_400))
        let item = try f.sessions.addExercise(bench, to: s2, setCount: 2)
        for log in item.sortedSets { try f.sessions.completeSet(log, reps: 10, load: .kg(30)) }
        // 600 kg em ambas: sem recorde de volume (antes contaria 300 por entrada).
        #expect(try f.sessions.summary(for: s2).personalRecords.isEmpty)
    }

    @Test func discardAndFinishRequireInProgress() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let s = try f.sessions.start(routine: routine)
        try f.sessions.finish(s, mood: 9)
        #expect(s.mood == 5)
        #expect(throws: SessionStoreError.sessionNotInProgress) { try f.sessions.finish(s) }
        #expect(throws: SessionStoreError.sessionNotInProgress) { try f.sessions.discard(s) }
        #expect(try f.count(WorkoutSession.self) == 1)

        let s2 = try f.sessions.start(routine: routine)
        try f.sessions.discard(s2)
        #expect(try f.sessions.inProgressSession() == nil)
        #expect(try f.sessions.completedSessions().count == 1)
        try f.sessions.finish(try f.sessions.start(routine: nil), mood: 0)
        #expect(try f.sessions.completedSessions().first?.mood == 1)
    }

    @Test func deletingRoutineDuringSessionKeepsSessionWorking() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        f.context.delete(routine)
        try f.context.save()
        #expect(try f.count(SetPrescription.self) == 0)

        let current = try #require(try f.sessions.inProgressSession())
        #expect(current.routine == nil && current.routineName == "A")
        let logs = try #require(current.sortedExercises.first).sortedSets
        #expect(logs.count == 4)
        for log in logs { try f.sessions.completeSet(log, reps: 10, load: .kg(40)) }
        #expect(try f.sessions.loadProposals(for: session).isEmpty) // prescrições não existem mais
        try f.sessions.finish(session, applying: [])
        #expect(session.status == .completed)
    }

    @Test func sequentialSuggestionAfterLastRoutineDeleted() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "ABC", scheduleMode: .sequential, activate: true)
        let a = try f.programs.addRoutine(to: program, name: "A")
        let b = try f.programs.addRoutine(to: program, name: "B")
        let c = try f.programs.addRoutine(to: program, name: "C")
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (i, r) in [a, b].enumerated() {
            let s = try f.sessions.start(routine: r, at: t0.addingTimeInterval(Double(i) * 86_400))
            try f.sessions.finish(s, at: t0.addingTimeInterval(Double(i) * 86_400 + 600))
        }
        #expect(try f.programs.todaySuggestion(for: program) == .routine(c.id))
        f.context.delete(b)
        try f.context.save()
        // Âncora (B) apagada → fallback: A é a mais recente que resta → próxima é C.
        #expect(try f.programs.todaySuggestion(for: program) == .routine(c.id))
        // C concluída → volta para A.
        try f.sessions.finish(try f.sessions.start(routine: c, at: t0.addingTimeInterval(3 * 86_400)))
        #expect(try f.programs.todaySuggestion(for: program) == .routine(a.id))
    }

    @Test func markMealDoneClampsTimeToTargetDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let f = try PersistenceFixture(seed: false)
        let store = NutritionStore(context: f.context, calendar: cal)
        let meal = Meal(name: "Almoço", minutesFromMidnight: 12 * 60)
        f.context.insert(meal)
        let item = MealItem(name: "Arroz", quantity: 100, unit: .grams, values: NutrientValues(kcal: 130))
        f.context.insert(item)
        item.meal = meal
        let target = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 8))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 13, minute: 15))!
        let entries = try store.markMealDone(meal, on: target, at: otherDay)
        let date = try #require(entries.first?.date)
        #expect(cal.isDate(date, inSameDayAs: target))
        #expect(cal.component(.hour, from: date) == 13 && cal.component(.minute, from: date) == 15)
        #expect(try store.entries(on: target).count == 1)
        #expect(try store.entries(on: otherDay).isEmpty)
    }

    @Test func mealTimeRespectsDaylightSaving() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let dstStart = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9))! // relógio adianta às 2h
        let meal = Meal(name: "Almoço", minutesFromMidnight: 12 * 60 + 30)
        let time = meal.time(on: dstStart, calendar: cal)
        #expect(cal.component(.hour, from: time) == 12 && cal.component(.minute, from: time) == 30)
        #expect(cal.isDate(time, inSameDayAs: dstStart))
    }
}
