import SwiftUI

/// Ajustes › Coach e IA › "O que é enviado e para quem" (proposta §3.7, DESIGN §4.16): o destino atual, os três usos e
/// as quatro categorias (ligar um toggle aqui conta como permissão — a tela nomeia o destino e o dado), "Revogar tudo"
/// com confirmação e os outros provedores já autorizados. Reflete exatamente `AIConsentStore`.
struct AIPrivacyView: View {
    private let secrets: any SecretStore
    private let defaults: UserDefaults

    @State private var recipient: AIRecipient
    @State private var isReady = false
    @State private var records: [String: AIConsentStore.Record] = [:]
    @State private var confirmRevoke = false

    init() {
        self.init(secrets: KeychainSecretStore(), defaults: .standard)
    }

    init(secrets: any SecretStore, defaults: UserDefaults) {
        self.secrets = secrets
        self.defaults = defaults
        _recipient = State(initialValue: AIRecipientResolver.resolve(settings: ProviderSettingsStore(defaults: defaults).load()))
    }

    private var store: AIConsentStore { AIConsentStore(defaults: defaults) }
    private var current: AIConsentStore.Record? { records[recipient.key] }
    private var destination: String { AIConsentPresentation.destination(recipient) }
    private var others: [(key: String, record: AIConsentStore.Record)] {
        records.filter { $0.key != recipient.key }
            .sorted { $0.value.displayName.localizedStandardCompare($1.value.displayName) == .orderedAscending }
            .map { (key: $0.key, record: $0.value) }
    }

