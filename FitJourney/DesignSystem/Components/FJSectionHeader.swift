import SwiftUI

/// Cabeçalho de seção com ação opcional à direita ("Ver tudo", "Editar").
struct FJSectionHeader: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(title)
                    .font(FJFont.sectionTitle)
                    .foregroundStyle(FJColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: FJSpacing.s)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(FJFont.label)
                    .frame(minHeight: FJSize.minTap)
            }
        }
        .padding(.horizontal, FJSpacing.xs)
    }
}

#Preview("Cabeçalho de seção") {
    VStack(spacing: FJSpacing.l) {
        FJSectionHeader("Fichas")
        FJSectionHeader("Histórico", subtitle: "Últimas 4 semanas", actionTitle: "Ver tudo") {}
    }
    .padding(FJSpacing.screenMargin)
    .tint(FJColor.training)
    .fjScreenBackground()
}
