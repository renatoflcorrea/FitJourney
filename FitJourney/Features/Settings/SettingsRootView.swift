import SwiftData
import SwiftUI

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
    @AppStorage(AppPreferenceKeys.defaultRestSeconds) private var defaultRest = 90
    @AppStorage(AppPreferenceKeys.restSound) private var restSound = true
    @AppStorage(AppPreferenceKeys.maxHeartRate) private var maxHeartRate = 0.0
    @AppStorage(AppPreferenceKeys.liveActivity) private var liveActivity = true

    @State private var profile = CoachProfile()
    @State private var providerSettings = ProviderSettings.default
    @State private var hasKey = false
    @State private var notification: SettingsPresentation.NotificationState = .notRequested
    @State private var manualHeartRate = false
    @State private var path: [Route] = Self.initialPath

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
    }

    private var unit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .kg }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                profileSection
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

    // MARK: Unidades

    private var unitsSection: some View {
        Section {
            Picker("Carga", selection: $weightUnitRaw) {
                Text("kg").tag(WeightUnit.kg.rawValue)
                Text("lb").tag(WeightUnit.lb.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("Unidade de carga"))

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

            Picker("Semana começa em", selection: $weekStartRaw) {
                Text("Segunda").tag(WeekStart.monday.rawValue)
                Text("Domingo").tag(WeekStart.sunday.rawValue)
            }
        } header: {
            Text("Unidades")
        } footer: {
            Text("Mudar a unidade muda só a exibição. O histórico não é alterado.")
        }
    }

    // MARK: Treino

    private var trainingSection: some View {
        Section {
            Picker("Descanso padrão", selection: $defaultRest) {
                ForEach(AppPreferenceKeys.defaultRestOptions, id: \.self) { seconds in
                    Text(verbatim: SettingsPresentation.restText(seconds)).tag(seconds)
                }
            }
            Toggle("Som ao fim do descanso", isOn: $restSound)
            heartRateRows
            Toggle("Atividade ao Vivo", isOn: $liveActivity)
        } header: {
            Text("Treino")
        } footer: {
            Text("A FC máxima define as zonas de frequência cardíaca. Sem valor manual, usamos 220 menos a idade do seu perfil. A Atividade ao Vivo mostra o treino e o descanso na Tela Bloqueada (em breve).")
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
        hasKey = secrets.contains(.apiKey(providerSettings.provider))
        manualHeartRate = maxHeartRate > 0
        await healthAuthorization?.refresh()
        notification = .init(await scheduler?.authorization())
    }
}

#Preview {
    SettingsRootView(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: "preview.settings") ?? .standard)
}
