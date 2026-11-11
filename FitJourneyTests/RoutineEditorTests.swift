import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
struct RoutineEditorTests {
    private func routineWithItems(_ f: PersistenceFixture, keys: [String]) throws -> (Routine, [RoutineExercise]) {
        let program = try f.programs.createProgram(name: "P")
        let routine = try f.programs.addRoutine(to: program, name: "A", symbol: "A")
        var items: [RoutineExercise] = []
        for key in keys { items.append(try f.programs.addExercise(try f.exercise(key), to: routine)) }
        return (routine, items)
    }

    // MARK: Padrões por tipo de medida

    @Test func defaultsByMeasurementKind() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "P")
        let routine = try f.programs.addRoutine(to: program, name: "A")
        let all = try f.context.fetch(FetchDescriptor<Exercise>())
        func first(_ k: MeasurementKind) throws -> Exercise { try #require(all.first { $0.measurementKind == k }) }

        let reps = RoutineEditorOps.add([try first(.repsAndLoad)], to: routine, context: f.context)[0]
        #expect(reps.sortedSets.count == 3)
        #expect(reps.sortedSets.allSatisfy { $0.repTarget == .range(min: 8, max: 12) })

        let iso = RoutineEditorOps.add([try first(.isometric)], to: routine, context: f.context)[0]
        #expect(iso.sortedSets.count == 3)
        #expect(iso.sortedSets.allSatisfy { $0.holdSeconds == 30 && $0.repTarget == nil })

        let cardio = RoutineEditorOps.add([try first(.timeOrDistance)], to: routine, context: f.context)[0]
        #expect(cardio.sortedSets.count == 1)
        #expect(cardio.sortedSets[0].cardio?.durationSeconds == 1200)

        let bw = RoutineEditorOps.add([try first(.repsOnly)], to: routine, context: f.context)[0]
        #expect(bw.sortedSets[0].initialLoad == .bodyweight(delta: 0, unit: .kg))
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1, 2, 3])
    }

    // MARK: Ordem

    @Test func moveAndReindex() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        RoutineEditorOps.move(items[2], by: -2, context: f.context)
        #expect(routine.sortedExercises.map(\.id) == [items[2].id, items[0].id, items[1].id])
        #expect(!RoutineEditorOps.canMove(items[2], by: -1))
        RoutineEditorOps.move(in: routine, from: IndexSet(integer: 0), to: 3, context: f.context)
        #expect(routine.sortedExercises.map(\.id) == [items[0].id, items[1].id, items[2].id])
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func deleteReindexesAndDissolvesLoneGroup() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        RoutineEditorOps.group(selected: [items[0].id, items[1].id], in: routine, context: f.context)
        RoutineEditorOps.delete(items[0], context: f.context)
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1])
        #expect(items[1].groupID == nil)
    }

    // MARK: Agrupamento

    @Test func groupRequiresConsecutiveItems() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        #expect(!RoutineEditorOps.canGroup(selected: [items[0].id], in: routine))
        #expect(!RoutineEditorOps.canGroup(selected: [items[0].id, items[2].id], in: routine))
        #expect(RoutineEditorOps.canGroup(selected: [items[1].id, items[2].id], in: routine))
        RoutineEditorOps.group(selected: [items[0].id, items[2].id], in: routine, context: f.context)
        #expect(items.allSatisfy { $0.groupID == nil })
        RoutineEditorOps.group(selected: [items[0].id, items[1].id, items[2].id], in: routine, context: f.context)
        #expect(Set(items.compactMap(\.groupID)).count == 1)
        #expect(GroupLabel.name(forCount: 2) == "Bi-set")
        #expect(GroupLabel.name(forCount: 3) == "Tri-set")
        #expect(GroupLabel.name(forCount: 5) == "Circuito")
        let gid = try #require(items[0].groupID)
        RoutineEditorOps.ungroup(gid, in: routine, context: f.context)
        #expect(items.allSatisfy { $0.groupID == nil })
    }

    @Test func draggingOutOfGroupSplitsIt() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        RoutineEditorOps.group(selected: [items[0].id, items[1].id], in: routine, context: f.context)
        // arrasta o 1º para o fim: o grupo perde um membro e se dissolve
        RoutineEditorOps.move(in: routine, from: IndexSet(integer: 0), to: 3, context: f.context)
        #expect(items.allSatisfy { $0.groupID == nil })
    }

    // MARK: Duplicar / mover / copiar

    @Test func duplicateKeepsPrescriptionAndInsertsBelow() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck"])
        items[0].sortedSets[0].initialLoad = .kg(30)
        items[0].sortedSets[0].currentLoad = .kg(34)
        let copy = try #require(RoutineEditorOps.duplicate(items[0], context: f.context))
        #expect(routine.sortedExercises.map(\.id) == [items[0].id, copy.id, items[1].id])
        #expect(copy.sortedSets.count == 3)
        #expect(copy.sortedSets[0].initialLoad == .kg(30))
        #expect(copy.sortedSets[0].currentLoad == .kg(34))
    }

    @Test func moveAndCopyToAnotherRoutine() throws {
        let f = try PersistenceFixture()
        let (a, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck"])
        let b = try f.programs.addRoutine(to: try #require(a.program), name: "B")
        items[0].sortedSets[0].initialLoad = .kg(30)
        items[0].sortedSets[0].currentLoad = .kg(34)

        RoutineEditorOps.transfer(items[0], to: b, copy: true, context: f.context)
        #expect(a.sortedExercises.count == 2)
        let copied = try #require(b.sortedExercises.first)
        #expect(copied.sortedSets[0].initialLoad == .kg(34))
        #expect(copied.sortedSets[0].currentLoad == nil)

        RoutineEditorOps.transfer(items[1], to: b, copy: false, context: f.context)
        #expect(a.sortedExercises.map(\.id) == [items[0].id])
        #expect(b.sortedExercises.count == 2)
        #expect(b.sortedExercises.map(\.sortIndex) == [0, 1])
    }

    // MARK: Rascunho de prescrição

    @Test func blockToPerSetKeepsDataAndPerSetToBlockNeedsEqualSets() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        var draft = PrescriptionDraft(items[0])
        #expect(draft.isUniform)
        draft.resize(to: 5)
        #expect(draft.sets.count == 5)
        draft.sets[0].kind = .warmup
        #expect(!draft.isUniform)
        #expect(draft.initialMode == .perSet)
        draft.makeUniform()
        #expect(draft.isUniform)
        #expect(draft.sets.allSatisfy { $0.kind == .warmup })
        draft.resize(to: 2)
        #expect(draft.sets.count == 2)
    }

    @Test func applyPersistsAddsAndRemovesSets() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        var draft = PrescriptionDraft(items[0])
        draft.resize(to: 4)
        draft.template.repTarget = .fixed(reps: 5)
        draft.notes = "banco 30°"
        draft.exerciseRest = 120
        draft.apply(to: items[0], context: f.context)
        draft.apply(to: items[0], context: f.context) // idempotente
        #expect(items[0].sortedSets.count == 4)
        #expect(items[0].sortedSets.allSatisfy { $0.repTarget == .fixed(reps: 5) })
        #expect(items[0].notes == "banco 30°")
        #expect(items[0].restSeconds == 120)
        draft.resize(to: 1)
        draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets.count == 1)
        #expect(try f.count(SetPrescription.self) == 1)
    }

    @Test func invalidRangeKeepsPreviousValue() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        var draft = PrescriptionDraft(items[0])
        draft.template.repTarget = .range(min: 12, max: 8)
        #expect(!draft.sets[0].isValid)
        draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets.allSatisfy { $0.repTarget == .fixed(reps: 10) })
        draft.template.repTarget = .range(min: 8, max: 8) // mín = máx é válido
        draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets[0].repTarget == .range(min: 8, max: 8))
    }

    // MARK: Carga inicial x atual (R-T2)

    @Test func editingLoadSetsInitialAndFollowsCurrentUnlessDivergent() {
        var s = SetDraft(initialLoad: .kg(30), currentLoad: .kg(30))
        s.setInitialLoad(.kg(32.5))
        #expect(s.initialLoad == .kg(32.5))
        #expect(s.currentLoad == .kg(32.5))
        #expect(s.divergentCurrent == nil)

        var d = SetDraft(initialLoad: .kg(30), currentLoad: .kg(34))
        #expect(d.divergentCurrent == .kg(34))
        d.setInitialLoad(.kg(31))
        #expect(d.initialLoad == .kg(31))
        #expect(d.currentLoad == .kg(34))

        d.useCurrentAsInitial()
        #expect(d.initialLoad == .kg(34))
        #expect(d.divergentCurrent == nil)

        var none = SetDraft(initialLoad: .kg(30), currentLoad: nil)
        none.setInitialLoad(.kg(35))
        #expect(none.currentLoad == nil)
        #expect(none.initialLoad == .kg(35))
    }

    @Test func halfKiloStepLoadRoundTrips() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        var draft = PrescriptionDraft(items[0])
        draft.template.initialLoad = .kg(32.5)
        draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets.allSatisfy { $0.initialLoad == .kg(32.5) })
        #expect(PrescriptionFormat.loadText(.kg(32.5)).hasSuffix("kg"))
    }

    // MARK: Resumo

    @Test func summaryText() {
        let rest: (SetDraft) -> Int = { $0.restSeconds ?? 90 }
        let sets = Array(repeating: SetDraft(repTarget: .range(min: 8, max: 12), initialLoad: .kg(32.5)), count: 4)
        let line = PrescriptionSummary.line(sets: sets, measurement: .repsAndLoad, effectiveRest: rest)
        #expect(line.hasPrefix("4 × 8–12 · "))
        #expect(line.hasSuffix("kg · 90 s"))

        let mixed = [SetDraft(kind: .warmup, repTarget: .fixed(reps: 15), initialLoad: .kg(20))] + sets
        #expect(PrescriptionSummary.line(sets: mixed, measurement: .repsAndLoad, effectiveRest: rest).contains(" + 4 × 8–12"))

        let iso = Array(repeating: SetDraft(repTarget: nil, holdSeconds: 30), count: 3)
        #expect(PrescriptionSummary.line(sets: iso, measurement: .isometric, effectiveRest: rest) == "3 × 30 s · 90 s")

        #expect(PrescriptionFormat.loadText(.bodyweight(delta: -20, unit: .kg)).hasPrefix("PC −"))
        #expect(PrescriptionFormat.loadText(.bodyweight(delta: 0, unit: .kg)) == "PC")
        #expect(PrescriptionFormat.repText(.amrap) == "máx.")
        #expect(!PrescriptionSummary.spoken(sets: sets, measurement: .repsAndLoad, effectiveRest: rest).isEmpty)
    }

    @Test func removedExerciseStillSummarizesAndNamed() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        let exercise = try #require(items[0].exercise)
        f.context.delete(exercise)
        try f.context.save()
        #expect(items[0].exercise == nil)
        #expect(items[0].displayName == "Exercício removido")
        #expect(!items[0].prescriptionSummary.isEmpty)
        #expect(PrescriptionDraft(items[0]).measurement == .repsAndLoad)
    }

    @Test func estimatedDurationReactsToEdits() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press"])
        let before = routine.estimatedDurationSeconds
        var draft = PrescriptionDraft(items[0])
        draft.resize(to: 6)
        draft.apply(to: items[0], context: f.context)
        #expect(routine.estimatedDurationSeconds > before)
    }
}
