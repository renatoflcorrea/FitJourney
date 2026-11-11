import Foundation
import SwiftData
import Testing
@testable import FitJourney

struct SessionFlowTests {
    private func state(_ id: UUID, group: UUID? = nil, status: SessionExerciseStatus = .pending,
                       done: Int = 0, total: Int = 3) -> SessionFlow.ExerciseState {
        SessionFlow.ExerciseState(id: id, groupID: group, status: status, completedSets: done, totalSets: total)
    }

    @Test func currentExerciseFollowsOrderAndSkipsClosed() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(SessionFlow.currentExerciseID([state(a), state(b)]) == a)
        #expect(SessionFlow.currentExerciseID([state(a, status: .completed, done: 3), state(b)]) == b)
        #expect(SessionFlow.currentExerciseID([state(a, status: .skipped), state(b, status: .partial, done: 1), state(c)]) == c)
        #expect(SessionFlow.currentExerciseID([state(a, status: .completed, done: 3)]) == nil)
        // Exercício sem séries fica aberto até a conclusão manual.
        #expect(SessionFlow.currentExerciseID([state(a, total: 0)]) == a)
    }

    @Test func groupAlternatesByRound() {
        let a = UUID(), b1 = UUID(), b2 = UUID(), c = UUID(), g = UUID()
        func current(_ doneB1: Int, _ doneB2: Int, totalB1: Int = 3, totalB2: Int = 3) -> UUID? {
            SessionFlow.currentExerciseID([
                state(a, status: .completed, done: 3),
                state(b1, group: g, status: doneB1 >= totalB1 ? .completed : .pending, done: doneB1, total: totalB1),
                state(b2, group: g, status: doneB2 >= totalB2 ? .completed : .pending, done: doneB2, total: totalB2),
                state(c),
            ])
        }
        #expect(current(0, 0) == b1)
        #expect(current(1, 0) == b2)
        #expect(current(1, 1) == b1)
        #expect(current(3, 3) == c)
        // Membro com mais séries continua sozinho depois que o outro acaba.
        #expect(current(2, 2, totalB1: 4, totalB2: 2) == b1)
        // Grupo não contíguo conta na posição do primeiro membro.
        let order = [state(b1, group: g, done: 1), state(c), state(b2, group: g, done: 0)]
        #expect(SessionFlow.currentExerciseID(order) == b2)
    }

    @Test func focusWinsWhileOpen() {
        let a = UUID(), b = UUID()
        #expect(SessionFlow.currentExerciseID([state(a), state(b)], focused: b) == b)
        #expect(SessionFlow.currentExerciseID([state(a), state(b, status: .skipped)], focused: b) == a)
        #expect(SessionFlow.currentExerciseID([state(a), state(b)], focused: UUID()) == a)
    }

    @Test func endOfRound() {
        let a = UUID(), b = UUID(), c = UUID(), g = UUID()
        #expect(SessionFlow.isEndOfRound(after: a, in: [state(a, done: 1)]))
        #expect(!SessionFlow.isEndOfRound(after: a, in: [state(a, group: g, done: 1), state(b, group: g, done: 0)]))
        #expect(SessionFlow.isEndOfRound(after: b, in: [state(a, group: g, done: 1), state(b, group: g, done: 1)]))
        // Tri-set.
        #expect(!SessionFlow.isEndOfRound(after: b, in: [state(a, group: g, done: 1), state(b, group: g, done: 1),
                                                          state(c, group: g, done: 0)]))
        // Os outros acabaram (ou foram pulados): cada série do restante descansa.
        #expect(SessionFlow.isEndOfRound(after: a, in: [state(a, group: g, done: 4, total: 5),
                                                         state(b, group: g, status: .completed, done: 3)]))
        #expect(SessionFlow.isEndOfRound(after: a, in: [state(a, group: g, done: 1), state(b, group: g, status: .skipped)]))
    }

    @Test func staleAfterFourHours() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!SessionFlow.isStale(lastActivity: t, now: t.addingTimeInterval(4 * 3_600)))
        #expect(SessionFlow.isStale(lastActivity: t, now: t.addingTimeInterval(4 * 3_600 + 1)))
    }
}

struct OptionalRepsMetricsTests {
    @Test func missingRepsUseTargetFloorAndAreFlagged() {
        let sets = [
            PerformedSet(reps: nil, load: .kg(30), targetFloorReps: 8),
            PerformedSet(reps: 10, load: .kg(30), targetFloorReps: 8),
            PerformedSet(reps: nil, load: .kg(30), targetFloorReps: nil), // AMRAP sem reps → 0
            PerformedSet(kind: .warmup, reps: nil, load: .kg(20), targetFloorReps: 15),
        ]
        #expect(WorkoutMetrics.volumeKg(sets) == 240 + 300)
        #expect(WorkoutMetrics.recordedVolumeKg(sets) == 300)
        #expect(WorkoutMetrics.hasEstimatedVolume(sets))
        #expect(!WorkoutMetrics.hasEstimatedVolume([PerformedSet(reps: 10, load: .kg(30))]))
    }

