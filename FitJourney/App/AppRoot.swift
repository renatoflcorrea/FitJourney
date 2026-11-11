import SwiftUI

/// Raiz do app: abas principais (SPEC §10). Coach entra no ciclo 5.
struct AppRoot: View {
    enum Tab: Hashable { case today, training, nutrition, health }

    @State private var selection: Tab = .today

    var body: some View {
        TabView(selection: $selection) {
            SwiftUI.Tab("Hoje", systemImage: "sun.max", value: Tab.today) {
                PlaceholderScreen(title: "Hoje")
            }
            SwiftUI.Tab("Treinos", systemImage: "dumbbell", value: Tab.training) {
                PlaceholderScreen(title: "Treinos")
            }
            SwiftUI.Tab("Dieta", systemImage: "fork.knife", value: Tab.nutrition) {
                PlaceholderScreen(title: "Dieta")
            }
            SwiftUI.Tab("Saúde", systemImage: "heart", value: Tab.health) {
                PlaceholderScreen(title: "Saúde")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
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

#Preview { AppRoot() }
