import SwiftUI

/// Cores de ficha (`Routine.colorName`). Paleta própria, independente dos tokens semânticos de área/estado.
/// Cada cor tem par `fill`/`onFill` com contraste AA (≥ 4,5:1): branco sobre tons escuros, texto escuro
/// sobre tons claros (turquesa, amarelo, cinza). A cor sempre acompanha letra/símbolo.
/// A pedir ao `ios-design` os tokens oficiais; trocar só os valores aqui.
enum RoutineColor: String, CaseIterable, Sendable {
    case orange, green, pink, blue, purple, teal, yellow, gray

    init(name: String) { self = RoutineColor(rawValue: name) ?? .orange }

    private var hex: UInt32 {
        switch self {
        case .orange: 0xC2410C
        case .green: 0x15803D
        case .pink: 0xBE185D
        case .blue: 0x0A66C2
        case .purple: 0x7C3AED
        case .teal: 0x5CD4D8
        case .yellow: 0xF5C518
        case .gray: 0xC3CAD4
        }
    }

    private var usesDarkText: Bool { self == .teal || self == .yellow || self == .gray }

    var fill: Color { Color(uiColor: UIColor(fjHex: hex)) }
    var onFill: Color { Color(uiColor: UIColor(fjHex: usesDarkText ? 0x111827 : 0xFFFFFF)) }

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
}

/// Selo quadrado da ficha: letra/símbolo sobre a cor escolhida. Público para Treinos e Hoje.
struct RoutineBadge: View {
    let symbol: String
    let name: String
    let colorName: String
    var size: CGFloat = 44

    init(routine: Routine, size: CGFloat = 44) {
        self.init(symbol: routine.symbol, name: routine.name, colorName: routine.colorName, size: size)
    }

    init(symbol: String, name: String, colorName: String, size: CGFloat = 44) {
        self.symbol = symbol
        self.name = name
        self.colorName = colorName
        self.size = size
    }

    var body: some View {
        let color = RoutineColor(name: colorName)
        let text = symbol.isEmpty ? String(name.prefix(1)).uppercased() : symbol
        Text(text.isEmpty ? "?" : text)
            .font(.system(.title3, design: .rounded, weight: .bold))
            .minimumScaleFactor(0.6)
            .foregroundStyle(color.onFill)
            .frame(width: size, height: size)
            .background(color.fill, in: FJRadius.shape(FJRadius.chip))
            .accessibilityHidden(true)
    }
}
