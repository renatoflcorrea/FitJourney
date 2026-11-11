import SwiftData
import SwiftUI
import UserNotifications

@main
struct FitJourneyApp: App {
    private let modelContainer: ModelContainer
    /// Motor da sessão de treino (única porta de escrita da sessão).
    @State private var sessionEngine: SessionEngine
    /// Apresentação da sessão (tela cheia, acessório, treino esquecido). O `sessionHost` no `AppRoot`
    /// chama `restoreIfNeeded()` no launch e `handleForeground()` ao voltar ao primeiro plano.
    @State private var sessionCoordinator: SessionCoordinator
    /// Apple Health: autorização contextual e gravação do treino acoplada ao motor (SPEC §6).
    @State private var healthAuthorization: HealthAuthorization
    @State private var healthController: HealthWorkoutController
    /// Lembretes de refeição (agendamento) e tratamento das notificações locais. O delegate do
    /// `UNUserNotificationCenter` é fraco: o App o retém.
    private let mealReminders: MealReminderScheduler
    private let notificationDelegate: AppNotificationDelegate
    private let categoryRegistry: NotificationCategoryRegistry
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
        // Coach: respostas que ficaram `.streaming` quando o app morreu viram `.stopped`.
        _ = try? CoachConversationService.repairInterruptedMessages(in: container.mainContext)

        // Notificações: delegate e categorias antes de qualquer view (ação "Marcar como feita" no cold start).
        let reminders = MealReminderScheduler()
        let delegate = AppNotificationDelegate(context: container.mainContext, reminders: reminders)
        UNUserNotificationCenter.current().delegate = delegate
        let registry = NotificationCategoryRegistry()
        registry.register(MealReminderResponder.category)
        mealReminders = reminders
        notificationDelegate = delegate
        categoryRegistry = registry

        let engine = SessionEngine(context: container.mainContext, notifications: UserNotificationRestScheduler())
        let authorization = HealthAuthorization(store: HealthKitStore.shared)
        _sessionEngine = State(initialValue: engine)
        _sessionCoordinator = State(initialValue: SessionCoordinator(engine: engine))
        _healthAuthorization = State(initialValue: authorization)
        _healthController = State(initialValue: HealthWorkoutController(
            store: HealthKitStore.shared, authorization: authorization, context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(sessionEngine)
                .environment(sessionCoordinator)
                .environment(healthAuthorization)
                .environment(healthController)
                .environment(\.mealReminderScheduler, mealReminders)
                .task {
                    await categoryRegistry.apply()
                    await mealReminders.reschedule(for: modelContainer.mainContext)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await mealReminders.reschedule(for: modelContainer.mainContext) } }
                }
                .task {
                    // Recuperar sessões espelhadas do relógio e acoplar o Saúde aos eventos do motor
                    // (retoma a gravação de uma sessão em andamento e reconcilia treinos pendentes).
                    healthController.startObservingMirroredSessions()
                    healthController.attach(to: sessionEngine)
                }
                .task {
                    // FC ao vivo na tela da sessão; a zona usa a FC máxima de Ajustes (ou 220 − idade do perfil).
                    for await sample in healthController.heartRateUpdates() {
                        let stored = UserDefaults.standard.double(forKey: AppPreferenceKeys.maxHeartRate)
                        let age = CoachProfileStore().load().age
                        let zone = HeartRateZones.resolve(configuredMax: stored > 0 ? stored : nil, age: age)
                            .zones?.zone(for: sample.bpm).map(HealthPresentation.designZone)
                        sessionCoordinator.heartRate = SessionHeartRate(bpm: Int(sample.bpm.rounded()), zone: zone)
                    }
                }
                .task(priority: .utility) {
                    // Limpeza de mídia órfã/temporária, fora do caminho crítico do launch.
                    _ = await MediaMaintenance.runAtLaunch(container: modelContainer)
                    // Exportações temporárias com mais de 24 h (podem conter dados pessoais).
                    _ = BackupMaintenance.runAtLaunch()
                }
        }
        .modelContainer(modelContainer)
    }
}
