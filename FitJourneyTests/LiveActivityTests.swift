import Foundation
import Testing
@testable import FitJourney

// MARK: - Fakes

@MainActor
final class FakeLiveActivityClient: LiveActivityClient {
    typealias State = WorkoutActivityAttributes.ContentState
    struct Update: Equatable { var id: String; var state: State; var staleDate: Date?; var alert: LiveActivityAlert? }
    struct End: Equatable { var id: String; var state: State?; var dismissal: LiveActivityDismissal }
    struct RequestError: Error {}

    var enabled = true
    var failRequests = false
    var existing: [LiveActivityRecord] = []
    var requests: [(attributes: WorkoutActivityAttributes, state: State, staleDate: Date?)] = []
    var updates: [Update] = []
    var ends: [End] = []
    private var counter = 0

    var areActivitiesEnabled: Bool { enabled }

    func currentActivities() -> [LiveActivityRecord] { existing }

    func request(attributes: WorkoutActivityAttributes, state: State, staleDate: Date?) throws -> String {
        if failRequests { throw RequestError() }
        counter += 1
        let id = "act-\(counter)"
        existing.append(LiveActivityRecord(id: id, sessionID: attributes.sessionID))
        requests.append((attributes, state, staleDate))
        return id
    }

    var observed: [String: @MainActor @Sendable (String) -> Void] = [:]

    func update(id: String, state: State, staleDate: Date?, alert: LiveActivityAlert?) async -> Bool {
        guard existing.contains(where: { $0.id == id }) else { return false }
        updates.append(Update(id: id, state: state, staleDate: staleDate, alert: alert))
        return true
    }

    func observeEnd(id: String, onEnd: @escaping @MainActor @Sendable (String) -> Void) { observed[id] = onEnd }

    /// O sistema encerrou (usuário dispensou).
    func systemDismiss(_ id: String) {
        existing.removeAll { $0.id == id }
        observed[id]?(id)
    }

    func end(id: String, state: State?, dismissal: LiveActivityDismissal) async {
        ends.append(End(id: id, state: state, dismissal: dismissal))
        existing.removeAll { $0.id == id }
    }
}

@MainActor
final class FakeSessionSource: LiveActivitySessionSource {
    var snapshot: SessionSnapshot?
    var sent: [SessionCommand.Kind] = []
    var restoreCount = 0
    var onSend: ((SessionCommand.Kind) -> Void)?

    var activeSessionID: UUID? {
        guard let snapshot, snapshot.status == .active || snapshot.status == .paused else { return nil }
        return snapshot.sessionID
    }

    func snapshots() -> AsyncStream<SessionSnapshot> { AsyncStream { _ in } }
    func events() -> AsyncStream<SessionEvent> { AsyncStream { _ in } }
    func restore() { restoreCount += 1 }

    func send(_ kind: SessionCommand.Kind, issuedAt: Date?) -> SessionApplyResult {
        sent.append(kind)
        onSend?(kind)
        return .applied(revision: (snapshot?.revision ?? 0) + 1, events: [])
    }
}

// MARK: - Snapshots de exemplo

/// Supino inclinado (4 séries, 26 kg, 8–12, RIR 2) + prancha (2 × 45 s); 6 exercícios no total.
@MainActor
struct LiveSnapshots {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let sessionID = UUID()
    let benchID = UUID()
    let plankID = UUID()
    let benchSets = (0..<4).map { _ in UUID() }
    let plankSets = (0..<2).map { _ in UUID() }

