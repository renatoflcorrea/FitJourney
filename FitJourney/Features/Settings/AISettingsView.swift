import SwiftUI

private struct SettingsDefaultsTransfer: @unchecked Sendable { let value: UserDefaults }

/// Texto do estado de prontidão e validação da URL (puro, testável).
enum AISettingsText {
    struct Warning: Equatable { let text: String; let symbol: String; let identifier: String }
    static func openCodeModelWarning(model: String, cache: OpenCodeModelCache.Snapshot?) -> Warning? {
        if OpenCodeGo.isFreeModel(model) { return Warning(text: String(localized: "Modelos “-free” só funcionam dentro do OpenCode. Escolha outro."), symbol: "exclamationmark.triangle.fill", identifier: "settings.opencode.free") }
        if OpenCodeModelCatalog.trainsOnData(model: model, cache: cache) { return Warning(text: String(localized: "Este modelo pode usar o que você envia para treinar a IA. O FitJourney não o usa com seus dados de saúde: escolha outro."), symbol: "hand.raised.fill", identifier: "settings.opencode.training") }
        if !OpenCodeModelCatalog.capabilities(model: model, cache: cache).supportsImages { return Warning(text: String(localized: "Este modelo não lê imagens: importar PDF ou foto e a foto da refeição ficam indisponíveis."), symbol: "eye.slash", identifier: "settings.opencode.textOnly") }
        return nil
    }
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
        case .signedOut:
            (String(localized: "Entre com o ChatGPT"),
             String(localized: "Este provedor usa o login da sua assinatura ChatGPT, sem chave de API."), .attention)
        }
    }

    /// Aviso de risco do provedor ChatGPT (login) — experimental e não oficial.
    static let chatGPTRisk = String(localized: """
    Experimental e não oficial. Usa o login da sua assinatura ChatGPT por um endpoint não documentado (o mesmo \
    do Codex CLI), que pode mudar ou parar de funcionar sem aviso. Usar esse acesso em outro app é uma zona \
    cinzenta dos termos da OpenAI: só para uso pessoal, por sua conta e risco. As conversas contam no limite \
    de uso da sua assinatura.
    """)

    /// "Conectado · Plus" ou "Conectado".
    static func chatGPTStatus(plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return String(localized: "Conectado") }
        return String(localized: "Conectado · \(plan)")
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
    @State private var chatGPTLogin = ChatGPTLoginModel()
    @State private var chatGPTPlan: String?
    @State private var chatGPTModels: [String]?
    @State private var openCodeModels: [OpenCodeModel]?
    @State private var openCodeKeyRejected = false
    @State private var keyRevision = 0
    @State private var pastedCallback = ""
    @Environment(\.openURL) private var openURL

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
            if descriptor.usesChatGPTLogin { chatGPTSection } else { keySection }
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
        .task(id: descriptor.usesChatGPTLogin && hasKey) { await discoverChatGPTModels() }
        .task(id: "\(settings.provider)-\(hasKey)-\(keyRevision)") { await discoverOpenCodeModels() }
        .onDisappear { chatGPTLogin.cancel() }
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
            if descriptor.usesChatGPTLogin {
                Text("Sem chave de API: entra com a sua conta ChatGPT. As requisições vão direto do aparelho ao ChatGPT.")
        } else if settings.provider == .openCode {
            Text("Use a chave da sua assinatura OpenCode Go. As requisições vão direto do aparelho ao OpenCode, que as repassa a quem hospeda o modelo escolhido. Conta no limite de uso do seu plano.")
        } else {
                Text("A chave é sua (BYOK). As requisições vão direto do aparelho ao provedor escolhido.")
            }
        }
    }

    private var modelSection: some View {
        Section {
            ForEach(modelSuggestions, id: \.self) { model in
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
                get: { modelSuggestions.contains(settings.model) ? "" : settings.model },
                set: { settings.model = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if settings.provider == .openCode, let warning = AISettingsText.openCodeModelWarning(model: settings.model, cache: OpenCodeModelCache(defaults: defaults).load()) {
                Label(warning.text, systemImage: warning.symbol).font(FJFont.caption).foregroundStyle(FJTone.attention.color).accessibilityIdentifier(warning.identifier)
            }
        } header: { Text("Modelo") } footer: {
            if settings.provider == .openCode { Text("Só modelos que leem imagens e não usam seus dados para treinar, do que menos gasta o limite do Go ao que mais gasta.") }
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
            if settings.provider == .openCode, openCodeKeyRejected {
                Label("O OpenCode recusou esta chave. Confira se é a chave do Go em opencode.ai/auth.", systemImage: "exclamationmark.triangle.fill").font(FJFont.caption).foregroundStyle(FJTone.attention.color).accessibilityIdentifier("settings.opencode.keyRejected")
            }
        } header: {
            Text(descriptor.requiresAPIKey ? "Chave de API" : "Chave de API (opcional)")
        } footer: {
            Text("Guardada no Keychain deste aparelho, fora de backups. O app nunca mostra a chave salva.")
        }
    }

    /// Lista descoberta da conta ChatGPT (quando logado) ou as sugestões do catálogo.
    private var modelSuggestions: [String] {
        if settings.provider == .openCode { return OpenCodeModelCatalog.pickerModels(discovered: openCodeModels, suggested: descriptor.suggestedModels) }
        return descriptor.usesChatGPTLogin ? (chatGPTModels ?? descriptor.suggestedModels) : descriptor.suggestedModels
    }

    private var chatGPTSection: some View {
        Section {
            FJBanner("Experimental / não oficial", message: LocalizedStringKey(AISettingsText.chatGPTRisk), tone: .attention)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("settings.chatgpt.warning")
            if hasKey {
                LabeledContent("Conta ChatGPT") {
                    Text(AISettingsText.chatGPTStatus(plan: chatGPTPlan)).foregroundStyle(FJTone.success.color)
                }
                .accessibilityIdentifier("settings.chatgpt.status")
                Button("Sair", role: .destructive, action: signOutChatGPT)
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
                    .accessibilityIdentifier("settings.chatgpt.signOut")
            } else {
                chatGPTSignInRows
            }
            if case let .failed(message) = chatGPTLogin.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(FJFont.caption)
                    .foregroundStyle(FJTone.attention.color)
            }
        } header: {
            Text("Conta ChatGPT")
        } footer: {
            Text("Os tokens do login ficam só no Keychain deste aparelho, fora de backups. Sair apaga o login daqui.")
        }
    }

    @ViewBuilder
    private var chatGPTSignInRows: some View {
        switch chatGPTLogin.phase {
        case .waiting:
            HStack(spacing: FJSpacing.s) {
                ProgressView()
                Text("Aguardando o ChatGPT…").foregroundStyle(FJColor.textSecondary)
            }
            .frame(minHeight: FJSize.minTap)
            Button("Cancelar") { chatGPTLogin.cancel() }
                .frame(minHeight: FJSize.minTap, alignment: .leading)
        case let .manual(url, problem):
            Text("Não deu para receber o login aqui (porta 1455 ocupada). Entre na página pelo navegador e cole aqui o endereço inteiro em que ele parar.")
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(FJFont.caption)
                    .foregroundStyle(FJTone.attention.color)
            }
            Button("Abrir a página de login") { openURL(url) }
                .frame(minHeight: FJSize.minTap, alignment: .leading)
            TextField("Cole o endereço (http://localhost:1455/auth/callback?…)", text: $pastedCallback)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Concluir") {
                let text = pastedCallback
                pastedCallback = ""
                Task {
                    if await chatGPTLogin.finishManually(text, store: SecretChatGPTStore(secrets: secrets)) {
                        reloadKeyState()
                    }
                }
            }
            .disabled(pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(minHeight: FJSize.minTap, alignment: .leading)
            Button("Cancelar") { chatGPTLogin.cancel() }
                .frame(minHeight: FJSize.minTap, alignment: .leading)
        case .idle, .failed:
            Button {
                Task {
                    if await chatGPTLogin.signIn(store: SecretChatGPTStore(secrets: secrets)) { reloadKeyState() }
                }
            } label: {
                Label("Entrar com ChatGPT", systemImage: "person.badge.key")
            }
            .frame(minHeight: FJSize.minTap, alignment: .leading)
            .accessibilityIdentifier("settings.chatgpt.signIn")
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
        hasKey = descriptor.hasCredential(in: secrets)
        chatGPTPlan = descriptor.usesChatGPTLogin
            ? SecretChatGPTStore(secrets: secrets).loadIgnoringErrors()?.planLabel : nil
    }

    private func signOutChatGPT() {
        chatGPTLogin.cancel()
        do {
            try SecretChatGPTStore(secrets: secrets).clear()
            chatGPTModels = nil
            reloadKeyState()
        } catch {
            errorMessage = String(localized: "Não foi possível remover do Keychain.")
        }
    }

    /// Lista de modelos da conta (backend não oficial); sem login ou com falha, fica a lista do catálogo.
    private func discoverChatGPTModels() async {
        guard descriptor.usesChatGPTLogin, hasKey else { return }
        let lister = ChatGPTModelLister(session: ChatGPTAuthSession(store: SecretChatGPTStore(secrets: secrets)))
        let models = await lister.models()
        guard !Task.isCancelled else { return }
        chatGPTModels = models
        // Modelo salvo que a conta não oferece: vira o primeiro da lista (como no fireplaice).
        if let first = models.first, !models.contains(settings.model), settings.models[.chatGPT] == nil {
            settings.model = first
        }
        reloadKeyState() // um refresh permanente recusado apaga o login
    }

    private func saveKey() {
        do {
            try secrets.set(keyInput, for: descriptor.secretKey)
            keyInput = ""
            reloadKeyState()
            keyRevision += 1
        } catch {
            errorMessage = String(localized: "Não foi possível gravar no Keychain.")
        }
    }

    private func discoverOpenCodeModels() async {
        guard settings.provider == .openCode, hasKey else { openCodeModels = nil; openCodeKeyRejected = false; return }
        let key: String
        do { key = try secrets.string(for: .apiKey(.openCode)) ?? "" } catch { return }
        guard !key.isEmpty else { return }
        let transferredDefaults = SettingsDefaultsTransfer(value: defaults)
        let result = await OpenCodeModelLister(apiKey: key, defaults: transferredDefaults.value).discover()
        guard !Task.isCancelled else { return }
        openCodeModels = result.models
        openCodeKeyRejected = result.keyRejected
        let choices = OpenCodeModelCatalog.pickerModels(discovered: result.models, suggested: descriptor.suggestedModels)
        if settings.models[.openCode] == nil, let first = choices.first, !choices.contains(settings.model) { settings.model = first }
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
