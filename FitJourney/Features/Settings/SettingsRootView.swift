import ActivityKit
import SwiftData
import SwiftUI
import UIKit

/// Ajustes (DESIGN_DIRECTION §4.12): sheet a partir do avatar em Hoje, `Form` nativo (sem vidro).
/// Preferências em `UserDefaults` via `@AppStorage` (chaves em `AppPreferenceKeys`).
struct SettingsRootView: View {
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    @Environment(\.dismiss) private var dismiss
    @Environment(HealthAuthorization.self) private var healthAuthorization: HealthAuthorization?

    @AppStorage(AppPreferenceKeys.weightUnit) private var weightUnitRaw = WeightUnit.kg.rawValue
    @AppStorage(AppPreferenceKeys.loadStep) private var loadStep = 0.0
    @AppStorage(AppPreferenceKeys.weekStart) private var weekStartRaw = WeekStart.monday.rawValue
    @AppStorage(AppPreferenceKeys.defaultRestSeconds) private var defaultRest = RestPreference.fallbackSeconds
    @AppStorage(AppPreferenceKeys.restSound) private var restSound = true
    @AppStorage(AppPreferenceKeys.restAlertRepeat) private var restAlertRepeat = true
    @AppStorage(AppPreferenceKeys.maxHeartRate) private var maxHeartRate = 0.0
    /// Atividade ao Vivo (padrão ligado; consumidor: `LiveActivityController`).
    @AppStorage(AppPreferenceKeys.liveActivity) private var liveActivity = true
    /// Abrir o app do relógio gravando ao iniciar no iPhone (padrão ligado; consumidor: `WatchAutoStarter`).
    @AppStorage(AppPreferenceKeys.autoStartWatchWorkout) private var autoStartWatchWorkout = true
    /// Atividades ao Vivo permitidas em Ajustes do iPhone › FitJourney (relido ao voltar ao app).
    @State private var systemLiveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var profile = CoachProfile()
    @State private var providerSettings = ProviderSettings.default
    @State private var hasKey = false
    @State private var notification: SettingsPresentation.NotificationState = .notRequested
    @State private var manualHeartRate = false
    @State private var path: [Route] = Self.initialPath
    @State private var languageSelection: AppLanguagePreference
    @State private var showsRestartAlert = false

    enum Route: Hashable { case data }

    private static var initialPath: [Route] {
        #if DEBUG
        // QA/evidências: `-fj.openSettings data` abre direto em Dados.
        UserDefaults.standard.string(forKey: "fj.openSettings") == "data" ? [.data] : []
        #else
        []
        #endif
    }

    @Environment(\.mealReminderScheduler) private var scheduler

    init() {
        self.init(secrets: KeychainSecretStore(), defaults: .standard)
    }

    /// Para previews e testes.
    init(secrets: any SecretStore, defaults: UserDefaults) {
        self.secrets = secrets
        self.defaults = defaults
        _languageSelection = State(initialValue: AppLanguagePreference.current(defaults))
    }

