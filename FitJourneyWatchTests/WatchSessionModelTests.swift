import Foundation
import Testing
@testable import FitJourneyWatch

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
struct WatchSessionModelTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Rig {
        var model: WatchSessionModel
        var transport: MockWatchTransport
        var haptics: RecordingHaptics
        var health: FixedHealthProvider
        var snapshot: SessionSnapshot
        var clock: TestClock
    }

    /// Modelo com relógio controlável, iPhone simulado que não responde sozinho e sessão com `completed` séries feitas.
    private func make(completed: Int = 0, reachable: Bool = true, revision: Int = 5, snapshot custom: SessionSnapshot? = nil,
                      recording: Bool = false) -> Rig {
        let digest = WatchFixtures.digest(now: t0)
        let snapshot = custom ?? WatchFixtures.snapshot(completed: completed, now: t0, startedAgo: 600, revision: revision)
        let transport = MockWatchTransport(digest: digest, snapshot: snapshot, reachable: reachable)
        transport.autoRespond = false
        let haptics = RecordingHaptics()
        let health = FixedHealthProvider(access: .authorized)
        let clock = TestClock(t0)
        let model = WatchSessionModel(transport: transport, haptics: haptics, health: health, clock: { clock.now })
        model.loadCoalesceInterval = 0 // coalescência tem testes próprios
        model.receive(digest: digest)
        model.receive(snapshot: snapshot)
        if recording { model.startRecordingOnWatch() }
        return Rig(model: model, transport: transport, haptics: haptics, health: health, snapshot: snapshot, clock: clock)
    }

    private func reply(_ command: SessionCommand, revision: Int, _ outcome: SessionCommandReply.Outcome = .applied) -> WatchLinkMessage {
        .commandReply(.init(commandID: command.commandID, sessionID: command.sessionID, outcome: outcome, revision: revision))
    }

    private func sentCommands(_ transport: MockWatchTransport) -> [SessionCommand] {
        transport.sent.compactMap { if case .command(let c) = $0 { c } else { nil } }
    }

    // MARK: Reconciliação otimista

    @Test func localCommandIsAppliedOptimisticallyAndQueued() throws {
        let r = make()
        let setID = try #require(r.snapshot.currentSetID)
        r.model.completeCurrentSet()
        #expect(r.model.display?.exercises[0].sets[0].isCompleted == true)
        #expect(r.model.confirmed?.exercises[0].sets[0].isCompleted == false)
        #expect(r.model.pendingCount == 1)
        #expect(r.model.display?.currentSetID != setID)
        let sent = try #require(sentCommands(r.transport).last)
        #expect(sent.origin == .watch)
        #expect(sent.sessionID == r.snapshot.sessionID)
    }

    @Test func completingSetStartsRestFromPrescription() {
        let r = make()
        r.model.completeCurrentSet()
        #expect(r.model.display?.restEndsAt == t0.addingTimeInterval(90))
    }

    @Test func newerSnapshotReplacesAndAckedCommandIsDropped() throws {
        let r = make()
        r.model.completeCurrentSet()
        let command = try #require(r.model.pending.first?.command)
        r.model.handle(reply(command, revision: 6))
        #expect(r.model.pendingCount == 1) // respondido, mas o snapshot ainda não o contém
        #expect(r.model.display?.exercises[0].sets[0].isCompleted == true)

        var phone = SessionReducer.apply(command, to: r.snapshot)!
        phone.revision = 6
        r.model.receive(snapshot: phone)
        #expect(r.model.pendingCount == 0)
        #expect(r.model.confirmed?.revision == 6)
        #expect(r.model.display == phone)
    }

    @Test func olderSnapshotIsDiscarded() {
        let r = make(revision: 5)
        var stale = r.snapshot
        stale.revision = 4
        stale.routineName = "velho"
        r.model.receive(snapshot: stale)
        #expect(r.model.confirmed?.revision == 5)
        #expect(r.model.display?.routineName != "velho")
    }

    @Test func equalRevisionIsAccepted() {
        let r = make(revision: 5)
        var same = r.snapshot
        same.routineName = "mesmo"
        r.model.receive(snapshot: same)
        #expect(r.model.confirmed?.routineName == "mesmo")
    }

    @Test func unackedCommandsAreReappliedOverNewerSnapshotThatLacksThem() throws {
        let r = make()
        let setID = try #require(r.snapshot.currentSetID)
        r.model.adjustLoad(setID: setID, by: 0.5)
        var phone = r.snapshot
        phone.revision = 6
        phone.routineName = "iPhone mudou"
        r.model.receive(snapshot: phone)
        #expect(r.model.pendingCount == 1)
        #expect(r.model.display?.routineName == "iPhone mudou")
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 26.5)
    }

    @Test func rejectedCommandRevertsNotifiesAndRequestsSnapshot() throws {
        let r = make()
        r.model.completeCurrentSet()
        let command = try #require(r.model.pending.first?.command)
        r.model.handle(reply(command, revision: 5, .rejected(.invalidState)))
        #expect(r.model.pendingCount == 0)
        #expect(r.model.display?.exercises[0].sets[0].isCompleted == false)
        #expect(r.model.notice?.text == "Atualizado pelo iPhone")
        #expect(r.haptics.events.contains(.failure))
        #expect(r.transport.sent.last == .snapshotRequest) // M1
    }

    @Test func duplicateReplyCountsAsApplied() throws {
        let r = make()
        r.model.completeCurrentSet()
        let command = try #require(r.model.pending.first?.command)
        r.model.handle(reply(command, revision: 5, .duplicate))
        #expect(r.model.pendingCount == 0)
    }

    @Test func sessionStartedOnPhoneAppearsOnWatch() {
        let digest = WatchFixtures.digest(now: t0)
        let health = FixedHealthProvider(access: .authorized)
        let model = WatchSessionModel(transport: MockWatchTransport(digest: digest), haptics: RecordingHaptics(), health: health, clock: { [t0] in t0 })
        #expect(!model.hasActiveSession)
        model.receive(snapshot: WatchFixtures.snapshot(completed: 0, now: t0))
        #expect(model.hasActiveSession)
        // Iniciada no iPhone: o relógio só controla e oferece gravar (FC do relógio).
        #expect(health.began == 0)
        #expect(model.canOfferWatchRecording)
    }

    // MARK: Poda da fila

    @Test func pendingCommandsWithUnknownIDsAreDroppedOnSnapshot() throws {
        let r = make()
        r.model.send(.adjustLoad(setID: UUID(), delta: 0.5)) // série inexistente
        #expect(r.model.pendingCount == 1)
        var next = r.snapshot
        next.revision = 6
        r.model.receive(snapshot: next)
        #expect(r.model.pendingCount == 0)
    }

    @Test func doubleStartIsGuarded() {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        model.startSession(routineID: WatchFixtures.routineB)
        #expect(sentCommands(transport).filter { $0.kind.isStart }.count == 1)
    }

    @Test func nilSnapshotAfterStartAckDoesNotEraseSession() throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        let start = try #require(model.pending.first?.command)
        model.handle(reply(start, revision: 1))
        model.receive(snapshot: nil) // atrasado
        #expect(model.hasActiveSession)
    }

    @Test func rejectedStartEndsWorkoutAndDropsDependents() throws {
        let digest = WatchFixtures.digest(now: t0)
        let health = FixedHealthProvider(access: .authorized)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: health, clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        model.completeCurrentSet()
        #expect(health.began == 1)
        let start = try #require(model.pending.first?.command)
        model.handle(reply(start, revision: 0, .rejected(.anotherSessionInProgress)))
        #expect(!model.hasActiveSession)
        #expect(model.pendingCount == 0)
        #expect(health.ended == 1) // M2
    }

    // MARK: Fila pendente, reenvio e timeouts

    @Test func pendingCommandsKeepOrderAndResendOnReconnect() throws {
        let r = make(reachable: false)
        let setID = try #require(r.snapshot.currentSetID)
        r.model.adjustLoad(setID: setID, by: 0.5)
        r.model.completeCurrentSet()
        let ids = r.model.pending.map(\.id)
        #expect(ids.count == 2)
        #expect(r.model.connection == .phoneUnreachable)

        let before = r.transport.sent.count
        r.model.handle(.reachability(true))
        let resent = r.transport.sent.dropFirst(before).compactMap { message -> UUID? in
            if case .command(let c) = message { return c.commandID }
            return nil
        }
        #expect(resent == ids)
        #expect(r.transport.sent.last == .snapshotRequest)
    }

    @Test func ackedCommandsAreNotResent() throws {
        let r = make(reachable: false)
        r.model.completeCurrentSet()
        let command = try #require(r.model.pending.first?.command)
        r.model.handle(reply(command, revision: 9))
        let before = r.transport.sent.count
        r.model.handle(.reachability(true))
        let commands = r.transport.sent.dropFirst(before).filter { if case .command = $0 { true } else { false } }
        #expect(commands.isEmpty)
    }

    /// A3: resposta perdida. O snapshot chega com o comando já aplicado; sem resposta o relógio reaplicaria por cima
    /// (carga dobrada) até o reenvio devolver `duplicate`.
    @Test func lostReplyIsResentAndDuplicateClearsIt() throws {
        let r = make()
        let setID = try #require(r.snapshot.currentSetID)
        r.model.adjustLoad(setID: setID, by: 0.5)
        let command = try #require(r.model.pending.first?.command)

        var phone = SessionReducer.apply(command, to: r.snapshot)!
        phone.revision = 6
        r.model.receive(snapshot: phone) // resposta se perdeu
        #expect(r.model.pendingCount == 1)

        let before = sentCommands(r.transport).count
        r.model.retryStalePending() // cedo demais: nada
        #expect(sentCommands(r.transport).count == before)

        r.clock.now = t0.addingTimeInterval(6)
        r.model.retryStalePending()
        let resent = sentCommands(r.transport)
        #expect(resent.count == before + 1)
        #expect(resent.last?.commandID == command.commandID)
        #expect(r.transport.sent.last == .snapshotRequest)

        r.model.handle(reply(command, revision: 6, .duplicate))
        #expect(r.model.pendingCount == 0)
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 26.5) // sem dobrar
    }

    @Test func awaitingSnapshotTimesOut() {
        let r = make(reachable: true)
        r.model.requestSnapshot()
        #expect(r.model.connection == .syncing)
        r.clock.now = t0.addingTimeInterval(11)
        r.model.retryStalePending()
        #expect(r.model.connection == .connected)
    }

    @Test func startIsIdempotentAndSubscribesOnce() async {
        let r = make()
        r.model.start()
        r.model.start()
        defer { r.model.stop() }
        #expect(r.transport.sent.filter { $0 == .snapshotRequest }.count == 1)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    // MARK: Coroa: passo e limites

    @Test func crownStepsAreHalfKilogram() throws {
        let r = make()
        let setID = try #require(r.snapshot.currentSetID)
        r.model.setLoad(setID: setID, to: 27.5)
        let sent = try #require(sentCommands(r.transport).last)
        guard case .adjustLoad(_, let delta) = sent.kind else { Issue.record("sem adjustLoad"); return }
        #expect(delta == 1.5)
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 27.5)
    }

    @Test func crownSnapsToStep() {
        let load = WatchLoad(value: 20)
        #expect(WatchLoadStepping.clamp(20.3, for: load) == 20.5)
        #expect(WatchLoadStepping.clamp(20.2, for: load) == 20.0)
    }

    @Test func loadCannotGoBelowZeroOrAboveMax() throws {
        let r = make()
        let setID = try #require(r.snapshot.currentSetID)
        r.model.adjustLoad(setID: setID, by: -100)
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 0)
        let count = r.transport.sent.count
        r.model.adjustLoad(setID: setID, by: -0.5)
        #expect(r.transport.sent.count == count)
        r.model.adjustLoad(setID: setID, by: 5_000)
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 1000)
    }

    @Test func bodyweightAllowsNegativeAssistance() {
        let load = WatchLoad(value: 0, isBodyweight: true)
        #expect(WatchLoadStepping.clamp(-10, for: load) == -10)
        #expect(WatchLoadStepping.clamp(-500, for: load) == -150)
        #expect(WatchFormat.load(WatchLoad(value: -10, isBodyweight: true)) == "PC −10 kg")
        #expect(WatchFormat.load(WatchLoad(value: 0, isBodyweight: true)) == "PC")
    }

    @Test func restNextLoadFollowsCurrentSetAfterCompletion() throws {
        let r = make()
        r.model.completeCurrentSet()
        let next = try #require(r.model.display?.currentSetID)
        #expect(next != r.snapshot.currentSetID)
        r.model.setLoad(setID: next, to: 27)
        #expect(r.model.display?.exercises[0].sets[1].load?.value == 27)
        #expect(r.model.display?.exercises[0].sets[0].load?.value == 26)
    }

    // MARK: Descanso, pausa, sustentação, cardio

    @Test func restEndFiresStrongHapticOnce() throws {
        let r = make()
        r.model.completeCurrentSet()
        let end = try #require(r.model.display?.restEndsAt)
        r.model.restDidEnd(at: end)
        #expect(r.haptics.events.filter { $0 == .restEnded }.count == 1)
        r.model.restDidEnd(at: end.addingTimeInterval(-5))
        #expect(r.haptics.events.filter { $0 == .restEnded }.count == 1)
    }

    @Test func extendingRestAddsFifteenSeconds() {
        let r = make()
        r.model.completeCurrentSet()
        r.model.extendRest()
        #expect(r.model.display?.restEndsAt == t0.addingTimeInterval(105))
        r.model.skipRest()
        #expect(r.model.display?.restEndsAt == nil)
    }

    @Test func pauseFreezesClock() {
        let r = make()
        r.model.pause()
        #expect(r.model.isPaused)
        #expect(r.model.display?.elapsed(at: t0.addingTimeInterval(500)) == 600)
    }

    @Test func holdFlowCompletesSetWithMeasuredDuration() throws {
        let r = make(completed: 10)
        #expect(r.model.currentExercise?.measurementKind == .isometric)
        let setID = try #require(r.model.currentSet?.id)
        r.model.startHold(setID: setID)
        #expect(r.model.display?.holdSetID == setID)
        r.clock.now = t0.addingTimeInterval(38)
        r.model.endHold()
        let done = try #require(r.model.display?.exercises.flatMap(\.sets).first { $0.id == setID })
        #expect(done.isCompleted)
        #expect(done.durationSeconds == 38)
    }

    @Test func holdIsRefusedForStaleSetOrPausedSession() throws {
        let r = make(completed: 10)
        let setID = try #require(r.model.currentSet?.id)
        r.model.startHold(setID: UUID()) // série que já não é a atual (M5)
        #expect(r.model.display?.holdSetID == nil)
        r.model.pause()
        r.model.startHold(setID: setID)
        #expect(r.model.display?.holdSetID == nil)
    }

    @Test func holdStartClearsRestAndIsometricDefaultsToTarget() throws {
        let r = make(completed: 10)
        r.model.completeCurrentSet() // conclui sem medir → alvo como duração (B2)
        let first = try #require(r.model.display?.exercises[3].sets[0])
        #expect(first.durationSeconds == 45)
        #expect(r.model.display?.restEndsAt != nil)
        let next = try #require(r.model.currentSet?.id)
        r.model.startHold(setID: next)
        #expect(r.model.display?.restEndsAt == nil)
    }

    @Test func cardioTimerLivesInModelAndSkipsPause() throws {
        var snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600)
        snapshot.exercises[0].measurementKind = .timeOrDistance
        let r = make(snapshot: snapshot)
        let setID = try #require(r.model.currentSet?.id)
        r.clock.now = t0.addingTimeInterval(100)
        #expect(r.model.cardioElapsed(setID: setID, at: r.clock.now) == 100)
        r.model.pause() // em t0+100
        r.clock.now = t0.addingTimeInterval(160)
        r.model.resume()
        r.clock.now = t0.addingTimeInterval(190)
        #expect(r.model.cardioElapsed(setID: setID, at: r.clock.now) == 130) // 190 − 60 de pausa
        r.model.completeCurrentSet()
        let done = try #require(r.model.display?.exercises[0].sets.first { $0.id == setID })
        #expect(done.durationSeconds == 130)
    }

    // MARK: M3 — bi-set: descanso só no fim da rodada

    @Test func supersetRestStartsOnlyAtEndOfRound() throws {
        let r = make(completed: 7) // próximo: Tríceps corda (grupo com Prancha)
        #expect(r.model.currentExercise?.name == "Tríceps corda")
        r.model.completeCurrentSet()
        #expect(r.model.display?.restRemaining(at: t0) == nil) // Prancha ainda está atrás
        #expect(r.model.currentExercise?.name == "Prancha") // alterna A1, B1…
        r.model.completeCurrentSet()
        #expect(r.model.display?.restRemaining(at: t0) != nil) // fim da rodada
        #expect(r.model.currentExercise?.name == "Tríceps corda")
    }

    @Test func focusReopensSkippedExercise() throws {
        let r = make()
        let crucifixo = r.snapshot.exercises[1].id
        r.model.skip(exerciseID: crucifixo)
        #expect(r.model.display?.exercises[1].status == .skipped)
        r.model.focus(exerciseID: crucifixo)
        #expect(r.model.display?.exercises[1].status == .inProgress)
        #expect(r.model.display?.currentExerciseID == crucifixo)
    }

    // MARK: A2 — fim da sessão só com confirmação

    private func terminal(from snapshot: SessionSnapshot, rpe: Int? = 7, at: Date, revision: Int) -> SessionSnapshot {
        let cmd = SessionCommand(sessionID: snapshot.sessionID, issuedAt: at, origin: .watch, kind: .finish(rpe: rpe, applyLoadProposalIDs: []))
        var s = SessionReducer.apply(cmd, to: snapshot)!
        s.revision = revision
        return s
    }

    @Test func finishWaitsForConfirmationBeforeSummaryAndWorkoutEnd() throws {
        let r = make(completed: 2, recording: true)
        r.model.finish(rpe: 8)
        #expect(r.model.display?.status == .finished)
        #expect(r.model.summary == nil)
        #expect(r.model.isSavingSession)
        #expect(r.health.ended == 0)

        let command = try #require(sentCommands(r.transport).last)
        r.model.handle(reply(command, revision: 6))
        #expect(r.model.summary == nil) // resposta sem snapshot terminal ainda não basta
        r.model.receive(snapshot: terminal(from: r.snapshot, at: t0, revision: 6))
        #expect(r.model.summary?.completedSets == 2)
        #expect(!r.model.isSavingSession)
        #expect(r.health.ended == 1)
        #expect(r.health.lastFinal?.status == .finished) // grava o treino com o snapshot terminal confirmado
        r.model.dismissSummary()
        #expect(r.model.summary == nil)
    }

    @Test func rejectedFinishReturnsToActiveSession() throws {
        let r = make(completed: 2, recording: true)
        r.model.finish(rpe: 8)
        let command = try #require(sentCommands(r.transport).last)
        r.model.handle(reply(command, revision: 5, .rejected(.persistenceFailed)))
        #expect(r.model.hasActiveSession)
        #expect(!r.model.isSavingSession)
        #expect(r.model.summary == nil)
        #expect(r.health.ended == 0)
        // e a sessão continua utilizável
        r.model.completeCurrentSet()
        #expect(r.model.display?.metrics.completedSets == 3)
    }

    @Test func lateActiveSnapshotCannotResurrectConfirmedClosedSession() {
        let r = make(completed: 1)
        r.model.finish(rpe: 7)
        r.model.receive(snapshot: terminal(from: r.snapshot, at: t0, revision: 6))
        var late = r.snapshot
        late.revision = 99
        r.model.receive(snapshot: late)
        #expect(r.model.display?.status == .finished)
        #expect(!r.model.hasActiveSession)
    }

    @Test func nextExerciseIntroAppearsAfterExerciseCompletes() {
        let r = make(completed: 3)
        #expect(r.model.introExerciseID == nil)
        r.model.completeCurrentSet()
        #expect(r.model.currentExercise?.name == "Crucifixo")
        #expect(r.model.introExerciseID == r.model.currentExercise?.id)
        r.model.startIntroExercise()
        #expect(r.model.introExerciseID == nil)
    }

    // MARK: Estados de conexão

    @Test func connectionStateMapping() {
        #expect(WatchConnectionState.resolve(hasReceivedData: false, reachable: true, awaitingSync: false) == .neverSynced)
        #expect(WatchConnectionState.resolve(hasReceivedData: false, reachable: false, awaitingSync: true) == .neverSynced)
        #expect(WatchConnectionState.resolve(hasReceivedData: true, reachable: false, awaitingSync: true) == .phoneUnreachable)
        #expect(WatchConnectionState.resolve(hasReceivedData: true, reachable: true, awaitingSync: true) == .syncing)
        #expect(WatchConnectionState.resolve(hasReceivedData: true, reachable: true, awaitingSync: false) == .connected)
    }

    @Test func modelConnectionFollowsReachabilityAndQueue() {
        let transport = MockWatchTransport(reachable: false)
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { [t0] in t0 })
        #expect(model.connection == .neverSynced)
        model.receive(digest: WatchFixtures.digest(now: t0))
        #expect(model.connection == .phoneUnreachable)
        model.handle(.reachability(true))
        #expect(model.connection == .syncing)
        model.receive(snapshot: nil)
        #expect(model.connection == .connected)
        model.handle(.reachability(false))
        #expect(model.connection == .phoneUnreachable)
    }

    @Test func unavailableTransportKeepsWatchNeverSynced() {
        let model = WatchSessionModel(transport: UnavailableWatchTransport(), haptics: RecordingHaptics())
        #expect(model.connection == .neverSynced)
    }

    @Test func staleSessionPromptAfterFourHours() {
        let late = WatchSessionModel(transport: MockWatchTransport(), haptics: RecordingHaptics(),
                                     clock: { [t0] in t0.addingTimeInterval(5 * 3600) })
        late.receive(snapshot: WatchFixtures.snapshot(now: t0, startedAgo: 60))
        #expect(late.staleSessionSince != nil)
        late.keepStaleSessionGoing()
        #expect(late.staleSessionSince == nil)
    }
}