    func make(status: SessionSnapshot.Status = .active, revision: Int = 3, completed: Int = 2,
              restEndsAt: Date? = nil, restTotal: Double? = nil, pausedAt: Date? = nil,
              holdOnPlank: Date? = nil, current: UUID?? = nil, endedAt: Date? = nil) -> SessionSnapshot {
        let bench = SessionSnapshot.Exercise(
            id: benchID, exerciseID: nil, name: "Supino inclinado halter", measurementKind: .repsAndLoad,
            status: .inProgress, groupID: nil, restSeconds: 120,
            sets: benchSets.enumerated().map { index, id in
                SessionSnapshot.ExerciseSet(
                    id: id, kind: .working, targetText: "8–12", repTarget: .range(min: 8, max: 12), effort: .rir(2),
                    plannedLoad: WatchLoad(value: 26), load: WatchLoad(value: 26), reps: nil, targetHoldSeconds: nil,
                    durationSeconds: nil, distanceMeters: nil, restSeconds: 120, isCompleted: index < completed,
                    completedAt: index < completed ? t0.addingTimeInterval(Double(index) * 200) : nil)
            })
        let plank = SessionSnapshot.Exercise(
            id: plankID, exerciseID: nil, name: "Prancha", measurementKind: .isometric, status: .pending,
            groupID: nil, restSeconds: 60,
            sets: plankSets.map { id in
                SessionSnapshot.ExerciseSet(
                    id: id, kind: .working, targetText: "45 s", repTarget: nil, effort: nil, plannedLoad: nil,
                    load: nil, reps: nil, targetHoldSeconds: 45, durationSeconds: nil, distanceMeters: nil,
                    restSeconds: 60, isCompleted: false, completedAt: nil)
            })
        let currentExercise: UUID? = current ?? benchID
        let currentSet = currentExercise == benchID ? (completed < 4 ? benchSets[completed] : nil)
            : currentExercise == plankID ? plankSets[0] : nil
        return SessionSnapshot(
            sessionID: sessionID, revision: revision, status: status, routineID: nil,
            routineName: "A — Peito e tríceps", startedAt: t0, endedAt: endedAt, pausedAt: pausedAt,
            accumulatedPauseSeconds: 60, restEndsAt: restEndsAt, holdSetID: holdOnPlank == nil ? nil : plankSets[0],
            holdStartedAt: holdOnPlank, currentExerciseID: currentExercise, currentSetID: currentSet,
            exercises: [bench, plank],
            metrics: .init(completedSets: 18, totalSets: 24, exercisesDone: 3, exercisesTotal: 6,
                           volumeKg: 8_420, hasEstimatedVolume: false),
            loadProposals: [], restTotalSeconds: restTotal)
    }
}

// MARK: - Mapeamento snapshot → ContentState

@MainActor
struct LiveActivityMapperTests {
    let s = LiveSnapshots()

    @Test func exercisingShowsSetTargetEffortAndProgress() throws {
        let state = try #require(LiveActivityStateMapper.state(for: s.make(), now: s.t0.addingTimeInterval(500), unit: .kg))
        #expect(state.phase == .exercising)
        #expect(state.exerciseName == "Supino inclinado halter")
        #expect(state.setPositionText == "Série 3 de 4")
        #expect(state.compactSetText == "3/4")
        #expect(state.detailText(includeEffort: true) == "26 kg · alvo 8–12 · RIR 2")
        #expect(state.detailText(includeEffort: false) == "26 kg · alvo 8–12")
        #expect(state.progressText == "3 de 6")
        #expect(state.spokenDetail == "26 kg, alvo 8 a 12 repetições")
        // Tempo de sessão como data-base (início + pausas), nunca um contador.
        #expect(state.sessionTimerStart == s.t0.addingTimeInterval(60))
        #expect(state.frozenElapsedSeconds == nil)
        #expect(LiveActivityStateMapper.staleDate(for: state) == nil)
    }

