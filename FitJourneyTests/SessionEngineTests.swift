import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
final class FakeRestScheduler: RestNotificationScheduling {
    var scheduled: [Date] = []
    var cancelCount = 0
    var granted = true
    var requested = 0

    func authorization() async -> RestNotificationAuthorization { granted ? .authorized : .notDetermined }
    func requestAuthorization() async -> Bool { requested += 1; return granted }
    func scheduleRestEnd(at date: Date, nextExerciseName: String?) { scheduled.append(date) }
    func cancelRestEnd() { cancelCount += 1 }
}

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
struct EngineFixture {
    let base: PersistenceFixture
    let clock: TestClock
    let scheduler = FakeRestScheduler()
    let engine: SessionEngine
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var context: ModelContext { base.context }

    init(base: PersistenceFixture? = nil, clockAt: Date? = nil) throws {
        self.base = try base ?? PersistenceFixture()
        let clock = TestClock(clockAt ?? Date(timeIntervalSinceReferenceDate: 800_000_000))
        self.clock = clock
        engine = SessionEngine(context: self.base.context, notifications: scheduler, autoRestTimer: false,
                               now: { clock.now })
    }

    /// Ficha: supino (aquecimento + 3 × 8–12 a 30 kg, 90 s) → bi-set rosca (2) + tríceps (2), 60 s → prancha (2 × 45 s).
    func makeRoutine() throws -> Routine {
        let (_, routine, _) = try base.makeProgram()
        let group = UUID()
        let programs = base.programs
        try programs.addExercise(try base.exercise("barbell-curl"), to: routine, setCount: 2,
                                 repTarget: .range(min: 8, max: 12), load: .kg(20), restSeconds: 60, groupID: group)
        try programs.addExercise(try base.exercise("triceps-pushdown"), to: routine, setCount: 2,
                                 repTarget: .range(min: 10, max: 15), load: .kg(25), restSeconds: 60, groupID: group)
        let plank = try programs.addExercise(try base.exercise("plank"), to: routine, setCount: 2,
                                             repTarget: .fixed(reps: 1), restSeconds: 60)
        for set in plank.sets ?? [] { set.holdSeconds = 45 }
        try context.save()
        return routine
    }

    func command(_ kind: SessionCommand.Kind, at offset: TimeInterval, session: UUID,
                 origin: WatchCommandOrigin = .watch, id: UUID = UUID()) -> SessionCommand {
        SessionCommand(commandID: id, sessionID: session, issuedAt: t0.addingTimeInterval(offset), origin: origin, kind: kind)
    }

    /// Inicia pela ficha e devolve o ID da sessão.
    @discardableResult
    func start(_ routine: Routine?, at offset: TimeInterval = 0) throws -> UUID {
        let id = UUID()
        clock.now = t0.addingTimeInterval(offset)
        let result = engine.apply(command(.start(routineID: routine?.id), at: offset, session: id))
        try #require(result.isApplied)
        return id
    }

    /// Aplica com o relógio do iPhone em `t0 + offset` (ou depois, `phoneAt`).
    @discardableResult
    func apply(_ kind: SessionCommand.Kind, at offset: TimeInterval, session: UUID, phoneAt: TimeInterval? = nil,
               id: UUID = UUID()) -> SessionApplyResult {
        clock.now = t0.addingTimeInterval(max(offset, phoneAt ?? offset))
        return engine.apply(command(kind, at: offset, session: session, id: id))
    }

