import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct PersistenceFixture {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var programs: ProgramStore { ProgramStore(context: context) }
    var sessions: SessionStore { SessionStore(context: context) }

    init(seed: Bool = true) throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        if seed { try ExerciseCatalogSeeder.seedIfNeeded(in: container.mainContext) }
    }

    func exercise(_ key: String) throws -> Exercise {
        let k: String? = key
        return try #require(try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.catalogKey == k })).first)
    }

    func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// Programa com uma ficha "A": supino 1 aquecimento + 3 válidas a 30 kg.
    func makeProgram(name: String = "P", activate: Bool = true) throws -> (TrainingProgram, Routine, RoutineExercise) {
        let program = try programs.createProgram(name: name, activate: activate)
        let routine = try programs.addRoutine(to: program, name: "A", symbol: "A")
        let bench = try programs.addExercise(try exercise("bench-press"), to: routine, setCount: 3,
                                             repTarget: .range(min: 8, max: 12), load: .kg(30), restSeconds: 90)
        let warmup = SetPrescription(sortIndex: -1, kind: .warmup, repTarget: .fixed(reps: 15), initialLoad: .kg(20))
        context.insert(warmup)
        warmup.routineExercise = bench
        try context.save()
        return (program, routine, bench)
    }
}

@MainActor
struct CatalogSeedTests {
    @Test func seedIsIdempotent() throws {
        let f = try PersistenceFixture(seed: false)
        let first = try ExerciseCatalogSeeder.seedIfNeeded(in: f.context)
        #expect(first == ExerciseCatalog.all.count)
        #expect(first >= 55)
        #expect(try ExerciseCatalogSeeder.seedIfNeeded(in: f.context) == 0)
        #expect(try f.count(Exercise.self) == ExerciseCatalog.all.count)
    }

    @Test func catalogKeysAreUnique() {
        let keys = ExerciseCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(Set(ExerciseCatalog.all.map(\.name)).count == keys.count)
    }

    @Test func sampleDataLoads() throws {
        let f = try PersistenceFixture(seed: false)
        try SampleData.insert(into: f.context)
        let program = try #require(try f.programs.activeProgram())
        #expect(program.sortedRoutines.count == 3)
        #expect(try f.sessions.completedSessions().count == 1)
        let nutrition = NutritionStore(context: f.context)
        #expect(try nutrition.plannedMeals(on: .now).count == 5)
        // Sequencial: depois de A vem B.
        let suggestion = try f.programs.todaySuggestion(for: program)
        #expect(suggestion == .routine(program.sortedRoutines[1].id))
        // A sessão de exemplo atualizou a carga atual do supino para 32 kg.
        let bench = try #require(program.sortedRoutines[0].sortedExercises.first)
        #expect(bench.sortedSets.filter { $0.kind.isWorking }.allSatisfy { $0.currentLoad == .kg(32) })
    }
}