    @Test func restingCarriesDatesAndStaleDate() throws {
        let end = s.t0.addingTimeInterval(600)
        let snapshot = s.make(restEndsAt: end, restTotal: 135)
        let state = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(500), unit: .kg))
        #expect(state.phase == .resting)
        #expect(state.restEndsAt == end)
        #expect(state.restTotalSeconds == 135)
        #expect(state.restInterval == end.addingTimeInterval(-135)...end)
        #expect(LiveActivityStateMapper.staleDate(for: state) == end)
        // "A seguir": a próxima série pendente.
        #expect(state.setPositionText == "Série 3 de 4")
        // Vencido sem atualização = "Descanso concluído" no layout.
        #expect(state.displayPhase(isStale: true) == .restDone)
        #expect(state.displayPhase(isStale: false, now: end.addingTimeInterval(1)) == .restDone)
        #expect(state.displayPhase(isStale: false, now: end.addingTimeInterval(-1)) == .resting)
    }

    @Test func expiredRestMapsToExercising() throws {
        let snapshot = s.make(restEndsAt: s.t0.addingTimeInterval(400), restTotal: 120)
        let state = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(500), unit: .kg))
        #expect(state.phase == .exercising)
        #expect(state.restEndsAt == nil)
    }

    @Test func pausedFreezesSessionTime() throws {
        let snapshot = s.make(status: .paused, pausedAt: s.t0.addingTimeInterval(1_000))
        let state = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(5_000), unit: .kg))
        #expect(state.phase == .paused)
        // 1000 s até a pausa − 60 s de pausas anteriores.
        #expect(state.frozenElapsedSeconds == 940)
        #expect(state.frozenElapsedText == "15:40")
    }

    @Test func holdUsesHoldSetAndTarget() throws {
        let started = s.t0.addingTimeInterval(800)
        let snapshot = s.make(holdOnPlank: started)
        let state = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(810), unit: .kg))
        #expect(state.phase == .hold)
        #expect(state.exerciseName == "Prancha")
        #expect(state.holdTargetSeconds == 45)
        #expect(state.holdInterval == started...started.addingTimeInterval(45))
        #expect(state.loadText == nil)
        #expect(state.targetText == "45 s")
    }

    @Test func allDoneAndFinished() throws {
        let allDone = try #require(LiveActivityStateMapper.state(for: s.make(current: .some(nil)), now: s.t0, unit: .kg))
        #expect(allDone.phase == .allDone)
        #expect(allDone.exerciseName == "A — Peito e tríceps")

        let ended = s.t0.addingTimeInterval(52 * 60 + 60)
        let finished = try #require(LiveActivityStateMapper.state(
            for: s.make(status: .finished, endedAt: ended), now: ended.addingTimeInterval(100), unit: .kg))
        #expect(finished.phase == .finished)
        #expect(finished.exerciseName == "A — Peito e tríceps")
        #expect(finished.summaryText == "52 min · 18 séries · 8.420 kg")
        #expect(finished.frozenElapsedSeconds == 52 * 60)
        #expect(finished.setPositionText == nil)
    }

    @Test func loadFollowsDisplayUnit() throws {
        let state = try #require(LiveActivityStateMapper.state(for: s.make(), now: s.t0, unit: .lb))
        #expect(state.loadText == "57,3 lb")
    }

    @Test func discardedHasNoState() {
        #expect(LiveActivityStateMapper.state(for: s.make(status: .discarded), now: s.t0, unit: .kg) == nil)
    }

    @Test func restDoneAlertBody() throws {
        let state = try #require(LiveActivityStateMapper.state(for: s.make(restEndsAt: s.t0.addingTimeInterval(900)),
                                                               now: s.t0, unit: .kg))
        let done = LiveActivityStateMapper.restDone(from: state)
        #expect(done.phase == .restDone)
        #expect(done.restEndsAt == nil)
        #expect(LiveActivityStateMapper.restDoneAlertBody(done) == "Série 3 de 4 · 26 kg")
    }
}

// MARK: - Controlador: quando pedir/atualizar/encerrar

@MainActor
struct LiveActivityControllerTests {
    let s = LiveSnapshots()
    let source = FakeSessionSource()
    let client = FakeLiveActivityClient()
    let notifications = FakeRestScheduler()
    let gate: LiveActivityRestNotificationGate
    let defaults = UserDefaults(suiteName: "live-activity-\(UUID().uuidString)")!
    let clock: TestClock
    let controller: LiveActivityController

