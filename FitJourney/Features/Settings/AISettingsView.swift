import SwiftUI

/// Texto do estado de prontidão e validação da URL (puro, testável).
enum AISettingsText {
    static func readiness(_ value: ProviderReadiness) -> (title: String, detail: String, tone: FJTone) {
        switch value {
        case .ready:
            (String(localized: "Pronto para conversar"), String(localized: "Provedor, modelo e chave configurados."), .success)
        case .missingModel:
            (String(localized: "Escolha um modelo"), String(localized: "Informe o nome do modelo a usar."), .attention)
        case .invalidEndpoint:
            (String(localized: "URL inválida"),
             String(localized: "Use HTTPS. HTTP só vale para rede local (localhost, .local ou IP privado)."), .attention)
        case let .missingAPIKey(provider):
            (String(localized: "Falta a chave de API"),
             String(localized: "Salve a chave do \(ProviderCatalog.descriptor(for: provider).name) para começar."), .attention)
        }
    }

    /// `nil` = campo vazio ou aceitável; texto = motivo de recusa.
    static func urlProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return String(localized: "Informe uma URL completa, como http://192.168.0.10:11434/v1.")
        }
        guard ProviderReadiness.isAcceptable(url) else {
            if url.scheme?.lowercased() == "http" {
                return String(localized: "HTTP só é aceito em rede local (localhost, .local ou IP privado). Use HTTPS.")
            }
            return String(localized: "Use uma URL HTTPS, sem usuário, senha ou fragmento.")
        }
        return nil
    }
}

/// Ajustes de IA (SPEC §7): provedor, modelo, URL própria, chave (Keychain), compartilhamento e consentimento.
struct AISettingsView: View {
    private let secrets: any SecretStore
    private let defaults: UserDefaults

    @State private var settings: ProviderSettings
    @State private var customURLText: String
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var sharing: CoachProfile.Sharing
    @State private var hasConsented: Bool
    @State private var errorMessage: String?
    @State private var showRevoke = false

    init() {
        self.init(secrets: KeychainSecretStore(), defaults: .standard)
    }

    /// Para previews e testes.
    init(secrets: any SecretStore, defaults: UserDefaults) {
        self.secrets = secrets
        self.defaults = defaults
        let loaded = ProviderSettingsStore(defaults: defaults).load()
        _settings = State(initialValue: loaded)
        _customURLText = State(initialValue: loaded.customBaseURL?.absoluteString ?? "")
        let store = CoachProfileStore(defaults: defaults)
        _sharing = State(initialValue: store.load().sharing)
        _hasConsented = State(initialValue: store.hasConsented)
    }

    private var descriptor: ProviderDescriptor { ProviderCatalog.descriptor(for: settings.provider) }
    private var readiness: ProviderReadiness { .evaluate(settings, hasAPIKey: hasKey) }

