import Foundation
import SwiftData
import Testing
@testable import FitJourney

// P2.8 — memória de carga: a carga começa definida (ficha → última usada → "Definir carga"), acompanha as séries
// seguintes na sessão e vira `currentLoad` ao finalizar quando a ficha não tinha carga.

@MainActor
struct LoadMemoryPolicyTests {
    let p1 = UUID(), p2 = UUID(), p3 = UUID()

    @Test func firstDefinitionIsProposedEvenWithPendingSets() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: nil, usedLoad: .kg(10), isCompleted: true),
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(0), usedLoad: .kg(12), isCompleted: true),
            .init(prescriptionID: p3, kind: .working, currentLoad: nil, usedLoad: nil, isCompleted: false),
        ])
        let proposals = CurrentLoadPolicy.proposals(for: [entry])
        #expect(proposals.map(\.prescriptionID) == [p1, p2])
        #expect(proposals.allSatisfy { $0.isFirstDefinition && $0.to == .kg(12) }) // carga final (17/11)
    }

    @Test func unsetUsedLoadAndPendingSetsAreNotFirstDefinitions() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: nil, usedLoad: .kg(0), isCompleted: true),
            .init(prescriptionID: p2, kind: .working, currentLoad: nil, usedLoad: .kg(10), isCompleted: false),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [entry]).isEmpty)
    }

    @Test func definedLoadStillNeedsAllSetsAndIsNotFirstDefinition() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Barra", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .bodyweight(delta: 0, unit: .kg),
                  usedLoad: .bodyweight(delta: 5, unit: .kg), isCompleted: true),
        ])
        let proposal = CurrentLoadPolicy.proposals(for: [entry]).first
        #expect(proposal?.isFirstDefinition == false) // peso corporal 0 é carga válida
    }

    @Test func loadHelpers() {
        #expect(Load.kg(0).isUnsetWeight)
        #expect(!Load.bodyweight(delta: 0, unit: .kg).isUnsetWeight)
        #expect(Load.defined(.kg(0)) == nil)
        #expect(Load.defined(.kg(10)) == .kg(10))
        #expect(SessionStore.plannedLoad(prescribed: .kg(0), fallback: .kg(8)) == .kg(8))
        #expect(SessionStore.plannedLoad(prescribed: .bodyweight(delta: 0, unit: .kg), fallback: .kg(8))
                == .bodyweight(delta: 0, unit: .kg))
        #expect(SessionStore.plannedLoad(prescribed: nil, fallback: nil) == nil)
    }
}

@MainActor
struct LoadMemorySessionTests {
    /// Programa de exemplo ABC (sem cargas) no motor de teste.
    private func starter(_ f: EngineFixture) throws -> TrainingProgram {
        try SampleProgramFactory.makeStarterABC(in: f.context, activate: true, now: f.t0)
    }

    private func routine(_ program: TrainingProgram, _ index: Int) -> Routine { program.sortedRoutines[index] }

    private func complete(_ f: EngineFixture, _ setID: UUID, load: WatchLoad? = nil, at offset: TimeInterval,
                          session: UUID) {
        f.apply(.completeSet(setID: setID, reps: nil, load: load, durationSeconds: nil, distanceMeters: nil),
                at: offset, session: session)
    }

    @Test func starterWithoutLoadIsRememberedAcrossSessions() throws {
        let f = try EngineFixture()
        let program = try starter(f)
        let a = routine(program, 0)

        // 1ª sessão: sem carga em lugar nenhum → "Definir carga" (nil), nunca 0.
        let first = try f.start(a)
        var bench = try f.snapshot.exercises[0]
        #expect(bench.sets.allSatisfy { $0.plannedLoad == nil && $0.load == nil })
        #expect(SessionPresentation.displayLoad(bench.sets[0]) == nil)
        let live = try #require(LiveActivityStateMapper.state(for: try f.snapshot, now: f.t0, unit: .kg))
        #expect(live.loadText == nil)

        // Define 10 kg na 1ª série: as seguintes (sem carga) acompanham.
        complete(f, bench.sets[0].id, load: WatchLoad(value: 10), at: 60, session: first)
        bench = try f.snapshot.exercises[0]
        #expect(bench.sets.dropFirst().allSatisfy { $0.plannedLoad == WatchLoad(value: 10) && $0.load == nil })
        for (index, set) in bench.sets.dropFirst().enumerated() {
            complete(f, set.id, at: TimeInterval(200 + 100 * index), session: first)
        }
        #expect(try f.snapshot.loadProposals.count == bench.sets.count)

        // Finaliza sem marcar nada: primeira definição é aplicada sempre (currentLoad, não initialLoad).
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 900, session: first)
        let prescriptions = a.sortedExercises[0].sortedSets
        #expect(prescriptions.allSatisfy { $0.currentLoad == .kg(10) && $0.initialLoad == nil })

