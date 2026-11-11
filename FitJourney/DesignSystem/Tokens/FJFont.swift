import SwiftUI

/// Tipografia (DESIGN_DIRECTION §2.2). Só estilos de texto do sistema, para Dynamic Type até AX5.
/// Números de treino (carga, reps, tempo, FC, kcal) usam SF Rounded com dígitos monoespaçados.
enum FJFont {
    // MARK: Números

    /// 34 pt — valor principal de um cartão (tempo da sessão, kcal do dia).
    static let numberHero = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// 28 pt — carga e reps editáveis na série atual.
    static let numberLarge = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    /// 20 pt — célula de métrica, séries não atuais.
    static let numberMedium = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    /// 17 pt — número em linha de lista.
    static let numberBody = Font.system(.body, design: .rounded, weight: .medium).monospacedDigit()
    /// 13 pt — número em legenda, eixo, badge.
    static let numberCaption = Font.system(.footnote, design: .rounded, weight: .medium).monospacedDigit()
    /// Unidade ao lado do número ("kg", "reps", "bpm").
    static let unit = Font.system(.subheadline, design: .rounded, weight: .medium)

    /// Timer de descanso/sustentação: tamanho escalado por quem usa (`@ScaledMetric`), legível à distância.
    static func timer(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: Texto

    static let screenTitle = Font.largeTitle.weight(.bold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let body = Font.body
    static let label = Font.subheadline
    static let caption = Font.footnote
    static let overline = Font.caption.weight(.semibold)
}