    var body: some View {
        Form {
            readinessSection
            providerSection
            modelSection
            if settings.provider == .custom { customSection }
            keySection
            sharingSection
            consentSection
        }
        .navigationTitle("Ajustes de IA")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadKeyState()
            let store = CoachProfileStore(defaults: defaults)
            hasConsented = store.hasConsented
            sharing = store.load().sharing
        }
        .onChange(of: settings) { ProviderSettingsStore(defaults: defaults).save(settings) }
        .onChange(of: sharing) {
            let store = CoachProfileStore(defaults: defaults)
            var profile = store.load()
            profile.sharing = sharing
            store.save(profile)
        }
        .confirmationDialog("Revogar consentimento?", isPresented: $showRevoke, titleVisibility: .visible) {
            Button("Revogar", role: .destructive) {
                CoachProfileStore(defaults: defaults).revokeConsent()
                sharing = .none
                hasConsented = false
                NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
            }
        } message: {
            Text("O Coach para de compartilhar seus dados e volta a pedir consentimento na próxima abertura. Conversas já enviadas ao provedor não podem ser recolhidas por aqui.")
        }
    }

    // MARK: Seções

    private var readinessSection: some View {
        let status = AISettingsText.readiness(readiness)
        return Section {
            FJBanner(LocalizedStringKey(status.title), message: LocalizedStringKey(status.detail), tone: status.tone)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if let errorMessage {
                FJBanner("Não foi possível concluir", message: CoachMarkdown.literal(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Provedor", selection: $settings.provider) {
                ForEach(ProviderCatalog.all) { Text($0.name).tag($0.id) }
            }
            .onChange(of: settings.provider) {
                keyInput = ""
                reloadKeyState()
            }
        } footer: {
            Text("A chave é sua (BYOK). As requisições vão direto do aparelho ao provedor escolhido.")
        }
    }

    private var modelSection: some View {
        Section("Modelo") {
            ForEach(descriptor.suggestedModels, id: \.self) { model in
                Button {
                    settings.model = model
                } label: {
                    HStack {
                        Text(model).foregroundStyle(FJColor.textPrimary)
                        Spacer()
                        if settings.model == model { Image(systemName: "checkmark").foregroundStyle(FJArea.coach.color) }
                    }
                    .frame(minHeight: FJSize.minTap)
                }
                .accessibilityAddTraits(settings.model == model ? .isSelected : [])
            }
            TextField("Outro modelo", text: Binding(
                get: { descriptor.suggestedModels.contains(settings.model) ? "" : settings.model },
                set: { settings.model = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }

    private var customSection: some View {
        Section {
            TextField("http://192.168.0.10:11434/v1", text: $customURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: customURLText) {
                    let trimmed = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if AISettingsText.urlProblem(trimmed) == nil, !trimmed.isEmpty {
                        settings.customBaseURL = URL(string: trimmed)
                    } else {
                        settings.customBaseURL = nil
                    }
                }
            if let problem = AISettingsText.urlProblem(customURLText) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(FJFont.caption)
                    .foregroundStyle(FJTone.attention.color)
            }
            Stepper(value: Binding(
                get: { settings.customContextTokens ?? ProviderSettings.customDefaultContextTokens },
                set: { settings.customContextTokens = $0 }
            ), in: 2_000 ... 200_000, step: 2_000) {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text("Orçamento de contexto")
                    Text("\(settings.contextBudgetTokens) tokens aproximados")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        } header: {
            Text("Servidor próprio")
        } footer: {
            Text("Ollama, LM Studio ou qualquer servidor compatível com a API da OpenAI. HTTP só em rede local. Modelos locais têm janela menor: ajuste o orçamento.")
        }
    }

    private var keySection: some View {
        Section {
            if hasKey {
                LabeledContent("Chave de API") {
                    Text("•••• configurada").foregroundStyle(FJColor.textSecondary)
                }
                Button("Remover chave", role: .destructive, action: removeKey)
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
            SecureField(hasKey ? "Substituir chave" : "Chave de API", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                            Button("Salvar chave", action: saveKey)
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(minHeight: FJSize.minTap, alignment: .leading)
            if let url = descriptor.keyHelpURL {
                Link(destination: url) { Label("Onde criar a chave", systemImage: "arrow.up.right.square") }
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
        } header: {
            Text(descriptor.requiresAPIKey ? "Chave de API" : "Chave de API (opcional)")
        } footer: {
            Text("Guardada no Keychain deste aparelho, fora de backups. O app nunca mostra a chave salva.")
        }
    }

    private var sharingSection: some View {
        Section {
            SharingToggles(sharing: $sharing)
                .disabled(!hasConsented)
        } header: {
            Text("O que o Coach pode ler")
        } footer: {
            Text(hasConsented
                 ? "O que você ligar pode ser enviado ao provedor quando o Coach consultar seu histórico. Desligado, o Coach nem enxerga."
                 : "Sem consentimento, nada é compartilhado. Aceite na aba Coach para escolher o que compartilhar.")
        }
    }

    private var consentSection: some View {
        Section {
            if hasConsented {
                Button("Revogar consentimento", role: .destructive) { showRevoke = true }
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            } else {
                Label("Consentimento pendente. O Coach pergunta na próxima abertura.", systemImage: "hand.raised")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    // MARK: Ações

    private func reloadKeyState() {
        hasKey = secrets.contains(descriptor.secretKey)
    }

    private func saveKey() {
        do {
            try secrets.set(keyInput, for: descriptor.secretKey)
            keyInput = ""
            reloadKeyState()
        } catch {
            errorMessage = String(localized: "Não foi possível gravar no Keychain.")
        }
    }

    private func removeKey() {
        do {
            try secrets.set(nil, for: descriptor.secretKey)
            reloadKeyState()
        } catch {
            errorMessage = String(localized: "Não foi possível remover do Keychain.")
        }
    }
}

#if DEBUG
#Preview("Ajustes de IA") {
    NavigationStack {
        AISettingsView(secrets: InMemorySecretStore([SecretKey.apiKey(.openAI): "sk-preview-0000000000"]),
                       defaults: CoachPreviewData.defaults(consented: true))
    }
    .tint(FJColor.coach)
}
#endif
