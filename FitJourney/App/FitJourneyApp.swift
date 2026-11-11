import SwiftData
import SwiftUI

@main
struct FitJourneyApp: App {
    private let modelContainer: ModelContainer

    init() {
        let container = PersistenceController.makeAppContainer()
        #if DEBUG
        // Evidências/QA: `-fj.seedSample YES` popula dados de exemplo uma única vez (banco vazio).
        if UserDefaults.standard.bool(forKey: "fj.seedSample") {
            let context = container.mainContext
            if StarterProgram.shouldOffer(in: context) {
                try? SampleData.insert(into: context)
            }
        }
        #endif
        modelContainer = container
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
        .modelContainer(modelContainer)
    }
}
