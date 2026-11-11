import SwiftUI

/// Estilo do botão principal: Liquid Glass tingido na cor da área, texto branco, altura mínima
/// `FJSize.primaryButton`. Com Reduzir Transparência o vidro vira preenchimento sólido (`fjGlass`).
struct FJPrimaryButtonStyle: ButtonStyle {
    let area: FJArea
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(FJColor.onFill)
            .padding(.horizontal, FJSpacing.xl)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: FJSize.primaryButton)
            .contentShape(Capsule())
            .fjGlass(tint: area.fill, interactive: true)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Estilo do botão secundário: Liquid Glass neutro, texto primário, altura mínima `FJSize.secondaryButton`.
struct FJSecondaryButtonStyle: ButtonStyle {
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(FJColor.textPrimary)
            .padding(.horizontal, FJSpacing.l)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: FJSize.secondaryButton)
            .contentShape(Capsule())
            .fjGlass(interactive: true)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == FJPrimaryButtonStyle {
    static func fjPrimary(_ area: FJArea = .training, fillsWidth: Bool = true) -> FJPrimaryButtonStyle {
        FJPrimaryButtonStyle(area: area, fillsWidth: fillsWidth)
    }
}

extension ButtonStyle where Self == FJSecondaryButtonStyle {
    static func fjSecondary(fillsWidth: Bool = true) -> FJSecondaryButtonStyle {
        FJSecondaryButtonStyle(fillsWidth: fillsWidth)
    }
}

/// Botão principal grande. Um por tela, na metade inferior.
/// Ex.: "Iniciar treino", "Concluir série", "Salvar treino".
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
                    ProgressView()
                        .tint(FJColor.onFill)
                        .accessibilityLabel(Text("Carregando"))
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .buttonStyle(.fjPrimary(area))
        .disabled(isLoading)
    }
}

/// Botão secundário. Alternativa ao principal: "Outra ficha", "Treino livre".
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
        }
        .buttonStyle(.fjSecondary(fillsWidth: fillsWidth))
    }
}

/// Botão circular de ícone em vidro, 44 pt (ação flutuante fora de uma toolbar do sistema).
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
                .foregroundStyle(FJColor.textPrimary)
                .frame(width: FJSize.minTap, height: FJSize.minTap)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fjGlass(in: Circle(), interactive: true)
        .accessibilityLabel(Text(label))
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
