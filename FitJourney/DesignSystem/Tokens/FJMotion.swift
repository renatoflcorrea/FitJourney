import SwiftUI

/// Animações (DESIGN_DIRECTION §2.5). Com Reduzir Movimento tudo vira esmaecimento curto.
enum FJMotion {
    /// Mudança de estrutura: expandir exercício, abrir timer, minimizar sessão.
    static let structure = Animation.smooth(duration: 0.4, extraBounce: 0.1)
    /// Mudança de valor: check, progresso, número.
    static let value = Animation.snappy(duration: 0.25)
    /// Resposta ao toque.
    static let press = Animation.easeOut(duration: 0.08)
    /// Substituto com Reduzir Movimento.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

private struct FJAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(FJMotion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Anima respeitando Reduzir Movimento. Use no lugar de `.animation(_:value:)`.
    func fjAnimation<V: Equatable>(_ animation: Animation = FJMotion.value, value: V) -> some View {
        modifier(FJAnimationModifier(animation: animation, value: value))
    }
}
