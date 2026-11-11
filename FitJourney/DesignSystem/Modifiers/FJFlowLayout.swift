import SwiftUI

/// Layout que quebra linha: etiquetas, chips, amostras de cor, sugestões de prompt.
/// Um filho mais largo que a linha recebe a largura disponível (quebra o próprio texto em vez de vazar).
struct FJFlowLayout: Layout {
    /// Distância horizontal entre itens.
    var spacing: CGFloat
    /// Distância entre linhas (padrão: igual a `spacing`).
    var lineSpacing: CGFloat

    init(spacing: CGFloat = FJSpacing.s, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}

#Preview("FJFlowLayout") {
    FJCard {
        FJFlowLayout(spacing: FJSpacing.xs) {
            ForEach(["Peitoral", "Tríceps", "Deltoide anterior", "Barra", "Bilateral", "Repetições × carga"], id: \.self) {
                FJTag(LocalizedStringKey($0))
            }
        }
    }
    .padding(FJSpacing.screenMargin)
}
