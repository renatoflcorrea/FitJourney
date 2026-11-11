import Foundation
import SwiftData
import Testing
@testable import FitJourney

private struct InjectedSaveFailure: Error {}

/// Correções da revisão do P2.1.
@MainActor
struct SessionEngineReviewTests {
    private func complete(_ id: UUID, reps: Int? = nil) -> SessionCommand.Kind {
        .completeSet(setID: id, reps: reps, load: nil, durationSeconds: nil, distanceMeters: nil)
    }

    @Test func olderCommandDoesNotResumePause() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.pause, at: 100, session: session)
        let sets = try f.sets(0)
        // Série feita antes da pausa, entregue depois (relógio offline): registra sem retomar.
        let result = f.apply(complete(sets[1].id), at: 80, session: session, phoneAt: 120)
        #expect(result.isApplied)
        #expect(!result.events.contains(.sessionResumed(at: f.t0.addingTimeInterval(80))))
        let snap = try f.snapshot
        #expect(snap.status == .paused)
        #expect(snap.exercises[0].sets[1].completedAt == f.t0.addingTimeInterval(80))
        f.apply(.startHold(setID: try f.sets(3)[0].id), at: 90, session: session, phoneAt: 130)
        #expect(try f.snapshot.status == .paused)
        // Posterior à pausa: retoma.
        f.apply(complete(sets[2].id), at: 150, session: session)
        #expect(try f.snapshot.status == .active)
    }

    @Test func tombstonesSurviveRestart() throws {
        let f = try EngineFixture()
        let startID = UUID(), completeID = UUID()
        let session = UUID()
        f.clock.now = f.t0
        #expect(f.engine.apply(f.command(.start(routineID: try f.makeRoutine().id), at: 0, session: session, id: startID)).isApplied)
        let setID = try f.sets(0)[1].id
        f.apply(complete(setID), at: 10, session: session, id: completeID)
        #expect(f.apply(.discard, at: 20, session: session) == .applied(revision: 3, events: [.sessionDiscarded(sessionID: session)]))

        let reopened = f.reopen(at: 100)
        reopened.restore()
        #expect(reopened.snapshot == nil)
        #expect(reopened.apply(f.command(complete(setID), at: 10, session: session, id: completeID)) == .duplicate(revision: 3))
        #expect(reopened.apply(f.command(.pause, at: 30, session: session)) == .duplicate(revision: 3))
        #expect(reopened.apply(f.command(.start(routineID: nil), at: 0, session: session, id: startID)) == .duplicate(revision: 3))
        #expect(reopened.apply(f.command(.start(routineID: nil), at: 40, session: session)) == .rejected(.sessionDiscarded))
        #expect(try f.base.count(WorkoutSession.self) == 0)
    }

    @Test func perSetOrderingIgnoresOlderCommands() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let set = try f.sets(0)[1].id
        f.apply(.updateSet(setID: set, reps: 10, load: WatchLoad(value: 30), durationSeconds: nil, distanceMeters: nil),
                at: 300, session: session)
        #expect(f.apply(.updateSet(setID: set, reps: 5, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 200, session: session, phoneAt: 310).isApplied)
        #expect(f.apply(.adjustLoad(setID: set, delta: 5), at: 250, session: session, phoneAt: 320).isApplied)
        var line = try f.sets(0)[1]
        #expect(line.reps == 10 && line.load == WatchLoad(value: 30))

        f.apply(complete(set), at: 400, session: session)
        f.apply(.uncompleteSet(setID: set), at: 350, session: session, phoneAt: 410)
        line = try f.sets(0)[1]
        #expect(line.isCompleted)
        // `startRest` explícito anterior à última série também é ignorado.
        let rest = try f.snapshot.restEndsAt
        f.apply(.startRest(seconds: 10), at: 390, session: session, phoneAt: 420)
        #expect(try f.snapshot.restEndsAt == rest)
    }

    /// Lê o que está gravado em disco (contexto novo, sem as mudanças pendentes da memória).
    private func onDisk<T: PersistentModel>(_ f: EngineFixture, _ type: T.Type) throws -> [T] {
        try ModelContext(f.base.container).fetch(FetchDescriptor<T>())
    }

    @Test func failedSaveIsHeldAndResendCommits() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let set = try f.sets(0)[1].id
        let exerciseID = try f.snapshot.exercises[0].id
        let command = f.command(complete(set, reps: 9), at: 50, session: session)
        f.clock.now = f.t0.addingTimeInterval(50)
        f.engine.beforeSave = { throw InjectedSaveFailure() }
        #expect(f.engine.apply(command) == .rejected(.persistenceFailed))
        #expect(f.engine.lastPersistenceError != nil)
        // Nada gravado: nem a série, nem o registro do comando/revisão.
        let diskLog = try #require(try onDisk(f, SetLog.self).first { $0.id == set })
        #expect(!diskLog.isCompleted && diskLog.reps == nil)
        let diskSession = try #require(try onDisk(f, WorkoutSession.self).first)
        #expect(diskSession.revision == 1 && diskSession.appliedCommandIDs.count == 1)
        #expect(try f.snapshot.revision == 1) // não publicado

        // Ainda falhando: qualquer comando é recusado sem aplicar nada novo.
        #expect(f.apply(.pause, at: 60, session: session) == .rejected(.persistenceFailed))

        // Reenvio com o save funcionando: grava o pendente e devolve o resultado original.
        f.engine.beforeSave = nil
        #expect(f.engine.apply(command) == .applied(revision: 2, events: [
            .setCompleted(setID: set, exerciseID: exerciseID, at: f.t0.addingTimeInterval(50)),
            .restStarted(endsAt: f.t0.addingTimeInterval(140)),
        ]))
        #expect(f.engine.lastPersistenceError == nil)
        #expect(try f.snapshot.revision == 2)
        #expect(try onDisk(f, SetLog.self).first { $0.id == set }?.reps == 9)
        #expect(f.engine.apply(command) == .duplicate(revision: 2))
    }

    @Test func pendingCommitIsFlushedByNextCommand() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let set = try f.sets(0)[1].id
        f.engine.beforeSave = { throw InjectedSaveFailure() }
        let first = f.command(complete(set), at: 50, session: session)
        f.clock.now = f.t0.addingTimeInterval(50)
        #expect(f.engine.apply(first) == .rejected(.persistenceFailed))
        f.engine.beforeSave = nil
        #expect(f.apply(.pause, at: 70, session: session) == .applied(revision: 3, events: [.sessionPaused(at: f.t0.addingTimeInterval(70))]))
        #expect(try f.sets(0)[1].isCompleted)
        #expect(f.engine.apply(first) == .duplicate(revision: 3))
    }

    @Test func failedStartIsNotPersistedUntilRetried() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let command = f.command(.start(routineID: routine.id), at: 0, session: UUID())
        f.engine.beforeSave = { throw InjectedSaveFailure() }
        #expect(f.engine.apply(command) == .rejected(.persistenceFailed))
        #expect(try onDisk(f, WorkoutSession.self).isEmpty)
        #expect(f.engine.snapshot == nil)
        f.engine.beforeSave = nil
        #expect(f.engine.apply(command).isApplied)
        #expect(try onDisk(f, WorkoutSession.self).count == 1)
        #expect(f.engine.snapshot?.revision == 1)
    }

    @Test func restFinishedHasTolerance() async throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.startRest(seconds: 90), at: 10, session: session)
        let stream = f.engine.events()
        var events = stream.makeAsyncIterator()
        f.clock.now = f.t0.addingTimeInterval(100 + 60) // vencido há 60 s: sem aviso
        f.engine.refresh()
        f.apply(.startRest(seconds: 90), at: 300, session: session)
        f.clock.now = f.t0.addingTimeInterval(390 + 5)
        f.engine.refresh()
        #expect(await events.next() == .restStarted(endsAt: f.t0.addingTimeInterval(390)))
        #expect(await events.next() == .restFinished(at: f.t0.addingTimeInterval(390)))
    }

    @Test func restEventsForHoldAndResume() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.startRest(seconds: 90), at: 10, session: session)
        f.apply(.pause, at: 20, session: session)
        let resumed = f.apply(.resume, at: 50, session: session)
        #expect(resumed.events == [.sessionResumed(at: f.t0.addingTimeInterval(50)),
                                   .restAdjusted(endsAt: f.t0.addingTimeInterval(130))])
        let hold = f.apply(.startHold(setID: try f.sets(3)[0].id), at: 60, session: session)
        #expect(hold.events.first == .restSkipped)
        #expect(try f.snapshot.restEndsAt == nil)
    }

    @Test func valueLimits() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let set = try f.sets(0)[1].id
        #expect(f.apply(.startRest(seconds: 3_601), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.startRest(seconds: -1), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.adjustRest(seconds: -4_000), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.adjustLoad(setID: set, delta: .nan), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.adjustLoad(setID: set, delta: 1_000), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.completeSet(setID: set, reps: nil, load: WatchLoad(value: .infinity), durationSeconds: nil,
                                     distanceMeters: nil), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.updateSet(setID: set, reps: nil, load: WatchLoad(value: -5), durationSeconds: nil,
                                   distanceMeters: nil), at: 1, session: session) == .rejected(.invalidValue))
        #expect(f.apply(.updateSet(setID: set, reps: 5, load: WatchLoad(value: -5, isBodyweight: true), durationSeconds: nil,
                                   distanceMeters: nil), at: 1, session: session).isApplied) // assistência
        #expect(f.apply(.startRest(seconds: 3_600), at: 2, session: session).isApplied)
    }

    @Test func addSubstituteAndReorderGoThroughEngine() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let snap = try f.snapshot
        let legPress = try f.base.exercise("leg-press")
        f.apply(.addExercise(catalogExerciseID: legPress.id, afterExerciseID: snap.exercises[0].id), at: 10, session: session)
        var names = try f.snapshot.exercises.map(\.name)
        #expect(names == ["Supino reto com barra", "Leg press 45°", "Rosca direta com barra",
                          "Tríceps na polia (corda)", "Prancha"])
        f.apply(.addExercise(catalogExerciseID: legPress.id, afterExerciseID: nil), at: 11, session: session)
        #expect(try f.snapshot.exercises.last?.name == "Leg press 45°")

        let curl = snap.exercises[1]
        let hammer = try f.base.exercise("hammer-curl")
        f.apply(.substituteExercise(exerciseID: curl.id, withCatalogExerciseID: hammer.id), at: 12, session: session)
        let swapped = try #require(f.engine.activeSession?.exercises?.first { $0.id == curl.id })
        #expect(swapped.name == "Rosca martelo" && swapped.substitutedFromName == "Rosca direta com barra")

        f.apply(.reorderExercise(exerciseID: snap.exercises[3].id, toIndex: 0), at: 13, session: session)
        names = try f.snapshot.exercises.map(\.name)
        #expect(names.first == "Prancha")
        f.apply(.reorderExercise(exerciseID: snap.exercises[3].id, toIndex: 99), at: 14, session: session)
        #expect(try f.snapshot.exercises.last?.name == "Prancha")
        #expect(Set(try f.snapshot.exercises.map(\.id)).count == 6)

        #expect(f.apply(.addExercise(catalogExerciseID: UUID(), afterExerciseID: nil), at: 15, session: session)
                == .rejected(.unknownCatalogExercise))
        #expect(f.apply(.reorderExercise(exerciseID: curl.id, toIndex: -1), at: 15, session: session) == .rejected(.invalidValue))
    }

    @Test func notificationNameFollowsFocus() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.apply(.startRest(seconds: 90), at: 10, session: session)
        #expect(f.scheduler.names.last == "Supino reto com barra")
        f.apply(.focusExercise(exerciseID: try f.snapshot.exercises[3].id), at: 20, session: session)
        #expect(f.scheduler.names.last == "Prancha")
        #expect(f.scheduler.scheduled.count == 2 && Set(f.scheduler.scheduled).count == 1)
    }

    @Test func handleForegroundReevaluatesStaleSession() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        f.engine.handleForeground()
        #expect(f.engine.staleSessionPrompt == nil)
        f.clock.now = f.t0.addingTimeInterval(5 * 3_600)
        f.engine.handleForeground()
        #expect(f.engine.staleSessionPrompt?.sessionID == session)
        // Sem sessão carregada, volta a carregar.
        let fresh = f.reopen(at: 5 * 3_600)
        fresh.handleForeground()
        #expect(fresh.snapshot?.sessionID == session && fresh.staleSessionPrompt != nil)
    }
}

