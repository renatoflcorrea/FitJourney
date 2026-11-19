import SwiftUI

/// Primeira abertura: o que o Coach faz, aviso de privacidade, o que compartilhar e configuração do provedor.
struct CoachWelcomeView: View {
    let gate: CoachGate
    let secrets: any SecretStore
    let defaults: UserDefaults
    let onChange: () -> Void

    @State private var sharing = CoachProfile.Sharing()

    private var store: CoachProfileStore { CoachProfileStore(defaults: defaults) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.sectionGap) {
                header
                capabilities
                if gate == .needsConsent {
                    privacyCard
                    sharingCard
                } else {
                    FJBanner("Falta configurar o provedor",
                             message: "Escolha o provedor de IA e informe sua chave de API para começar a conversar.",
                             tone: .attention, systemImage: "key.fill")
                }
                actions
            }
            .padding(FJSpacing.screenMargin)
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .fjScreenBackground()
        .onAppear {
            sharing = store.load().sharing
            onChange()
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

    private var privacyCard: some View {
        let recipient = AIRecipientResolver.resolve(settings: ProviderSettingsStore(defaults: defaults).load())
        return FJBanner("Privacidade",
                 message: "Suas mensagens, o histórico da conversa e os dados que você escolher são enviados para \(recipient.displayName). Nada vai a servidor do FitJourney. A chave fica só no Keychain deste aparelho.",
                 tone: .neutral, systemImage: "lock.shield.fill")
    }

    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            FJSectionHeader("O que compartilhar", subtitle: "Tudo começa desligado. Você pode mudar depois em Ajustes de IA.")
            VStack(spacing: 0) {
                SharingToggles(sharing: $sharing)
            }
            .padding(.horizontal, FJSpacing.l)
            .padding(.vertical, FJSpacing.xs)
            .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        }
    }

    private var actions: some View {
        VStack(spacing: FJSpacing.m) {
            if gate == .needsConsent {
                FJPrimaryButton("Aceitar e continuar", systemImage: "checkmark", area: .coach) {
                    store.grantConsent(sharing: sharing)
                    onChange()
                }
            }
            let link = NavigationLink {
                AISettingsView(secrets: secrets, defaults: defaults)
            } label: {
                Label("Configurar provedor e chave", systemImage: "key")
            }
            if gate == .needsProvider {
                link.buttonStyle(.fjPrimary(.coach))
            } else {
                link.buttonStyle(.fjSecondary())
            }
        }
    }
}

/// Os quatro toggles de compartilhamento (boas-vindas e Ajustes de IA).
struct SharingToggles: View {
    @Binding var sharing: CoachProfile.Sharing

    var body: some View {
        Toggle(isOn: $sharing.profile) { label("Perfil", "Idade, objetivo, restrições…", "person.crop.circle") }
        Divider()
        Toggle(isOn: $sharing.workouts) { label("Treinos", "Programas e histórico de séries", "dumbbell") }
        Divider()
        Toggle(isOn: $sharing.nutrition) { label("Dieta", "Planos e registro alimentar", "fork.knife") }
        Divider()
        Toggle(isOn: $sharing.health) { label("Saúde", "Resumo do app Saúde (passos, FC, sono)", "heart") }
    }

    private func label(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(title)
                Text(detail).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(FJArea.coach.color)
        }
        .padding(.vertical, FJSpacing.xs)
    }
}

#if DEBUG
#Preview("Boas-vindas") {
    NavigationStack {
        CoachWelcomeView(gate: .needsConsent, secrets: InMemorySecretStore(),
                         defaults: CoachPreviewData.defaults(consented: false), onChange: {})
    }
    .tint(FJColor.coach)
}
#endif
