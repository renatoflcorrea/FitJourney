import SwiftData
import SwiftUI

/// Raiz do app: abas principais (SPEC §10). Coach entra no ciclo 5.
struct AppRoot: View {
    enum Tab: Hashable { case today, training, nutrition, health }

    @State private var selection: Tab = Self.initialTab

    private static var initialTab: Tab {
        #if DEBUG
        // QA/evidências: `-fj.startTab training`.
        if UserDefaults.standard.string(forKey: "fj.startTab") == "training" { return .training }
        #endif
        return .today
    }

    var body: some View {
        TabView(selection: $selection) {
            SwiftUI.Tab("Hoje", systemImage: "sun.max", value: Tab.today) {
                TodayView(onOpenTraining: { selection = .training })
            }
            SwiftUI.Tab("Treinos", systemImage: "dumbbell", value: Tab.training) {
                TrainingRootView()
            }
            SwiftUI.Tab("Dieta", systemImage: "fork.knife", value: Tab.nutrition) {
                // PONTO DE INTEGRAÇÃO (P3.x): trocar por `NutritionRootView()`.
                PlaceholderScreen(title: "Dieta")
            }
            SwiftUI.Tab("Saúde", systemImage: "heart", value: Tab.health) {
                PlaceholderScreen(title: "Saúde")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(FJColor.training)
    }
}

private struct PlaceholderScreen: View {
    let title: LocalizedStringKey

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Em construção"))
                .navigationTitle(title)
        }
    }
}

#Preview { AppRoot().modelContainer(PersistenceController.preview) }