    @Test func estimatedRepsNeverMakeRepRecords() {
        let ex = UUID()
        let history = [ex: WorkoutMetrics.bests(of: [PerformedSet(reps: 10, load: .kg(30))])]
        // Mais carga sem reps: recorde de carga sim; volume e 1RM (dependem de reps) não.
        let session = [ex: [PerformedSet(reps: nil, load: .kg(40), targetFloorReps: 12),
                            PerformedSet(reps: nil, load: .kg(40), targetFloorReps: 12)]]
        let records = WorkoutMetrics.personalRecords(session: session, history: history)
        #expect(records.map(\.kind) == [.heaviestLoad])
        #expect(records.first?.valueKg == 40)
        // Reps explícitas 0 não contam nem para carga.
        #expect(WorkoutMetrics.bests(of: [PerformedSet(reps: 0, load: .kg(100))]).heaviestLoadKg == 0)
    }

    @MainActor
    @Test func loadPolicyStillWorksWithoutReps() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let session = try f.sessions.start(routine: routine)
        for log in try #require(session.sortedExercises.first).sortedSets {
            try f.sessions.completeSet(log, load: log.kind.isWorking ? .kg(32.5) : nil)
        }
        let summary = try f.sessions.summary(for: session)
        #expect(summary.loadProposals.count == 3)
        #expect(summary.loadProposals.allSatisfy { $0.to == .kg(32.5) })
        #expect(summary.volumeKg == 3 * 8 * 32.5)
        #expect(summary.hasEstimatedVolume)
    }
}

struct WatchLinkCodecTests {
    private let t = Date(timeIntervalSinceReferenceDate: 800_000_123.456)

    private func roundTrip(_ message: WatchLinkMessage) throws -> WatchLinkMessage {
        try WatchLinkCodec.decode(try WatchLinkCodec.encode(message))
    }

    @Test func commandsRoundTrip() throws {
        let set = UUID(), ex = UUID(), session = UUID()
        let kinds: [SessionCommand.Kind] = [
            .start(routineID: UUID()), .start(routineID: nil),
            .completeSet(setID: set, reps: nil, load: WatchLoad(value: 32.5), durationSeconds: nil, distanceMeters: nil),
            .completeSet(setID: set, reps: 10, load: WatchLoad(value: -10, unit: .lb, isBodyweight: true),
                         durationSeconds: 42, distanceMeters: 1_000),
            .uncompleteSet(setID: set),
            .updateSet(setID: set, reps: 8, load: nil, durationSeconds: nil, distanceMeters: nil),
            .adjustLoad(setID: set, delta: -0.5), .startRest(seconds: nil), .startRest(seconds: 90),
            .adjustRest(seconds: -15), .skipRest, .startHold(setID: set), .endHold(setID: set),
            .skipExercise(exerciseID: ex, reason: .pain), .skipExercise(exerciseID: ex, reason: nil),
            .completeExercise(exerciseID: ex), .focusExercise(exerciseID: ex), .addSet(exerciseID: ex, kind: .dropSet),
            .addExercise(catalogExerciseID: UUID(), afterExerciseID: ex), .addExercise(catalogExerciseID: UUID(), afterExerciseID: nil),
            .substituteExercise(exerciseID: ex, withCatalogExerciseID: UUID()), .reorderExercise(exerciseID: ex, toIndex: 2),
            .pause, .resume, .finish(rpe: 8, applyLoadProposalIDs: [UUID(), UUID()]), .finish(rpe: nil, applyLoadProposalIDs: []),
            .discard,
        ]
        for kind in kinds {
            let command = SessionCommand(sessionID: session, issuedAt: t, origin: .watch, kind: kind)
            #expect(try roundTrip(.command(command)) == .command(command))
        }
        let reply = SessionCommandReply(commandID: UUID(), sessionID: session, outcome: .rejected(.unknownSet), revision: 7)
        #expect(try roundTrip(.commandReply(reply)) == .commandReply(reply))
        #expect(try roundTrip(.snapshotRequest) == .snapshotRequest)
        #expect(try roundTrip(.snapshot(nil)) == .snapshot(nil))
        #expect(try roundTrip(.programDigest(nil)) == .programDigest(nil))
    }

