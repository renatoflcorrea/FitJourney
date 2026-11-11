import Foundation
import SwiftData
import Testing
@testable import FitJourney

@MainActor
final class FakeRecorder: HealthWorkoutRecorder {
    struct Finish {
        var start: Date
        var end: Date
        var plan: HealthWorkoutEventPlan
        var metadata: HealthWorkoutMetadata
        var energy: Double?
    }

    let isLive: Bool
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?
    var startedAt: Date?
    var startError: (any Error)?
    var finishError: (any Error)?
    var pauses: [Date] = []
    var resumes: [Date] = []
    var finished: Finish?
    var discarded = false
    let workoutID = UUID()

    init(isLive: Bool) { self.isLive = isLive }

    func start(at date: Date) async throws {
        if let startError { throw startError }
        startedAt = date
    }

    func pause(at date: Date) { pauses.append(date) }
    func resume(at date: Date) { resumes.append(date) }

    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? {
        if let finishError { throw finishError }
        finished = Finish(start: start, end: end, plan: plan, metadata: metadata, energy: estimatedEnergyKcal)
        return workoutID
    }

    func discard() { discarded = true }
}

@MainActor
final class FakeRemoteSession: HealthRemoteWorkoutSession {
    var startDate: Date?
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?
    var onRemoteData: (([Data]) -> Void)?
    var onEnd: ((String?) -> Void)?
    var sent: [Data] = []

    func send(_ data: Data) async throws { sent.append(data) }
}

struct FakeHealthError: Error {}

@MainActor
final class FakeHealthStore: HealthStoreProtocol {
    var isHealthDataAvailable = true
    var sharing: [HealthDataKind: HealthSharingStatus] = [.workouts: .authorized, .activeEnergy: .authorized]
    var status: HealthRequestStatus = .unnecessary
    var liveSupported = true
    var liveStartError: (any Error)?
    var recoverable: FakeRecorder?
    var bodyMass: Double? = 80
    var requests = 0
    var live: [FakeRecorder] = []
    var basic: [FakeRecorder] = []
    var mirroringHandler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?

