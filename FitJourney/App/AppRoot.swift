import SwiftData
import SwiftUI

/// Raiz do app: abas principais (SPEC §10).
struct AppRoot: View {
    enum Tab: Hashable { case today, training, nutrition, health, coach }

    @State private var selection: Tab = Self.initialTab
    /// Muda depois de substituir/apagar tudo: recria as abas (os modelos antigos deixaram de existir).
    @State private var resetGeneration = 0
    /// Entre `fjDataWillReset` e `fjDataDidReset` as abas não existem.
    @State private var isResetting = false
    /// Modelo de Dados de nível superior: guarda o resultado de substituir/apagar para mostrar após o reset.
    @Environment(DataTransferModel.self) private var transfer: DataTransferModel?
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
        Group {
            if isResetting {
                // Estado neutro bloqueante: nenhuma view com modelos antigos fica viva durante a escrita.
                ProgressView("Atualizando dados…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .fjScreenBackground()
                    .allowsHitTesting(false)
            } else {
                tabs
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fjDataWillReset)) { _ in
            sessionCoordinator?.isPresented = false
            isResetting = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fjDataDidReset)) { _ in
            sessionCoordinator?.engine.restore()
            selection = .today
            resetGeneration += 1
            isResetting = false
        }
        .alert(item: Binding(get: { transfer?.announcement }, set: { transfer?.announcement = $0 })) { item in
            Alert(title: Text(verbatim: item.title), message: Text(verbatim: item.message))
        }
    }

    private var tabs: some View {
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
        .id(resetGeneration)
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
