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

        let reps = try RoutineEditorOps.add([try first(.repsAndLoad)], to: routine, store: f.programs)[0]
        #expect(reps.sortedSets.count == 3)
        #expect(reps.sortedSets.allSatisfy { $0.repTarget == .range(min: 8, max: 12) })

        let iso = try RoutineEditorOps.add([try first(.isometric)], to: routine, store: f.programs)[0]
        #expect(iso.sortedSets.count == 3)
        #expect(iso.sortedSets.allSatisfy { $0.holdSeconds == 30 && $0.repTarget == nil })

        let cardio = try RoutineEditorOps.add([try first(.timeOrDistance)], to: routine, store: f.programs)[0]
        #expect(cardio.sortedSets.count == 1)
        #expect(cardio.sortedSets[0].cardio?.durationSeconds == 1200)

        let bw = try RoutineEditorOps.add([try first(.repsOnly)], to: routine, store: f.programs)[0]
        #expect(bw.sortedSets[0].initialLoad == .bodyweight(delta: 0, unit: .kg))
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1, 2, 3])
    }

    // MARK: Ordem

    @Test func moveAndReindex() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.moveExercise(items[2], by: -2)
        #expect(routine.sortedExercises.map(\.id) == [items[2].id, items[0].id, items[1].id])
        #expect(!RoutineEditorOps.canMove(items[2], by: -1))
        try f.programs.moveExercises(in: routine, from: IndexSet(integer: 0), to: 3)
        #expect(routine.sortedExercises.map(\.id) == [items[0].id, items[1].id, items[2].id])
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func deleteReindexesAndDissolvesLoneGroup() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.groupExercises(Set([items[0].id, items[1].id]), in: routine)
        try f.programs.deleteExercise(items[0])
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
        try f.programs.groupExercises(Set([items[0].id, items[2].id]), in: routine)
        #expect(items.allSatisfy { $0.groupID == nil })
        try f.programs.groupExercises(Set([items[0].id, items[1].id, items[2].id]), in: routine)
        #expect(Set(items.compactMap(\.groupID)).count == 1)
        #expect(GroupLabel.name(forCount: 2) == "Bi-set")
        #expect(GroupLabel.name(forCount: 3) == "Tri-set")
        #expect(GroupLabel.name(forCount: 5) == "Circuito")
        let gid = try #require(items[0].groupID)
        try f.programs.ungroup(gid, in: routine)
        #expect(items.allSatisfy { $0.groupID == nil })
    }

    @Test func draggingOutOfGroupSplitsIt() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.groupExercises(Set([items[0].id, items[1].id]), in: routine)
        // arrasta o 1º para o fim: o grupo perde um membro e se dissolve
        try f.programs.moveExercises(in: routine, from: IndexSet(integer: 0), to: 3)
        #expect(items.allSatisfy { $0.groupID == nil })
    }

    // MARK: Duplicar / mover / copiar

    @Test func duplicateKeepsPrescriptionAndInsertsBelow() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck"])
        items[0].sortedSets[0].initialLoad = .kg(30)
        items[0].sortedSets[0].currentLoad = .kg(34)
        let copy = try #require(try f.programs.duplicateExercise(items[0]))
        #expect(routine.sortedExercises.map(\.id) == [items[0].id, copy.id, items[1].id])
        #expect(copy.sortedSets.count == 3)
        // regra única: a carga atual vira a inicial da cópia
        #expect(copy.sortedSets[0].initialLoad == .kg(34))
        #expect(copy.sortedSets[0].currentLoad == nil)
    }

    @Test func moveAndCopyToAnotherRoutine() throws {
        let f = try PersistenceFixture()
        let (a, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck"])
        let b = try f.programs.addRoutine(to: try #require(a.program), name: "B")
        items[0].sortedSets[0].initialLoad = .kg(30)
        items[0].sortedSets[0].currentLoad = .kg(34)

        try f.programs.transferExercise(items[0], to: b, copy: true)
        #expect(a.sortedExercises.count == 2)
        let copied = try #require(b.sortedExercises.first)
        #expect(copied.sortedSets[0].initialLoad == .kg(34))
        #expect(copied.sortedSets[0].currentLoad == nil)

        try f.programs.transferExercise(items[1], to: b, copy: false)
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
        try draft.apply(to: items[0], context: f.context)
        try draft.apply(to: items[0], context: f.context) // idempotente
        #expect(items[0].sortedSets.count == 4)
        #expect(items[0].sortedSets.allSatisfy { $0.repTarget == .fixed(reps: 5) })
        #expect(items[0].notes == "banco 30°")
        #expect(items[0].restSeconds == 120)
        draft.resize(to: 1)
        try draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets.count == 1)
        #expect(try f.count(SetPrescription.self) == 1)
    }

    @Test func invalidRangeInDraftKeepsPreviousValue() throws {
        let f = try PersistenceFixture()
        let (_, items) = try routineWithItems(f, keys: ["bench-press"])
        var draft = PrescriptionDraft(items[0])
        draft.template.repTarget = .range(min: 12, max: 8)
        #expect(!draft.sets[0].isValid)
        try draft.apply(to: items[0], context: f.context)
        #expect(items[0].sortedSets.allSatisfy { $0.repTarget == .fixed(reps: 10) })
        draft.template.repTarget = .range(min: 8, max: 8) // mín = máx é válido
        try draft.apply(to: items[0], context: f.context)
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

        var noOld = SetDraft(initialLoad: nil, currentLoad: .kg(34))
        #expect(noOld.divergentCurrent == .kg(34))
        noOld.setInitialLoad(.kg(30))
        #expect(noOld.currentLoad == .kg(34))
        #expect(noOld.divergentCurrent == .kg(34))

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
        try draft.apply(to: items[0], context: f.context)
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
        try draft.apply(to: items[0], context: f.context)
        #expect(routine.estimatedDurationSeconds > before)
    }

    // MARK: Revisão

    @Test func droppingIntoMiddleOfGroupJoinsIt() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown", "seated-cable-row"])
        try f.programs.groupExercises([items[0].id, items[1].id], in: routine)
        let gid = try #require(items[0].groupID)
        // arrasta o 4º para entre o 1º e o 2º
        try f.programs.moveExercises(in: routine, from: IndexSet(integer: 3), to: 1)
        let order = routine.sortedExercises
        #expect(order.map(\.id) == [items[0].id, items[3].id, items[1].id, items[2].id])
        #expect(items[3].groupID == gid)
        #expect(items[0].groupID == gid && items[1].groupID == gid)
        #expect(items[2].groupID == nil)
    }

    @Test func movingOutOfMiddleOfGroupDissolvesOriginOnly() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown", "seated-cable-row"])
        try f.programs.groupExercises([items[0].id, items[1].id, items[2].id], in: routine)
        // leva o do meio para o fim: grupo de origem fica 0,2 (ainda contíguo) e o item sai
        try f.programs.moveExercises(in: routine, from: IndexSet(integer: 1), to: 4)
        #expect(items[1].groupID == nil)
        #expect(items[0].groupID != nil && items[0].groupID == items[2].groupID)
    }

    @Test func duplicatingGroupMemberGrowsGroup() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.groupExercises([items[0].id, items[1].id], in: routine)
        let copy = try #require(try f.programs.duplicateExercise(items[0]))
        #expect(routine.sortedExercises.map(\.id) == [items[0].id, copy.id, items[1].id, items[2].id])
        #expect(copy.groupID == items[0].groupID)
        #expect(Set(routine.sortedExercises.prefix(3).compactMap(\.groupID)).count == 1)
        #expect(items[2].groupID == nil)
    }

    @Test func repRangeEditingNeverInvalid() {
        let r: RepTarget = .range(min: 8, max: 12)
        #expect(RepRangeEditing.setLow(15, of: r) == .range(min: 15, max: 15))
        #expect(RepRangeEditing.setHigh(5, of: r) == .range(min: 5, max: 5))
        #expect(RepRangeEditing.setLow(0, of: r) == .range(min: 1, max: 12))
        #expect(RepRangeEditing.setFixed(0) == .fixed(reps: 1))
    }

    @Test func normalizationByMeasurement() {
        var iso = PrescriptionDraft(measurement: .isometric, sets: [SetDraft(repTarget: .fixed(reps: 1), holdSeconds: nil), SetDraft(repTarget: nil, holdSeconds: 2)])
        iso.normalizeForMeasurement()
        #expect(iso.sets.allSatisfy { $0.repTarget == nil })
        #expect(iso.sets[0].holdSeconds == 30)
        #expect(iso.sets[1].holdSeconds == 5)
        var reps = PrescriptionDraft(measurement: .repsAndLoad, sets: [SetDraft(repTarget: nil)])
        reps.normalizeForMeasurement()
        #expect(reps.sets[0].repTarget == .range(min: 8, max: 12))
        var cardio = PrescriptionDraft(measurement: .timeOrDistance, sets: [SetDraft(repTarget: .fixed(reps: 3), cardio: nil)])
        cardio.normalizeForMeasurement()
        #expect(cardio.sets[0].repTarget == nil)
        #expect(cardio.sets[0].cardio?.durationSeconds == 1200)
    }

    @Test func groupRestWritesToLastMember() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.groupExercises([items[0].id, items[1].id], in: routine)
        let gid = try #require(items[0].groupID)
        items[1].sortedSets[0].restSeconds = 45
        try f.programs.setGroupRest(120, groupID: gid, in: routine)
        #expect(items[1].restSeconds == 120)
        #expect(items[1].sortedSets.allSatisfy { $0.restSeconds == nil })
        #expect(items[0].restSeconds == nil)
        #expect(RoutineEditorOps.effectiveRest(of: items[1]) == 120)
        #expect(RoutineEditorOps.isInnerGroupMember(items[0]))
        #expect(!RoutineEditorOps.isInnerGroupMember(items[1]))
        #expect(!RoutineEditorOps.isInnerGroupMember(items[2]))
    }

    @Test func singleSaveDeleteReindexesAndNormalizes() throws {
        let f = try PersistenceFixture()
        let (routine, items) = try routineWithItems(f, keys: ["bench-press", "pec-deck", "lat-pulldown"])
        try f.programs.groupExercises([items[0].id, items[1].id], in: routine)
        try f.programs.deleteExercise(items[1])
        #expect(routine.sortedExercises.map(\.sortIndex) == [0, 1])
        #expect(items[0].groupID == nil)
    }

    @Test func addExerciseAcceptsNilRepsAndHold() throws {
        let f = try PersistenceFixture()
        let program = try f.programs.createProgram(name: "P")
        let routine = try f.programs.addRoutine(to: program, name: "A")
        let plank = try f.programs.addExercise(try f.exercise("plank"), to: routine, setCount: 2,
                                               repTarget: nil, holdSeconds: 30)
        #expect(plank.sortedSets.allSatisfy { $0.repTarget == nil && $0.holdSeconds == 30 })
    }
}
