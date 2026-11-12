import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// P1.5 — copiar ficha para outro programa (DESIGN §4.2.1).
@MainActor
struct RoutineCopyTests {
    private struct Boom: Error {}

    /// Origem com a ficha "Costas e bíceps": remada 1+3 séries, rosca (bi-set com a remada alta) e um solto.
    private func makeSource(_ f: PersistenceFixture, mode: ScheduleMode = .weekly)
        throws -> (program: TrainingProgram, routine: Routine) {
        let program = try f.programs.createProgram(name: "Origem", scheduleMode: mode, activate: true)
        let routine = try f.programs.addRoutine(to: program, name: "Costas e bíceps", symbol: "B",
                                                weekdays: [.tuesday, .friday])
        routine.colorName = "teal"
        routine.notes = "Foco na descida"
        let bi = UUID()
        let row = try f.programs.addExercise(try f.exercise("bench-press"), to: routine, setCount: 3,
                                             repTarget: .range(min: 8, max: 12), load: .kg(40), restSeconds: 90, groupID: bi)
        row.notes = "Pausa de 1 s"
        row.sortedSets.first?.tempo = "3-1-1-0"
        try f.programs.addExercise(try f.exercise("bench-press"), to: routine, setCount: 2,
                                   repTarget: .fixed(reps: 12), load: .kg(15), restSeconds: 60, groupID: bi)
        try f.programs.addExercise(try f.exercise("bench-press"), to: routine, setCount: 4,
                                   repTarget: .fixed(reps: 5), load: .kg(60))
        try f.context.save()
        return (program, routine)
    }

    private func counts(_ f: PersistenceFixture) throws -> (routines: Int, items: Int, sets: Int) {
        (try f.count(Routine.self), try f.count(RoutineExercise.self), try f.count(SetPrescription.self))
    }

    // MARK: Cópia profunda

    @Test func copyIsDeepAndLeavesTheOriginalUntouched() throws {
        let f = try PersistenceFixture()
        let (source, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .sequential)
        let before = try counts(f)
        let originalItems = routine.sortedExercises.map(\.persistentModelID)
        let originalSets = routine.sortedExercises.flatMap(\.sortedSets).map(\.persistentModelID)

        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)

        let after = try counts(f)
        #expect(after.routines == before.routines + 1)
        #expect(after.items == before.items * 2)
        #expect(after.sets == before.sets * 2)

        #expect(copy !== routine)
        #expect(copy.program === target)
        #expect(copy.symbol == "B" && copy.colorName == "teal" && copy.notes == "Foco na descida")
        #expect(copy.sortedExercises.count == routine.sortedExercises.count)
        for (a, b) in zip(routine.sortedExercises, copy.sortedExercises) {
            #expect(a !== b)
            #expect(a.exercise === b.exercise) // catálogo é referenciado, não duplicado
            #expect(a.sortIndex == b.sortIndex && a.restSeconds == b.restSeconds && a.notes == b.notes)
            #expect(a.sortedSets.count == b.sortedSets.count)
            for (x, y) in zip(a.sortedSets, b.sortedSets) {
                #expect(x !== y)
                #expect(x.kind == y.kind && x.repTarget == y.repTarget && x.restSeconds == y.restSeconds)
                #expect(x.effectiveLoad == y.effectiveLoad && x.tempo == y.tempo)
            }
        }
        #expect(copy.sortedExercises[0].sortedSets.first?.tempo == "3-1-1-0")

