import SwiftUI

/// Célula de métrica: valor grande + unidade + rótulo. `value == nil` mostra "—" e o VoiceOver
/// diz "indisponível" (dado ausente nunca é zero).
struct FJMetricCell: View {
    private let label: LocalizedStringKey
    private let value: String?
    private let unit: String?
    private let systemImage: String?
    private let tint: Color

    init(
        _ label: LocalizedStringKey,
        value: String?,
        unit: String? = nil,
        systemImage: String? = nil,
        tint: Color = FJColor.textSecondary
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack(spacing: FJSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .foregroundStyle(FJColor.textSecondary)
            }
            .font(FJFont.caption)
            .lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: FJSpacing.xs) {
                Text(verbatim: value ?? "—")
                    .font(FJFont.numberMedium)
                    .foregroundStyle(value == nil ? FJColor.textSecondary : FJColor.textPrimary)
                    .fjNumericTransition()
                if let unit, value != nil {
                    Text(verbatim: unit)
                        .font(FJFont.unit)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.map { Text(verbatim: [$0, unit].compactMap(\.self).joined(separator: " ")) } ?? Text("Indisponível"))
    }
}

/// Grade de métricas: 3 colunas, 2 em texto grande, 1 em tamanhos de acessibilidade.
struct FJMetricGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var columns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return dynamicTypeSize >= .xxLarge ? 2 : 3
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: FJSpacing.m, alignment: .topLeading), count: columns),
            alignment: .leading,
            spacing: FJSpacing.l
        ) {
            content
        }
    }
}

#Preview("Métricas") {
    ScrollView {
        FJCard {
            FJMetricGrid {
                FJMetricCell("Duração", value: "52:18", systemImage: "clock")
                FJMetricCell("Volume", value: "8.420", unit: "kg", systemImage: "scalemass")
                FJMetricCell("Séries", value: "18/20", systemImage: "checkmark.circle")
                FJMetricCell("FC média", value: "128", unit: "bpm", systemImage: "heart.fill", tint: FJColor.health)
                FJMetricCell("Energia ativa", value: nil, unit: "kcal", systemImage: "flame.fill", tint: FJColor.health)
                FJMetricCell("Recordes", value: "2", systemImage: "trophy.fill", tint: FJColor.record)
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
