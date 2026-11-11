import SwiftUI
import WatchKit

/// Tokens do relógio (DESIGN §9.2): tons do tema escuro de §2.1 (o relógio é sempre escuro).
/// Espelham `FJColor`/`FJFont` do iPhone, mas vivem no alvo watchOS (o design system do iPhone é UIKit/iOS).
enum WF {
    // MARK: Cor
    /// Treino e destaque — laranja do tema escuro.
    static let training = Color(wfHex: 0xFF9A3D)
    /// Preenchimento de botão principal — branco sobre ele passa 4,5:1.
    static let trainingFill = Color(wfHex: 0xD4450C)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.66)
    static let fill = Color.white.opacity(0.14)
    static let fillStrong = Color.white.opacity(0.26)
    /// Atenção/aviso (resumo antigo): amarelo da zona 4.
    static let attention = Color(wfHex: 0xFFD23F)
    static let success = Color(wfHex: 0x3DD56D)
    static let destructive = Color(wfHex: 0xFF6B5E)
    static let health = Color(wfHex: 0xFF5C7A)

    static let zones: [Color] = [Color(wfHex: 0x98A2B3), Color(wfHex: 0x4DB5FF), Color(wfHex: 0x3DD56D),
                                 Color(wfHex: 0xFFD23F), Color(wfHex: 0xF06ADB)]
    static func zone(_ number: Int) -> Color { zones[min(max(number, 1), 5) - 1] }

    // MARK: Fonte (números em SF Rounded, dígitos monoespaçados)
    static func number(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static let exerciseName = Font.headline
    static let caption = Font.footnote
}

extension Color {
    init(wfHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Medidas por tamanho de caixa (41/42 mm vs 45/46/49 mm) — DESIGN §9.2.
enum WatchLayout {
    /// 46 mm tem 208 pt de largura; 42 mm, 187; 41 mm, 176 (versões antigas).
    static var isLargeCase: Bool { WKInterfaceDevice.current().screenBounds.width >= 198 }
    static var primaryButtonHeight: CGFloat { isLargeCase ? 52 : 46 }
    static var loadFontSize: CGFloat { isLargeCase ? 42 : 36 }
    static var timerFontSize: CGFloat { isLargeCase ? 54 : 48 }
}

/// Botão principal em largura total (Concluir, Iniciar, Começar, Salvar…): vidro laranja.
struct WatchPrimaryButton: View {
    let title: String
    var systemImage: String?
    var accessibilityLabel: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title).fontWeight(.semibold)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: WatchLayout.primaryButtonHeight - 12)
        }
        .buttonStyle(.glassProminent)
        .tint(WF.trainingFill)
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
