import SwiftUI

/// Marca de IA (DESIGN_DIRECTION §4.15.1): `sparkles` em gradiente, sozinho, em etiqueta ou em orbe.
///
/// - `.symbol`: só o símbolo, para ficar ao lado de um título ("✦ Importar com IA"). Decorativo.
/// - `.tag`: etiqueta sólida com rótulo ("IA", "Importado com IA", "Sugestão da IA").
/// - `.hero`: orbe de 72 pt para o topo de folhas e estados vazios do copiloto.
struct FJAIBadge: View {
    enum Style: Sendable {
        case symbol, tag, hero
    }

    private let title: LocalizedStringKey
    private let style: Style

    init(_ title: LocalizedStringKey = "IA", style: Style = .tag) {
        self.title = title
        self.style = style
    }

    var body: some View {
        switch style {
        case .symbol:
            Image(systemName: "sparkles")
                .foregroundStyle(FJAI.gradient)
                .accessibilityHidden(true)
        case .tag:
            HStack(spacing: FJSpacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(FJAI.gradient)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(FJColor.textPrimary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, FJSpacing.s)
            .padding(.vertical, FJSpacing.xs)
            .background(FJAI.softGradient, in: FJRadius.shape(FJRadius.chip))
            .accessibilityElement(children: .combine)
        case .hero:
            FJAIOrb()
        }
    }
}

/// Estilo de botão de IA (`.buttonStyle(.fjAI())`).
///
/// - `.prominent`: cápsula no gradiente de IA, texto branco, brilho único ao aparecer. Um por tela,
///   só onde a IA é o caminho principal (primeiro uso, estado vazio, folha do copiloto).
/// - `.subtle`: vidro neutro com contorno e símbolo em gradiente. Para conviver com o botão principal
///   da área ("Criar programa" laranja + "Importar com IA" ao lado) e para "Editar com IA".
struct FJAIButtonStyle: ButtonStyle {
    enum Prominence: Sendable {
        case prominent, subtle
    }

    let prominence: Prominence
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        switch prominence {
        case .prominent:
            configuration.label
                .labelStyle(FJAILabelStyle(gradientIcon: false))
                .font(.headline)
                .foregroundStyle(FJColor.onFill)
                .padding(.horizontal, FJSpacing.xl)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: FJSize.primaryButton)
                .background(FJAI.fillGradient, in: Capsule())
                .fjAISheen()
                .contentShape(Capsule())
                .fjGlass(interactive: true)
                .opacity(isEnabled ? 1 : 0.5)
        case .subtle:
            configuration.label
                .labelStyle(FJAILabelStyle(gradientIcon: isEnabled))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FJColor.textPrimary)
                .padding(.horizontal, FJSpacing.l)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: FJSize.secondaryButton)
                .contentShape(Capsule())
                // O contorno faz parte do conteúdo: desenhado depois do vidro, some dentro de um GlassEffectContainer.
                .fjAIBorder(in: Capsule())
                .fjGlass(interactive: true)
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// Rótulo com o ícone em gradiente de IA (ou na cor do texto, sobre preenchimento).
private struct FJAILabelStyle: LabelStyle {
    let gradientIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FJSpacing.s) {
            if gradientIcon {
                configuration.icon.foregroundStyle(FJAI.gradient)
            } else {
                configuration.icon
            }
            configuration.title
        }
    }
}

extension ButtonStyle where Self == FJAIButtonStyle {
    static func fjAI(
        _ prominence: FJAIButtonStyle.Prominence = .prominent,
        fillsWidth: Bool = true
    ) -> FJAIButtonStyle {
        FJAIButtonStyle(prominence: prominence, fillsWidth: fillsWidth)
    }
}

/// Botão de IA pronto: "Importar com IA", "Editar com IA". O símbolo padrão é `sparkles`.
struct FJAIButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let prominence: FJAIButtonStyle.Prominence
    private let fillsWidth: Bool
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String = "sparkles",
        prominence: FJAIButtonStyle.Prominence = .prominent,
        fillsWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.prominence = prominence
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.fjAI(prominence, fillsWidth: fillsWidth))
    }
}

#Preview("IA — marca e botões") {
    ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(spacing: FJSpacing.l) {
            FJAIBadge(style: .hero)
            HStack(spacing: FJSpacing.s) {
                FJAIBadge(style: .symbol)
                FJAIBadge()
                FJAIBadge("Importado com IA")
            }
            FJAIButton("Importar com IA") {}
            GlassEffectContainer(spacing: FJSpacing.s) {
                VStack(spacing: FJSpacing.s) {
                    FJPrimaryButton("Criar programa", systemImage: "plus") {}
                    FJAIButton("Importar com IA", prominence: .subtle) {}
                }
            }
            FJAIButton("Editar com IA", prominence: .subtle, fillsWidth: false) {}
            FJAIButton("Importar com IA", prominence: .subtle) {}
                .disabled(true)
        }
        .padding(FJSpacing.screenMargin)
    }
}
