import SwiftData
import SwiftUI

/// Raiz do app: abas principais (SPEC §10).
struct AppRoot: View {
    enum Tab: Hashable { case today, training, nutrition, health, coach }

    @State private var selection: Tab = Self.initialTab
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?

    private static var initialTab: Tab {
        #if DEBUG
        // QA/evidências: `-fj.startTab training|nutrition`.
        switch UserDefaults.standard.string(forKey: "fj.startTab") {
        case "training": return .training
        case "nutrition": return .nutrition
        case "coach": return .coach
        default: break
        }
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
                NutritionRootView()
            }
            SwiftUI.Tab("Saúde", systemImage: "heart", value: Tab.health) {
                HealthRootView()
            }
            SwiftUI.Tab("Coach", systemImage: "sparkles", value: Tab.coach) {
                CoachRootView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(OptionalSessionHost(coordinator: sessionCoordinator))
        .tint(FJColor.training)
    }
}

/// Instala o host da sessão quando há coordenador no ambiente (previews podem não ter).
private struct OptionalSessionHost: ViewModifier {
    let coordinator: SessionCoordinator?

    func body(content: Content) -> some View {
        if let coordinator { content.sessionHost(coordinator) } else { content }
    }
}


#Preview { AppRoot().modelContainer(PersistenceController.preview) }
