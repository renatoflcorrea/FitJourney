import Foundation
import SwiftData
import Testing
@testable import FitJourney

// Decisão 17/11: carga ajustada vale para todas as séries pendentes do exercício (e a ficha fica uniforme);
// reps digitadas na sessão viram o alvo do exercício (sessão e ficha), não reps feitas.

struct WholeExercisePolicyTests {
    let p1 = UUID(), p2 = UUID(), p3 = UUID(), w = UUID()
    let t = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func adjustedPyramidProposesFinalLoadOfLastCompletedSet() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: w, kind: .warmup, currentLoad: .kg(20), usedLoad: .kg(25), isCompleted: true),
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(33), isCompleted: true,
                  completedAt: t.addingTimeInterval(300)),
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(32), usedLoad: .kg(31), isCompleted: true,
                  completedAt: t.addingTimeInterval(100)),
            .init(prescriptionID: p3, kind: .working, currentLoad: .kg(34), usedLoad: .kg(31), isCompleted: true,
                  completedAt: t.addingTimeInterval(200)),
        ])
        let proposals = CurrentLoadPolicy.proposals(for: [entry])
        #expect(proposals.map(\.prescriptionID) == [p1, p2, p3])
        #expect(proposals.allSatisfy { $0.to == .kg(33) }) // a concluída por último (p1), não a última da lista
    }

    @Test func untouchedPyramidAndPendingAdjustedSetsProposeNothing() {
        let pyramid = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(30), isCompleted: true),
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(32), usedLoad: .kg(32), isCompleted: true),
        ])
        let pending = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Remada", sets: [
            .init(prescriptionID: p3, kind: .working, currentLoad: .kg(30), usedLoad: .kg(35), isCompleted: true),
            .init(prescriptionID: UUID(), kind: .working, currentLoad: .kg(30), usedLoad: nil, isCompleted: false),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [pyramid, pending]).isEmpty)
    }

    @Test func repTargetPolicyProposesFinalTargetForAllWorkingPrescriptions() {
        let entry = RepTargetPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: w, kind: .warmup, prescribed: .fixed(reps: 15), session: .fixed(reps: 12), isCompleted: true),
            .init(prescriptionID: p1, kind: .working, prescribed: .range(min: 8, max: 12), session: .range(min: 8, max: 12),
                  isCompleted: true),
            .init(prescriptionID: p2, kind: .working, prescribed: .range(min: 8, max: 12), session: .fixed(reps: 10),
                  isCompleted: true, updatedAt: t),
            .init(prescriptionID: p3, kind: .working, prescribed: .fixed(reps: 6), session: .fixed(reps: 12),
                  isCompleted: false),
            .init(prescriptionID: UUID(), kind: .working, prescribed: .amrap, session: .amrap, isCompleted: false),
        ])
        let proposals = RepTargetPolicy.proposals(for: [entry])
        // A pendente guarda o número mais recente (12); AMRAP e aquecimento ficam fora.
        #expect(proposals.map(\.prescriptionID) == [p1, p2, p3])
        #expect(proposals.allSatisfy { $0.to == .fixed(reps: 12) })
        #expect(proposals.first?.from == .range(min: 8, max: 12))
    }

    @Test func repTargetPolicyWithoutPendingUsesLatestEditAndIgnoresUnchanged() {
        let done = RepTargetPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, prescribed: .fixed(reps: 10), session: .fixed(reps: 12),
                  isCompleted: true, updatedAt: t),
            .init(prescriptionID: p2, kind: .working, prescribed: .fixed(reps: 10), session: .fixed(reps: 8),
                  isCompleted: true, updatedAt: t.addingTimeInterval(60)),
        ])
        #expect(RepTargetPolicy.proposals(for: [done]).map(\.to) == [.fixed(reps: 8), .fixed(reps: 8)])
        let same = RepTargetPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, prescribed: .range(min: 8, max: 12), session: .range(min: 8, max: 12),
                  isCompleted: true),
        ])
        var skipped = done
        skipped.isEligible = false
        #expect(RepTargetPolicy.proposals(for: [same, skipped]).isEmpty)
    }

    @Test func peersArePendingSameGroupBeforeOrAfter() {
        let ids = (0..<5).map { _ in UUID() }
        let sets: [SessionSetPropagation.SetState] = [
            .init(id: ids[0], kind: .warmup, isCompleted: false),
            .init(id: ids[1], kind: .working, isCompleted: false),
            .init(id: ids[2], kind: .working, isCompleted: true),
            .init(id: ids[3], kind: .dropSet, isCompleted: false),
            .init(id: ids[4], kind: .working, isCompleted: false),
        ]
        #expect(SessionSetPropagation.peers(of: ids[3], in: sets) == [ids[1], ids[4]])
        #expect(SessionSetPropagation.peers(of: ids[0], in: sets).isEmpty)
    }

    @Test func groupsCombineLoadAndRepsPerExercise() {
        let ex = UUID()
        let load = [LoadUpdateProposal(prescriptionID: p1, exerciseName: "Supino", from: .kg(30), to: .kg(32), sessionExerciseID: ex),
                    LoadUpdateProposal(prescriptionID: p2, exerciseName: "Supino", from: .kg(30), to: .kg(32), sessionExerciseID: ex),
                    LoadUpdateProposal(prescriptionID: p3, exerciseName: "Remada", from: nil, to: .kg(20))]
        let reps = [RepTargetUpdateProposal(prescriptionID: p2, exerciseName: "Supino", from: .fixed(reps: 10),
                                            to: .fixed(reps: 12), sessionExerciseID: ex)]
        let groups = PrescriptionUpdateGroup.make(load: load, reps: reps)
        #expect(groups.count == 2)
        #expect(groups[0].confirmableIDs == [p1, p2])
        #expect(groups[0].fromLoad == .kg(30) && groups[0].toLoad == .kg(32))
        #expect(groups[0].fromRepTarget == .fixed(reps: 10) && groups[0].toRepTarget == .fixed(reps: 12))
        #expect(groups[1].isAutomatic && groups[1].isFirstDefinition)
    }
}

