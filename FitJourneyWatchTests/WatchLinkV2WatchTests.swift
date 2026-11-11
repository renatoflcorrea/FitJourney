import Foundation
import Testing
@testable import FitJourneyWatch

// W2/W3b no relógio: IDs determinísticos, poda, coalescência, gravação no relógio e transporte real (com fakes).

struct WatchLinkIDsWatchTests {
    /// Mesmos vetores de `WatchLinkIDsTests` (alvo iOS): os dois lados chegam aos mesmos IDs.
    @Test func sameVectorsAsPhone() throws {
        let session = try #require(UUID(uuidString: "5E000000-0000-0000-0000-000000000001"))
        let routineExercise = try #require(UUID(uuidString: "E0000000-0000-0000-0000-000000000100"))
        let prescription = try #require(UUID(uuidString: "E0000000-0000-0000-0000-000000000110"))
        let command = try #require(UUID(uuidString: "C0000000-0000-0000-0000-000000000001"))
        let dns = try #require(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(WatchLinkIDs.uuid5(namespace: dns, name: "python.org").uuidString == "886313E1-3B8A-5372-9B90-0C9AEE199E5D")
        #expect(WatchLinkIDs.uuid5(namespace: dns, name: "www.example.com").uuidString == "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
        #expect(WatchLinkIDs.sessionExerciseID(sessionID: session, routineExerciseID: routineExercise).uuidString
                == "04199F87-B496-54FD-8F06-BB25EE79AF03")
        #expect(WatchLinkIDs.setLogID(sessionID: session, prescriptionID: prescription).uuidString
                == "E7F0109D-A4DC-5AFE-A8AE-3F59FB9E5022")
        #expect(WatchLinkIDs.extraSetID(sessionID: session, commandID: command).uuidString
                == "6B64A6BD-9D26-5C85-B02B-7D81847384EF")
        #expect(WatchLinkIDs.addedSetID(sessionID: session, commandID: command, index: 2).uuidString
                == "7F7D5267-A5BA-59AC-917D-8EE740358ACC")
    }
}

