import SwiftUI
import UIKit

/// Selo da ficha: letra (ou SF Symbol) sobre a cor da ficha, em quadrado de cantos contínuos.
/// Usado em Hoje, Treinos, editor, histórico, Saúde e Coach (DESIGN_DIRECTION §2.1.1).
///
/// Acessibilidade: por padrão é decorativo (fica ao lado do nome da ficha, que já diz tudo).
/// Quando aparece sozinho (célula de calendário, legenda), passe `accessibilityLabel`.
struct FJRoutineBadge: View {
    enum Size: Sendable {
        /// 32 pt — linhas compactas (histórico, Saúde, cartão de proposta).
        case sm
        /// 44 pt — cartões de ficha, Hoje, editor.
        case md
        /// 56 pt — cabeçalho da ficha e do resumo do treino.
        case lg

        var side: CGFloat {
            switch self {
            case .sm: 32
            case .md: 44
            case .lg: 56
            }
        }
    }

    private let glyph: Glyph
    private let color: FJRoutineColor
    private let size: Size
    private let label: Text?

    /// O selo cresce com o Dynamic Type, até 1,4×, para não tomar a linha em tamanhos de acessibilidade.
    @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

    /// - Parameters:
    ///   - symbol: `Routine.symbol` — letra(s) ou nome de SF Symbol. Vazio usa a inicial de `name`.
    ///   - name: nome da ficha (só para a inicial quando `symbol` está vazio).
    ///   - accessibilityLabel: informe só quando o selo aparece sem o nome da ficha ao lado.
    init(
        symbol: String,
        name: String = "",
        color: FJRoutineColor,
        size: Size = .md,
        accessibilityLabel: Text? = nil
    ) {
        self.glyph = Glyph(symbol: symbol, name: name)
        self.color = color
        self.size = size
        self.label = accessibilityLabel
    }

    /// Conveniência com `Routine.colorName`.
    init(
        symbol: String,
        name: String = "",
        colorName: String,
        size: Size = .md,
        accessibilityLabel: Text? = nil
    ) {
        self.init(
            symbol: symbol,
            name: name,
            color: FJRoutineColor(name: colorName),
            size: size,
            accessibilityLabel: accessibilityLabel
        )
    }

    var body: some View {
        let side = size.side * min(max(scale, 1), 1.4)
        let badge = FJRadius.shape(side * 0.27)
            .fill(color.fill)
            .frame(width: side, height: side)
            .overlay {
                glyphView(side: side)
                    .foregroundStyle(color.onFill)
                    .padding(.horizontal, side * 0.08)
            }

        if let label {
            badge
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        } else {
            badge.accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func glyphView(side: CGFloat) -> some View {
        switch glyph {
        case let .text(text):
            Text(verbatim: text)
                .font(.system(size: side * (text.count > 1 ? 0.38 : 0.46), weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        case let .systemImage(name):
            Image(systemName: name)
                .font(.system(size: side * 0.42, weight: .semibold))
        }
    }

    private enum Glyph: Equatable {
        case text(String)
        case systemImage(String)

        init(symbol: String, name: String) {
            let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 2, UIImage(systemName: trimmed) != nil {
                self = .systemImage(trimmed)
            } else if !trimmed.isEmpty {
                self = .text(String(trimmed.prefix(2)).uppercased())
            } else if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                self = .text(String(initial).uppercased())
            } else {
                self = .systemImage("dumbbell.fill")
            }
        }
    }
}

/// Seletor de cor da ficha: as oito cores em amostras de 44 pt que quebram linha (nada de rolagem horizontal).
/// Selecionada = check + anel; o nome da cor vai para o VoiceOver.
struct FJRoutineColorPicker: View {
    @Binding private var selection: FJRoutineColor

    init(selection: Binding<FJRoutineColor>) {
        self._selection = selection
    }

    /// Conveniência para ligar direto em `Routine.colorName`.
    init(colorName: Binding<String>) {
        self._selection = Binding(
            get: { FJRoutineColor(name: colorName.wrappedValue) },
            set: { colorName.wrappedValue = $0.rawValue }
        )
    }

    var body: some View {
        FJFlowLayout(spacing: FJSpacing.s) {
            ForEach(FJRoutineColor.allCases) { option in
                let isOn = option == selection
                Button {
                    selection = option
                } label: {
                    Circle()
                        .fill(option.fill)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if isOn {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(option.onFill)
                            }
                        }
                        .padding(4)
                        .overlay {
                            if isOn {
                                Circle().strokeBorder(FJColor.textPrimary, lineWidth: 2)
                            }
                        }
                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: option.localizedName))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .fjHaptic(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Cor da ficha"))
    }
}

#Preview("Selo e cores de ficha") {
    @Previewable @State var color: FJRoutineColor = .orange

    return ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(alignment: .leading, spacing: FJSpacing.l) {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    HStack(spacing: FJSpacing.m) {
                        FJRoutineBadge(symbol: "A", color: color, size: .sm)
                        FJRoutineBadge(symbol: "A", color: color)
                        FJRoutineBadge(symbol: "A", color: color, size: .lg)
                        FJRoutineBadge(symbol: "figure.run", color: color, size: .lg)
                    }
                    FJFlowLayout(spacing: FJSpacing.s) {
                        ForEach(Array(FJRoutineColor.allCases.enumerated()), id: \.element) { index, option in
                            FJRoutineBadge(symbol: String(UnicodeScalar(UInt8(65 + index))), color: option)
                        }
                    }
                    FJRoutineColorPicker(selection: $color)
                }
            }
        }
        .padding(FJSpacing.screenMargin)
    }
}
