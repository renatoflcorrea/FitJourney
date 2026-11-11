#if DEBUG
import SwiftUI

/// Harness de screenshots/QA no simulador (só DEBUG): `-FJWScene <nome>` abre o app já num estado de teste.
/// Cenas: never, noprogram, list, offline, detail, series, series-last, rest, rest-done, hold, hold-running, cardio, paused,
/// controls, metrics, routine, finish, summary, intro, unreachable.
struct WatchHarnessScene {
    let name: String

    static func fromLaunchArguments() -> WatchHarnessScene? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-FJWScene"), args.indices.contains(i + 1) else { return nil }
        return WatchHarnessScene(name: args[i + 1])
    }

    @MainActor func build() -> WatchAppComposition.Result {
        let now = Date()
        let digest = WatchFixtures.digest(now: now)
        var snapshot: SessionSnapshot?
        var page = 1
        var reachable = true
        var healthAccess = WatchHealthAccess.authorized
        var override: (@MainActor () -> AnyView)?
        var metrics = WatchLiveMetrics.empty

        switch name {
        case "never": reachable = false
        case "noprogram": break
        case "list", "detail", "offline": break
        case "series", "controls", "metrics", "routine", "finish", "summary", "unreachable":
            snapshot = WatchFixtures.snapshot(completed: 1, now: now)
        case "series-last": snapshot = WatchFixtures.snapshot(completed: 3, now: now)
        case "rest", "rest-done": snapshot = WatchFixtures.snapshot(completed: 1, now: now)
        case "intro": snapshot = WatchFixtures.snapshot(completed: 4, now: now)
        case "hold", "hold-running", "cardio": snapshot = WatchFixtures.snapshot(completed: 10, now: now)
        case "paused": snapshot = WatchFixtures.snapshot(completed: 2, now: now)
        default: break
        }
        if name == "unreachable" || name == "offline" { reachable = false }
        if name == "controls" { page = 0 }
        if name == "metrics" { page = 2; metrics = WatchLiveMetrics(heartRate: 128, heartRateZone: 3, activeKilocalories: 214, averageHeartRate: 121) }
        if name == "routine" { page = 3 }
        if name == "rest" { snapshot?.restEndsAt = now.addingTimeInterval(52) }
        if name == "hold-running" {
            let holdID = snapshot?.currentSetID
            snapshot?.holdSetID = holdID
            snapshot?.holdStartedAt = now.addingTimeInterval(-31)
        }
        if name == "paused" { snapshot?.status = .paused; snapshot?.pausedAt = now.addingTimeInterval(-30) }
        if name == "intro" { healthAccess = .authorized }

        let transport = MockWatchTransport(digest: name == "never" || name == "noprogram" ? nil : digest, snapshot: snapshot, reachable: reachable)
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: FixedHealthProvider(access: healthAccess))
        if name != "never" {
            model.receive(digest: name == "noprogram" ? nil : digest)
            if let snapshot { model.receive(snapshot: snapshot) }
        }
        model.liveMetrics = metrics
        if name == "rest" { model.restTotalSeconds = 90 }
        if name == "intro" { model.introExerciseID = WatchFixtures.id(200) }
        if name == "rest-done" { model.restFinishedAt = now }
        if name == "summary" {
            model.finish(rpe: 8)
        }
        switch name {
        case "detail":
            override = { AnyView(NavigationStack { RoutineDetailView(routine: digest.routines[0]) }) }
        case "finish":
            override = { AnyView(FinishView()) }
        default: break
        }
        return .init(model: model, initialPage: page, rootOverride: override)
    }
}
#endif
