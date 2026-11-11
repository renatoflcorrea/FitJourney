import SwiftUI

/// Etiqueta estática dentro de conteúdo (não vidro): tipo de série, grupo muscular, "Fora da dieta".
struct FJTag: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let foreground: Color
    private let background: Color

    /// Etiqueta na cor de uma área.
    init(_ title: LocalizedStringKey, systemImage: String? = nil, area: FJArea) {
        self.title = title
        self.systemImage = systemImage
        self.foreground = area.color
        self.background = area.soft
    }

    /// Etiqueta de tipo de treino (Força / Aeróbico) com símbolo.
    init(_ kind: FJWorkoutKind) {
        self.title = kind.title
        self.systemImage = kind.systemImage
        self.foreground = kind.color
        self.background = kind.soft
    }

    /// Etiqueta de estado. O texto fica primário; a cor vai no símbolo e no fundo.
    init(_ title: LocalizedStringKey, systemImage: String? = nil, tone: FJTone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.foreground = tone.color
        self.background = tone.soft
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(foreground)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(FJColor.textPrimary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, FJSpacing.s)
        .padding(.vertical, FJSpacing.xs)
        .background(background, in: FJRadius.shape(FJRadius.chip))
        .accessibilityElement(children: .combine)
    }
}

/// Chip de filtro/seleção em vidro (flutua sobre a lista: filtros da biblioteca, período do gráfico).
/// Selecionado = check + contorno na cor da área; o texto continua primário sobre vidro neutro,
/// então o contraste não depende do que está atrás.
struct FJFilterChip: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let isSelected: Bool
    private let area: FJArea
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isSelected: Bool,
        area: FJArea = .training,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.area = area
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: FJSpacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(area.color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(FJColor.textPrimary)
            .padding(.horizontal, FJSpacing.m)
            .frame(minHeight: FJSize.minTap)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fjGlass(interactive: true)
        .overlay {
            if isSelected {
                Capsule().strokeBorder(area.color, lineWidth: 1.5)
            }
        }
        .fjHaptic(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Chips e etiquetas") {
    @Previewable @State var selected: Set<String> = ["Peito"]
    let groups = ["Peito", "Costas", "Pernas", "Ombros"]

    return ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(alignment: .leading, spacing: FJSpacing.l) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: FJSpacing.s) {
                    HStack(spacing: FJSpacing.s) {
                        ForEach(groups, id: \.self) { group in
                            FJFilterChip(LocalizedStringKey(group), isSelected: selected.contains(group)) {
                                if selected.contains(group) { selected.remove(group) } else { selected.insert(group) }
                            }
                        }
                    }
                }
            }
            HStack {
                FJTag("Aquecimento", tone: .neutral)
                FJTag("Drop-set", area: .training)
                FJTag("Recorde", systemImage: "trophy.fill", tone: .record)
            }
            HStack {
                FJTag("Feita", systemImage: "checkmark.circle.fill", tone: .success)
                FJTag("Ajustada", systemImage: "pencil.circle.fill", tone: .attention)
                FJTag("Fora da dieta", systemImage: "plus.circle.fill", tone: .neutral)
            }
        }
        .padding(FJSpacing.screenMargin)
    }
}