        // Original e programa de origem: os mesmos objetos, ordem e valores.
        #expect(routine.program === source)
        #expect(source.sortedRoutines.count == 1)
        #expect(routine.sortedExercises.map(\.persistentModelID) == originalItems)
        #expect(routine.sortedExercises.flatMap(\.sortedSets).map(\.persistentModelID) == originalSets)
        #expect(routine.name == "Costas e bíceps")
        #expect(routine.weekdays == [.tuesday, .friday])
    }

    @Test func editingTheCopyDoesNotChangeTheOriginal() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)

        copy.sortedExercises[0].sortedSets[0].initialLoad = .kg(99)
        copy.sortedExercises[0].restSeconds = 5
        copy.symbol = "Z"
        try f.context.save()

        #expect(routine.sortedExercises[0].sortedSets[0].initialLoad == .kg(40))
        #expect(routine.sortedExercises[0].restSeconds == 90)
        #expect(routine.symbol == "B")
    }

    @Test func currentLoadBecomesInitialLoadLikeDuplicate() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let set = try #require(routine.sortedExercises[0].sortedSets.first)
        set.currentLoad = .kg(47.5)
        try f.context.save()
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)

        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)

        let copied = try #require(copy.sortedExercises[0].sortedSets.first)
        #expect(copied.initialLoad == .kg(47.5))
        #expect(copied.currentLoad == nil)
    }

    @Test func biSetGetsANewGroupIDAndKeepsTheGrouping() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)

        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)

        let original = routine.sortedExercises.map(\.groupID)
        let copied = copy.sortedExercises.map(\.groupID)
        let originalGroup = try #require(original[0])
        let copiedGroup = try #require(copied[0])
        #expect(original[1] == originalGroup && original[2] == nil)
        #expect(copied[1] == copiedGroup && copied[2] == nil)   // continua um bi-set
        #expect(copiedGroup != originalGroup)                    // mas com identidade própria
    }

    @Test func twoCopiesOfTheSameRoutineDoNotShareGroups() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let first = try f.programs.copyRoutines([routine], to: target)
        let second = try f.programs.copyRoutines([routine], to: target)
        let groups = Set((first + second + [routine]).compactMap { $0.sortedExercises.first?.groupID })
        #expect(groups.count == 3)
    }

    // MARK: Ordem, dias e destino

    @Test func entersAtTheEndInTheRequestedOrder() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let other = try f.programs.addRoutine(to: routine.program!, name: "Pernas", symbol: "C")
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .sequential)
        try f.programs.addRoutine(to: target, name: "A", symbol: "A")
        try f.programs.addRoutine(to: target, name: "B", symbol: "B")

        // Ordem pedida (Pernas antes de Costas), não a da origem.
        let copies = try f.programs.copyRoutines([other, routine], to: target)

        #expect(copies.map(\.name) == ["Pernas", "Costas e bíceps"])
        #expect(target.sortedRoutines.map(\.name) == ["A", "B", "Pernas", "Costas e bíceps"])
        #expect(target.sortedRoutines.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test func entersAtTheEndEvenWithGapsInSortIndex() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let existing = try f.programs.addRoutine(to: target, name: "A", symbol: "A")
        existing.sortIndex = 7
        try f.context.save()
        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)
        #expect(copy.sortIndex == 8)
        #expect(target.sortedRoutines.last === copy)
    }

    @Test func weeklyDestinationAppliesTheChosenDays() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let other = try f.programs.addRoutine(to: routine.program!, name: "Pernas", symbol: "C", weekdays: [.monday])
        let target = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly)

        let copies = try f.programs.copyRoutines(
            [routine, other], to: target,
            weekdays: [routine.id: [.wednesday], other.id: []])  // vazio é uma escolha válida

        #expect(copies[0].weekdays == [.wednesday])
        #expect(copies[1].weekdays.isEmpty)
        #expect(routine.weekdays == [.tuesday, .friday])          // a original não muda
    }

    @Test func weeklyDestinationWithoutChoiceSuggestsTheOriginalDays() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f, mode: .weekly)
        let target = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly)
        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)
        #expect(copy.weekdays == [.tuesday, .friday])
    }

    @Test func busyDaysAreAllowed() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly)
        try f.programs.addRoutine(to: target, name: "A", symbol: "A", weekdays: [.tuesday])
        let copy = try #require(try f.programs.copyRoutines([routine], to: target, weekdays: [routine.id: [.tuesday]]).first)
        #expect(copy.weekdays == [.tuesday])
    }

    @Test func nonWeeklyDestinationIgnoresDays() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f, mode: .weekly)
        for mode in [ScheduleMode.free, .sequential] {
            let target = try f.programs.createProgram(name: "Destino \(mode.rawValue)", scheduleMode: mode)
            let copy = try #require(try f.programs.copyRoutines([routine], to: target, weekdays: [routine.id: [.monday]]).first)
            #expect(copy.weekdays.isEmpty)
        }
    }

    @Test func weeklyDestinationFromANonWeeklyOriginStartsWithoutDays() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f, mode: .sequential) // dias herdados de um modo antigo não valem
        let target = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly)
        let copy = try #require(try f.programs.copyRoutines([routine], to: target).first)
        #expect(copy.weekdays.isEmpty)
    }

    @Test func archivedAndPastProgramsReceiveCopies() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let archived = try f.programs.createProgram(name: "Arquivado", scheduleMode: .free)
        try f.programs.archive(archived)
        let copy = try #require(try f.programs.copyRoutines([routine], to: archived).first)
        #expect(copy.program === archived)
        #expect(archived.isArchived)
    }

    @Test func copyingNothingDoesNothing() throws {
        let f = try PersistenceFixture()
        let target = try f.programs.createProgram(name: "Destino")
        #expect(try f.programs.copyRoutines([], to: target).isEmpty)
    }

    // MARK: Nome

    @Test func repeatedNameGetsNumberedButLetterAndColorStay() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let twin = try f.programs.addRoutine(to: target, name: " costas e BICEPS ", symbol: "X")

        let first = try #require(try f.programs.copyRoutines([routine], to: target).first)
        let second = try #require(try f.programs.copyRoutines([routine], to: target).first)

        #expect(twin.name == " costas e BICEPS ")
        #expect(first.name == "Costas e bíceps (2)")
        #expect(second.name == "Costas e bíceps (3)")
        #expect(first.symbol == "B" && first.colorName == "teal")
    }

    @Test func severalCopiesInOneGoCountTheOnesAboveThem() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let twin = try f.programs.addRoutine(to: routine.program!, name: "Costas e bíceps", symbol: "B")
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let copies = try f.programs.copyRoutines([routine, twin], to: target)
        #expect(copies.map(\.name) == ["Costas e bíceps", "Costas e bíceps (2)"])
    }

    @Test func namingRuleIsPureAndTolerant() {
        #expect(RoutineNaming.uniqueName("Peito", among: ["A"]) == "Peito")
        #expect(RoutineNaming.uniqueName("Peito", among: ["Peito"]) == "Peito (2)")
        #expect(RoutineNaming.uniqueName("Peito", among: ["Peito", "Peito (2)"]) == "Peito (3)")
        #expect(RoutineNaming.uniqueName("Peito (2)", among: ["Peito", "Peito (2)"]) == "Peito (3)")
        #expect(RoutineNaming.uniqueName("Peito (2)", among: ["Peito (2)", "Peito (3)"]) == "Peito (4)")
        #expect(RoutineNaming.uniqueName("Peito (2)", among: ["Peito"]) == "Peito (2)") // sem repetição, intacto
        // Sem caixa, sem acento, sem espaços nas pontas.
        #expect(RoutineNaming.uniqueName("Bíceps", among: ["  BICEPS "]) == "Bíceps (2)")
        #expect(RoutineNaming.uniqueName("Peito", among: ["peito (2)", "PEITO"]) == "Peito (3)")
        // Sufixo que não é número não conta; só "(n)" no fim.
        #expect(RoutineNaming.uniqueName("Peito (leve)", among: ["Peito (leve)"]) == "Peito (leve) (2)")
        #expect(RoutineNaming.uniqueName("(2)", among: ["(2)"]) == "(2) (2)")
        #expect(RoutineNaming.uniqueName("Peito (2) ", among: ["Peito (2)"]) == "Peito (3)")
    }

    @Test func hugeNumericSuffixNeverOverflows() {
        let max = "Peito (\(Int.max))"
        #expect(RoutineNaming.uniqueName(max, among: [max]) == "\(max) (2)")
        #expect(RoutineNaming.uniqueName("Peito (999999999)", among: ["Peito (999999999)"]) == "Peito (1000000000)")
        #expect(RoutineNaming.uniqueName("Peito (1234567890)", among: ["Peito (1234567890)"]) == "Peito (1234567890) (2)")
    }

    @Test func namingRuleCountsPreviousNamesOfTheSameBatch() {
        #expect(RoutineNaming.uniqueNames(["Peito", "Peito", "Costas", "Peito"], among: ["Peito"])
                == ["Peito (2)", "Peito (3)", "Costas", "Peito (4)"])
    }

    // MARK: Treino em andamento

    @Test func sessionInProgressInTheDestinationBlocksEverything() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let (target, targetRoutine, _) = try f.makeProgram(name: "Destino", activate: false)
        let session = try f.sessions.start(routine: targetRoutine)
        let before = try counts(f)

        #expect(throws: ProgramStoreError.sessionInProgress(routineName: session.routineName)) {
            try f.programs.copyRoutines([routine], to: target)
        }

        let after = try counts(f)
        #expect(after.routines == before.routines && after.items == before.items && after.sets == before.sets)
        #expect(target.sortedRoutines.count == 1)
    }

    @Test func sessionInProgressOnTheSourceDoesNotBlock() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        _ = try f.sessions.start(routine: routine)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let copies = try f.programs.copyRoutines([routine], to: target)
        #expect(copies.count == 1)
    }

    @Test func sessionInAnotherProgramDoesNotBlockTheDestination() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        _ = try f.sessions.start(routine: routine)
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .free)
        let third = try f.programs.createProgram(name: "Terceiro", scheduleMode: .free)
        #expect(try f.programs.copyRoutines([routine], to: third).count == 1)
        #expect(target.sortedRoutines.isEmpty)
    }

    // MARK: Atomicidade

    @Test func failureLeavesNothingBehind() throws {
        let f = try PersistenceFixture()
        let (_, routine) = try makeSource(f)
        let other = try f.programs.addRoutine(to: routine.program!, name: "Pernas", symbol: "C")
        let target = try f.programs.createProgram(name: "Destino", scheduleMode: .weekly)
        try f.programs.addRoutine(to: target, name: "A", symbol: "A", weekdays: [.monday])
        let before = try counts(f)
        let targetUpdatedAt = target.updatedAt
        let bench = try f.exercise("bench-press")
        let linksBefore = bench.routineExercises?.count ?? 0
        try f.context.save()
        #expect(!f.context.hasChanges)

        #expect(throws: Boom.self) {
            try f.programs.copyRoutines([routine, other], to: target) { _ in throw Boom() }
        }

        let after = try counts(f)
        #expect(after.routines == before.routines)
        #expect(after.items == before.items)
        #expect(after.sets == before.sets)
        #expect(target.sortedRoutines.map(\.name) == ["A"])
        #expect(target.updatedAt == targetUpdatedAt)
        // O catálogo não guarda itens fantasmas, e o contexto não fica sujo.
        #expect(bench.routineExercises?.count == linksBefore)
        #expect(bench.routineExercises?.allSatisfy { $0.routine != nil } == true)
        #expect(!f.context.hasChanges)
        // E uma nova tentativa funciona normalmente.
        #expect(try f.programs.copyRoutines([routine, other], to: target).count == 2)
        #expect(target.sortedRoutines.count == 3)
    }

    // MARK: Apresentação

    @Test func destinationsAreOrderedActiveThenPastThenArchived() throws {
        let f = try PersistenceFixture()
        let old = try f.programs.createProgram(name: "Antigo", startDate: Date(timeIntervalSince1970: 1_000))
        let recent = try f.programs.createProgram(name: "Recente", startDate: Date(timeIntervalSince1970: 9_000))
        let archived = try f.programs.createProgram(name: "Arquivado", startDate: Date(timeIntervalSince1970: 5_000))
        try f.programs.archive(archived)
        let active = try f.programs.createProgram(name: "Ativo", startDate: Date(timeIntervalSince1970: 2_000), activate: true)
        let source = try f.programs.createProgram(name: "Origem", startDate: Date(timeIntervalSince1970: 3_000))

        // A consulta da folha vem da mais recente para a mais antiga.
        let queried = [recent, source, archived, active, old]
        let ordered = RoutineCopyLogic.orderedPrograms(queried, excluding: source)
        #expect(ordered.map(\.name) == ["Ativo", "Recente", "Antigo", "Arquivado"])
    }

    @Test func busyDaysNameTheRoutinesThatHoldThem() throws {
        let f = try PersistenceFixture()
        let target = try f.programs.createProgram(name: "Semanal", scheduleMode: .weekly)
        try f.programs.addRoutine(to: target, name: "B — Costas", symbol: "B", weekdays: [.tuesday])
        let used = RoutineCopyLogic.usedDays(destination: target, others: [(name: "C — Pernas", days: [.tuesday, .friday])])
        #expect(used[.tuesday] == ["B — Costas", "C — Pernas"])
        #expect(used[.friday] == ["C — Pernas"])
        #expect(RoutineCopyLogic.conflictText(days: [.wednesday], used: used) == nil)
        let text = try #require(RoutineCopyLogic.conflictText(days: [.tuesday], used: used))
        #expect(text.contains("B — Costas") && text.contains("C — Pernas"))
    }

    @Test func duplicateRoutineStillWorksWithTheSharedCloner() throws {
        let f = try PersistenceFixture()
        let (program, routine) = try makeSource(f)
        let copy = try RoutineActions(context: f.context).duplicate(routine)
        #expect(copy.name == "Costas e bíceps (cópia)")
        #expect(copy.weekdays.isEmpty)
        #expect(program.sortedRoutines.map(\.name) == ["Costas e bíceps", "Costas e bíceps (cópia)"])
        #expect(copy.sortedExercises.count == 3)
        #expect(copy.sortedExercises[0].groupID != routine.sortedExercises[0].groupID)
    }
}