@MainActor
struct ProgramStoreTests {
    @Test func onlyOneActiveProgram() throws {
        let f = try PersistenceFixture()
        let p1 = try f.programs.createProgram(name: "1", activate: true)
        let p2 = try f.programs.createProgram(name: "2", activate: true)
        #expect(!p1.isActive && p2.isActive)
        try f.programs.activate(p1)
        let active = try f.context.fetch(FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.isActive }))
        #expect(active.map(\.name) == ["1"])
        #expect(try f.programs.activeProgram()?.name == "1")
        #expect(try f.programs.pastPrograms().map(\.name) == ["2"])
    }

    @Test func deletingProgramCascadesButKeepsSessionsAndCatalog() throws {
        let f = try PersistenceFixture()
        let (program, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        try f.sessions.finish(session)
        let catalogCount = try f.count(Exercise.self)

        try f.programs.delete(program)
        #expect(try f.count(TrainingProgram.self) == 0)
        #expect(try f.count(Routine.self) == 0)
        #expect(try f.count(RoutineExercise.self) == 0)
        #expect(try f.count(SetPrescription.self) == 0)
        #expect(try f.count(Exercise.self) == catalogCount)
        let kept = try #require(try f.sessions.completedSessions().first)
        #expect(kept.routine == nil)
        #expect(kept.routineName == "A")
        #expect(try f.count(SetLog.self) == 4)
    }

    @Test func deletingSessionCascadesToLogs() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        try f.sessions.discard(session)
        #expect(try f.count(WorkoutSession.self) == 0)
        #expect(try f.count(SessionExercise.self) == 0)
        #expect(try f.count(SetLog.self) == 0)
        #expect(try f.count(Routine.self) == 1)
    }

    @Test func duplicateCopiesStructureWithCurrentLoadAsInitial() throws {
        let f = try PersistenceFixture()
        let (program, _, bench) = try f.makeProgram()
        bench.sortedSets.last?.currentLoad = .kg(35)
        let copy = try f.programs.duplicate(program, name: "Cópia")
        #expect(copy.origin == .duplicated && !copy.isActive)
        let copiedSets = try #require(copy.sortedRoutines.first?.sortedExercises.first?.sortedSets)
        #expect(copiedSets.count == 4)
        #expect(copiedSets.last?.initialLoad == .kg(35))
        #expect(copiedSets.last?.currentLoad == nil)
        #expect(try f.count(TrainingProgram.self) == 2)
    }

    @Test func weeklySuggestionUsesRoutineWeekdays() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "W", scheduleMode: .weekly, activate: true)
        let monday = try f.programs.addRoutine(to: program, name: "Seg", weekdays: [.monday])
        _ = try f.programs.addRoutine(to: program, name: "Qua", weekdays: [.wednesday])
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let mondayDate = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10))!
        #expect(try f.programs.todaySuggestion(for: program, on: mondayDate, calendar: cal) == .routines([monday.id]))
        #expect(try f.programs.todaySuggestion(for: program, on: mondayDate.addingTimeInterval(86_400), calendar: cal) == .rest)
    }

    @Test func storedEnumsAndValuesRoundTrip() throws {
        let f = try PersistenceFixture()
        let e = try f.exercise("pull-up")
        #expect(e.measurementKind == .repsOnly && e.equipment == .bodyweight && e.primaryMuscles == [.back])
        e.media = [.image(fileName: "x.jpg")]
        let routine = Routine(name: "R", weekdays: [.friday, .monday])
        f.context.insert(routine)
        try f.context.save()
        #expect(routine.weekdaysRaw == "monday,friday")
        #expect(e.media == [.image(fileName: "x.jpg")])
    }
}