    func requestAuthorization(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async throws {
        requests += 1
        status = .unnecessary
        sharing[.workouts] = .authorized
    }

    func requestStatus(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async -> HealthRequestStatus { status }
    func sharingStatus(for kind: HealthDataKind) -> HealthSharingStatus { sharing[kind] ?? .notDetermined }

    func makeLiveRecorder(type: HealthWorkoutType) throws -> any HealthWorkoutRecorder {
        guard liveSupported else { throw FakeHealthError() }
        let recorder = FakeRecorder(isLive: true)
        recorder.startError = liveStartError
        live.append(recorder)
        return recorder
    }

    func makeBasicRecorder(type: HealthWorkoutType) -> any HealthWorkoutRecorder {
        let recorder = FakeRecorder(isLive: false)
        basic.append(recorder)
        return recorder
    }

    func recoverLiveRecorder() async -> (any HealthWorkoutRecorder)? { recoverable }
    func setMirroringStartHandler(_ handler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?) { mirroringHandler = handler }
    func latestBodyMassKg() async -> Double? { bodyMass }
}

@MainActor
struct HealthFixture {
    let engine: EngineFixture
    let store = FakeHealthStore()
    let defaults = UserDefaults(suiteName: "health-tests-\(UUID().uuidString)")!
    let authorization: HealthAuthorization
    let controller: HealthWorkoutController

    init(connected: Bool = true) throws {
        engine = try EngineFixture()
        defaults.set(connected, forKey: HealthAuthorization.connectionKey)
        authorization = HealthAuthorization(store: store, defaults: defaults)
        controller = HealthWorkoutController(store: store, authorization: authorization, context: engine.context)
    }

    /// Aplica no motor e repassa os eventos ao controller (como o `attach` faz).
    @discardableResult
    func apply(_ kind: SessionCommand.Kind, at offset: TimeInterval, session: UUID) async -> SessionApplyResult {
        let result = engine.apply(kind, at: offset, session: session)
        for event in result.events { await controller.handle(event) }
        return result
    }

    func start() async throws -> UUID {
        let routine = try engine.makeRoutine()
        let id = UUID()
        let result = await apply(.start(routineID: routine.id), at: 0, session: id)
        try #require(result.isApplied)
        return id
    }

    func complete(exercise: Int, set: Int, at offset: TimeInterval, session: UUID) async throws {
        let setID = try engine.sets(exercise)[set].id
        let result = await apply(.completeSet(setID: setID, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil),
                                 at: offset, session: session)
        try #require(result.isApplied)
    }

    func session(_ id: UUID) throws -> WorkoutSession {
        try #require(try engine.context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })).first)
    }
}

@MainActor
struct HealthWorkoutControllerTests {
    @Test func liveSessionFollowsEngineAndSavesWorkout() async throws {
        let f = try HealthFixture()
        let id = try await f.start()
        let recorder = try #require(f.store.live.first)
        #expect(recorder.startedAt == f.engine.t0)
        #expect(f.controller.state == .recording(sessionID: id, live: true))

        // FC ao vivo.
        let stream = f.controller.heartRateUpdates()
        recorder.onLiveUpdate?(.heartRate(HeartRateSample(date: f.engine.t0.addingTimeInterval(30), bpm: 120)))
        recorder.onLiveUpdate?(.activeEnergy(kilocalories: 42))
        #expect(f.controller.latestHeartRate?.bpm == 120)
        #expect(f.controller.activeEnergyKcal == 42)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.bpm == 120)

        try await f.complete(exercise: 0, set: 1, at: 100, session: id)
        try await f.complete(exercise: 0, set: 2, at: 200, session: id)
        await f.apply(.pause, at: 250, session: id)
        #expect(recorder.pauses == [f.engine.t0.addingTimeInterval(250)])
        #expect(f.controller.state == .paused(sessionID: id, live: true))
        await f.apply(.resume, at: 300, session: id)
        #expect(recorder.resumes == [f.engine.t0.addingTimeInterval(300)])
        try await f.complete(exercise: 1, set: 0, at: 400, session: id)

        await f.apply(.finish(rpe: 7, applyLoadProposalIDs: []), at: 600, session: id)
        let finished = try #require(recorder.finished)
        #expect(finished.start == f.engine.t0)
        #expect(finished.end == f.engine.t0.addingTimeInterval(600))
        #expect(finished.metadata.sessionID == id)
        #expect(finished.metadata.routineName == "A")
        #expect(finished.metadata.workoutType == .traditionalStrength)
        #expect(finished.plan.segments.count == 2)
        #expect(finished.plan.segments[0].interval == DateInterval(start: f.engine.t0.addingTimeInterval(100),
                                                                   end: f.engine.t0.addingTimeInterval(200)))
        #expect(finished.plan.markers.count == 3)
        // Energia medida ao vivo: não estima.
        #expect(finished.energy == nil)
        #expect(f.store.basic.isEmpty)
        #expect(try f.session(id).healthKitWorkoutID == recorder.workoutID)
        #expect(f.controller.state == .saved(sessionID: id, workoutID: recorder.workoutID))

        // Idempotente.
        #expect(await f.controller.sessionFinished(id) == recorder.workoutID)
    }

    @Test func discardDropsWorkout() async throws {
        let f = try HealthFixture()
        let id = try await f.start()
        await f.apply(.discard, at: 60, session: id)
        let recorder = try #require(f.store.live.first)
        #expect(recorder.discarded)
        #expect(recorder.finished == nil)
        #expect(f.controller.state == .idle)
    }

