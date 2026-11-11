import SwiftUI

/// Espaçamentos em múltiplos de 4 pt (DESIGN_DIRECTION §2.3).
enum FJSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Margem lateral das telas.
    static let screenMargin: CGFloat = 16
    /// Distância entre cartões.
    static let cardGap: CGFloat = 12
    /// Distância entre seções.
    static let sectionGap: CGFloat = 24
}

/// Raios, sempre contínuos.
enum FJRadius {
    static let chip: CGFloat = 10
    static let field: CGFloat = 12
    static let card: CGFloat = 20
    /// Painel de vidro flutuante (timer de descanso).
    static let panel: CGFloat = 28

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Tamanhos de alvo de toque.
enum FJSize {
    /// Mínimo absoluto.
    static let minTap: CGFloat = 44
    /// Botões +/− do `NumberStepperField`.
    static let stepperButton: CGFloat = 48
    /// Check de série — o alvo mais tocado do app.
    static let setCheck: CGFloat = 52
    /// Altura mínima do botão secundário.
    static let secondaryButton: CGFloat = 48
    /// Altura mínima do botão principal.
    static let primaryButton: CGFloat = 56
    static let progressRing: CGFloat = 72
}

extension Comparable {
    func fjClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