@MainActor
struct WholeExerciseSessionTests {
    private func complete(_ f: EngineFixture, _ id: UUID, load: WatchLoad? = nil, at offset: TimeInterval, _ session: UUID) {
        f.apply(.completeSet(setID: id, reps: nil, load: load, durationSeconds: nil, distanceMeters: nil), at: offset, session: session)
    }

    @Test func pyramidAdjustedFlowsToAllPendingSetsAndFichaEndsUniform() throws {
        let f = try EngineFixture()
        let (_, routine, item) = try f.base.makeProgram() // aquecimento 20 + 3 × 30 kg
        let working = item.sortedSets.filter { $0.kind == .working }
        working[1].initialLoad = .kg(32)
        working[2].initialLoad = .kg(35)
        try f.context.save()
        let session = try f.start(routine)
        var sets = try f.sets(0) // [aq 20, 30, 32, 35]

        // Concluir com a carga mostrada não achata a pirâmide.
        complete(f, sets[1].id, at: 60, session)
        sets = try f.sets(0)
        #expect(sets[2].plannedLoad == WatchLoad(value: 32) && sets[3].plannedLoad == WatchLoad(value: 35))

        // Editar a última leva a anterior pendente; concluída e aquecimento ficam (snapshot = o que vai ao relógio).
        f.apply(.updateSet(setID: sets[3].id, reps: nil, load: WatchLoad(value: 34), durationSeconds: nil, distanceMeters: nil),
                at: 70, session: session)
        sets = try f.sets(0)
        #expect(sets[2].plannedLoad == WatchLoad(value: 34))
        #expect(sets[1].load == WatchLoad(value: 30))
        #expect(sets[0].plannedLoad == WatchLoad(value: 20) && sets[0].load == nil)
        // Ajustar a 3ª sobrescreve a `load` registrada da 4ª. Idempotente: mesma carga não muda nada.
        f.apply(.adjustLoad(setID: sets[2].id, delta: 1), at: 80, session: session)
        sets = try f.sets(0)
        #expect(sets[3].load == WatchLoad(value: 35))
        let revision = try f.snapshot.revision
        f.apply(.updateSet(setID: sets[2].id, reps: nil, load: WatchLoad(value: 35), durationSeconds: nil, distanceMeters: nil),
                at: 85, session: session)
        #expect(try f.sets(0)[3].load == WatchLoad(value: 35))
        #expect(try f.snapshot.revision == revision + 1)

        complete(f, sets[2].id, at: 120, session)
        complete(f, sets[3].id, at: 180, session)
        complete(f, sets[0].id, at: 200, session) // aquecimento por último não conta como "última válida"
        let proposals = try f.snapshot.loadProposals
        #expect(Set(proposals.map(\.prescriptionID)) == Set([working[0].id, working[1].id]))
        #expect(proposals.allSatisfy { $0.to == WatchLoad(value: 35) })
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: try f.snapshot.defaultProposalIDs), at: 300, session: session)
        #expect(working.allSatisfy { $0.effectiveLoad == .kg(35) })
        #expect(item.sortedSets.first?.effectiveLoad == .kg(20))

        try f.start(routine, at: 3_600)
        #expect(try f.sets(0).dropFirst().allSatisfy { $0.plannedLoad == WatchLoad(value: 35) })
    }

    @Test func finishedSessionEditsDoNotPropagateOrRetarget() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        let logs = try #require(session.sortedExercises.first).sortedSets
        try f.sessions.completeSet(logs[1])
        try f.sessions.finish(session)
        try f.sessions.adjustLoad(logs[1], by: 5)
        try f.sessions.updateSet(logs[1], reps: 9, load: logs[1].load)
        #expect(logs[1].load == .kg(35) && logs[1].reps == 9)
        #expect(logs[1].repTarget == .range(min: 8, max: 12))
        #expect(logs[2].plannedLoad == .kg(30) && logs[2].repTarget == .range(min: 8, max: 12))
    }

    @Test func enteringRepsRetargetsPendingSetsAndUpdatesFicha() throws {
        let f = try EngineFixture()
        let (_, routine, item) = try f.base.makeProgram() // válidas 8–12, aquecimento 15
        let session = try f.start(routine)
        let sets = try f.sets(0)
        complete(f, sets[0].id, at: 30, session)
        complete(f, sets[1].id, at: 60, session)
        complete(f, sets[2].id, at: 120, session)
        // "+ reps" do relógio na 2ª válida concluída: vira o alvo dela e das pendentes; reps feitas ficam vazias.
        f.apply(.updateSet(setID: sets[2].id, reps: 12, load: nil, durationSeconds: nil, distanceMeters: nil), at: 130, session: session)
        var now = try f.sets(0)
        #expect(now[2].reps == nil && now[2].repTarget == .fixed(reps: 12) && now[2].targetText == "12")
        #expect(now[3].repTarget == .fixed(reps: 12))
        #expect(now[1].repTarget == .range(min: 8, max: 12)) // concluída antes: intocada
        #expect(now[0].repTarget == .fixed(reps: 15)) // aquecimento

        // Limpar não mexe nos alvos.
        f.apply(.updateSet(setID: sets[2].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil), at: 140, session: session)
        now = try f.sets(0)
        #expect(now[3].repTarget == .fixed(reps: 12) && now[2].reps == nil)

        let repProposals = try #require(try f.snapshot.repTargetProposals)
        #expect(repProposals.count == 3 && repProposals.allSatisfy { $0.to == .fixed(reps: 12) })
        // Relógio: finaliza com o padrão (todas as propostas).
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: try f.snapshot.defaultProposalIDs), at: 300, session: session)
        let working = item.sortedSets.filter { $0.kind == .working }
        #expect(working.allSatisfy { $0.repTarget == .fixed(reps: 12) })
        #expect(item.sortedSets.first?.repTarget == .fixed(reps: 15))
    }

    @Test func uncheckedRepProposalIsNotApplied() throws {
        let f = try EngineFixture()
        let (_, routine, item) = try f.base.makeProgram()
        let session = try f.start(routine)
        let sets = try f.sets(0)
        f.apply(.updateSet(setID: sets[1].id, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil), at: 30, session: session)
        #expect(try f.sets(0).dropFirst().allSatisfy { $0.repTarget == .fixed(reps: 10) })
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 300, session: session)
        #expect(item.sortedSets.filter { $0.kind == .working }.allSatisfy { $0.repTarget == .range(min: 8, max: 12) })
    }

    @Test func amrapRecordsRepsDone() throws {
        let f = try PersistenceFixture()
        let (_, routine, item) = try f.makeProgram()
        for set in item.sortedSets where set.kind == .working { set.repTarget = .amrap }
        try f.context.save()
        let session = try f.sessions.start(routine: routine)
        let logs = try #require(session.sortedExercises.first).sortedSets
        try f.sessions.completeSet(logs[1])
        try f.sessions.updateSet(logs[1], reps: 15, load: logs[1].load)
        #expect(logs[1].reps == 15 && logs[1].repTarget == .amrap && logs[2].repTarget == .amrap)
        #expect(try f.sessions.repTargetProposals(for: session).isEmpty)
    }
}