    @Test func withoutLiveSupportSavesSimpleWorkoutAtEnd() async throws {
        let f = try HealthFixture()
        f.store.liveSupported = false
        let id = try await f.start()
        #expect(f.controller.state == .recording(sessionID: id, live: false))
        try await f.complete(exercise: 0, set: 1, at: 100, session: id)
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 3_600, session: id)
        let recorder = try #require(f.store.basic.first)
        let finished = try #require(recorder.finished)
        // Estimativa: (3,5 − 1) × 80 kg × 1 h.
        #expect(finished.energy == 200)
        #expect(try f.session(id).healthKitWorkoutID == recorder.workoutID)
    }

    @Test func liveStartFailureFallsBackToSimple() async throws {
        let f = try HealthFixture()
        f.store.liveStartError = FakeHealthError()
        let id = try await f.start()
        #expect(try #require(f.store.live.first).discarded)
        #expect(f.controller.state == .recording(sessionID: id, live: false))
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(f.store.basic.first?.finished != nil)
    }

    @Test func noBodyMassMeansNoEnergyEstimate() async throws {
        let f = try HealthFixture()
        f.store.liveSupported = false
        f.store.bodyMass = nil
        let id = try await f.start()
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(try #require(f.store.basic.first?.finished).energy == nil)
    }

    @Test func writeDeniedSavesNothing() async throws {
        let f = try HealthFixture()
        f.store.sharing[.workouts] = .denied
        let id = try await f.start()
        #expect(f.store.live.isEmpty)
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(f.store.basic.isEmpty)
        #expect(f.controller.state == .skipped(sessionID: id, reason: .writeNotAuthorized))
        #expect(try f.session(id).healthKitWorkoutID == nil)
        // A sessão do app terminou normalmente.
        #expect(try f.session(id).status == .completed)
    }

    @Test func notConnectedSavesNothing() async throws {
        let f = try HealthFixture(connected: false)
        let id = try await f.start()
        #expect(f.store.live.isEmpty)
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(f.controller.state == .skipped(sessionID: id, reason: .notConnected))
    }

    @Test func permissionGrantedAtFinishSavesSimpleWorkout() async throws {
        let f = try HealthFixture(connected: false)
        f.store.sharing[.workouts] = .notDetermined
        f.store.status = .shouldRequest
        await f.authorization.refresh()
        let id = try await f.start()
        #expect(f.authorization.shouldAskBeforeFinishing)
        // Primeiro "Finalizar treino": a UI pede antes de enviar o comando.
        await f.authorization.request()
        #expect(f.authorization.canWriteWorkouts)
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(f.store.basic.first?.finished != nil)
    }

    @Test func finishFailureDoesNotBreakSession() async throws {
        let f = try HealthFixture()
        f.store.liveSupported = false
        let id = try await f.start()
        let result = f.engine.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(result.isApplied)
        // Gravador simples falha ao gravar.
        let failing = FakeRecorder(isLive: false)
        failing.finishError = FakeHealthError()
        let store = f.store
        store.basic = []
        let controller = HealthWorkoutController(store: FailingBasicStore(base: store, recorder: failing),
                                                 authorization: f.authorization, context: f.engine.context)
        #expect(await controller.sessionFinished(id) == nil)
        guard case .failed = controller.state else { Issue.record("\(controller.state)"); return }
        #expect(try f.session(id).status == .completed)
    }

    @Test func resumesRecoveredSessionOnAttach() async throws {
        let f = try HealthFixture()
        let routine = try f.engine.makeRoutine()
        let id = UUID()
        #expect(f.engine.apply(.start(routineID: routine.id), at: 0, session: id).isApplied)
        f.engine.apply(.pause, at: 50, session: id)
        let recovered = FakeRecorder(isLive: true)
        f.store.recoverable = recovered
        await f.controller.resumeIfNeeded(sessionID: id)
        #expect(f.store.live.isEmpty)
        #expect(recovered.startedAt == nil) // recuperada: já estava rodando
        #expect(recovered.pauses.count == 1)
        #expect(f.controller.state == .paused(sessionID: id, live: true))
    }

    @Test func attachListensToEngineEvents() async throws {
        let f = try HealthFixture()
        f.controller.attach(to: f.engine.engine)
        let routine = try f.engine.makeRoutine()
        let id = UUID()
        #expect(f.engine.apply(.start(routineID: routine.id), at: 0, session: id).isApplied)
        for _ in 0..<100 where f.controller.state == .idle { await Task.yield() }
        #expect(f.controller.state == .recording(sessionID: id, live: true))
        f.controller.detach()
    }

    @Test func mirroredSessionTakesOverAndRelaysData() async throws {
        let f = try HealthFixture()
        f.controller.startObservingMirroredSessions()
        let id = try await f.start()
        let local = try #require(f.store.live.first)
        let remote = FakeRemoteSession()
        f.store.mirroringHandler?(remote)
        #expect(local.discarded)
        #expect(f.controller.hasRemoteSession)
        #expect(f.controller.state == .mirrored(sessionID: id))

        let incoming = f.controller.remoteData()
        remote.onRemoteData?([Data([1, 2]), Data([3])])
        var iterator = incoming.makeAsyncIterator()
        #expect(await iterator.next() == Data([1, 2]))
        #expect(await iterator.next() == Data([3]))
        try await f.controller.sendToRemote(Data([9]))
        #expect(remote.sent == [Data([9])])
        remote.onLiveUpdate?(.heartRate(HeartRateSample(date: Date(), bpm: 133)))
        #expect(f.controller.latestHeartRate?.bpm == 133)

        // O relógio grava o treino; o iPhone não grava outro.
        await f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 600, session: id)
        #expect(f.store.basic.isEmpty)
        #expect(local.finished == nil)
        let watchWorkout = UUID()
        #expect(f.controller.linkWorkout(watchWorkout, to: id))
        #expect(try f.session(id).healthKitWorkoutID == watchWorkout)

        remote.onEnd?(nil)
        #expect(!f.controller.hasRemoteSession)
        await #expect(throws: HealthMirroringError.self) { try await f.controller.sendToRemote(Data()) }
    }

    @Test func linkRefusesSessionInProgress() async throws {
        let f = try HealthFixture()
        let id = try await f.start()
        #expect(!f.controller.linkWorkout(UUID(), to: id))
    }
}

