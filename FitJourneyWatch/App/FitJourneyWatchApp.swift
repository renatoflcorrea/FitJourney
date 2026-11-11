import SwiftUI
import WatchKit

@main
struct FitJourneyWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model: WatchSessionModel
    private let initialPage: Int
    private let override: (@MainActor () -> AnyView)?

    init() {
        let setup = WatchAppComposition.make()
        _model = State(initialValue: setup.model)
        initialPage = setup.initialPage
        override = setup.rootOverride
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let override { override() } else { WatchRootView(initialPage: initialPage) }
            }
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
    }
}

/// Recuperação do treino do Saúde quando o app do relógio é reaberto com uma `HKWorkoutSession` em curso.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in
            guard let provider = WatchAppComposition.workoutProvider else { return }
            await provider.recoverActiveWorkout()
            WatchAppComposition.model?.reevaluateRecording()
        }
    }
}

/// Composição das dependências do app.
///
/// Release: `WatchConnectivityTransport` (`WCSession` + canal da `HKWorkoutSession` espelhada) e
/// `WatchWorkoutProvider` (`HKWorkoutSession` no relógio). DEBUG com `-FJWScene`: harness de screenshots com o
/// `MockWatchTransport` (só DEBUG, também usado em previews/testes).
enum WatchAppComposition {
    struct Result {
        var model: WatchSessionModel
        var initialPage: Int
        /// Só o harness de screenshots (DEBUG) substitui a raiz (ex.: mostrar a Ficha ou o RPE direto).
        var rootOverride: (@MainActor () -> AnyView)?
    }

    /// Referências para o delegate do app (recuperação do treino).
    @MainActor private(set) static var workoutProvider: WatchWorkoutProvider?
    @MainActor private(set) static weak var model: WatchSessionModel?

    @MainActor static func make() -> Result {
        #if DEBUG
        if let scene = WatchHarnessScene.fromLaunchArguments() { return scene.build() }
        #endif
        let provider = WatchWorkoutProvider()
        let transport = WatchConnectivityTransport(session: WCWatchLinkSession(), workoutChannel: provider)
        transport.activate()
        let model = WatchSessionModel(transport: transport, haptics: SystemWatchHaptics(), health: provider)
        workoutProvider = provider
        self.model = model
        return Result(model: model, initialPage: 1, rootOverride: nil)
    }
}
