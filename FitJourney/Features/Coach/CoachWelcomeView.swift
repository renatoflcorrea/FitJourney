import SwiftUI

/// Primeira abertura da aba Coach (DESIGN §4.16): sem provedor pronto, as boas-vindas com "Configurar provedor e
/// chave" (ainda não há a quem pedir); com o provedor pronto, o consentimento como tela da aba, nomeando quem recebe,
/// com os quatro toggles (pré-selecionados dos toggles antigos; nada vale até Permitir). Não permitir mostra
/// "O Coach está desligado" + Rever (a escolha negada não é gravada).
struct CoachWelcomeView: View {
    let gate: CoachGate
    let secrets: any SecretStore
    let defaults: UserDefaults
    let onChange: () -> Void

    @State private var recipient: AIRecipient?
    @State private var categories: Set<AIDataCategory> = []
    @State private var denied = false

    var body: some View {
        Group {
            if gate == .needsConsent, let recipient {
                if denied {
                    coachOff
                } else {
                    consent(recipient)
                }
            } else {
                setup
            }
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if gate == .needsConsent {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AISettingsView(secrets: secrets, defaults: defaults)
                    } label: {
                        Label("Ajustes de IA", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("coach.settings")
                }
            }
        }
        .fjScreenBackground()
        .onAppear {
            reload()
            onChange()
        }
        .onChange(of: gate) { reload() }
    }

    private func reload() {
        let next = AIRecipientResolver.resolve(settings: ProviderSettingsStore(defaults: defaults).load())
        if next != recipient || categories.isEmpty {
            categories = AIConsentPresentation.initialCoachCategories(
                stored: AIConsentStore(defaults: defaults).categories(for: next),
                legacy: CoachProfileStore(defaults: defaults).load().sharing)
        }
        if next.key != recipient?.key { denied = false }
        recipient = next
    }

    // MARK: Consentimento (provedor pronto)

    private func consent(_ recipient: AIRecipient) -> some View {
        AIConsentContentView(
            content: AIConsentPresentation.content(for: .coach(previous: nil), recipient: recipient),
            categories: $categories,
            onAllow: {
                let content = AIConsentPresentation.content(for: .coach(previous: nil), recipient: recipient)
                AIConsentPresentation.grant(.coach(previous: nil), for: recipient, categories: categories,
                                            store: AIConsentStore(defaults: defaults))
                AccessibilityNotification.Announcement(content.allowedAnnouncement).post()
                onChange()
            },
            onDeny: { denied = true })
    }

    private var coachOff: some View {
        ContentUnavailableView {
            Label("O Coach está desligado", systemImage: "sparkles")
        } description: {
            Text("Nada é enviado. Os outros recursos do app funcionam normalmente.")
        } actions: {
            Button("Rever") { denied = false }
                .buttonStyle(.fjPrimary(.coach, fillsWidth: false))
                .accessibilityIdentifier("coach.off.review")
        }
    }

    // MARK: Sem provedor

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.sectionGap) {
                header
                capabilities
                FJBanner("Falta configurar o provedor",
                         message: "Escolha o provedor de IA e informe sua chave de API. Antes de enviar qualquer coisa, o Coach mostra o que vai e para quem.",
                         tone: .attention, systemImage: "key.fill")
                NavigationLink {
                    AISettingsView(secrets: secrets, defaults: defaults)
                } label: {
                    Label("Configurar provedor e chave", systemImage: "key")
                }
                .buttonStyle(.fjPrimary(.coach))
                .accessibilityIdentifier("coach.setup")
            }
            .padding(FJSpacing.screenMargin)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            Image(systemName: FJArea.coach.systemImage)
                .font(.largeTitle)
                .foregroundStyle(FJArea.coach.color)
                .accessibilityHidden(true)
            Text("Seu Coach de treino e dieta")
                .font(FJFont.screenTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Converse para montar programas de treino e planos alimentares a partir do seu histórico. Nada é salvo sem você revisar.")
                .font(FJFont.body)
                .foregroundStyle(FJColor.textSecondary)
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            capability("dumbbell.fill", "Monta treinos", "Fichas com exercícios, séries e cargas.")
            capability("fork.knife", "Ajusta a dieta", "Metas, refeições e substituições.")
            capability("chart.line.uptrend.xyaxis", "Analisa a evolução", "Responde com base no seu histórico.")
        }
    }

    private func capability(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(FJArea.coach.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(title).font(FJFont.cardTitle)
                Text(detail).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Boas-vindas — consentimento") {
    NavigationStack {
        CoachWelcomeView(gate: .needsConsent, secrets: InMemorySecretStore(),
                         defaults: CoachPreviewData.defaults(consented: false), onChange: {})
    }
    .tint(FJColor.coach)
}

#Preview("Boas-vindas — sem provedor") {
    NavigationStack {
        CoachWelcomeView(gate: .needsProvider, secrets: InMemorySecretStore(),
                         defaults: CoachPreviewData.defaults(consented: false), onChange: {})
    }
    .tint(FJColor.coach)
}
#endif
