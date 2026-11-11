import SwiftUI

/// Botão principal grande (Liquid Glass proeminente). Um por tela, na metade inferior.
/// Ex.: "Iniciar treino", "Finalizar treino", "Salvar".
struct FJPrimaryButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let area: FJArea
    private let isLoading: Bool
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        area: FJArea = .training,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.area = area
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: FJSpacing.s) {
                if isLoading {
                    ProgressView().tint(FJColor.onFill)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: FJSize.primaryButton - 30)
        }
        .fjPrimaryButtonStyle(area)
        .disabled(isLoading)
    }
}

/// Botão secundário (Liquid Glass). Alternativa ao principal: "Outra ficha", "Treino livre".
struct FJSecondaryButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let fillsWidth: Bool
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        fillsWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: FJSpacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(minHeight: FJSize.minTap - 16)
        }
        .fjSecondaryButtonStyle()
    }
}

/// Botão circular de ícone em vidro (toolbar própria, ação flutuante).
struct FJIconButton: View {
    private let systemImage: String
    private let label: LocalizedStringKey
    private let action: () -> Void

    init(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: FJSize.minTap - 14, height: FJSize.minTap - 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(label))
    }
}

extension View {
    /// Estilo do botão principal para um `Button` com rótulo próprio.
    func fjPrimaryButtonStyle(_ area: FJArea = .training) -> some View {
        self
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(area.fill)
    }

    /// Estilo do botão secundário para um `Button` com rótulo próprio.
    func fjSecondaryButtonStyle() -> some View {
        self
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }
}

#Preview("Botões") {
    ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(spacing: FJSpacing.m) {
            FJPrimaryButton("Iniciar treino", systemImage: "play.fill") {}
            FJPrimaryButton("Registrar refeição", systemImage: "checkmark", area: .nutrition) {}
            FJPrimaryButton("Salvando…", isLoading: true) {}
            GlassEffectContainer(spacing: FJSpacing.s) {
                HStack(spacing: FJSpacing.s) {
                    FJSecondaryButton("Outra ficha", systemImage: "list.bullet") {}
                    FJSecondaryButton("Treino livre", systemImage: "plus") {}
                }
            }
            FJIconButton(systemImage: "chevron.down", label: "Minimizar treino") {}
        }
        .padding(FJSpacing.screenMargin)
    }
}
