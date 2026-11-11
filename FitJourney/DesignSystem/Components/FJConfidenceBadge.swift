import SwiftUI

/// Confiança da IA num item extraído (SPEC §7A.1: alta / média / baixa).
enum FJConfidence: String, CaseIterable, Sendable, Comparable {
    case low, medium, high

    static func < (lhs: FJConfidence, rhs: FJConfidence) -> Bool {
        lhs.level < rhs.level
    }

    /// 1…3 — quantas barras ficam cheias.
    var level: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    /// Alta é neutra-positiva; média e baixa pedem o olhar do usuário. Vermelho nunca: não é erro.
    var tone: FJTone {
        switch self {
        case .high: .success
        case .medium: .neutral
        case .low: .attention
        }
    }

    /// "Confiança alta" — texto completo e rótulo do VoiceOver.
    var title: LocalizedStringResource {
        switch self {
        case .high: "Confiança alta"
        case .medium: "Confiança média"
        case .low: "Confiança baixa"
        }
    }

    /// Texto curto que diz o que fazer: nada, conferir, revisar.
    var shortTitle: LocalizedStringResource {
        switch self {
        case .high: "Lido com clareza"
        case .medium: "Conferir"
        case .low: "Revisar"
        }
    }
}

/// Indicador de confiança (DESIGN_DIRECTION §4.15.7). Nunca depende só de cor: o nível vem em três
/// barras (1, 2 ou 3 cheias), num texto e, na baixa, num símbolo de atenção.
///
/// - `.full`: barras + "Confiança média" — cabeçalho de cartão de ficha/refeição.
/// - `.compact`: barras + "Conferir"/"Revisar" — ao lado de um campo. Por decisão, campo com
///   confiança alta não mostra selo (use `FJConfidenceBadge` só para média e baixa nas linhas).
/// - `.glyph`: só as barras (com rótulo de acessibilidade) — linhas muito densas.
struct FJConfidenceBadge: View {
    enum Style: Sendable {
        case full, compact, glyph
    }

    private let confidence: FJConfidence
    private let style: Style

    init(_ confidence: FJConfidence, style: Style = .full) {
        self.confidence = confidence
        self.style = style
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            if confidence == .low {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(confidence.tone.color)
            }
            FJConfidenceBars(level: confidence.level, color: confidence.tone.color)
            switch style {
            case .full:
                Text(confidence.title).foregroundStyle(FJColor.textPrimary)
            case .compact:
                Text(confidence.shortTitle).foregroundStyle(FJColor.textPrimary)
            case .glyph:
                EmptyView()
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, style == .glyph ? FJSpacing.xs : FJSpacing.s)
        .padding(.vertical, FJSpacing.xs)
        .background(confidence.tone.soft, in: FJRadius.shape(FJRadius.chip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(confidence.title))
    }
}

/// Três barras crescentes; as `level` primeiras cheias, as demais só contorno.
private struct FJConfidenceBars: View {
    let level: Int
    let color: Color
    @ScaledMetric(relativeTo: .caption) private var unit: CGFloat = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: unit * 0.5) {
            ForEach(1...3, id: \.self) { index in
                let shape = RoundedRectangle(cornerRadius: unit * 0.3, style: .continuous)
                Group {
                    if index <= level {
                        shape.fill(color)
                    } else {
                        shape.strokeBorder(FJColor.textTertiary, lineWidth: 1)
                    }
                }
                .frame(width: unit * 0.9, height: unit * (0.9 + CGFloat(index) * 0.7))
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Confiança") {
    ZStack {
        FJColor.background.ignoresSafeArea()
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                ForEach(FJConfidence.allCases.reversed(), id: \.self) { confidence in
                    HStack(spacing: FJSpacing.s) {
                        FJConfidenceBadge(confidence)
                        FJConfidenceBadge(confidence, style: .compact)
                        FJConfidenceBadge(confidence, style: .glyph)
                    }
                }
            }
        }
        .padding(FJSpacing.screenMargin)
    }
}
