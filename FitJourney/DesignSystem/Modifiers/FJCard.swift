import SwiftUI

extension View {
    /// Cartão de conteúdo sólido (não vidro): fundo `surface`, raio contínuo de 20 pt.
    func fjCard(padding: CGFloat = FJSpacing.l, radius: CGFloat = FJRadius.card) -> some View {
        self
            .padding(padding)
            .background(FJColor.surface, in: FJRadius.shape(radius))
    }

    /// Fundo padrão de tela.
    func fjScreenBackground() -> some View {
        background(FJColor.background.ignoresSafeArea())
    }
}

/// Cartão de conteúdo. Números, listas e gráficos vivem aqui, nunca sobre vidro.
struct FJCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = FJSpacing.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .fjCard(padding: padding)
    }
}

/// `HStack` que vira `VStack` em tamanhos de acessibilidade do Dynamic Type.
struct FJAdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let spacing: CGFloat
    private let verticalAlignment: VerticalAlignment
    private let content: Content

    init(
        spacing: CGFloat = FJSpacing.m,
        verticalAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.verticalAlignment = verticalAlignment
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: verticalAlignment, spacing: spacing) { content }
        }
    }
}

#Preview("Cartão") {
    ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    Text("A — Peito e tríceps").font(FJFont.cardTitle)
                    Text("6 exercícios · 55 min").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
            }
            FJCard {
                FJAdaptiveStack {
                    Text("Lado a lado")
                    Spacer()
                    Text("Empilha em AX").foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
