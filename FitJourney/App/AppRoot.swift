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
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?
    @Environment(CoachHandoff.self) private var coachHandoff: CoachHandoff?
    @Environment(\.modelContext) private var context

    private static var initialTab: Tab {
        #if DEBUG
        // QA/evidências: `-fj.startTab training|nutrition`.
        switch UserDefaults.standard.string(forKey: "fj.startTab") {
        case "training": return .training
        case "nutrition": return .nutrition
        case "coach": return .coach
        case "health": return .health
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
        .sheet(item: Binding(get: { importCoordinator?.presented }, set: { if $0 == nil { importCoordinator?.closeSheet() } })) { session in
            ImportFlowView(session: session)
        }
        .overlay(alignment: .top) {
            if let completion = importCoordinator?.banner {
                ImportResultBanner(completion: completion, onUndo: { undoImport(completion) },
                                   onDismiss: { importCoordinator?.banner = nil })
                    .id(completion.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: importCoordinator?.route) { _, route in
            guard let route else { return }
            selection = route.kind == .program ? .training : .nutrition
        }
        .onChange(of: coachHandoff?.request) { _, request in
            if request != nil { selection = .coach }
        }
        .alert(item: Binding(get: { transfer?.announcement }, set: { transfer?.announcement = $0 })) { item in
            Alert(title: Text(verbatim: item.title), message: Text(verbatim: item.message))
        }
    }

    private func undoImport(_ completion: ImportCompletion) {
        importCoordinator?.banner = nil
        try? ImportOverrides.undo(completion, context: context)
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