struct WatchLinkCompatibilityTests {
    @MainActor
    @Test func futureFieldsAndUnknownRawValuesDoNotBreakMessages() throws {
        let f = try EngineFixture()
        try f.start(try f.makeRoutine())
        var json = try #require(String(data: try WatchLinkCodec.encode(.snapshot(try f.snapshot)), encoding: .utf8))
        #expect(json.contains(#""status":"active""#))
        json = json.replacingOccurrences(of: #""status":"active""#, with: #""status":"hyperdrive""#)
        json = json.replacingOccurrences(of: #""measurementKind":"isometric""#, with: #""measurementKind":"swim""#)
        json = json.replacingOccurrences(of: #""schemaVersion":1"#, with: #""futureField":{"x":1},"schemaVersion":1"#)
        guard case .snapshot(let decoded?) = try WatchLinkCodec.decode(Data(json.utf8)) else {
            Issue.record("snapshot não decodificado"); return
        }
        #expect(decoded.status == .unknown)
        #expect(decoded.exercises[3].measurementKind == .unknown)
        #expect(decoded.exercises[0].measurementKind == .repsAndLoad)
    }

    @Test func unknownEnumValuesDecodeAsUnknown() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(WatchExerciseStatus.self, from: Data(#""frozen""#.utf8)) == .unknown)
        #expect(try decoder.decode(WatchSetKind.self, from: Data(#""cluster""#.utf8)) == .unknown)
        #expect(try decoder.decode(WatchSkipReason.self, from: Data(#""pain""#.utf8)) == .pain)
        #expect(WatchSetKind.unknown.setKind == .working)
    }

    @Test func incompatibilityNoticeIsReadableAcrossVersions() throws {
        let future = WatchLinkCompatibility(minimumVersion: 5, currentVersion: 7)
        let data = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .incompatible(future), schemaVersion: 7))
        #expect(try WatchLinkCodec.decode(data) == .incompatible(future))
        #expect(!future.peerIsOutdated) // o outro lado é mais novo: este precisa atualizar
        #expect(try WatchLinkCodec.decode(try WatchLinkCodec.incompatibilityNotice()) == .incompatible(.current))
        // Fluxo: mensagem de versão futura → `unsupportedVersion` → responder com o aviso.
        let unknown = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 9))
        #expect(throws: WatchLinkCodecError.unsupportedVersion(9)) { try WatchLinkCodec.decode(unknown) }
    }
}
