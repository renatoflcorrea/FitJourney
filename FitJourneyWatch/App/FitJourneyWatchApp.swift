import SwiftUI

@main
struct FitJourneyWatchApp: App {
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
                .task { await model.start() }
        }
    }
}

/// Composição das dependências do app.
///
/// PONTO DE INJEÇÃO (W2/W3b): hoje o transporte é o `UnavailableWatchTransport` (o `MockWatchTransport`, só DEBUG, serve a previews/testes/harness) e a saúde é o
/// `UnavailableHealthProvider`. O W2 troca por um `WatchConnectivityTransport` (+ canal da `HKWorkoutSession`
/// espelhada) e o W3b por um `HealthKitWorkoutProvider` — só aqui, sem mexer em modelo nem telas.
enum WatchAppComposition {
    struct Result {
        var model: WatchSessionModel
        var initialPage: Int
        /// Só o harness de screenshots (DEBUG) substitui a raiz (ex.: mostrar a Ficha ou o RPE direto).
        var rootOverride: (@MainActor () -> AnyView)?
    }

    @MainActor static func make() -> Result {
        #if DEBUG
        if let scene = WatchHarnessScene.fromLaunchArguments() { return scene.build() }
        #endif
        // Sem canal real ainda: o relógio abre como "nunca sincronizou" (iPhone fora de alcance, sem dados).
        // PENDÊNCIA DE LANÇAMENTO: trocar `UnavailableWatchTransport` pelo transporte real do W2.
        let transport = UnavailableWatchTransport()
        let model = WatchSessionModel(transport: transport, haptics: SystemWatchHaptics())
        return Result(model: model, initialPage: 1, rootOverride: nil)
    }
}