    init() {
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_500))
        self.clock = clock
        gate = LiveActivityRestNotificationGate(wrapping: notifications)
        controller = LiveActivityController(engine: source, client: client, gate: gate, defaults: defaults,
                                            now: { clock.now }, unit: { .kg }, routineColorName: { _ in "blue" },
                                            isAppActive: { false }, restDoneHold: .milliseconds(20))
    }

    private func feed(_ snapshot: SessionSnapshot) async {
        source.snapshot = snapshot
        controller.handle(snapshot)
        await controller.waitUntilIdle()
    }

    @Test func startsOneActivityPerSessionAndSkipsInvisibleChanges() async throws {
        await feed(s.make(revision: 1))
        #expect(client.requests.count == 1)
        #expect(client.requests[0].attributes.sessionID == s.sessionID)
        #expect(client.requests[0].attributes.routineName == "A — Peito e tríceps")
        #expect(client.requests[0].attributes.routineColorName == "blue")
        #expect(gate.isLiveActivityActive)

        // Revisões novas que não mudam o que a atividade mostra (nota, dor…): nenhuma atualização.
        await feed(s.make(revision: 2))
        await feed(s.make(revision: 3))
        #expect(client.updates.isEmpty)
        #expect(client.requests.count == 1)

        // Série concluída → descanso: uma atualização, com staleDate = fim do descanso.
        let end = clock.now.addingTimeInterval(120)
        await feed(s.make(revision: 4, completed: 3, restEndsAt: end, restTotal: 120))
        #expect(client.updates.count == 1)
        #expect(client.updates[0].state.phase == .resting)
        #expect(client.updates[0].staleDate == end)
        #expect(client.updates[0].alert == nil)

        // Snapshot antigo (revisão menor) é ignorado.
        await feed(s.make(revision: 2))
        #expect(client.updates.count == 1)
    }

    @Test func respectsPreferenceAndSystemSwitch() async {
        defaults.set(false, forKey: AppPreferenceKeys.liveActivity)
        await feed(s.make())
        #expect(client.requests.isEmpty)
        #expect(!gate.isLiveActivityActive)

        defaults.set(true, forKey: AppPreferenceKeys.liveActivity)
        client.enabled = false
        await feed(s.make(revision: 4))
        #expect(client.requests.isEmpty)

        client.enabled = true
        await feed(s.make(revision: 5))
        #expect(client.requests.count == 1)

        // Desligou no meio da sessão: a atividade sai.
        defaults.set(false, forKey: AppPreferenceKeys.liveActivity)
        await feed(s.make(revision: 6, completed: 3))
        #expect(client.ends.map(\.dismissal) == [.immediate])
        #expect(controller.current == nil)
    }

    @Test func failedRequestRetriesOnlyOnForeground() async {
        client.failRequests = true
        await feed(s.make(revision: 1))
        client.failRequests = false
        await feed(s.make(revision: 2, completed: 3))
        #expect(client.requests.isEmpty)

        controller.handleForeground()
        await controller.waitUntilIdle()
        #expect(client.requests.count == 1)
        #expect(client.requests[0].state.setPositionText == "Série 4 de 4")
    }

    @Test func finishEndsWithSummaryAndLinger() async throws {
        await feed(s.make())
        let ended = clock.now
        source.snapshot = nil
        controller.handle(s.make(status: .finished, revision: 9, endedAt: ended))
        await controller.waitUntilIdle()
        let end = try #require(client.ends.first)
        #expect(end.state?.phase == .finished)
        #expect(end.state?.summaryText?.contains("18 séries") == true)
        #expect(end.dismissal == .after(ended.addingTimeInterval(LiveActivityController.finishedLinger)))
        #expect(controller.current == nil)
        #expect(!gate.isLiveActivityActive)
    }

    @Test func discardEndsImmediately() async {
        await feed(s.make())
        source.snapshot = nil
        controller.handle(s.make(status: .discarded, revision: 9))
        await controller.waitUntilIdle()
        #expect(client.ends == [.init(id: "act-1", state: nil, dismissal: .immediate)])
    }

    @Test func restFinishedAlertsSuppressesNotificationAndRevertsToSet() async throws {
        let end = clock.now.addingTimeInterval(60)
        await feed(s.make(completed: 3, restEndsAt: end, restTotal: 90))
        // Com a atividade ativa, a notificação vai para depois do fim (folga para o app cancelá-la).
        gate.scheduleRestEnd(at: end, nextExerciseName: nil)
        #expect(notifications.scheduled == [end.addingTimeInterval(LiveActivityRestNotificationGate.defaultGrace)])

        clock.now = end
        controller.handle(.restFinished(at: end))
        await controller.waitUntilIdle()
        let alerted = try #require(client.updates.last)
        #expect(alerted.state.phase == .restDone)
        #expect(alerted.alert == LiveActivityAlert(title: "Descanso concluído", body: "Série 4 de 4 · 26 kg"))
        #expect(notifications.cancelCount == 1)

        // Depois do intervalo, volta a "Série" (descanso vencido no snapshot).
        try await Task.sleep(for: .milliseconds(150))
        await controller.waitUntilIdle()
        #expect(client.updates.last?.state.phase == .exercising)
    }

    @Test func gatePassesThroughWithoutActivity() {
        let end = clock.now.addingTimeInterval(60)
        gate.scheduleRestEnd(at: end, nextExerciseName: "Supino")
        #expect(notifications.scheduled == [end])
        gate.cancelRestEnd()
        #expect(notifications.cancelCount == 1)
    }

    @Test func reconcileAdoptsCurrentSessionAndEndsOldOnes() async {
        let old = UUID()
        client.existing = [LiveActivityRecord(id: "old", sessionID: old),
                           LiveActivityRecord(id: "mine", sessionID: s.sessionID)]
        source.snapshot = s.make()
        controller.start()
        await controller.waitUntilIdle()
        #expect(client.ends.map(\.id) == ["old"])
        #expect(controller.current?.id == "mine")
        #expect(source.restoreCount == 0)

        // O primeiro snapshot atualiza a atividade adotada (sem pedir outra).
        controller.handle(s.make())
        await controller.waitUntilIdle()
        #expect(client.requests.isEmpty)
        #expect(client.updates.map(\.id) == ["mine"])
    }

    @Test func reconcileWithoutSessionEndsEverything() async {
        client.existing = [LiveActivityRecord(id: "old", sessionID: UUID())]
        controller.start()
        await controller.waitUntilIdle()
        #expect(source.restoreCount == 1)
        #expect(client.ends.map(\.id) == ["old"])
        #expect(controller.current == nil)
    }
}