    var snapshot: SessionSnapshot { get throws { try #require(engine.snapshot) } }

    func sets(_ exerciseIndex: Int) throws -> [SessionSnapshot.ExerciseSet] {
        try snapshot.exercises[exerciseIndex].sets
    }
}

@MainActor
struct SessionEngineTests {
    // MARK: Idempotência e revisão

    @Test func sameCommandTwiceIsAppliedOnce() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let startID = UUID(), sessionID = UUID()
        let start = f.command(.start(routineID: routine.id), at: 0, session: sessionID, id: startID)
        #expect(f.engine.apply(start).isApplied)
        #expect(f.engine.apply(start) == .duplicate(revision: 1))
        #expect(try f.base.count(WorkoutSession.self) == 1)

        let setID = try f.sets(0)[1].id
        let complete = f.command(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                                 at: 100, session: sessionID)
        f.clock.now = f.t0.addingTimeInterval(100)
        #expect(f.engine.apply(complete).isApplied)
        f.clock.now = f.t0.addingTimeInterval(500)
        #expect(f.engine.apply(complete) == .duplicate(revision: 2))
        #expect(try f.sets(0)[1].completedAt == f.t0.addingTimeInterval(100))
        #expect(try f.snapshot.revision == 2)

        // Dedupe sobrevive a reabrir o app (IDs persistidos na sessão).
        let reopened = SessionEngine(context: f.context, autoRestTimer: false, now: { f.t0.addingTimeInterval(600) })
        reopened.restore()
        #expect(reopened.apply(complete) == .duplicate(revision: 2))
        #expect(reopened.snapshot?.revision == 2)
    }

    @Test func revisionIsMonotonic() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        var revisions = [try f.snapshot.revision]
        let set = try f.sets(0)[1].id
        let kinds: [SessionCommand.Kind] = [
            .adjustLoad(setID: set, delta: 2.5), .completeSet(setID: set, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil),
            .adjustRest(seconds: 15), .skipRest, .pause, .resume, .uncompleteSet(setID: set),
        ]
        for (index, kind) in kinds.enumerated() {
            let result = f.apply(kind, at: TimeInterval(10 * (index + 1)), session: session)
            guard case .applied(let revision, _) = result else { Issue.record("not applied: \(result)"); return }
            revisions.append(revision)
            #expect(try f.snapshot.revision == revision)
        }
        #expect(revisions == Array(1...8))
        // Recusa não muda a revisão.
        #expect(f.apply(.completeSet(setID: UUID(), reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 200, session: session) == .rejected(.unknownSet))
        #expect(try f.snapshot.revision == 8)
    }

    // MARK: Sequência completa