    private var unit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .kg }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                profileSection
                generalSection
                unitsSection
                trainingSection
                integrationsSection
                Section {
                    NavigationLink(value: Route.data) {
                        Label("Exportar, importar e apagar", systemImage: "externaldrive")
                    }
                } header: {
                    Text("Dados")
                }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("Sobre", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { _ in
                DataSettingsView(onClose: { dismiss() })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .onAppear { Task { await reload() } }
        }
        .tint(FJColor.training)
    }

    // MARK: Perfil

    private var profileSection: some View {
        Section {
            NavigationLink {
                CoachProfileView(defaults: defaults)
            } label: {
                HStack(spacing: FJSpacing.m) {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(FJColor.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(FJColor.fill, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text("Seu perfil").font(FJFont.cardTitle)
                        if let summary = SettingsPresentation.profileSummary(profile) {
                            Text(verbatim: summary).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        } else {
                            Text("Opcional — ajuda o Coach a conhecer você")
                                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Geral

    private var generalSection: some View {
        Section {
            Picker("Idioma", selection: $languageSelection) {
                ForEach(AppLanguagePreference.allCases, id: \.self) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Idioma do app"))
            .onChange(of: languageSelection) { _, newValue in
                guard newValue != AppLanguagePreference.current(defaults) else { return }
                newValue.apply(to: defaults)
                showsRestartAlert = true
            }
        } header: {
            Text("Geral")
        } footer: {
            Text("O Apple Watch segue o idioma escolhido aqui (reabra o app do relógio para aplicar). Os nomes dos exercícios do catálogo aparecem no mesmo idioma no iPhone, no relógio, na Atividade ao Vivo e no Coach.")
        }
        .alert("Reinicie o FitJourney para aplicar", isPresented: $showsRestartAlert) {
            // Encerra o app de forma limpa; o iOS não reabre sozinho, o usuário abre de novo.
            Button("Reiniciar agora") { exit(0) }
            Button("Depois", role: .cancel) {}
        } message: {
            Text("O idioma muda ao reabrir o app. Se escolher Reiniciar agora, o FitJourney fecha e você o abre de novo pela tela de início.")
        }
    }

    // MARK: Unidades

    @ViewBuilder private var unitOptions: some View {
        Text("kg").tag(WeightUnit.kg.rawValue)
        Text("lb").tag(WeightUnit.lb.rawValue)
    }

    private var unitsSection: some View {
        Section {
            // Segmentado não cresce com Dynamic Type: em tamanhos de acessibilidade vira menu (linha que cresce).
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Carga", selection: $weightUnitRaw) { unitOptions }
                    .pickerStyle(.menu)
                    .accessibilityLabel(Text("Unidade de carga"))
            } else {
                Picker("Carga", selection: $weightUnitRaw) { unitOptions }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Unidade de carga"))
            }

            Picker("Passo de carga", selection: $loadStep) {
                ForEach(LoadDisplay.stepOptions, id: \.self) { step in
                    Text(verbatim: SettingsPresentation.stepText(step, unit: unit)).tag(step)
                }
            }
            .onAppear {
                // Valor ausente/inválido = padrão da unidade.
                if !LoadDisplay.stepOptions.contains(loadStep) { loadStep = LoadDisplay.step(for: unit, stored: loadStep) }
            }
            .onChange(of: weightUnitRaw) { _, _ in
                // Trocar a unidade volta ao padrão dela (0,5 kg / 1 lb).
                loadStep = unit == .kg ? 0.5 : 1
            }

            Picker("Início da semana", selection: $weekStartRaw) {
                Text("Segunda").tag(WeekStart.monday.rawValue)
                Text("Domingo").tag(WeekStart.sunday.rawValue)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Unidades")
        } footer: {
            Text("Mudar a unidade muda só a exibição. O histórico não é alterado. O início da semana vale para a Dieta, a aderência semanal, Saúde e o calendário; os dias das fichas não mudam.")
        }
    }

    // MARK: Treino

    private var trainingSection: some View {
        Section {
            Picker("Descanso padrão", selection: $defaultRest) {
                ForEach(restOptions, id: \.self) { seconds in
                    Text(verbatim: FJFormat.clock(seconds)).tag(seconds)
                }
            }
            Toggle("Som ao fim do descanso", isOn: $restSound)
            Toggle("Alerta insistente no fim do descanso", isOn: $restAlertRepeat)
            heartRateRows
            liveActivityRows
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Toggle("Iniciar no Apple Watch automaticamente", isOn: $autoStartWatchWorkout)
                Text("Ao iniciar um treino no iPhone, o FitJourney abre no relógio já gravando (frequência cardíaca e calorias do relógio). Exige o app no Apple Watch e o Saúde conectado. O app Exercício da Apple não é aberto.")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
        } header: {
            Text("Treino")
        } footer: {
            Text("O descanso padrão vale quando a ficha e o exercício não definem um, a partir do próximo descanso. Sem som, o alerta da Atividade ao Vivo é dispensado e o aviso chega silencioso pela notificação. Com o alerta insistente, o relógio e a tela do treino vibram várias vezes até você tocar; desligado, vibram uma vez. A FC máxima define as zonas de frequência cardíaca. Sem valor manual, usamos 220 menos a idade do seu perfil. A Atividade ao Vivo mostra o treino e o descanso na Tela Bloqueada e na Dynamic Island.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemLiveActivities = ActivityAuthorizationInfo().areActivitiesEnabled }
        }
    }

    /// Opções de descanso padrão; um valor antigo fora da lista continua selecionável.
    private var restOptions: [Int] {
        Array(Set(AppPreferenceKeys.defaultRestOptions + [defaultRest])).sorted()
    }

    /// Atividade ao Vivo (§4.14): desligada nos Ajustes do iPhone → aviso + Abrir Ajustes; senão, o toggle.
    @ViewBuilder
    private var liveActivityRows: some View {
        if systemLiveActivities {
            Toggle("Atividade ao Vivo", isOn: $liveActivity)
        } else {
            LabeledContent("Atividade ao Vivo") {
                Text("Desativada nos Ajustes do iPhone").foregroundStyle(FJColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    @ViewBuilder
    private var heartRateRows: some View {
        Toggle("Definir FC máxima manualmente", isOn: Binding(
            get: { manualHeartRate },
            set: { on in
                manualHeartRate = on
                if on, maxHeartRate <= 0 {
                    let resolved = HeartRateZones.resolve(configuredMax: nil, age: profile.age)
                    if case .resolved(let bpm, _) = resolved { maxHeartRate = bpm.rounded() } else { maxHeartRate = 185 }
                }
                if !on { maxHeartRate = 0 }
            }))
        if manualHeartRate {
            NumberStepperField("FC máxima", value: $maxHeartRate, unit: "bpm", step: 1,
                               range: HeartRateZones.validMaxHeartRate, fractionDigits: 0)
        } else {
            LabeledContent("FC máxima") {
                Text(verbatim: SettingsPresentation.maxHeartRateSummary(stored: maxHeartRate, age: profile.age))
                    .foregroundStyle(FJColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Integrações

    private var integrationsSection: some View {
        Section("Integrações") {
            NavigationLink {
                HealthConnectView()
            } label: {
                LabeledContent {
                    Text(verbatim: SettingsPresentation.healthTitle(HealthConnectionState(healthAuthorization)))
                } label: {
                    Label("Saúde", systemImage: "heart")
                }
            }
            NavigationLink {
                NotificationSettingsView()
            } label: {
                LabeledContent {
                    Text(verbatim: notification.title)
                } label: {
                    Label("Notificações", systemImage: "bell")
                }
            }
            NavigationLink {
                AISettingsView(secrets: secrets, defaults: defaults)
            } label: {
                LabeledContent {
                    Text(verbatim: SettingsPresentation.aiTitle(settings: providerSettings, hasAPIKey: hasKey))
                } label: {
                    Label("Coach e IA", systemImage: "sparkles")
                }
            }
        }
    }

    // MARK: Dados

    private func reload() async {
        profile = CoachProfileStore(defaults: defaults).load()
        providerSettings = ProviderSettingsStore(defaults: defaults).load()
        hasKey = ProviderCatalog.descriptor(for: providerSettings.provider).hasCredential(in: secrets)
        manualHeartRate = maxHeartRate > 0
        await healthAuthorization?.refresh()
        notification = .init(await scheduler?.authorization())
    }
}

#Preview {
    SettingsRootView(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: "preview.settings") ?? .standard)
}