    var body: some View {
        Form {
            if isReady {
                recipientSection
                permissionsSection
                categoriesSection
                revokeSection
            } else {
                Section {
                    Label("Configure um provedor para ver para quem os dados iriam.", systemImage: "key")
                        .foregroundStyle(FJColor.textSecondary)
                        .accessibilityIdentifier("privacy.setup")
                }
            }
            if !others.isEmpty { othersSection }
            policySection
        }
        .navigationTitle("O que é enviado")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .aiConsentChanged)) { _ in reload() }
        .confirmationDialog(Text(verbatim: String(localized: "Revogar tudo para \(destination)?")),
                            isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revogar", role: .destructive) { store.revokeAll(for: recipient) }
                .accessibilityIdentifier("privacy.revokeAll.confirm")
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(verbatim: String(localized: "O FitJourney para de enviar dados para \(destination) e volta a perguntar antes do próximo envio. O que já foi enviado fica com quem recebeu."))
        }
    }

    // MARK: Seções

    private var recipientSection: some View {
        Section {
            AIRecipientCardView(hops: AIConsentPresentation.hops(recipient), note: AIConsentPresentation.note(recipient),
                                identifier: "privacy.recipient")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } header: {
            Text("Para quem")
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(AIFeature.allCases, id: \.self) { feature in
                Toggle(isOn: featureBinding(feature)) {
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text(verbatim: AIConsentPresentation.featureTitle(feature))
                        Text(verbatim: AIConsentPresentation.featureDetail(feature))
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                    .padding(.vertical, FJSpacing.xxs)
                }
                .tint(FJColor.coachFill)
                .accessibilityIdentifier(AIConsentPresentation.featureIdentifier(feature))
            }
        } header: {
            Text("Permissões")
        } footer: {
            Text("Desligar vale para os próximos envios. O que já foi enviado fica com quem recebeu, conforme a política de privacidade dele.")
        }
    }

    private var categoriesSection: some View {
        let coachOn = current?.features[AIFeature.coach.rawValue] != nil
        let mealOn = current?.features[AIFeature.mealLog.rawValue] != nil
        return Section {
            ForEach(AIDataCategory.allCases, id: \.self) { category in
                let info = AIConsentPresentation.category(category)
                Toggle(isOn: categoryBinding(category)) {
                    Label {
                        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                            Text(verbatim: info.title)
                            Text(verbatim: info.detail)
                                .font(FJFont.caption)
                                .foregroundStyle(FJColor.textSecondary)
                        }
                        .padding(.vertical, FJSpacing.xxs)
                    } icon: {
                        Image(systemName: info.systemImage).foregroundStyle(FJColor.coach)
                    }
                }
                .tint(FJColor.coachFill)
                // Dieta também serve ao registro de refeições; as outras só valem com o Coach ligado.
                .disabled(category == .nutrition ? !(coachOn || mealOn) : !coachOn)
                .accessibilityIdentifier("privacy.toggle.\(category.rawValue)")
            }
        } header: {
            Text("O Coach também pode ler")
        } footer: {
            Text(coachOn ? "Só vai o que estiver ligado, e só quando o Coach consultar o seu histórico. Dieta também vale para o registro de refeições."
                         : "Ligue o Coach acima para escolher o que ele pode ler. Dieta também vale para o registro de refeições.")
        }
    }

    private var revokeSection: some View {
        Section {
            Button(role: .destructive) {
                confirmRevoke = true
            } label: {
                Text(verbatim: String(localized: "Revogar tudo para \(destination)"))
            }
            .frame(minHeight: FJSize.minTap, alignment: .leading)
            .disabled(current == nil)
            .accessibilityIdentifier("privacy.revokeAll")
        }
    }

    private var othersSection: some View {
        Section {
            ForEach(others, id: \.key) { item in
                LabeledContent {
                    let features = Set(item.record.features.keys.compactMap(AIFeature.init(rawValue:)))
                    Text(verbatim: AIConsentPresentation.permissionSummary(features: features, categories: item.record.categories)
                         ?? String(localized: "Nada permitido"))
                        .foregroundStyle(FJColor.textSecondary)
                } label: {
                    Text(verbatim: item.record.displayName)
                }
                .accessibilityIdentifier("privacy.other.\(item.key)")
                .swipeActions(allowsFullSwipe: false) {
                    Button("Remover", systemImage: "trash", role: .destructive) { remove(key: item.key) }
                }
                .accessibilityAction(named: Text("Remover")) { remove(key: item.key) }
            }
            Button("Esquecer os outros provedores", role: .destructive) { store.forgetOthers(except: recipient) }
                .frame(minHeight: FJSize.minTap, alignment: .leading)
                .accessibilityIdentifier("privacy.forgetOthers")
        } header: {
            Text("Outros provedores já autorizados")
        } footer: {
            Text("Voltar a um destes provedores restaura o que você permitiu.")
        }
    }

    private var policySection: some View {
        Section {
            Link(destination: AIConsentPresentation.appPolicyURL()) {
                Label("Política de Privacidade do FitJourney", systemImage: "arrow.up.right.square")
            }
            .frame(minHeight: FJSize.minTap, alignment: .leading)
            .accessibilityIdentifier("aiConsent.appPolicyLink")
        } footer: {
            Text("O FitJourney não tem servidor. O que você permitir vai direto deste iPhone para quem recebe.")
        }
    }

    // MARK: Estado

    private func reload() {
        let settings = ProviderSettingsStore(defaults: defaults).load()
        recipient = AIRecipientResolver.resolve(settings: settings)
        let hasKey = ProviderCatalog.descriptor(for: settings.provider).hasCredential(in: secrets)
        isReady = ProviderReadiness.evaluate(settings, hasAPIKey: hasKey).isReady
        records = store.records
    }

    private func featureBinding(_ feature: AIFeature) -> Binding<Bool> {
        Binding(get: { current?.features[feature.rawValue] != nil }, set: { isOn in
            if isOn { store.grant(feature, for: recipient) } else { store.revoke(feature, for: recipient) }
        })
    }

    private func categoryBinding(_ category: AIDataCategory) -> Binding<Bool> {
        Binding(get: { current?.categories.contains(category) == true }, set: { isOn in
            var categories = store.categories(for: recipient)
            if isOn { categories.insert(category) } else { categories.remove(category) }
            store.setCategories(categories, for: recipient)
        })
    }

    private func remove(key: String) {
        guard let other = AIConsentPresentation.recipient(forKey: key) else { return }
        store.revokeAll(for: other)
    }
}

#if DEBUG
#Preview("O que é enviado") {
    NavigationStack {
        AIPrivacyView(secrets: InMemorySecretStore([SecretKey.apiKey(.openAI): "sk-preview-0000000000"]),
                      defaults: CoachPreviewData.defaults(consented: true))
    }
    .tint(FJColor.coach)
}
#endif