/// Store cujo gravador simples é um dado (para simular falha ao gravar).
@MainActor
private final class FailingBasicStore: HealthStoreProtocol {
    let base: FakeHealthStore
    let recorder: FakeRecorder
    init(base: FakeHealthStore, recorder: FakeRecorder) {
        self.base = base
        self.recorder = recorder
    }

    var isHealthDataAvailable: Bool { true }
    func requestAuthorization(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async throws {}
    func requestStatus(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async -> HealthRequestStatus { .unnecessary }
    func sharingStatus(for kind: HealthDataKind) -> HealthSharingStatus { base.sharingStatus(for: kind) }
    func makeLiveRecorder(type: HealthWorkoutType) throws -> any HealthWorkoutRecorder { throw FakeHealthError() }
    func makeBasicRecorder(type: HealthWorkoutType) -> any HealthWorkoutRecorder { recorder }
    func recoverLiveRecorder() async -> (any HealthWorkoutRecorder)? { nil }
    func setMirroringStartHandler(_ handler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?) {}
    func latestBodyMassKg() async -> Double? { nil }
}

@MainActor
struct HealthAuthorizationTests {
    @Test func unavailableDevice() async {
        let store = FakeHealthStore()
        store.isHealthDataAvailable = false
        let auth = HealthAuthorization(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(auth.access == .unavailable)
        #expect(await auth.request() == .unavailable)
        #expect(store.requests == 0)
        #expect(!auth.shouldAskBeforeFinishing)
    }

    @Test func requestTurnsConnectionOn() async {
        let store = FakeHealthStore()
        store.status = .shouldRequest
        store.sharing = [:]
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let auth = HealthAuthorization(store: store, defaults: defaults)
        await auth.refresh()
        #expect(auth.access == .notDetermined)
        #expect(!auth.canAttemptReading)
        #expect(await auth.request() == .requested(canWriteWorkouts: true))
        #expect(auth.isConnectionEnabled)
        #expect(defaults.bool(forKey: HealthAuthorization.connectionKey))
        #expect(auth.canAttemptReading)
        auth.disconnect()
        #expect(!auth.canWriteWorkouts)
        #expect(!auth.canAttemptReading)
    }

    @Test func accessMapping() {
        #expect(HealthAuthorization.access(status: .shouldRequest, sharing: .notDetermined) == .notDetermined)
        #expect(HealthAuthorization.access(status: .unnecessary, sharing: .notDetermined) == .requested(canWriteWorkouts: false))
        #expect(HealthAuthorization.access(status: .shouldRequest, sharing: .denied) == .requested(canWriteWorkouts: false))
        #expect(HealthAuthorization.access(status: .unknown, sharing: .authorized) == .requested(canWriteWorkouts: true))
    }
}