@MainActor
struct WatchSessionModelV2Tests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func sentCommands(_ transport: MockWatchTransport) -> [SessionCommand] {
        transport.sent.compactMap { if case .command(let c) = $0 { c } else { nil } }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    private func model(transport: MockWatchTransport, health: FixedHealthProvider = FixedHealthProvider(access: .authorized),
                       clock: TestClock) -> WatchSessionModel {
        WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: health, clock: { clock.now })
    }

    // MARK: IDs determinísticos (sem retenção)

    @Test func commandsAfterStartGoOutImmediatelyWithDeterministicIDs() throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = model(transport: transport, clock: TestClock(t0))
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        let sessionID = try #require(model.display?.sessionID)
        #expect(model.display?.exercises[0].id
                == WatchLinkIDs.sessionExerciseID(sessionID: sessionID, routineExerciseID: WatchFixtures.id(100)))
        #expect(model.display?.exercises[0].sets[0].id
                == WatchLinkIDs.setLogID(sessionID: sessionID, prescriptionID: WatchFixtures.id(110)))
        model.completeCurrentSet()
        let sent = sentCommands(transport)
        #expect(sent.count == 2) // start + completeSet, sem esperar o 1º snapshot
        guard case .completeSet(let setID, _, _, _, _) = sent[1].kind else { Issue.record("sem completeSet"); return }
        #expect(setID == WatchLinkIDs.setLogID(sessionID: sessionID, prescriptionID: WatchFixtures.id(110)))
    }

    @Test func fullFlowWatchToPhoneKeepsSameIDs() async throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest, reachable: true)
        let model = model(transport: transport, clock: TestClock(t0))
        model.start()
        defer { model.stop() }
        await settle { model.digest != nil }
        model.startSession(routineID: WatchFixtures.routineA)
        model.completeCurrentSet()
        model.adjustLoad(setID: try #require(model.currentSet?.id), by: 1)
        model.flushCoalescedCommands()
        model.completeCurrentSet()
        await settle { model.pendingCount == 0 && (model.confirmed?.metrics.completedSets ?? 0) == 2 }
        #expect(model.pendingCount == 0)
        #expect(model.notice == nil)
        let phone = try #require(transport.phoneSnapshot)
        let watch = try #require(model.confirmed)
        #expect(phone.exercises.map(\.id) == watch.exercises.map(\.id))
        #expect(phone.exercises[0].sets[1].load?.value == 27)
        #expect(phone.appliedCommandIDs.count == 4)
        model.finish(rpe: 7)
        await settle { model.summary != nil }
        #expect(model.summary?.completedSets == 2)
    }

    // MARK: Poda por appliedCommandIDs

    @Test func snapshotWithAppliedIDsPrunesQueueWithoutReply() throws {
        let clock = TestClock(t0)
        let snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let model = model(transport: transport, clock: clock)
        model.loadCoalesceInterval = 0
        model.receive(snapshot: snapshot)
        model.adjustLoad(setID: try #require(snapshot.currentSetID), by: 0.5)
        let command = try #require(model.pending.first?.command)
        var phone = try #require(SessionReducer.apply(command, to: snapshot))
        phone.revision = 6
        phone.appliedCommandIDs = [UUID(), command.commandID]
        model.receive(snapshot: phone) // resposta perdida
        #expect(model.pendingCount == 0)
        #expect(model.display?.exercises[0].sets[0].load?.value == 26.5) // sem dobrar
    }

    @Test func pendingAddSetKeepsCommandsOnTheNewSet() throws {
        let snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let model = model(transport: transport, clock: TestClock(t0))
        model.loadCoalesceInterval = 0
        model.receive(snapshot: snapshot)
        let add = try #require(model.send(.addSet(exerciseID: snapshot.exercises[0].id, kind: nil)))
        let newSet = WatchLinkIDs.extraSetID(sessionID: snapshot.sessionID, commandID: add.commandID)
        model.adjustLoad(setID: newSet, by: 0.5)
        var next = snapshot
        next.revision = 6 // ainda sem a série extra
        model.receive(snapshot: next)
        #expect(model.pendingCount == 2)
        #expect(model.notice == nil)
        #expect(model.display?.exercises[0].sets.last?.id == newSet)
    }

    @Test func validMessageClearsIncompatibility() {
        let model = WatchSessionModel(transport: MockWatchTransport(), haptics: RecordingHaptics(), clock: { [t0] in t0 })
        model.handle(.incompatible(WatchLinkCompatibility(minimumVersion: 3, currentVersion: 3)))
        #expect(model.incompatibility != nil)
        model.handle(.snapshot(nil))
        #expect(model.incompatibility == nil)
    }

    // MARK: Coalescência da Coroa

    @Test func crownAdjustmentsCoalesceIntoOneUnsentCommand() throws {
        let clock = TestClock(t0)
        let snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let model = model(transport: transport, clock: clock)
        model.loadCoalesceInterval = 10
        model.receive(snapshot: snapshot)
        let setID = try #require(snapshot.currentSetID)
        for _ in 0..<3 { model.adjustLoad(setID: setID, by: 0.5) }
        #expect(model.pendingCount == 1)
        #expect(sentCommands(transport).isEmpty)
        #expect(model.display?.exercises[0].sets[0].load?.value == 27.5)
        guard case .adjustLoad(_, let delta) = model.pending[0].command.kind else { Issue.record("sem adjustLoad"); return }
        #expect(delta == 1.5)

        // Outro comando: o ajuste sai antes (ordem preservada).
        model.completeCurrentSet()
        let sent = sentCommands(transport)
        #expect(sent.count == 2)
        guard case .adjustLoad = sent[0].kind, case .completeSet = sent[1].kind else { Issue.record("ordem"); return }
    }

    @Test func coalescedCommandFlushesOnTickAndNetZeroDisappears() throws {
        let clock = TestClock(t0)
        let snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let model = model(transport: transport, clock: clock)
        model.loadCoalesceInterval = 10
        model.receive(snapshot: snapshot)
        let setID = try #require(snapshot.currentSetID)
        model.adjustLoad(setID: setID, by: 0.5)
        model.adjustLoad(setID: setID, by: -0.5)
        #expect(model.pendingCount == 0) // ida e volta: nada a enviar
        model.adjustLoad(setID: setID, by: 1)
        model.retryStalePending()
        #expect(sentCommands(transport).isEmpty) // ainda na janela
        clock.now = t0.addingTimeInterval(11)
        model.retryStalePending()
        #expect(sentCommands(transport).count == 1)
    }

    // MARK: Quem grava

    @Test func sessionStartedHereRecordsOnWatchAndStatusGoesFirst() throws {
        let digest = WatchFixtures.digest(now: t0)
        var digestWithType = digest
        digestWithType.routines[0].workoutType = "functionalStrength"
        let transport = MockWatchTransport(digest: digestWithType)
        transport.autoRespond = false
        let health = FixedHealthProvider(access: .authorized)
        let model = model(transport: transport, health: health, clock: TestClock(t0))
        model.receive(digest: digestWithType)
        model.startSession(routineID: WatchFixtures.routineA)
        #expect(health.began == 1)
        #expect(health.lastContext?.workoutType == "functionalStrength")
        #expect(health.lastContext?.sessionID == model.display?.sessionID)
        #expect(model.recordingSessionID == model.display?.sessionID)
        #expect(!model.canOfferWatchRecording)
    }

    @Test func providerStatusIsForwardedBeforeStart() throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let health = RecordingStatusProvider()
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: health, clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        let kinds = transport.sent.compactMap { message -> String? in
            switch message {
            case .workoutStatus: "status"
            case .command(let c) where c.kind.isStart: "start"
            default: nil
            }
        }
        #expect(kinds == ["status", "start"])
    }

    @Test func notRecordingFallsBackToOffer() throws {
        let digest = WatchFixtures.digest(now: t0)
        let transport = MockWatchTransport(digest: digest)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: UnavailableHealthProvider(),
                                      clock: { [t0] in t0 })
        model.receive(digest: digest)
        model.startSession(routineID: WatchFixtures.routineA)
        #expect(model.recordingSessionID == nil)
        #expect(transport.sent.contains { if case .workoutStatus(let s) = $0 { s.state == .notRecording } else { false } })
    }

    @Test func phoneStartedSessionRecordsOnRequestAndFollowsPhonePause() throws {
        let clock = TestClock(t0)
        let snapshot = WatchFixtures.snapshot(completed: 1, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let health = FixedHealthProvider(access: .authorized)
        let model = model(transport: transport, health: health, clock: clock)
        model.receive(snapshot: snapshot)
        #expect(health.began == 0)
        model.handle(.recordingRequest(sessionID: snapshot.sessionID))
        #expect(health.began == 1)
        #expect(health.lastContext?.startedAt == snapshot.startedAt)

        // Pausa feita no iPhone pausa a gravação; retomada retoma.
        var paused = snapshot
        paused.revision = 6
        paused.status = .paused
        paused.pausedAt = t0
        model.receive(snapshot: paused)
        #expect(health.paused == 1)
        var resumed = paused
        resumed.revision = 7
        resumed.status = .active
        resumed.pausedAt = nil
        model.receive(snapshot: resumed)
        #expect(health.resumed == 1)

        // Métricas vão ao iPhone, no máximo a cada `metricsInterval`.
        health.onMetrics?(WatchLiveMetrics(heartRate: 120, heartRateZone: 3, activeKilocalories: 40, averageHeartRate: 110))
        health.onMetrics?(WatchLiveMetrics(heartRate: 121, heartRateZone: 3, activeKilocalories: 41, averageHeartRate: 110))
        let metrics = transport.sent.compactMap { if case .liveMetrics(let m) = $0 { m } else { nil } }
        #expect(metrics.count == 1)
        #expect(metrics.first?.heartRate == 120)
        #expect(model.liveMetrics.heartRate == 121)
        clock.now = t0.addingTimeInterval(3)
        health.onMetrics?(WatchLiveMetrics(heartRate: 125))
        #expect(transport.sent.filter { if case .liveMetrics = $0 { true } else { false } }.count == 2)
    }

    @Test func recoveredWorkoutIsAdoptedForItsSession() throws {
        let snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let health = FixedHealthProvider(access: .authorized)
        health.activeWorkoutSessionID = snapshot.sessionID
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        let model = model(transport: transport, health: health, clock: TestClock(t0))
        model.receive(snapshot: snapshot)
        #expect(model.recordingSessionID == snapshot.sessionID)
        #expect(health.began == 1) // o provedor ignora o reinício da mesma sessão
    }

    // MARK: Cardio pelo cronômetro (startHold/endHold)

    @Test func cardioUsesHoldTimerWithPauseDiscount() throws {
        let clock = TestClock(t0)
        var snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        snapshot.exercises[0].measurementKind = .timeOrDistance
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: snapshot)
        transport.autoRespond = false
        let model = model(transport: transport, clock: clock)
        model.receive(snapshot: snapshot)
        model.startCardio()
        let setID = try #require(model.currentSet?.id)
        #expect(model.display?.holdSetID == setID)
        clock.now = t0.addingTimeInterval(60)
        model.pause()
        clock.now = t0.addingTimeInterval(90)
        #expect(model.cardioElapsed(setID: setID, at: clock.now) == 60)
        model.resume()
        clock.now = t0.addingTimeInterval(130)
        #expect(model.cardioElapsed(setID: setID, at: clock.now) == 100)
        model.completeCurrentSet()
        guard case .endHold(let ended) = sentCommands(transport).last?.kind else { Issue.record("sem endHold"); return }
        #expect(ended == setID)
        #expect(model.display?.exercises[0].sets[0].durationSeconds == 100)
    }

    // MARK: Redutor v2

    @Test func reducerHandlesNewCommands() throws {
        let base = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        let digest = WatchFixtures.digest(now: t0)
        func apply(_ kind: SessionCommand.Kind, to s: SessionSnapshot, id: UUID = UUID()) throws -> SessionSnapshot {
            try #require(SessionReducer.apply(SessionCommand(commandID: id, sessionID: s.sessionID, issuedAt: t0, origin: .watch, kind: kind),
                                              to: s, digest: digest))
        }
        let exercise = base.exercises[0]
        var s = try apply(.removeSet(setID: exercise.sets[3].id), to: base)
        #expect(s.exercises[0].sets.count == 3)
        s = try apply(.changeSetKind(setID: exercise.sets[0].id, kind: .warmup), to: s)
        #expect(s.exercises[0].sets[0].kind == .warmup)
        let plank = base.exercises[3].sets[0].id
        s = try apply(.updateHoldTarget(setID: plank, seconds: 60), to: s)
        #expect(s.exercises[3].sets[0].targetHoldSeconds == 60)
        #expect(s.exercises[3].sets[0].targetText == "60 s")
        let addID = UUID()
        s = try apply(.addSet(exerciseID: exercise.id, kind: nil), to: s, id: addID)
        #expect(s.exercises[0].sets.last?.id == WatchLinkIDs.extraSetID(sessionID: s.sessionID, commandID: addID))
        s = try apply(.setExerciseNote(exerciseID: exercise.id, text: "banco 3"), to: s)
        s = try apply(.setPain(exerciseID: exercise.id, location: "ombro", score: 2), to: s)
        #expect(s.exercises[0].notes == "banco 3" && s.exercises[0].painScore == 2)
        s = try apply(.focusExercise(exerciseID: base.exercises[2].id), to: s)
        #expect(s.focusedExerciseID == base.exercises[2].id)
        #expect(s.currentGroup?.groupID == WatchFixtures.id(999))
        #expect(s.currentGroup?.completesRound == false)
    }
}