    @Test func fullSessionFlow() async throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let snapshots = f.engine.snapshots()
        let session = try f.start(routine)
        var snap = try f.snapshot
        #expect(snap.status == .active)
        #expect(snap.exercises.map(\.name) == ["Supino reto com barra", "Rosca direta com barra",
                                               "Tríceps na polia (corda)", "Prancha"])
        let bench = snap.exercises[0], curl = snap.exercises[1], pushdown = snap.exercises[2], plank = snap.exercises[3]
        #expect(curl.groupID != nil && curl.groupID == pushdown.groupID)
        #expect(snap.currentExerciseID == bench.id)
        #expect(snap.currentSetID == bench.sets[0].id)
        #expect(bench.sets[1].targetText == "8–12")
        #expect(bench.sets[1].plannedLoad == WatchLoad(value: 30))
        #expect(plank.sets[0].targetText == "45 s")

        // Aquecimento sem reps → descanso prescrito, notificação agendada.
        var result = f.apply(.completeSet(setID: bench.sets[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                             at: 60, session: session)
        let restEnd = f.t0.addingTimeInterval(60 + 90)
        #expect(result.events.contains(.setCompleted(setID: bench.sets[0].id, exerciseID: bench.id, at: f.t0.addingTimeInterval(60))))
        #expect(result.events.contains(.restStarted(endsAt: restEnd)))
        #expect(f.scheduler.scheduled.last == restEnd)
        snap = try f.snapshot
        #expect(snap.restEndsAt == restEnd)
        #expect(snap.restRemaining(at: f.t0.addingTimeInterval(100)) == 50)
        #expect(snap.currentSetPosition! == (2, 4))

        // Fim do descanso pela data, uma vez só.
        let stream = f.engine.events()
        var events = stream.makeAsyncIterator()
        f.clock.now = restEnd.addingTimeInterval(1)
        f.engine.refresh()
        f.engine.refresh()
        #expect(await events.next() == .restFinished(at: restEnd))

        // Crown: +2,5 kg e conclui as válidas (sem reps → volume estimado pelo piso 8).
        f.apply(.adjustLoad(setID: bench.sets[1].id, delta: 2.5), at: 200, session: session)
        #expect(try f.sets(0)[1].load == WatchLoad(value: 32.5))
        for (index, set) in bench.sets.dropFirst().enumerated() {
            f.apply(.completeSet(setID: set.id, reps: index == 2 ? 10 : nil, load: index == 0 ? nil : WatchLoad(value: 32.5),
                                 durationSeconds: nil, distanceMeters: nil), at: TimeInterval(300 + 150 * index), session: session)
        }
        snap = try f.snapshot
        #expect(snap.exercises[0].status == .completed)
        #expect(snap.metrics.volumeKg == 32.5 * 8 + 32.5 * 8 + 32.5 * 10)
        #expect(snap.metrics.hasEstimatedVolume)
        #expect(snap.loadProposals.count == 3)
        #expect(snap.currentExerciseID == curl.id) // bi-set começa pelo 1º membro

        // Bi-set: rosca não descansa; tríceps fecha a rodada e descansa; volta para a rosca.
        f.apply(.skipRest, at: 700, session: session)
        result = f.apply(.completeSet(setID: curl.sets[0].id, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil),
                         at: 760, session: session)
        #expect(!result.events.contains { if case .restStarted = $0 { true } else { false } })
        snap = try f.snapshot
        #expect(snap.restEndsAt == nil)
        #expect(snap.currentExerciseID == pushdown.id)
        result = f.apply(.completeSet(setID: pushdown.sets[0].id, reps: 12, load: nil, durationSeconds: nil, distanceMeters: nil),
                         at: 800, session: session)
        #expect(result.events.contains(.restStarted(endsAt: f.t0.addingTimeInterval(860))))
        #expect(try f.snapshot.currentExerciseID == curl.id)

        // Pula o resto do bi-set e vai para a prancha (isométrico).
        f.apply(.skipExercise(exerciseID: curl.id, reason: .equipmentBusy), at: 870, session: session)
        f.apply(.skipExercise(exerciseID: pushdown.id, reason: nil), at: 871, session: session)
        #expect(try f.snapshot.currentExerciseID == plank.id)
        result = f.apply(.startHold(setID: plank.sets[0].id), at: 900, session: session)
        #expect(result.events.contains(.holdStarted(setID: plank.sets[0].id, at: f.t0.addingTimeInterval(900))))
        #expect(try f.snapshot.holdSetID == plank.sets[0].id)
        f.apply(.endHold(setID: plank.sets[0].id), at: 942, session: session)
        snap = try f.snapshot
        #expect(snap.exercises[3].sets[0].durationSeconds == 42)
        #expect(snap.exercises[3].sets[0].isCompleted)
        #expect(snap.holdSetID == nil)

        // Finaliza com RPE e só a primeira proposta de carga.
        let proposalID = try #require(snap.loadProposals.first?.prescriptionID)
        let cancelsBefore = f.scheduler.cancelCount
        result = f.apply(.finish(rpe: 8, applyLoadProposalIDs: [proposalID]), at: 1_200, session: session)
        guard case .applied(_, let finishEvents) = result,
              case .sessionFinished(let finishedID, let summary) = finishEvents.first else {
            Issue.record("finish not applied: \(result)"); return
        }
        #expect(finishedID == session)
        #expect(summary.durationSeconds == 1_200)
        #expect(summary.hasEstimatedVolume)
        #expect(summary.skippedExercises.count == 2)
        #expect(f.engine.snapshot == nil)
        #expect(f.scheduler.cancelCount > cancelsBefore)
        let stored = try #require(try f.base.sessions.completedSessions().first)
        #expect(stored.id == session && stored.sessionRPE == 8)
        let updated = try f.context.fetch(FetchDescriptor<SetPrescription>()).filter { $0.currentLoad != nil }
        #expect(updated.map(\.id) == [proposalID])
        #expect(updated.first?.currentLoad == .kg(32.5))

        // O fluxo de snapshots recebeu o terminal.
        var last: SessionSnapshot?
        for await item in snapshots {
            last = item
            if item.status == .finished { break }
        }
        #expect(last?.status == .finished)
        #expect(last?.sessionID == session)
    }

    // MARK: Comandos inválidos

    @Test func invalidCommandsAreRejected() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        #expect(f.engine.send(.pause) == .rejected(.unknownSession))
        #expect(f.engine.send(.start(routineID: UUID())) == .rejected(.unknownRoutine))
        let session = try f.start(routine)
        #expect(f.engine.send(.start(routineID: nil)) == .rejected(.anotherSessionInProgress))
        let set = try f.sets(0)[1].id
        #expect(f.apply(.completeSet(setID: set, reps: -1, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 10, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.endHold(setID: set), at: 10, session: session) == .rejected(.invalidState))
        #expect(f.apply(.skipExercise(exerciseID: UUID(), reason: nil), at: 10, session: session) == .rejected(.unknownExercise))
        #expect(f.apply(.finish(rpe: 11, applyLoadProposalIDs: []), at: 10, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.pause, at: 10, session: UUID()) == .rejected(.unknownSession))
        #expect(try f.snapshot.revision == 1)

        #expect(f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 20, session: session).isApplied)
        #expect(f.apply(.completeSet(setID: set, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 30, session: session) == .rejected(.sessionNotInProgress))
        #expect(f.apply(.start(routineID: nil), at: 30, session: session) == .rejected(.sessionNotInProgress))
    }

    // MARK: Relógio offline / fora de ordem

    @Test func offlineCommandsApplyByIssuedAt() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let sets = try f.sets(0)
        // Relógio offline: série 2 (t=200) chega antes da série 1 (t=100); tudo entregue em t=400.
        f.apply(.completeSet(setID: sets[2].id, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 200, session: session, phoneAt: 250)
        let restFromLatest = f.t0.addingTimeInterval(200 + 90)
        #expect(try f.snapshot.restEndsAt == restFromLatest)
        f.apply(.completeSet(setID: sets[1].id, reps: 9, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 100, session: session, phoneAt: 260)
        #expect(try f.sets(0)[1].completedAt == f.t0.addingTimeInterval(100))
        #expect(try f.snapshot.restEndsAt == restFromLatest) // a conclusão antiga não reinicia o descanso
        // "Pular descanso" emitido antes da última série se referia a outro descanso: ignorado.
        #expect(f.apply(.skipRest, at: 150, session: session, phoneAt: 270).isApplied)
        #expect(try f.snapshot.restEndsAt == restFromLatest)
        // Horário futuro (relógio adiantado) é limitado ao agora do iPhone.
        f.clock.now = f.t0.addingTimeInterval(300)
        f.engine.apply(f.command(.completeSet(setID: sets[3].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                                 at: 9_999, session: session))
        #expect(try f.sets(0)[3].completedAt == f.t0.addingTimeInterval(300))
    }

    @Test func completingWhilePausedResumesAtIssuedAt() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.pause, at: 100, session: session)
        #expect(try f.snapshot.status == .paused)
        let result = f.apply(.completeSet(setID: try f.sets(0)[1].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                             at: 160, session: session)
        #expect(result.events.contains(.sessionResumed(at: f.t0.addingTimeInterval(160))))
        let snap = try f.snapshot
        #expect(snap.status == .active)
        #expect(snap.accumulatedPauseSeconds == 60)
        #expect(snap.elapsed(at: f.t0.addingTimeInterval(200)) == 140)
    }

    // MARK: Retomada e treino esquecido

    @Test func restoreDetectsForgottenSession() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.completeSet(setID: try f.sets(0)[1].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 600, session: session)

        // Dentro de 4 h: sem pergunta.
        let soon = SessionEngine(context: f.context, autoRestTimer: false, now: { f.t0.addingTimeInterval(600 + 3_600) })
        soon.restore()
        #expect(soon.staleSessionPrompt == nil)
        #expect(soon.snapshot?.sessionID == session)

        // 5 h depois da última série: pergunta e finaliza no horário da última série.
        let later = SessionEngine(context: f.context, autoRestTimer: false, now: { f.t0.addingTimeInterval(600 + 5 * 3_600) })
        later.restore()
        let prompt = try #require(later.staleSessionPrompt)
        #expect(prompt.sessionID == session)
        #expect(prompt.suggestedEndAt == f.t0.addingTimeInterval(600))
        later.resolveStaleSession(.finishAtLastSet())
        #expect(later.snapshot == nil && later.staleSessionPrompt == nil)
        let stored = try #require(try f.base.sessions.completedSessions().first)
        #expect(stored.endedAt == f.t0.addingTimeInterval(600))
        #expect(stored.clock.elapsed(at: .distantFuture) == 600)
    }

    @Test func forgottenSessionKeepGoingAndDiscard() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let clock = TestClock(f.t0.addingTimeInterval(5 * 3_600))
        let engine = SessionEngine(context: f.context, autoRestTimer: false, now: { clock.now })
        engine.restore()
        #expect(engine.staleSessionPrompt != nil)
        engine.resolveStaleSession(.keepGoing)
        #expect(engine.staleSessionPrompt == nil)
        engine.restore()
        #expect(engine.staleSessionPrompt == nil) // atividade passou a contar de agora

        clock.now = clock.now.addingTimeInterval(5 * 3_600)
        engine.restore()
        #expect(engine.staleSessionPrompt?.sessionID == session)
        engine.resolveStaleSession(.discard)
        #expect(engine.snapshot == nil)
        #expect(try f.base.count(WorkoutSession.self) == 0)
    }

    @Test func discardIsIdempotentAndBroadcastsTerminalSnapshot() async throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let stream = f.engine.snapshots()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.status == .active) // estado atual na assinatura
        let discardID = UUID()
        #expect(f.apply(.discard, at: 50, session: session, id: discardID) == .applied(revision: 2, events: [.sessionDiscarded(sessionID: session)]))
        let terminal = await iterator.next()
        #expect(terminal?.status == .discarded && terminal?.revision == 2)
        #expect(f.apply(.discard, at: 50, session: session, id: discardID) == .duplicate(revision: 0))
        #expect(f.apply(.discard, at: 60, session: session) == .rejected(.unknownSession))
    }

    // MARK: Exercício atual, foco e notificação

    @Test func focusOverridesCurrentExerciseUntilClosed() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let snap = try f.snapshot
        let plank = snap.exercises[3], curl = snap.exercises[1], pushdown = snap.exercises[2]
        f.apply(.focusExercise(exerciseID: plank.id), at: 10, session: session)
        #expect(try f.snapshot.currentExerciseID == plank.id)
        f.apply(.completeExercise(exerciseID: plank.id), at: 20, session: session)
        #expect(try f.snapshot.exercises[3].status == .partial)
        #expect(try f.snapshot.currentExerciseID == snap.exercises[0].id)

        // Foco num membro do bi-set cede à alternância quando a série é concluída.
        f.apply(.focusExercise(exerciseID: pushdown.id), at: 30, session: session)
        #expect(try f.snapshot.currentExerciseID == pushdown.id)
        f.apply(.completeSet(setID: pushdown.sets[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 40, session: session)
        #expect(try f.snapshot.currentExerciseID == snap.exercises[0].id) // supino segue primeiro na ordem
        f.apply(.skipExercise(exerciseID: snap.exercises[0].id, reason: nil), at: 50, session: session)
        #expect(try f.snapshot.currentExerciseID == curl.id) // rosca está atrás na rodada

        // Focar um exercício pulado o retoma.
        f.apply(.focusExercise(exerciseID: snap.exercises[0].id), at: 60, session: session)
        #expect(try f.snapshot.exercises[0].status == .pending)
        #expect(try f.snapshot.currentExerciseID == snap.exercises[0].id)
    }

    @Test func restNotificationFollowsPauseAndSkip() async throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.startRest(seconds: nil), at: 10, session: session)
        #expect(f.scheduler.scheduled == [f.t0.addingTimeInterval(10 + 90)]) // descanso do exercício atual
        f.apply(.pause, at: 20, session: session)
        #expect(f.scheduler.cancelCount == 1)
        f.apply(.resume, at: 50, session: session)
        #expect(f.scheduler.scheduled.last == f.t0.addingTimeInterval(130))
        f.apply(.adjustRest(seconds: 15), at: 60, session: session)
        #expect(f.scheduler.scheduled.last == f.t0.addingTimeInterval(145))
        f.apply(.skipRest, at: 70, session: session)
        #expect(f.scheduler.cancelCount == 2)
        #expect(await f.engine.requestNotificationPermission())
        #expect(f.scheduler.requested == 1)
    }

    @Test func addSetAndWatchStartedFreeSession() throws {
        let f = try EngineFixture()
        let session = try f.start(nil)
        let snap = try f.snapshot
        #expect(snap.exercises.isEmpty && snap.currentExerciseID == nil)
        #expect(snap.routineID == nil)
        // Treino livre: a UI adiciona exercício pelo store; o motor publica ao próximo comando.
        let stored = try #require(f.engine.activeSession)
        let exercise = try f.base.sessions.addExercise(try f.base.exercise("leg-press"), to: stored, setCount: 1)
        f.apply(.addSet(exerciseID: exercise.id, kind: .warmup), at: 10, session: session)
        #expect(try f.snapshot.exercises.first?.sets.map(\.kind) == [.working, .warmup])
    }
}
