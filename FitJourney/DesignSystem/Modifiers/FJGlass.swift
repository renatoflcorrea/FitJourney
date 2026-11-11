import SwiftUI

/// Único ponto de entrada para Liquid Glass em superfícies próprias (DESIGN_DIRECTION §1).
/// Vidro só no que flutua. Com Reduzir Transparência vira superfície sólida com contorno.
private struct FJGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? FJColor.surfaceElevated, in: shape)
                .overlay(shape.stroke(FJColor.separator, lineWidth: 0.5))
        } else {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

extension View {
    /// Aplica Liquid Glass (ou o substituto sólido). Nunca use em listas de dados, formulários ou gráficos.
    func fjGlass(
        in shape: some Shape = Capsule(),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(FJGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

#Preview("Vidro") {
    ZStack {
        LinearGradient(colors: [FJColor.training, FJColor.health], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        GlassEffectContainer(spacing: FJSpacing.m) {
            VStack(spacing: FJSpacing.m) {
                Text("Cápsula de vidro")
                    .padding(.horizontal, FJSpacing.l)
                    .padding(.vertical, FJSpacing.m)
                    .fjGlass()
                Text("Painel")
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .fjGlass(in: FJRadius.shape(FJRadius.panel))
            }
            .padding()
        }
    }
}