/// Provedor que avisa "gravando" de forma síncrona (como o `WatchWorkoutProvider`).
@MainActor
private final class RecordingStatusProvider: WatchHealthProvider {
    let access: WatchHealthAccess = .authorized
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    var onStatus: (@MainActor (WatchWorkoutStatus) -> Void)?
    private(set) var activeWorkoutSessionID: UUID?
    func requestAccess() async -> WatchHealthAccess { access }
    func workoutDidBegin(_ context: WatchWorkoutContext) {
        activeWorkoutSessionID = context.sessionID
        onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .recording))
    }
    func workoutDidPause(at date: Date) {}
    func workoutDidResume(at date: Date) {}
    func workoutDidEnd(final: SessionSnapshot?) { activeWorkoutSessionID = nil }
}

// MARK: Transporte real (WatchConnectivity abstraído)

@MainActor
private final class FakeLinkSession: WatchLinkSession {
    var isActivated = true
    var isReachable = false
    var isCounterpartInstalled = true
    var receivedContext: [String: Data] = [:]
    var onEvent: (@MainActor (WatchLinkSessionEvent) -> Void)?
    var failSends = false
    var replyWith: ((Data) -> Data?)?
    private(set) var messages: [Data] = []
    private(set) var userInfos: [Data] = []

    func activate() {}
    func sendMessage(_ data: Data, reply: (@MainActor @Sendable (Data) -> Void)?, failure: @escaping @MainActor @Sendable () -> Void) {
        guard isReachable, !failSends else { failure(); return }
        messages.append(data)
        if let reply, let response = replyWith?(data) { reply(response) }
    }
    func transferUserInfo(_ data: Data) { userInfos.append(data) }
    func updateContext(_ context: [String: Data]) throws {}

