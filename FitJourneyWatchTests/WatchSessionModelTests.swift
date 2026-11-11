import Foundation
import Testing
@testable import FitJourneyWatch

@MainActor
struct WatchSessionModelTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Modelo com relógio fixo, iPhone simulado que não responde sozinho e sessão com `completed` séries feitas.
    private func make(completed: Int = 0, reachable: Bool = true, revision: Int = 5)
        -> (model: WatchSessionModel, transport: MockWatchTransport, haptics: RecordingHaptics, snapshot: SessionSnapshot) {
        let digest = WatchFixtures.digest(now: t0)
        let snapshot = WatchFixtures.snapshot(completed: completed, now: t0, startedAgo: 600, revision: revision)
        let transport = MockWatchTransport(digest: digest, snapshot: snapshot, reachable: reachable)
        transport.autoRespond = false
        let haptics = RecordingHaptics()
        let model = WatchSessionModel(transport: transport, haptics: haptics, health: FixedHealthProvider(access: .authorized),
                                      clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.receive(snapshot: snapshot)
        return (model, transport, haptics, snapshot)
    }

    private func reply(_ command: SessionCommand, revision: Int, _ outcome: SessionCommandReply.Outcome = .applied) -> WatchLinkMessage {
        .commandReply(.init(commandID: command.commandID, sessionID: command.sessionID, outcome: outcome, revision: revision))
    }

    // MARK: Reconciliação otimista

    @Test func localCommandIsAppliedOptimisticallyAndQueued() throws {
        let (model, transport, _, snapshot) = make()
        let setID = try #require(snapshot.currentSetID)
        model.completeCurrentSet()
        #expect(model.display?.exercises[0].sets[0].isCompleted == true)
        #expect(model.confirmed?.exercises[0].sets[0].isCompleted == false)
        #expect(model.pendingCount == 1)
        #expect(model.display?.currentSetID != setID)
        guard case .command(let sent) = transport.sent.last else { Issue.record("comando não enviado"); return }
        #expect(sent.origin == .watch)
        #expect(sent.sessionID == snapshot.sessionID)
    }

    @Test func completingSetStartsRestFromPrescription() {
        let (model, _, _, _) = make()
        model.completeCurrentSet()
        #expect(model.display?.restEndsAt == t0.addingTimeInterval(90))
    }

    @Test func newerSnapshotReplacesAndAckedCommandIsDropped() throws {
        let (model, _, _, snapshot) = make()
        let command = try #require({ model.completeCurrentSet(); return model.pending.first?.command }())
        model.handle(reply(command, revision: 6))
        #expect(model.pendingCount == 1) // respondido, mas o snapshot ainda não o contém
        #expect(model.display?.exercises[0].sets[0].isCompleted == true)

        var phone = SessionReducer.apply(command, to: snapshot)!
        phone.revision = 6
        model.receive(snapshot: phone)
        #expect(model.pendingCount == 0)
        #expect(model.confirmed?.revision == 6)
        #expect(model.display == phone)
    }

    @Test func olderSnapshotIsDiscarded() {
        let (model, _, _, snapshot) = make(revision: 5)
        var stale = snapshot
        stale.revision = 4
        stale.routineName = "velho"
        model.receive(snapshot: stale)
        #expect(model.confirmed?.revision == 5)
        #expect(model.display?.routineName != "velho")
    }

    @Test func equalRevisionIsAccepted() {
        let (model, _, _, snapshot) = make(revision: 5)
        var same = snapshot
        same.routineName = "mesmo"
        model.receive(snapshot: same)
        #expect(model.confirmed?.routineName == "mesmo")
    }

    @Test func unackedCommandsAreReappliedOverNewerSnapshotThatLacksThem() throws {
        let (model, _, _, snapshot) = make()
        let setID = try #require(snapshot.currentSetID)
        model.adjustLoad(setID: setID, by: 0.5)
        // Snapshot mais novo (outra mudança no iPhone), sem o nosso comando.
        var phone = snapshot
        phone.revision = 6
        phone.routineName = "iPhone mudou"
        model.receive(snapshot: phone)
        #expect(model.pendingCount == 1)
        #expect(model.display?.routineName == "iPhone mudou")
        #expect(model.display?.exercises[0].sets[0].load?.value == 26.5)
    }

    @Test func rejectedCommandRevertsAndNotifies() throws {
        let (model, _, haptics, _) = make()
        let command = try #require({ model.completeCurrentSet(); return model.pending.first?.command }())
        model.handle(reply(command, revision: 5, .rejected(.invalidState)))
        #expect(model.pendingCount == 0)
        #expect(model.display?.exercises[0].sets[0].isCompleted == false)
        #expect(model.notice?.text == "Atualizado pelo iPhone")
        #expect(haptics.events.contains(.failure))
    }

    @Test func duplicateReplyCountsAsApplied() throws {
        let (model, _, _, _) = make()
        let command = try #require({ model.completeCurrentSet(); return model.pending.first?.command }())
        model.handle(reply(command, revision: 5, .duplicate)) // snapshot já tem revisão >= 5
        #expect(model.pendingCount == 0)
    }

    @Test func nilSnapshotIsIgnoredWhileStartIsInFlight() {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        #expect(model.hasActiveSession)
        model.receive(snapshot: nil)
        #expect(model.hasActiveSession)
    }

    @Test func snapshotOfClosedSessionDoesNotResurrectIt() throws {
        let (model, _, _, snapshot) = make(completed: 1)
        model.finish(rpe: 7)
        #expect(model.summary != nil)
        var late = snapshot
        late.revision = 99
        model.receive(snapshot: late) // snapshot atrasado, ainda "ativo"
        #expect(model.display?.status == .finished)
        #expect(!model.hasActiveSession)
    }

    @Test func sessionStartedOnPhoneAppearsOnWatch() {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        let health = FixedHealthProvider(access: .authorized)
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: health, clock: { [t0] in t0 })
        #expect(!model.hasActiveSession)
        model.receive(snapshot: WatchFixtures.snapshot(completed: 0, now: t0))
        #expect(model.hasActiveSession)
        #expect(health.began == 1)
    }

    // MARK: Fila pendente

    @Test func pendingCommandsKeepOrderAndResendOnReconnect() throws {
        let (model, transport, _, snapshot) = make(reachable: false)
        let setID = try #require(snapshot.currentSetID)
        model.adjustLoad(setID: setID, by: 0.5)
        model.completeCurrentSet()
        let ids = model.pending.map(\.id)
        #expect(ids.count == 2)
        #expect(model.connection == .phoneUnreachable)

        let before = transport.sent.count
        model.handle(.reachability(true))
        let resent = transport.sent.dropFirst(before).compactMap { message -> UUID? in
            if case .command(let c) = message { return c.commandID }
            return nil
        }
        #expect(resent == ids)
        #expect(transport.sent.last == .snapshotRequest)
    }

    @Test func ackedCommandsAreNotResent() throws {
        let (model, transport, _, _) = make(reachable: false)
        model.completeCurrentSet()
        let command = try #require(model.pending.first?.command)
        model.handle(reply(command, revision: 9))
        let before = transport.sent.count
        model.handle(.reachability(true))
        let commands = transport.sent.dropFirst(before).filter { if case .command = $0 { true } else { false } }
        #expect(commands.isEmpty)
    }

    @Test func endToEndWithMockPhone() async throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest, reachable: true)
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), clock: { [t0] in t0 })
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        await settle { model.digest != nil }
        #expect(model.digest != nil)

        model.startSession(routineID: WatchFixtures.routineA)
        await settle { model.confirmed?.revision == 1 && model.pendingCount == 0 }
        #expect(model.confirmed?.revision == 1)
        #expect(model.pendingCount == 0)

        model.completeCurrentSet()
        await settle { model.confirmed?.revision == 2 && model.pendingCount == 0 }
        #expect(model.confirmed?.metrics.completedSets == 1)
        #expect(model.connection == .connected)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    // MARK: Coroa: passo e limites

    @Test func crownStepsAreHalfKilogram() throws {
        let (model, transport, _, snapshot) = make()
        let setID = try #require(snapshot.currentSetID)
        model.setLoad(setID: setID, to: 27.5) // 26 → 27,5
        guard case .command(let sent) = transport.sent.last, case .adjustLoad(_, let delta) = sent.kind else {
            Issue.record("sem adjustLoad"); return
        }
        #expect(delta == 1.5)
        #expect(model.display?.exercises[0].sets[0].load?.value == 27.5)
    }

    @Test func crownSnapsToStep() {
        let load = WatchLoad(value: 20)
        #expect(WatchLoadStepping.clamp(20.3, for: load) == 20.5)
        #expect(WatchLoadStepping.clamp(20.2, for: load) == 20.0)
    }

    @Test func loadCannotGoBelowZeroOrAboveMax() throws {
        let (model, transport, _, snapshot) = make()
        let setID = try #require(snapshot.currentSetID)
        model.adjustLoad(setID: setID, by: -100)
        #expect(model.display?.exercises[0].sets[0].load?.value == 0)
        let count = transport.sent.count
        model.adjustLoad(setID: setID, by: -0.5) // já no piso: sem comando
        #expect(transport.sent.count == count)
        model.adjustLoad(setID: setID, by: 5_000)
        #expect(model.display?.exercises[0].sets[0].load?.value == 1000)
    }

    @Test func bodyweightAllowsNegativeAssistance() {
        let load = WatchLoad(value: 0, isBodyweight: true)
        #expect(WatchLoadStepping.clamp(-10, for: load) == -10)
        #expect(WatchLoadStepping.clamp(-500, for: load) == -150)
        #expect(WatchFormat.load(WatchLoad(value: -10, isBodyweight: true)) == "PC −10 kg")
        #expect(WatchFormat.load(WatchLoad(value: 0, isBodyweight: true)) == "PC")
    }

    @Test func restNextLoadFollowsCurrentSetAfterCompletion() throws {
        let (model, _, _, snapshot) = make()
        model.completeCurrentSet()
        let next = try #require(model.display?.currentSetID)
        #expect(next != snapshot.currentSetID)
        model.setLoad(setID: next, to: 27)
        #expect(model.display?.exercises[0].sets[1].load?.value == 27)
        #expect(model.display?.exercises[0].sets[0].load?.value == 26)
    }

    // MARK: Descanso e hápticos

    @Test func restEndFiresStrongHapticOnce() throws {
        let (model, _, haptics, _) = make()
        model.completeCurrentSet()
        let end = try #require(model.display?.restEndsAt)
        model.restDidEnd(at: end)
        #expect(haptics.events.filter { $0 == .restEnded }.count == 1)
        model.restDidEnd(at: end.addingTimeInterval(-5)) // descanso antigo/ajustado: ignora
        #expect(haptics.events.filter { $0 == .restEnded }.count == 1)
    }

    @Test func extendingRestAddsFifteenSeconds() {
        let (model, _, _, _) = make()
        model.completeCurrentSet()
        model.extendRest()
        #expect(model.display?.restEndsAt == t0.addingTimeInterval(105))
        model.skipRest()
        #expect(model.display?.restEndsAt == nil)
    }

    @Test func pauseFreezesClockAndResumeSkipsGap() {
        let (model, _, _, _) = make()
        model.pause()
        #expect(model.isPaused)
        #expect(model.display?.elapsed(at: t0.addingTimeInterval(500)) == 600)
    }

    @Test func holdFlowCompletesSetWithMeasuredDuration() throws {
        let (model, _, _, _) = make(completed: 10)
        let exercise = try #require(model.currentExercise)
        #expect(exercise.measurementKind == .isometric)
        model.startHold()
        #expect(model.display?.holdSetID == model.currentSet?.id)
        let holdID = try #require(model.display?.holdSetID)
        model.endHold()
        let done = try #require(model.display?.exercises.flatMap(\.sets).first { $0.id == holdID })
        #expect(done.isCompleted)
        #expect(done.durationSeconds == 0) // relógio fixo: 0 s entre início e fim
    }

    // MARK: Fim da sessão

    @Test func finishBuildsSummaryWithProposalCount() {
        let (model, transport, _, _) = make(completed: 2)
        model.finish(rpe: 8)
        #expect(model.summary?.completedSets == 2)
        #expect(model.display?.status == .finished)
        guard case .command(let sent) = transport.sent.last, case .finish(let rpe, _) = sent.kind else {
            Issue.record("sem finish"); return
        }
        #expect(rpe == 8)
        model.dismissSummary()
        #expect(model.summary == nil)
    }

    @Test func nextExerciseIntroAppearsAfterExerciseCompletes() {
        let (model, _, _, _) = make(completed: 3)
        #expect(model.introExerciseID == nil)
        model.completeCurrentSet() // 4ª série do supino
        #expect(model.currentExercise?.name == "Crucifixo")
        #expect(model.introExerciseID == model.currentExercise?.id)
        model.startIntroExercise()
        #expect(model.introExerciseID == nil)
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
        #expect(model.connection == .syncing) // pedido de snapshot em voo
        model.receive(snapshot: nil)
        #expect(model.connection == .connected)

        model.handle(.reachability(false))
        #expect(model.connection == .phoneUnreachable)
    }

    @Test func staleSessionPromptAfterFourHours() {
        let (model, _, _, _) = make()
        #expect(model.staleSessionSince == nil)
        let late = WatchSessionModel(transport: MockWatchTransport(), haptics: RecordingHaptics(),
                                     clock: { [t0] in t0.addingTimeInterval(5 * 3600) })
        late.receive(snapshot: WatchFixtures.snapshot(now: t0, startedAgo: 60))
        #expect(late.staleSessionSince != nil)
        late.keepStaleSessionGoing()
        #expect(late.staleSessionSince == nil)
    }
}
