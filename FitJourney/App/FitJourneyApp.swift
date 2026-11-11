import SwiftData
import SwiftUI

@main
struct FitJourneyApp: App {
    private let modelContainer: ModelContainer
    /// Motor da sessão de treino (única porta de escrita da sessão). A tela de treino (P2.2) o lê do ambiente.
    @State private var sessionEngine: SessionEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = PersistenceController.makeAppContainer()
        #if DEBUG
        // Evidências/QA: `-fj.seedSample YES` popula dados de exemplo uma única vez (banco vazio).
        if UserDefaults.standard.bool(forKey: "fj.seedSample") {
            let context = container.mainContext
            if (try? SampleProgramFactory.shouldOfferStarter(in: context)) == true {
                try? SampleData.insert(into: context)
            }
        }
        #endif
        modelContainer = container

        let engine = SessionEngine(context: container.mainContext, notifications: UserNotificationRestScheduler())
        engine.restore()
        _sessionEngine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(sessionEngine)
                .task(priority: .utility) {
                    // Limpeza de mídia órfã/temporária, fora do caminho crítico do launch.
                    _ = await MediaMaintenance.runAtLaunch(container: modelContainer)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sessionEngine.handleForeground() }
        }
    }
}