// MARK: - Intents

@MainActor
struct LiveActivityIntentTests {
    let s = LiveSnapshots()

    @Test func intentsGoThroughTheEngine() async throws {
        let source = FakeSessionSource()
        let client = FakeLiveActivityClient()
        let controller = LiveActivityController(engine: source, client: client,
                                                defaults: UserDefaults(suiteName: "li-\(UUID().uuidString)")!,
                                                now: { Date(timeIntervalSinceReferenceDate: 800_000_500) }, unit: { .kg },
                                                isAppActive: { false })
        source.snapshot = s.make(restEndsAt: Date(timeIntervalSinceReferenceDate: 800_000_600), restTotal: 120)
        LiveActivityIntentRouter.handler = controller
        defer { LiveActivityIntentRouter.handler = nil }

        _ = try await AdjustRestIntent(sessionID: s.sessionID, seconds: 15).perform()
        _ = try await SkipRestIntent(sessionID: s.sessionID).perform()
        #expect(source.sent == [.adjustRest(seconds: 15), .skipRest])
    }

    @Test func intentForEndedSessionDoesNothingAndEndsActivity() async {
        let source = FakeSessionSource()
        let client = FakeLiveActivityClient()
        let staleSession = UUID()
        client.existing = [LiveActivityRecord(id: "stale", sessionID: staleSession)]
        let controller = LiveActivityController(engine: source, client: client,
                                                defaults: UserDefaults(suiteName: "li-\(UUID().uuidString)")!, isAppActive: { false })
        await controller.perform(.skipRest, sessionID: staleSession)
        #expect(source.sent.isEmpty)
        #expect(client.ends.map(\.id) == ["stale"])
    }

    /// Fluxo real: motor + controlador, +15 s e Pular pelos intents com a sessão em descanso.
    @Test func realEngineRestFlow() async throws {
        let f = try EngineFixture()
        let client = FakeLiveActivityClient()
        let clock = f.clock
        let controller = LiveActivityController(engine: f.engine, client: client,
                                                defaults: UserDefaults(suiteName: "li-\(UUID().uuidString)")!,
                                                now: { clock.now }, unit: { .kg }, isAppActive: { false })
        let session = try f.start(try f.makeRoutine())
        controller.handle(try f.snapshot)
        await controller.waitUntilIdle()
        #expect(client.requests.count == 1)
        #expect(client.requests[0].state.phase == .exercising)

        let sets = try f.sets(0)
        f.apply(.completeSet(setID: sets[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 50, session: session)
        f.apply(.completeSet(setID: sets[1].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                at: 100, session: session)
        controller.handle(try f.snapshot)
        await controller.waitUntilIdle()
        let resting = try #require(client.updates.last)
        #expect(resting.state.phase == .resting)
        let end = try #require(f.engine.snapshot?.restEndsAt)
        #expect(resting.staleDate == end)
        #expect(resting.state.setPositionText == "Série 3 de 4")
        #expect(resting.state.detailText(includeEffort: false)?.hasPrefix("30 kg · alvo 8–12") == true)

        f.clock.now = f.t0.addingTimeInterval(110)
        await controller.perform(.adjustRest(seconds: 15), sessionID: session)
        #expect(f.engine.snapshot?.restEndsAt == end.addingTimeInterval(15))
        #expect(client.updates.last?.staleDate == end.addingTimeInterval(15))

        await controller.perform(.skipRest, sessionID: session)
        #expect(f.engine.snapshot?.restEndsAt == nil)
        #expect(client.updates.last?.state.phase == .exercising)
        #expect(client.updates.last?.staleDate == nil)
    }
}
