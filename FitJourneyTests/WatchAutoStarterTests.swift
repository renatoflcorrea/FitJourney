import Foundation
import Testing
@testable import FitJourney

// P2.8 — iniciar o treino no Apple Watch automaticamente (HKHealthStore.startWatchApp) ao começar no iPhone.

@MainActor
final class FakeAutoStartLink: WatchAutoStartLink {
    var isWatchAppInstalled = true
    var watchRecordingSessionID: UUID?
}

@MainActor
final class FakeAutoStartHealth: WatchAutoStartHealth {
    var canRecordWorkouts = true
}

@MainActor
final class FakeWatchLauncher: WatchAppLaunching {
    var launched: [HealthWorkoutType] = []
    var error: Error?
    /// Simula o relógio confirmando a gravação logo depois de abrir.
    var onLaunch: (() -> Void)?

    func startWatchApp(type: HealthWorkoutType) async throws {
        launched.append(type)
        if let error { throw error }
        onLaunch?()
    }
}

@MainActor
struct WatchAutoStarterTests {
    struct Rig {
        let fixture: EngineFixture
        let link: FakeAutoStartLink
        let health: FakeAutoStartHealth
        let launcher: FakeWatchLauncher
        let starter: WatchAutoStarter
        let defaults: UserDefaults
    }

    private func make(enabled: Bool? = nil) throws -> Rig {
        let fixture = try EngineFixture()
        let defaults = UserDefaults(suiteName: "autostart-\(UUID().uuidString)")!
        if let enabled { defaults.set(enabled, forKey: AppPreferenceKeys.autoStartWatchWorkout) }
        let link = FakeAutoStartLink(), health = FakeAutoStartHealth(), launcher = FakeWatchLauncher()
        let starter = WatchAutoStarter(engine: fixture.engine, link: link, health: health, launcher: launcher, defaults: defaults)
        starter.confirmationTimeout = .milliseconds(30)
        return Rig(fixture: fixture, link: link, health: health, launcher: launcher, starter: starter, defaults: defaults)
    }

    private func start(_ r: Rig, origin: WatchCommandOrigin) throws -> UUID {
        let id = UUID()
        let routine = try r.fixture.makeRoutine()
        let command = r.fixture.command(.start(routineID: routine.id), at: 0, session: id, origin: origin)
        try #require(r.fixture.engine.apply(command).isApplied)
        return id
    }

    @Test func phoneStartLaunchesWatchAppAndWatchAdoptsRecording() async throws {
        let r = try make()
        #expect(r.starter.isEnabled) // padrão ligado
        let id = try start(r, origin: .phone)
        #expect(r.fixture.engine.startOrigin(of: id) == .phone)
        let link = r.link
        r.launcher.onLaunch = { link.watchRecordingSessionID = id }
        await r.starter.sessionStarted(id)
        #expect(r.launcher.launched == [.traditionalStrength])
        #expect(r.starter.state == .watchRecording(sessionID: id))
    }

    @Test func noConfirmationKeepsPhoneRecording() async throws {
        let r = try make()
        let id = try start(r, origin: .phone)
        await r.starter.sessionStarted(id)
        #expect(r.launcher.launched.count == 1)
        #expect(r.starter.state == .timedOut(sessionID: id))
    }

    @Test func launchFailureIsReported() async throws {
        let r = try make()
        let id = try start(r, origin: .phone)
        r.launcher.error = HealthRecorderError.failed
        await r.starter.sessionStarted(id)
        guard case .failed(let failed, _) = r.starter.state else {
            Issue.record("estado inesperado: \(r.starter.state)")
            return
        }
        #expect(failed == id)
    }

    @Test func startedOnWatchIsSkipped() async throws {
        let r = try make()
        let id = try start(r, origin: .watch)
        await r.starter.sessionStarted(id)
        #expect(r.starter.state == .skipped(sessionID: id, reason: .startedOnWatch))
        #expect(r.launcher.launched.isEmpty)
    }

    @Test func disabledPreferenceIsSkipped() async throws {
        let r = try make(enabled: false)
        let id = try start(r, origin: .phone)
        await r.starter.sessionStarted(id)
        #expect(r.starter.state == .skipped(sessionID: id, reason: .disabled))
        #expect(r.launcher.launched.isEmpty)
    }

    @Test func missingWatchAppOrHealthIsSkipped() async throws {
        let r = try make()
        r.link.isWatchAppInstalled = false
        let id = try start(r, origin: .phone)
        await r.starter.sessionStarted(id)
        #expect(r.starter.state == .skipped(sessionID: id, reason: .watchAppNotInstalled))

        r.link.isWatchAppInstalled = true
        r.health.canRecordWorkouts = false
        await r.starter.sessionStarted(id)
        #expect(r.starter.state == .skipped(sessionID: id, reason: .healthNotAuthorized))

        r.health.canRecordWorkouts = true
        r.link.watchRecordingSessionID = id
        await r.starter.sessionStarted(id)
        #expect(r.starter.state == .skipped(sessionID: id, reason: .alreadyRecording))
        #expect(r.launcher.launched.isEmpty)
    }

    @Test func attachReactsToPhoneStartEvent() async throws {
        let r = try make()
        r.starter.attach()
        defer { r.starter.detach() }
        _ = try start(r, origin: .phone)
        for _ in 0..<200 where r.launcher.launched.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(r.launcher.launched.count == 1)
    }
}
