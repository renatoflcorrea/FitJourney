import SwiftUI
import UIKit

/// Cores da Atividade ao Vivo (§4.14). A Tela Bloqueada usa os tokens dinâmicos (claro/escuro); a
/// Dynamic Island é sempre preta e usa os tons do tema escuro.
struct LiveActivityPalette {
    var accent: Color
    var primary: Color
    var secondary: Color
    var success: Color
    /// Botão neutro (+15 s) e trilho da barra.
    var neutralFill: Color
    /// Botão principal (Pular), texto branco.
    var primaryFill: Color
    /// Preenchimento da barra de progresso.
    var bar: Color

    /// Tela Bloqueada/banner: segue claro/escuro.
    static let lockScreen = LiveActivityPalette(
        accent: FJColor.training, primary: FJColor.textPrimary, secondary: FJColor.textSecondary,
        success: FJColor.success, neutralFill: FJColor.fillStrong, primaryFill: FJColor.trainingFill,
        bar: FJColor.training)

    /// Ilha (sempre preta): `#FF9A3D` sobre preto (9:1).
    static let island = LiveActivityPalette(
        accent: Color(uiColor: UIColor(fjHex: 0xFF9A3D)), primary: .white, secondary: .white.opacity(0.62),
        success: Color(uiColor: UIColor(fjHex: 0x30D158)), neutralFill: .white.opacity(0.18),
        primaryFill: FJColor.trainingFill, bar: Color(uiColor: UIColor(fjHex: 0xFF9A3D)))

    /// Tela sempre ligada (luminância reduzida): o laranja escurece demais — textos brancos e barra neutra.
    func luminanceReduced(_ reduced: Bool) -> LiveActivityPalette {
        guard reduced else { return self }
        var palette = self
        palette.accent = .white
        palette.primary = .white
        palette.secondary = .white.opacity(0.7)
        palette.bar = .white.opacity(0.5)
        return palette
    }
}

/// Glifo da atividade: o motivo "degraus" do ícone (§2.6), numa cor só. Geometria em 1024:
/// traço 108 por (238,770) (420,770) (420,600) (602,600) (602,430) (786,430); ponto r 74 em (706,284) (traço do ícone em vidro).
struct StepsGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            StepsGlyphPath().stroke(style: StrokeStyle(lineWidth: size * StepsGlyphPath.strokeRatio,
                                                       lineCap: .round, lineJoin: .round))
            StepsGlyphDot()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Caixa do motivo (viewBox do protótipo): x 150…874, y 170…870.
private enum StepsGeometry {
    static let origin = CGPoint(x: 150, y: 170)
    static let box = CGSize(width: 724, height: 700)

    static func transform(in rect: CGRect) -> (CGPoint) -> CGPoint {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.minX + (rect.width - box.width * scale) / 2
        let dy = rect.minY + (rect.height - box.height * scale) / 2
        return { CGPoint(x: dx + ($0.x - origin.x) * scale, y: dy + ($0.y - origin.y) * scale) }
    }
}

struct StepsGlyphPath: Shape {
    static let strokeRatio: CGFloat = 108 / 724
    private static let points: [CGPoint] = [
        CGPoint(x: 238, y: 770), CGPoint(x: 420, y: 770), CGPoint(x: 420, y: 600),
        CGPoint(x: 602, y: 600), CGPoint(x: 602, y: 430), CGPoint(x: 786, y: 430),
    ]

    func path(in rect: CGRect) -> Path {
        let map = StepsGeometry.transform(in: rect)
        var path = Path()
        path.addLines(Self.points.map(map))
        return path
    }
}

struct StepsGlyphDot: Shape {
    func path(in rect: CGRect) -> Path {
        let map = StepsGeometry.transform(in: rect)
        let center = map(CGPoint(x: 706, y: 284))
        let edge = map(CGPoint(x: 706 + 74, y: 284))
        let radius = edge.x - center.x
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