    func setReachable(_ value: Bool) {
        isReachable = value
        onEvent?(.reachability(value))
    }
}

@MainActor
private final class FakeWorkoutChannel: WatchWorkoutDataChannel {
    var isMirroring = false { didSet { onMirroringChange?(isMirroring) } }
    var onDataFromPhone: (@MainActor (Data) -> Void)?
    var onMirroringChange: (@MainActor (Bool) -> Void)?
    private(set) var sent: [Data] = []
    func sendToPhone(_ data: Data) async throws { sent.append(data) }
}

@MainActor
struct WatchConnectivityTransportTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "watch-transport-\(UUID().uuidString)")! }
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func decode(_ data: [Data]) -> [WatchLinkMessage] { data.compactMap { try? WatchLinkCodec.decode($0) } }

    private func next(_ iterator: inout AsyncStream<WatchTransportEvent>.Iterator) async -> WatchTransportEvent? {
        await iterator.next(isolation: #isolation)
    }

    private func command() -> SessionCommand {
        SessionCommand(sessionID: UUID(), issuedAt: t0, origin: .watch, kind: .adjustLoad(setID: UUID(), delta: 0.5))
    }

    @Test func offlineCommandsGoToUserInfoQueue() {
        let session = FakeLinkSession()
        let transport = WatchConnectivityTransport(session: session, defaults: defaults())
        let command = command()
        transport.send(.command(command))
        transport.send(.snapshotRequest) // fora de alcance não vai
        transport.send(.liveMetrics(WatchLiveMetricsPayload(sessionID: UUID(), date: t0, heartRate: 100, activeKilocalories: nil)))
        #expect(decode(session.userInfos) == [.command(command)])
        #expect(session.messages.isEmpty)
    }

    @Test func reachableCommandUsesMessageAndReplyIsDelivered() async throws {
        let session = FakeLinkSession()
        session.isReachable = true
        let command = command()
        let reply = SessionCommandReply(commandID: command.commandID, sessionID: command.sessionID, outcome: .applied, revision: 3)
        session.replyWith = { _ in try? WatchLinkCodec.encode(.commandReply(reply)) }
        let transport = WatchConnectivityTransport(session: session, defaults: defaults())
        var events = transport.makeEventStream().makeAsyncIterator()
        transport.send(.command(command))
        #expect(decode(session.messages) == [.command(command)])
        #expect(await next(&events) == .message(.commandReply(reply)))

        // Falhou a entrega → cai na fila offline.
        session.failSends = true
        transport.send(.command(command))
        #expect(decode(session.userInfos) == [.command(command)])
    }

    @Test func contextDigestIsCachedForNextLaunch() async throws {
        let store = defaults()
        let session = FakeLinkSession()
        let digest = WatchFixtures.digest(now: t0)
        let transport = WatchConnectivityTransport(session: session, defaults: store)
        var events = transport.makeEventStream().makeAsyncIterator()
        session.onEvent?(.context([WatchLinkSessionKey.digest: try WatchLinkCodec.encode(.programDigest(digest))]))
        #expect(await next(&events) == .message(.programDigest(digest)))

        // Relançado sem iPhone: o fluxo novo começa com o digest guardado.
        let relaunched = WatchConnectivityTransport(session: FakeLinkSession(), defaults: store)
        var cached = relaunched.makeEventStream().makeAsyncIterator()
        #expect(await next(&cached) == .message(.programDigest(digest)))
    }

    @Test func unsupportedVersionIsAnsweredWithIncompatible() throws {
        let session = FakeLinkSession()
        let transport = WatchConnectivityTransport(session: session, defaults: defaults())
        defer { withExtendedLifetime(transport) {} }
        var response: Data?
        let future = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 99))
        session.onEvent?(.message(future, reply: WatchLinkReply { response = $0 }))
        let decoded = try WatchLinkCodec.decode(try #require(response))
        #expect(decoded == .incompatible(.current))
    }

    @Test func offlineQueueWaitsForActivation() {
        let session = FakeLinkSession()
        session.isActivated = false
        let transport = WatchConnectivityTransport(session: session, defaults: defaults())
        let command = command()
        transport.send(.command(command))
        #expect(session.userInfos.isEmpty)
        session.isActivated = true
        session.onEvent?(.activated)
        #expect(decode(session.userInfos) == [.command(command)])
    }

    @Test func savedStatusIsDurableUntilDelivered() {
        let store = defaults()
        let session = FakeLinkSession()
        session.isActivated = false
        let transport = WatchConnectivityTransport(session: session, defaults: store)
        let status = WatchWorkoutStatus(sessionID: UUID(), state: .saved(workoutID: UUID()))
        transport.send(.workoutStatus(status))
        #expect(store.data(forKey: WatchConnectivityTransport.savedStatusKey) != nil)
        withExtendedLifetime(transport) {}

        // App relançado: ao ativar, reenvia e limpa.
        let relaunchedSession = FakeLinkSession()
        let relaunched = WatchConnectivityTransport(session: relaunchedSession, defaults: store)
        relaunched.activate()
        #expect(decode(relaunchedSession.userInfos) == [.workoutStatus(status)])
        #expect(store.data(forKey: WatchConnectivityTransport.savedStatusKey) == nil)
    }

    @Test func olderContextAndNilSnapshotDoNotOverrideActiveSession() async throws {
        let store = defaults()
        let session = FakeLinkSession()
        let transport = WatchConnectivityTransport(session: session, defaults: store)
        var events = transport.makeEventStream().makeAsyncIterator()
        let active = WatchFixtures.snapshot(now: t0)
        func context(_ snapshot: SessionSnapshot?, stamp: TimeInterval) throws -> [String: Data] {
            [WatchLinkSessionKey.snapshot: try WatchLinkCodec.encode(.snapshot(snapshot)),
             WatchLinkSessionKey.stamp: WatchLinkSessionKey.encodeStamp(t0.addingTimeInterval(stamp))]
        }
        session.onEvent?(.context(try context(active, stamp: 100)))
        #expect(await next(&events) == .message(.snapshot(active)))
        session.onEvent?(.context(try context(nil, stamp: 50))) // mais velho: ignorado
        session.onEvent?(.context(try context(nil, stamp: 200))) // "sem sessão" do contexto não apaga a ativa
        var finished = active
        finished.status = .finished
        session.onEvent?(.context(try context(finished, stamp: 300)))
        #expect(await next(&events) == .message(.snapshot(finished)))
    }

    @Test func passiveChannelsGetNoIncompatibleNotice() throws {
        let session = FakeLinkSession()
        session.isReachable = true
        let transport = WatchConnectivityTransport(session: session, defaults: defaults())
        session.onEvent?(.userInfo(try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 99))))
        #expect(session.messages.isEmpty)
        withExtendedLifetime(transport) {}
    }

    @Test func mirroredWorkoutChannelIsPreferredAndCountsAsReachable() async throws {
        let session = FakeLinkSession()
        let channel = FakeWorkoutChannel()
        let transport = WatchConnectivityTransport(session: session, defaults: defaults(), workoutChannel: channel)
        var events = transport.makeEventStream().makeAsyncIterator()
        #expect(!transport.isReachable)
        channel.isMirroring = true
        #expect(await next(&events) == .reachability(true))
        let command = command()
        transport.send(.command(command))
        for _ in 0..<50 where channel.sent.isEmpty { await Task.yield() }
        #expect(decode(channel.sent) == [.command(command)])
        #expect(session.userInfos.isEmpty)

        // Dados do iPhone pelo canal chegam como mensagens.
        let snapshot = WatchFixtures.snapshot(now: t0)
        channel.onDataFromPhone?(try WatchLinkCodec.encode(.snapshot(snapshot)))
        #expect(await next(&events) == .message(.snapshot(snapshot)))
    }
}