        // 2ª sessão começa em 10 kg.
        try f.start(a, at: 86_400)
        #expect(try f.snapshot.exercises[0].sets.allSatisfy { $0.plannedLoad == WatchLoad(value: 10) })
    }

    @Test func lastLoadIsReusedFromAnotherRoutineAndBodyweightZeroStaysValid() throws {
        let f = try EngineFixture()
        let program = try f.base.programs.createProgram(name: "P", activate: true)
        let a = try f.base.programs.addRoutine(to: program, name: "A", symbol: "A")
        let b = try f.base.programs.addRoutine(to: program, name: "B", symbol: "B")
        let bench = try f.base.exercise("bench-press")
        try f.base.programs.addExercise(bench, to: a, setCount: 2, repTarget: .fixed(reps: 10), load: .kg(40))
        try f.base.programs.addExercise(bench, to: b, setCount: 2, repTarget: .fixed(reps: 10), load: .kg(0))
        try f.base.programs.addExercise(try f.base.exercise("plank"), to: b, setCount: 1, repTarget: .fixed(reps: 1),
                                        load: .bodyweight(delta: 0, unit: .kg))
        try f.context.save()

        let first = try f.start(a)
        let sets = try f.sets(0)
        complete(f, sets[0].id, load: WatchLoad(value: 42.5), at: 60, session: first)
        complete(f, sets[1].id, at: 120, session: first)
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: first)

        // Ficha B: supino com "0 kg" (vazia) → última carga usada (42,5 kg da ficha A); prancha 0 = peso corporal.
        try f.start(b, at: 3_600)
        let snap = try f.snapshot
        #expect(snap.exercises[0].sets.allSatisfy { $0.plannedLoad == WatchLoad(value: 42.5) })
        #expect(snap.exercises[1].sets[0].plannedLoad == WatchLoad(value: 0, isBodyweight: true))
    }

    @Test func propagationOverwritesPyramidsEditsAndEarlierSetsButNotWarmups() throws {
        let f = try EngineFixture()
        let (_, routine, item) = try f.base.makeProgram() // aquecimento 20 kg + 3 × 30 kg
        let pyramid = item.sortedSets.filter { $0.kind == .working }
        pyramid[2].initialLoad = .kg(35)
        try f.context.save()
        let session = try f.start(routine)
        var sets = try f.sets(0) // [aq 20, 30, 30, 35]

        // Aquecimento não arrasta as válidas.
        f.apply(.adjustLoad(setID: sets[0].id, delta: 2.5), at: 10, session: session)
        #expect(try f.sets(0)[1].plannedLoad == WatchLoad(value: 30))

        // 17/11: editar a 3ª leva a 2ª (anterior) e a 4ª (pirâmide); ajustar a 2ª sobrescreve a 3ª já editada.
        f.apply(.updateSet(setID: sets[2].id, reps: nil, load: WatchLoad(value: 31), durationSeconds: nil, distanceMeters: nil),
                at: 20, session: session)
        sets = try f.sets(0)
        #expect(sets[1].plannedLoad == WatchLoad(value: 31) && sets[3].plannedLoad == WatchLoad(value: 31))
        f.apply(.adjustLoad(setID: sets[1].id, delta: 2.5), at: 30, session: session)
        sets = try f.sets(0)
        #expect(sets[2].load == WatchLoad(value: 33.5))
        #expect(sets[3].plannedLoad == WatchLoad(value: 33.5))
        #expect(sets[0].load == WatchLoad(value: 22.5)) // aquecimento intocado
    }

    @Test func adjustingPropagatesToFollowingUneditedSets() throws {
        let f = try EngineFixture()
        let (_, routine, _) = try f.base.makeProgram()
        let session = try f.start(routine)
        let sets = try f.sets(0) // [aq 20, 30, 30, 30]
        f.apply(.adjustLoad(setID: sets[1].id, delta: 2.5), at: 10, session: session)
        var now = try f.sets(0)
        #expect(now[2].plannedLoad == WatchLoad(value: 32.5) && now[3].plannedLoad == WatchLoad(value: 32.5))
        #expect(now[2].load == nil && now[3].load == nil)
        // Concluir com a mesma carga mostrada não muda nada.
        complete(f, sets[1].id, at: 20, session: session)
        now = try f.sets(0)
        #expect(now[2].plannedLoad == WatchLoad(value: 32.5))
        // Concluída a 2ª, ajustar a 3ª leva só a 4ª.
        f.apply(.adjustLoad(setID: sets[2].id, delta: 2.5), at: 30, session: session)
        now = try f.sets(0)
        #expect(now[1].load == WatchLoad(value: 32.5))
        #expect(now[3].plannedLoad == WatchLoad(value: 35))
    }

    @Test func adjustWithoutLoadStartsFromLastKnownLoad() throws {
        let f = try EngineFixture()
        let program = try starter(f)
        let a = routine(program, 0)
        let first = try f.start(a)
        let bench = try f.sets(0)
        complete(f, bench[0].id, load: WatchLoad(value: 20), at: 60, session: first)
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: first)

        // Treino livre: adicionar o supino planeja 20 kg; série extra também.
        let free = try f.start(nil, at: 3_600)
        let catalogID = try #require(a.sortedExercises[0].exercise?.id)
        f.apply(.addExercise(catalogExerciseID: catalogID, afterExerciseID: nil), at: 3_610, session: free)
        var added = try f.snapshot.exercises[0]
        #expect(added.sets.allSatisfy { $0.plannedLoad == WatchLoad(value: 20) })
        f.apply(.addSet(exerciseID: added.id, kind: nil), at: 3_620, session: free)
        added = try f.snapshot.exercises[0]
        #expect(added.sets.last?.plannedLoad == WatchLoad(value: 20))

        // Exercício nunca feito: sem carga planejada; ajustar parte de 0.
        let neverID = try f.base.exercise("leg-press").id
        f.apply(.addExercise(catalogExerciseID: neverID, afterExerciseID: nil), at: 3_630, session: free)
        let never = try f.snapshot.exercises[1]
        #expect(never.sets.allSatisfy { $0.plannedLoad == nil })
        f.apply(.adjustLoad(setID: never.sets[0].id, delta: 5), at: 3_640, session: free)
        #expect(try f.snapshot.exercises[1].sets[0].load == WatchLoad(value: 5))
    }

    @Test func adjustWithNilPlannedUsesHistory() throws {
        let f = try EngineFixture()
        let program = try starter(f)
        let a = routine(program, 0)
        let first = try f.start(a)
        complete(f, try f.sets(0)[0].id, load: WatchLoad(value: 20), at: 60, session: first)
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: first)
        // Ficha sem carga na 2ª série (pendente da 1ª sessão): limpa `currentLoad` para simular série nunca definida.
        let second = a.sortedExercises[0].sortedSets[1]
        second.currentLoad = nil
        try f.context.save()
        let next = try f.start(a, at: 3_600)
        let sets = try f.sets(0)
        #expect(sets[1].plannedLoad == WatchLoad(value: 20)) // pela última carga usada
        f.apply(.adjustLoad(setID: sets[1].id, delta: 2.5), at: 3_610, session: next)
        #expect(try f.sets(0)[1].load == WatchLoad(value: 22.5))
    }

    @Test func staleFinishAtLastSetAppliesFirstDefinitions() throws {
        let f = try EngineFixture()
        let program = try starter(f)
        let a = routine(program, 0)
        let session = try f.start(a)
        let sets = try f.sets(0)
        complete(f, sets[0].id, load: WatchLoad(value: 15), at: 60, session: session)
        let later = f.reopen(at: 60 + 5 * 3_600)
        later.restore()
        #expect(later.resolveStaleSession(.finishAtLastSet()))
        #expect(a.sortedExercises[0].sortedSets[0].currentLoad == .kg(15))
        // Séries pendentes não ganham carga (o próximo treino usa a última carga registrada).
        #expect(a.sortedExercises[0].sortedSets[1].currentLoad == nil)
    }

    @Test func confirmedProposalsStillNeedToggleWhenRoutineHadLoad() throws {
        let f = try EngineFixture()
        let (_, routine, item) = try f.base.makeProgram()
        let session = try f.start(routine)
        let sets = try f.sets(0)
        for (index, set) in sets.enumerated() {
            complete(f, set.id, load: index == 0 ? nil : WatchLoad(value: 32.5), at: TimeInterval(60 * (index + 1)), session: session)
        }
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: session)
        #expect(item.sortedSets.filter { $0.kind == .working }.allSatisfy { $0.currentLoad == nil })
    }

    @Test func warmupHistoryNeverFeedsWorkingSets() throws {
        let f = try EngineFixture()
        let program = try f.base.programs.createProgram(name: "P", activate: true)
        let a = try f.base.programs.addRoutine(to: program, name: "A", symbol: "A")
        let bench = try f.base.exercise("bench-press")
        let item = try f.base.programs.addExercise(bench, to: a, setCount: 2, repTarget: .fixed(reps: 10), load: nil)
        let warmup = SetPrescription(sortIndex: -1, kind: .warmup, repTarget: .fixed(reps: 15), initialLoad: nil)
        f.context.insert(warmup)
        warmup.routineExercise = item
        try f.context.save()

        // 1ª sessão: só o aquecimento ganha carga (20 kg).
        let first = try f.start(a)
        let sets = try f.sets(0)
        complete(f, sets[0].id, load: WatchLoad(value: 20), at: 60, session: first)
        #expect(try f.sets(0)[1].plannedLoad == nil) // aquecimento não propaga para as válidas
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: first)
        let store = f.base.sessions
        #expect(try store.lastUsedLoad(exerciseID: bench.id, working: false) == .kg(20))
        #expect(try store.lastUsedLoad(exerciseID: bench.id, working: true) == nil)

        // 2ª sessão: aquecimento lembra 20 kg; válidas continuam sem carga ("Definir carga").
        let second = try f.start(a, at: 3_600)
        var snap = try f.snapshot.exercises[0].sets
        #expect(snap[0].plannedLoad == WatchLoad(value: 20))
        #expect(snap.dropFirst().allSatisfy { $0.plannedLoad == nil })
        // Ajustar uma válida sem carga parte de 0, não dos 20 kg do aquecimento; série extra válida idem.
        f.apply(.adjustLoad(setID: snap[1].id, delta: 5), at: 3_610, session: second)
        #expect(try f.sets(0)[1].load == WatchLoad(value: 5))
        f.apply(.addSet(exerciseID: try f.snapshot.exercises[0].id, kind: .warmup), at: 3_620, session: second)
        snap = try f.snapshot.exercises[0].sets
        #expect(snap.last?.plannedLoad == WatchLoad(value: 20)) // extra de aquecimento: última de aquecimento
    }

    @Test func editorDefaultsToLastKnownLoad() throws {
        let f = try EngineFixture()
        let program = try starter(f)
        let a = routine(program, 0)
        let first = try f.start(a)
        complete(f, try f.sets(0)[0].id, load: WatchLoad(value: 27.5), at: 60, session: first)
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: first)

        #expect(PrescriptionDefaults.initialLoad(for: .repsAndLoad, lastKnown: nil) == nil)
        #expect(PrescriptionDefaults.initialLoad(for: .repsAndLoad, lastKnown: .kg(0)) == nil)
        #expect(PrescriptionDefaults.initialLoad(for: .repsOnly, lastKnown: nil, unit: .kg) == .bodyweight(delta: 0, unit: .kg))
        #expect(PrescriptionDefaults.initialLoad(for: .timeOrDistance, lastKnown: .kg(5)) == nil)

        let b = routine(program, 1)
        let bench = try f.base.exercise("bench-press")
        let neverDone = try f.base.exercise("leg-press")
        let added = try RoutineEditorOps.add([bench, neverDone], to: b, store: f.base.programs)
        #expect(added[0].sortedSets.allSatisfy { $0.initialLoad == .kg(27.5) })
        #expect(added[1].sortedSets.allSatisfy { $0.initialLoad == nil })
    }
}