@MainActor
struct SessionStoreTests {
    @Test func onlyOneSessionInProgress() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let s = try f.sessions.start(routine: routine)
        #expect(throws: SessionStoreError.sessionAlreadyInProgress) { try f.sessions.start(routine: nil) }
        #expect(try f.sessions.inProgressSession()?.id == s.id)
        try f.sessions.finish(s)
        let free = try f.sessions.start(routine: nil)
        #expect(free.routineName == "Treino livre")
        #expect(free.exercises?.isEmpty == true)
    }

    @Test func startSnapshotsPrescription() throws {
        let f = try PersistenceFixture()
        let (program, routine, bench) = try f.makeProgram()
        bench.sortedSets[1].currentLoad = .kg(31)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = try f.sessions.start(routine: routine, at: start)

        #expect(session.programID == program.id && session.routineID == routine.id)
        let exercise = try #require(session.sortedExercises.first)
        #expect(exercise.name == "Supino reto com barra")
        #expect(exercise.status == .pending)
        let logs = exercise.sortedSets
        #expect(logs.map(\.kind) == [.warmup, .working, .working, .working])
        #expect(logs.map(\.plannedLoad) == [.kg(20), .kg(31), .kg(30), .kg(30)])
        #expect(logs[1].repTarget == .range(min: 8, max: 12))
        #expect(logs[1].restSeconds == 90)
        #expect(session.clock.elapsed(at: start.addingTimeInterval(65)) == 65)
    }

    @Test func editingRoutineDoesNotChangeSnapshot() throws {
        let f = try PersistenceFixture()
        let (_, routine, bench) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        try f.sessions.finish(session)

        routine.name = "A editada"
        bench.exercise?.name = "Outro nome"
        for set in bench.sets ?? [] {
            set.initialLoad = .kg(99)
            set.currentLoad = .kg(99)
            set.repTarget = .fixed(reps: 3)
        }
        try f.context.save()

        let exercise = try #require(session.sortedExercises.first)
        #expect(session.routineName == "A")
        #expect(exercise.name == "Supino reto com barra")
        #expect(exercise.sortedSets.map(\.plannedLoad) == [.kg(20), .kg(30), .kg(30), .kg(30)])
        #expect(exercise.sortedSets[1].repTarget == .range(min: 8, max: 12))
    }

    @Test func completingSetsUpdatesStatusAndRest() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = try f.sessions.start(routine: routine, at: t0)
        let exercise = try #require(session.sortedExercises.first)
        let logs = exercise.sortedSets

        try f.sessions.completeSet(logs[1], at: t0.addingTimeInterval(100))
        #expect(logs[1].reps == nil)        // reps opcionais (D2): "feita dentro do alvo"
        #expect(logs[1].load == .kg(30))    // carga planejada
        #expect(logs[1].completedAt == t0.addingTimeInterval(100))
        #expect(exercise.status == .inProgress)
        #expect(session.clock.restRemaining(at: t0.addingTimeInterval(130)) == 60)

        try f.sessions.adjustRest(session, by: 15, at: t0.addingTimeInterval(130))
        #expect(session.clock.restRemaining(at: t0.addingTimeInterval(130)) == 75)
        try f.sessions.skipRest(session)
        #expect(session.restEndsAt == nil)

        for log in logs where !log.isCompleted { try f.sessions.completeSet(log, reps: 10, load: .kg(32)) }
        #expect(exercise.status == .completed)
        try f.sessions.uncompleteSet(logs[3])
        #expect(exercise.status == .inProgress)
        #expect(!logs[3].edited)
    }

    @Test func manualCompletionAndSkip() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        let exercise = try #require(session.sortedExercises.first)
        try f.sessions.completeSet(exercise.sortedSets[0])
        try f.sessions.completeExercise(exercise)
        #expect(exercise.status == .partial)
        try f.sessions.skipExercise(exercise, reason: .equipmentBusy)
        #expect(exercise.status == .skipped && exercise.skipReason == .equipmentBusy)
        let summary = try f.sessions.summary(for: session)
        #expect(summary.skippedExercises == ["Supino reto com barra"])
        #expect(summary.loadProposals.isEmpty)
    }

    @Test func finishAppliesConfirmedLoadUpdatesOnly() throws {
        let f = try PersistenceFixture()
        let (_, routine, bench) = try f.makeProgram()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = try f.sessions.start(routine: routine, at: t0)
        let logs = try #require(session.sortedExercises.first).sortedSets
        try f.sessions.completeSet(logs[0], at: t0.addingTimeInterval(60))
        for log in logs.dropFirst() { try f.sessions.completeSet(log, reps: 10, load: .kg(32), at: t0.addingTimeInterval(120)) }

        let summary = try f.sessions.summary(for: session, at: t0.addingTimeInterval(1_800))
        #expect(summary.durationSeconds == 1_800)
        #expect(summary.volumeKg == 3 * 10 * 32)
        #expect(summary.completedSets == 4 && summary.totalSets == 4)
        #expect(summary.personalRecords.isEmpty) // sem histórico
        #expect(summary.loadProposals.count == 3)
        #expect(summary.loadProposals.allSatisfy { $0.from == .kg(30) && $0.to == .kg(32) })

        // Usuário confirma só duas.
        try f.sessions.finish(session, at: t0.addingTimeInterval(1_800), sessionRPE: 12, mood: 4,
                              applying: Array(summary.loadProposals.prefix(2)))
        #expect(session.status == .completed)
        #expect(session.sessionRPE == 10) // limitado a 1–10
        #expect(session.clock.elapsed(at: .distantFuture) == 1_800)
        let working = bench.sortedSets.filter { $0.kind.isWorking }
        #expect(working.map(\.currentLoad) == [.kg(32), .kg(32), nil])
        #expect(working.allSatisfy { $0.initialLoad == .kg(30) }) // inicial nunca muda
        #expect(bench.sortedSets.first?.currentLoad == nil) // aquecimento intocado
        #expect(throws: SessionStoreError.sessionNotInProgress) { try f.sessions.finish(session) }

        // Editar série depois de encerrar marca "editado".
        try f.sessions.updateSet(logs[1], reps: 9, load: .kg(32))
        #expect(logs[1].edited)

        // Próxima sessão pré-preenche com a carga atual e detecta recorde.
        let next = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(86_400))
        let nextLogs = try #require(next.sortedExercises.first).sortedSets
        #expect(nextLogs.map(\.plannedLoad) == [.kg(20), .kg(32), .kg(32), .kg(30)])
        for log in nextLogs.dropFirst() { try f.sessions.completeSet(log, reps: 10, load: .kg(35)) }
        let records = try f.sessions.summary(for: next).personalRecords
        #expect(Set(records.map(\.kind)) == [.heaviestLoad, .bestVolume, .estimated1RM])
        #expect(try f.sessions.lastPerformance(exerciseID: try f.exercise("bench-press").id)?.session?.id == session.id)
    }

    @Test func extraSetsAddedExercisesAndSubstitution() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        let bench = try #require(session.sortedExercises.first)
        let extra = try f.sessions.addSet(to: bench)
        #expect(extra.prescriptionID == nil && extra.plannedLoad == .kg(30) && bench.sets?.count == 5)
        try f.sessions.removeSet(extra)
        #expect(bench.sets?.count == 4)

        let curl = try f.sessions.addExercise(try f.exercise("barbell-curl"), to: session, setCount: 2)
        #expect(curl.sortIndex == 1 && curl.sets?.count == 2)

        try f.sessions.substitute(bench, with: try f.exercise("dumbbell-bench-press"))
        #expect(bench.substitutedFromName == "Supino reto com barra")
        #expect(bench.name == "Supino reto com halteres")
        for log in bench.sortedSets { try f.sessions.completeSet(log, reps: 10, load: .kg(16)) }
        #expect(try f.sessions.loadProposals(for: session).isEmpty) // substituído não atualiza a ficha
    }

    @Test func pauseResumePersistsDates() throws {
        let f = try PersistenceFixture()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = try f.sessions.start(routine: nil, at: t0)
        try f.sessions.pause(session, at: t0.addingTimeInterval(60))
        #expect(session.pausedAt == t0.addingTimeInterval(60))
        try f.sessions.resume(session, at: t0.addingTimeInterval(120))
        #expect(session.accumulatedPauseSeconds == 60)
        #expect(session.clock.elapsed(at: t0.addingTimeInterval(300)) == 240)
    }
}

