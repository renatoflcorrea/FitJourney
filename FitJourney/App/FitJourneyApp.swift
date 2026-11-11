import SwiftData
import SwiftUI

@main
struct FitJourneyApp: App {
    private let modelContainer = PersistenceController.makeAppContainer()

    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
        .modelContainer(modelContainer)
    }
}
