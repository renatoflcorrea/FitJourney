import SwiftUI

/// O glifo do ícone do app (escada de três degraus e o ponto da meta), como forma preenchível.
///
/// Geometria de `glyphPath()` em `design/icon/make_icon.swift` (quadro de 1024, origem no canto
/// superior esquerdo), normalizada: o contorno do glifo é centralizado e ajustado ao retângulo
/// recebido, sem distorcer. O traço de 92 pt do quadro vira contorno com pontas e junções
/// arredondadas, e o ponto é um círculo de raio 66.
struct StairGlyph: Shape {
    private static let stroke: CGFloat = 92
    private static let dotCenter = CGPoint(x: 706, y: 284)
    private static let dotRadius: CGFloat = 66
    private static let steps: [CGPoint] = [
        CGPoint(x: 238, y: 770), CGPoint(x: 420, y: 770),
        CGPoint(x: 420, y: 600), CGPoint(x: 602, y: 600),
        CGPoint(x: 602, y: 430), CGPoint(x: 786, y: 430)
    ]
    /// Caixa do glifo no quadro de 1024, já com a espessura do traço.
    private static let bounds = CGRect(x: 192, y: 218, width: 640, height: 598)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        guard scale.isFinite, scale > 0 else { return Path() }
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.bounds.midX, y: -Self.bounds.midY)

        var line = Path()
        line.addLines(Self.steps)
        var result = line.strokedPath(StrokeStyle(lineWidth: Self.stroke, lineCap: .round, lineJoin: .round))
        result.addEllipse(in: CGRect(
            x: Self.dotCenter.x - Self.dotRadius, y: Self.dotCenter.y - Self.dotRadius,
            width: Self.dotRadius * 2, height: Self.dotRadius * 2
        ))
        return result.applying(transform)
    }
}
