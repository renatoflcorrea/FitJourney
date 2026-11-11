import SwiftUI
import UIKit

/// Paleta oficial de cores de ficha (DESIGN_DIRECTION §2.1.1). Os nomes são os valores de `Routine.colorName`
/// e não mudam: orange, green, pink, blue, purple, teal, yellow, gray.
///
/// É uma paleta de **identidade** (distinguir a ficha A da B), separada das cores de área e de estado.
/// Regras:
/// - a cor nunca vai sozinha: sempre acompanha a letra/símbolo ou o nome da ficha;
/// - `onFill` sobre `fill` tem ≥ 4,5:1 e `fill` tem ≥ 3:1 sobre `surface` e `background`, em claro e escuro
///   (conferido por `design/tools/routine_palette_check.py`);
/// - `fill` serve para selo, ponto de calendário e trilho; não é cor de texto.
enum FJRoutineColor: String, CaseIterable, Identifiable, Sendable {
    case orange, green, pink, blue, purple, teal, yellow, gray

    /// Cor de uma ficha sem cor definida (nome vazio ou desconhecido).
    static let fallback: FJRoutineColor = .orange

    /// A partir de `Routine.colorName`. Nome vazio ou desconhecido cai em `fallback`.
    init(name: String) {
        self = FJRoutineColor(rawValue: name.lowercased()) ?? Self.fallback
    }

    var id: String { rawValue }

    /// Valores RGB de um tema.
    struct Tones: Sendable, Hashable {
        let fill: UInt32
        let onFill: UInt32
    }

    private static let white: UInt32 = 0xFFFFFF
    /// Texto escuro sobre os tons claros (turquesa, amarelo e cinza no escuro; amarelo no claro).
    private static let ink: UInt32 = 0x1A1206

    /// Tons do tema claro.
    var light: Tones {
        switch self {
        case .orange: Tones(fill: 0xD4450C, onFill: Self.white)
        case .green: Tones(fill: 0x18803A, onFill: Self.white)
        case .pink: Tones(fill: 0xC2256E, onFill: Self.white)
        case .blue: Tones(fill: 0x0A66C2, onFill: Self.white)
        case .purple: Tones(fill: 0x7C3AED, onFill: Self.white)
        case .teal: Tones(fill: 0x0B7F83, onFill: Self.white)
        case .yellow: Tones(fill: 0xAD8200, onFill: Self.ink)
        case .gray: Tones(fill: 0x5F6B7A, onFill: Self.white)
        }
    }

    /// Tons do tema escuro (também os do relógio, que é sempre escuro).
    var dark: Tones {
        switch self {
        case .orange: Tones(fill: 0xD4450C, onFill: Self.white)
        case .green: Tones(fill: 0x1C8540, onFill: Self.white)
        case .pink: Tones(fill: 0xC92C75, onFill: Self.white)
        case .blue: Tones(fill: 0x1F71CC, onFill: Self.white)
        case .purple: Tones(fill: 0x8349EE, onFill: Self.white)
        case .teal: Tones(fill: 0x5AD1D6, onFill: Self.ink)
        case .yellow: Tones(fill: 0xFFD23F, onFill: Self.ink)
        case .gray: Tones(fill: 0xAEB7C2, onFill: Self.ink)
        }
    }

    /// Preenchimento do selo, ponto de calendário, trilho.
    var fill: Color { Color(fjLight: light.fill, dark: dark.fill) }
    /// Letra/símbolo sobre `fill`.
    var onFill: Color { Color(fjLight: light.onFill, dark: dark.onFill) }

    /// Nome para o seletor de cor e o VoiceOver.
    var localizedName: String {
        switch self {
        case .orange: String(localized: "Laranja")
        case .green: String(localized: "Verde")
        case .pink: String(localized: "Rosa")
        case .blue: String(localized: "Azul")
        case .purple: String(localized: "Roxo")
        case .teal: String(localized: "Turquesa")
        case .yellow: String(localized: "Amarelo")
        case .gray: String(localized: "Cinza")
        }
    }

    /// Cor sugerida para a n-ésima ficha de um programa (0 = primeira): percorre a paleta numa ordem
    /// em que vizinhas ficam bem distintas (A laranja, B azul, C verde, D roxo…).
    static func suggested(forIndex index: Int) -> FJRoutineColor {
        let order: [FJRoutineColor] = [.orange, .blue, .green, .purple, .pink, .teal, .yellow, .gray]
        return order[((index % order.count) + order.count) % order.count]
    }
}
