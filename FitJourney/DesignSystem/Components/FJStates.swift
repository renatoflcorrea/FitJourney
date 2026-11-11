import SwiftUI

/// Estado vazio / primeiro uso padrão: símbolo, título, explicação e uma ação.
struct FJEmptyState: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let message: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let area: FJArea
    private let action: (() -> Void)?

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        area: FJArea = .training,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.area = area
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.fjPrimary(area, fillsWidth: false))
            }
        }
    }
}

/// Carregando: indicador + frase curta dizendo o que está sendo carregado.
struct FJLoadingState: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey = "Carregando…") {
        self.title = title
    }

    var body: some View {
        VStack(spacing: FJSpacing.m) {
            ProgressView()
            Text(title)
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityElement(children: .combine)
    }
}

/// Aviso em linha dentro do conteúdo (sólido): permissão negada, erro recuperável, dado parcial.
/// Sempre diz o que aconteceu e oferece a saída.
struct FJBanner: View {
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let tone: FJTone
    private let systemImage: String?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    init(
        _ title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        tone: FJTone = .neutral,
        systemImage: String? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Image(systemName: systemImage ?? tone.systemImage)
                .font(.title3)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FJColor.textPrimary)
                    if let message {
                        Text(message)
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                // Só o texto é combinado; o botão continua um elemento próprio para o VoiceOver.
                .accessibilityElement(children: .combine)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: FJSize.minTap)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(FJSpacing.l)
        .background(tone.soft, in: FJRadius.shape(FJRadius.card))
        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Estados") {
    ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJEmptyState(
                "Nenhum programa ainda",
                systemImage: "dumbbell",
                message: "Crie seu primeiro programa com as fichas da semana.",
                actionTitle: "Criar programa"
            ) {}
            FJLoadingState("Lendo dados do Saúde…")
            FJBanner(
                "Saúde não conectado",
                message: "Sem acesso ao app Saúde, a frequência cardíaca fica indisponível. Seus treinos continuam sendo registrados.",
                tone: .attention,
                systemImage: "heart.slash.fill",
                actionTitle: "Abrir Ajustes"
            ) {}
            FJBanner("3 itens sem calorias", message: "O total do dia pode estar abaixo do real.", tone: .neutral)
            FJBanner("Não foi possível salvar", message: "Tente de novo. Nada foi perdido.", tone: .destructive, actionTitle: "Tentar de novo") {}
        }
        .padding(FJSpacing.screenMargin)
    }
    .tint(FJColor.training)
    .fjScreenBackground()
}