@MainActor
struct NutritionStoreTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }

    func makePlan(_ f: PersistenceFixture, activate: Bool = true) throws -> (NutritionPlan, Meal) {
        let store = NutritionStore(context: f.context, calendar: cal)
        let plan = NutritionPlan(name: "D")
        plan.targets = NutritionTargets(kcal: 2_000, protein: 150)
        f.context.insert(plan)
        let day = NutritionDay()
        f.context.insert(day)
        day.plan = plan
        let meal = Meal(name: "Almoço", minutesFromMidnight: 12 * 60)
        f.context.insert(meal)
        meal.day = day
        for (i, food) in [("Arroz", 300.0), ("Frango", 250.0)].enumerated() {
            let item = MealItem(name: food.0, quantity: 100, unit: .grams, values: NutrientValues(kcal: food.1, protein: 10), sortIndex: i)
            f.context.insert(item)
            item.meal = meal
        }
        if activate { try store.activate(plan) } else { try f.context.save() }
        return (plan, meal)
    }

    @Test func onlyOneActivePlan() throws {
        let f = try PersistenceFixture(seed: false)
        let store = NutritionStore(context: f.context, calendar: cal)
        let (p1, _) = try makePlan(f)
        let (p2, _) = try makePlan(f)
        #expect(!p1.isActive && p2.isActive)
        try store.activate(p1)
        #expect(try f.context.fetchCount(FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.isActive })) == 1)
        #expect(try store.activePlan()?.persistentModelID == p1.persistentModelID)
    }

    @Test func mealLifecycleAndTotals() throws {
        let f = try PersistenceFixture(seed: false)
        let store = NutritionStore(context: f.context, calendar: cal)
        let (_, meal) = try makePlan(f)
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18))!

        #expect(try store.plannedMeals(on: day).map(\.status) == [.pending])
        #expect(try store.totals(on: day).kcal == 0) // planejado não conta

        try store.markMealDone(meal, on: day)
        #expect(try store.plannedMeals(on: day).first?.status == .done)
        #expect(try store.totals(on: day).kcal == 550)

        try store.skipMeal(meal, on: day)
        #expect(try store.plannedMeals(on: day).first?.status == .skipped)
        #expect(try store.totals(on: day).kcal == 0)
        #expect(try store.totals(on: day).entryCount == 0)

        try store.logAdjustedMeal(meal, on: day, items: [("Arroz", 50, .grams, NutrientValues(kcal: 150))])
        #expect(try store.plannedMeals(on: day).first?.status == .adjusted)
        #expect(try store.totals(on: day).kcal == 150)

        try store.logFood(name: "Chocolate", quantity: 20, unit: .grams, values: NutrientValues(kcal: 110), at: day)
        try store.logFood(name: "Café", quantity: 1, unit: .unit, at: day)
        let totals = try store.totals(on: day)
        #expect(totals.kcal == 260 && totals.itemsWithoutKcal == 1)
        #expect(try store.entries(on: day).filter(\.isOffPlan).count == 2)
        // Outro dia não é afetado.
        #expect(try store.entries(on: day.addingTimeInterval(86_400)).isEmpty)

        try store.addWater(milliliters: 500, at: day)
        let progress = try store.progress(on: day)
        #expect(progress[.kcal]?.consumed == 260)
        #expect(progress[.water] == nil) // sem meta de água

        try store.resetMeal(meal, on: day)
        #expect(try store.plannedMeals(on: day).first?.status == .pending)
    }

    @Test func recentsAndFavorites() throws {
        let f = try PersistenceFixture(seed: false)
        let store = NutritionStore(context: f.context, calendar: cal)
        try store.logFood(name: "Açaí", quantity: 200, unit: .grams, values: NutrientValues(kcal: 250), at: .now.addingTimeInterval(-60))
        try store.logFood(name: "acai", quantity: 300, unit: .grams, at: .now)
        let recents = try store.recentFoods()
        #expect(recents.count == 1)
        #expect(recents.first?.useCount == 2)
        #expect(recents.first?.kcal == 250) // sem valores novos, mantém os conhecidos
        #expect(recents.first?.values(forQuantity: 600).kcal == 750)
        recents.first?.isFavorite = true
        #expect(try store.favoriteFoods().count == 1)
    }

    @Test func deletingPlanCascades() throws {
        let f = try PersistenceFixture(seed: false)
        let store = NutritionStore(context: f.context, calendar: cal)
        let (plan, meal) = try makePlan(f)
        try store.markMealDone(meal, on: .now)
        try store.delete(plan)
        #expect(try f.count(NutritionDay.self) == 0)
        #expect(try f.count(Meal.self) == 0)
        #expect(try f.count(MealItem.self) == 0)
        #expect(try f.count(FoodEntry.self) == 2) // registros do dia são histórico
    }
}
