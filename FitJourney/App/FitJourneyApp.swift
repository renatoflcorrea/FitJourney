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
    /// Ponte com o Apple Watch (WatchConnectivity + canal da sessão espelhada). Iniciada cedo no launch:
    /// comandos feitos offline no relógio chegam por `transferUserInfo` assim que o WCSession ativa.
    @State private var watchLink: PhoneWatchLink
    /// Abre o app do relógio gravando quando a sessão começa no iPhone (P2.8).
    private let watchAutoStarter: WatchAutoStarter
    /// Lembretes de refeição (agendamento) e tratamento das notificações locais. O delegate do
    /// `UNUserNotificationCenter` é fraco: o App o retém.
    private let mealReminders: MealReminderScheduler
    private let notificationDelegate: AppNotificationDelegate
    private let categoryRegistry: NotificationCategoryRegistry
    /// Exportar/importar/apagar vivem aqui: sobrevivem ao reset da árvore e mostram o resultado depois dele.
    @State private var dataTransfer: DataTransferModel
    /// Copiloto de IA: importações em andamento (a folha única) e a ponte "Editar com IA" → conversa do Coach.
    @State private var importCoordinator: ImportCoordinator
    @State private var coachHandoff = CoachHandoff()
    /// Atividade ao Vivo + Dynamic Island da sessão (P6.4). Também atende os botões +15 s/Pular
    /// (`LiveActivityIntentRouter`), inclusive quando o sistema acorda o app só para o intent.
    private let liveActivity: LiveActivityController
    #if DEBUG
    /// Saúde sintético das capturas da App Store (`-fj.seedDemo YES`); `nil` fora da demonstração.
    private let storeDemoHealth: StoreDemoHealthModifier
    #endif
    /// Serviços da sessão que não dependem de UI (Saúde, canal do relógio, Atividade ao Vivo). Roda uma
    /// vez: no `.task` da cena ou antes, quando um intent da atividade acorda o app sem cena.
    private let backgroundServices: AppBackgroundServices
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
        #if DEBUG
        // Capturas da App Store: histórico rico, dieta, conversa do Coach e FC sintética (ver `StoreDemo`).
        if StoreDemo.isEnabled {
            // FC máxima definida: o gráfico de FC mostra as zonas em vez do pedido de configuração.
            UserDefaults.standard.set(185.0, forKey: AppPreferenceKeys.maxHeartRate)
            StoreDemo.insertIfNeeded(into: container.mainContext)
            storeDemoHealth = StoreDemoHealthModifier(reader: StoreDemo.healthReader(context: container.mainContext),
                                                      authorization: StoreDemo.healthAuthorization())
        } else {
            storeDemoHealth = StoreDemoHealthModifier(reader: nil, authorization: nil)
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

        // Com Atividade ao Vivo ativa, a notificação de fim de descanso dá lugar ao alerta da atividade.
        let restGate = LiveActivityRestNotificationGate(wrapping: Self.makeRestScheduler())
        let engine = SessionEngine(context: container.mainContext, notifications: restGate)
        let live = LiveActivityController(
            engine: engine, gate: restGate,
            routineColorName: LiveActivityController.routineColorLookup(context: container.mainContext))
        LiveActivityIntentRouter.handler = live
        liveActivity = live
        let authorization = HealthAuthorization(store: HealthKitStore.shared)
        _dataTransfer = State(initialValue: DataTransferModel(container: container))
        _importCoordinator = State(initialValue: ImportCoordinator(context: container.mainContext))
        _sessionEngine = State(initialValue: engine)
        _sessionCoordinator = State(initialValue: SessionCoordinator(engine: engine))
        _healthAuthorization = State(initialValue: authorization)
        let controller = HealthWorkoutController(
            store: HealthKitStore.shared, authorization: authorization, context: container.mainContext)
        _healthController = State(initialValue: controller)
        let link = PhoneWatchLink(engine: engine, health: controller,
                                  workoutFinder: PhoneWatchLink.finder(reading: HealthQueries.live))
        _watchLink = State(initialValue: link)
        // Ao iniciar no iPhone, abre o app do relógio já gravando (preferência `fj.autoStartWatchWorkout`).
        let autoStarter = WatchAutoStarter(engine: engine, link: link, health: controller, launcher: HealthKitStore.shared)
        watchAutoStarter = autoStarter
        let services = AppBackgroundServices {
            // Recuperar sessões espelhadas do relógio e acoplar o Saúde aos eventos do motor
            // (retoma a gravação de uma sessão em andamento e reconcilia treinos pendentes).
            controller.startObservingMirroredSessions()
            controller.attach(to: engine)
            link.start()
            autoStarter.attach()
            live.start()
        }
        backgroundServices = services
        live.onWake = { services.start() }
    }

    private static func makeRestScheduler() -> any RestNotificationScheduling {
        #if DEBUG
        if StoreDemo.isEnabled { return StoreDemo.RestScheduler() }
        #endif
        return UserNotificationRestScheduler()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                #if DEBUG
                .modifier(storeDemoHealth)
                #endif
                .environment(sessionEngine)
                .environment(sessionCoordinator)
                .environment(healthAuthorization)
                .environment(healthController)
                .environment(watchLink)
                .environment(dataTransfer)
                .environment(importCoordinator)
                .environment(coachHandoff)
                .environment(\.mealReminderScheduler, mealReminders)
                .task {
                    await categoryRegistry.apply()
                    await mealReminders.reschedule(for: modelContainer.mainContext)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await mealReminders.reschedule(for: modelContainer.mainContext) }
                        watchLink.handleForeground()
                        liveActivity.handleForeground()
                    }
                }
                .task { backgroundServices.start() }
                #if DEBUG
                .task { StoreDemo.scheduleScrollIfRequested() }
                #endif
                .task {
                    // FC ao vivo na tela da sessão; a zona usa a FC máxima de Ajustes (ou 220 − idade do perfil).
                    let zones = HeartRateZoneProvider()
                    for await sample in healthController.heartRateUpdates() {
                        sessionCoordinator.heartRate = SessionHeartRate(bpm: Int(sample.bpm.rounded()),
                                                                        zone: zones.zone(for: sample.bpm))
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

/// Inicialização única dos serviços sem UI (o `.task` da cena e o intent que acorda o app chamam `start()`).
@MainActor
final class AppBackgroundServices {
    private var work: (() -> Void)?

    init(_ work: @escaping () -> Void) { self.work = work }

    func start() {
        guard let work else { return }
        self.work = nil
        work()
    }
}
