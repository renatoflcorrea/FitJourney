#if DEBUG
import SwiftUI

/// Harness de screenshots/QA no simulador (só DEBUG): `-FJWScene <nome>` abre o app já num estado de teste.
/// Cenas: never, noprogram, list, offline, detail, series, series-last, rest, rest-done (aviso de 2 s, alerta insistente
/// desligado), rest-alert (alerta vibrando), rest-alert-quiet (alerta silenciado), hold, hold-running, cardio, paused,
/// controls, metrics, routine, finish, summary, intro, unreachable, load-editor (editor de carga, W4), load-editor-bw
/// (peso corporal com lastro), load-editor-unset (série sem carga), series-bw (Série com peso corporal + lastro).
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
        case "series", "controls", "metrics", "routine", "finish", "summary", "saving", "unreachable",
             "load-editor", "load-editor-bw", "load-editor-unset", "series-bw":
            snapshot = WatchFixtures.snapshot(completed: 1, now: now)
        case "series-last": snapshot = WatchFixtures.snapshot(completed: 3, now: now)
        case "rest", "rest-done", "rest-alert", "rest-alert-quiet": snapshot = WatchFixtures.snapshot(completed: 1, now: now)
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
        let alertEnd = now.addingTimeInterval(-12)
        if name.hasPrefix("rest-alert") { snapshot?.restEndsAt = alertEnd }
        if name == "hold-running" {
            let holdID = snapshot?.currentSetID
            snapshot?.holdSetID = holdID
            snapshot?.holdStartedAt = now.addingTimeInterval(-31)
        }
        if name == "paused" { snapshot?.status = .paused; snapshot?.pausedAt = now.addingTimeInterval(-30) }
        if name == "intro" { healthAccess = .authorized }
        if name == "load-editor-bw" || name == "series-bw" || name == "load-editor-unset", let setID = snapshot?.currentSetID,
           let e = snapshot?.exercises.firstIndex(where: { $0.sets.contains { $0.id == setID } }),
           let s = snapshot?.exercises[e].sets.firstIndex(where: { $0.id == setID }) {
            snapshot?.exercises[e].sets[s].load = nil
            snapshot?.exercises[e].sets[s].plannedLoad = name == "load-editor-unset" ? nil : WatchLoad(value: 10, isBodyweight: true)
        }

        let transport = MockWatchTransport(digest: name == "never" || name == "noprogram" ? nil : digest, snapshot: snapshot, reachable: reachable)
        if name == "saving" { transport.autoRespond = false }
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: FixedHealthProvider(access: healthAccess))
        if name != "never" {
            model.receive(digest: name == "noprogram" ? nil : digest)
            if let snapshot { model.receive(snapshot: snapshot) }
        }
        model.liveMetrics = metrics
        if name == "rest" { model.restTotalSeconds = 90 }
        if name == "intro" { model.introExerciseID = WatchFixtures.id(200) }
        if name == "rest-done" { model.restFinishedAt = now }
        if name.hasPrefix("rest-alert") {
            model.restDidEnd(at: alertEnd)
            if name == "rest-alert-quiet" { model.silenceRestAlert() }
        }
        if name == "summary", let snapshot {
            // iPhone confirma o fim: só então o resumo existe.
            let finish = SessionCommand(sessionID: snapshot.sessionID, issuedAt: now, origin: .watch, kind: .finish(rpe: 8, applyLoadProposalIDs: []))
            if var done = SessionReducer.apply(finish, to: snapshot, digest: digest) {
                done.revision = snapshot.revision + 1
                model.receive(snapshot: done)
            }
        }
        if name == "saving" { model.finish(rpe: 8) }
        switch name {
        case "detail":
            override = { AnyView(NavigationStack { RoutineDetailView(routine: digest.routines[0]) }) }
        case "finish":
            override = { AnyView(FinishView()) }
        case "load-editor", "load-editor-bw", "load-editor-unset":
            if let setID = snapshot?.currentSetID, let draft = model.loadDraft(setID: setID) {
                override = { AnyView(LoadEditorView(draft: draft)) }
            }
        default: break
        }
        return .init(model: model, initialPage: page, rootOverride: override)
    }
}
#endif