    @Test func versionIsCheckedBeforeDecoding() throws {
        let future = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 99))
        #expect(throws: WatchLinkCodecError.unsupportedVersion(99)) { try WatchLinkCodec.decode(future) }
        let old = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 0))
        #expect(throws: WatchLinkCodecError.unsupportedVersion(0)) { try WatchLinkCodec.decode(old) }
        #expect(throws: WatchLinkCodecError.malformed) { try WatchLinkCodec.decode(Data("nope".utf8)) }
        // Mensagem desconhecida na mesma versão → malformada (ignorar).
        let unknown = Data(#"{"schemaVersion":2,"message":{"teleport":{}}}"#.utf8)
        #expect(throws: WatchLinkCodecError.malformed) { try WatchLinkCodec.decode(unknown) }
        let envelope = try WatchLinkCodec.decodeEnvelope(try WatchLinkCodec.encode(.snapshotRequest))
        #expect(envelope.schemaVersion == WatchLinkProtocol.schemaVersion)
    }

    @MainActor
    @Test func snapshotAndDigestRoundTrip() throws {
        let f = try EngineFixture()
        try f.start(try f.makeRoutine())
        f.engine.send(.completeSet(setID: try f.sets(0)[1].id, reps: nil, load: WatchLoad(value: 31),
                                   durationSeconds: nil, distanceMeters: nil))
        let snapshot = try f.snapshot
        #expect(try roundTrip(.snapshot(snapshot)) == .snapshot(snapshot))

        let digest = try #require(try ProgramDigestBuilder.make(context: f.context, now: f.t0))
        #expect(try roundTrip(.programDigest(digest)) == .programDigest(digest))
    }
}

@MainActor
struct ProgramDigestTests {
    @Test func starterABCIsRealisticAndDigestible() throws {
        let f = try PersistenceFixture()
        #expect(try SampleProgramFactory.shouldOfferStarter(in: f.context))
        let program = try SampleProgramFactory.makeStarterABC(in: f.context)
        #expect(!(try SampleProgramFactory.shouldOfferStarter(in: f.context)))
        #expect(program.isActive && program.scheduleMode == .sequential)
        #expect(program.sortedRoutines.map(\.symbol) == ["A", "B", "C"])
        let all = program.sortedRoutines.flatMap(\.sortedExercises)
        #expect(all.allSatisfy { $0.exercise?.isBuiltIn == true })
        #expect(all.count >= 15)
        #expect(all.allSatisfy { ($0.restSeconds ?? 0) > 0 })
        #expect(all.flatMap(\.sortedSets).allSatisfy { $0.initialLoad == nil })

        let digest = try #require(try ProgramDigestBuilder.make(context: f.context))
        #expect(digest.programID == program.id && digest.scheduleMode == "sequential")
        #expect(digest.suggestedRoutines.map(\.symbol) == ["A"])
        let a = digest.routines[0]
        #expect(a.exercises[0].name == "Supino reto com barra")
        #expect(a.exercises[0].sets.count == 4)
        #expect(a.exercises[0].sets[0].targetText == "8–12")
        #expect(a.exercises[0].sets[0].repTarget == .range(min: 8, max: 12))
        #expect(a.exercises[0].sets[0].restSeconds == 120)
        #expect(a.estimatedDurationSeconds > 0)
        let b = digest.routines[1]
        let grouped = b.exercises.filter { $0.groupID != nil }
        #expect(grouped.count == 2 && Set(grouped.map(\.groupID)).count == 1) // bi-set de braços
        let plank = try #require(digest.routines[2].exercises.last)
        #expect(plank.measurementKind == .isometric && plank.sets[0].targetText == "45 s")

        // Segundo exemplo não rouba o programa ativo.
        let second = try SampleProgramFactory.makeStarterABC(in: f.context)
        #expect(!second.isActive && program.isActive)
    }

    @Test func digestReflectsCurrentLoadsAndSuggestion() throws {
        let f = try PersistenceFixture()
        #expect(try ProgramDigestBuilder.make(context: f.context) == nil)
        let (_, routine, bench) = try f.makeProgram()
        let second = try f.programs.addRoutine(to: try #require(routine.program), name: "B", symbol: "B")
        try f.programs.addExercise(try f.exercise("treadmill"), to: second, setCount: 1, repTarget: .fixed(reps: 1))
        let working = bench.sortedSets.filter { $0.kind.isWorking }
        working[0].currentLoad = .kg(35)
        working[0].effort = .rir(2)
        try f.context.save()
        let session = try f.sessions.start(routine: routine)
        try f.sessions.finish(session)

        let digest = try #require(try ProgramDigestBuilder.make(context: f.context))
        #expect(digest.suggestedRoutineIDs == [second.id]) // sequencial: depois de A vem B
        #expect(digest.routines[0].lastCompletedAt != nil)
        let sets = digest.routines[0].exercises[0].sets
        #expect(sets.map(\.kind) == [.warmup, .working, .working, .working])
        #expect(sets[1].load == WatchLoad(value: 35))
        #expect(sets[1].effort == .rir(2))
        #expect(sets[2].load == WatchLoad(value: 30))
        #expect(digest.routines[1].exercises[0].measurementKind == .timeOrDistance)
    }
}
