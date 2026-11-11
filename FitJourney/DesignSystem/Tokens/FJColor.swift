import SwiftUI
import UIKit

/// Cores semânticas do FitJourney (DESIGN_DIRECTION §2.1).
///
/// Regras: cor sempre acompanha texto ou símbolo; texto colorido usa o tom `color` (contraste ≥ 4,5:1
/// sobre `surface`); preenchimento com texto branco usa o tom `fill`.
enum FJColor {
    // MARK: Superfícies e texto (cores do sistema: claro/escuro/alto contraste automáticos)

    /// Fundo de tela (agrupado).
    static let background = Color(uiColor: .systemGroupedBackground)
    /// Cartão de conteúdo sólido — onde vivem números, listas e gráficos.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// Superfície sobre cartão e substituto do vidro com Reduzir Transparência.
    static let surfaceElevated = Color(uiColor: .tertiarySystemGroupedBackground)
    /// Preenchimento discreto: trilho de progresso, botão de passo, campo.
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let fillStrong = Color(uiColor: .secondarySystemFill)
    static let separator = Color(uiColor: .separator)

    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    /// Texto/símbolo sobre preenchimento `fill` de área ou tom.
    static let onFill = Color.white

    // MARK: Áreas

    /// Treino — índigo.
    static let training = Color(fjLight: 0x4B45D6, dark: 0x9A96FF)
    static let trainingFill = Color(fjLight: 0x4B45D6, dark: 0x5E58E8)
    /// Dieta — verde.
    static let nutrition = Color(fjLight: 0x18803A, dark: 0x30D158)
    static let nutritionFill = Color(fjLight: 0x18803A, dark: 0x1F8A40)
    /// Saúde — rosa-vermelho (coração).
    static let health = Color(fjLight: 0xD70F45, dark: 0xFF5C7A)
    static let healthFill = Color(fjLight: 0xD70F45, dark: 0xD92350)
    /// Coach (fase 2) — azul.
    static let coach = Color(fjLight: 0x0A6FB8, dark: 0x5AC8FA)
    static let coachFill = Color(fjLight: 0x0A6FB8, dark: 0x0F78C4)

    /// Treino aeróbico (força usa `training`) — turquesa.
    static let aerobic = Color(fjLight: 0x0B7F83, dark: 0x5AD1D6)

    // MARK: Zonas de frequência cardíaca (preenchimento de gráfico/ponto; nunca cor de texto)

    static let zone1 = Color(fjLight: 0x8E99A8, dark: 0x98A2B3)
    static let zone2 = Color(fjLight: 0x2F9BE6, dark: 0x4DB5FF)
    static let zone3 = Color(fjLight: 0x2FB457, dark: 0x3DD56D)
    static let zone4 = Color(fjLight: 0xF08A1C, dark: 0xFF9F2E)
    static let zone5 = Color(fjLight: 0xE5383B, dark: 0xFF5A5F)

    // MARK: Estados

    /// Concluído / salvo.
    static let success = Color(fjLight: 0x18803A, dark: 0x30D158)
    /// Atenção: ajustado, parcial, pendente de ação do usuário.
    static let attention = Color(fjLight: 0xA85400, dark: 0xFFB340)
    /// Só ação destrutiva e erro.
    static let destructive = Color(fjLight: 0xD12B20, dark: 0xFF6259)
    /// Recorde pessoal.
    static let record = Color(fjLight: 0x8F6400, dark: 0xFFD60A)
}

extension Color {
    /// Cor dinâmica claro/escuro a partir de hex RGB.
    init(fjLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(fjHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(fjHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Área do app: define a cor de destaque de uma tela ou componente.
enum FJArea: String, CaseIterable, Sendable {
    case training, nutrition, health, coach

    /// Tom para texto, símbolo e marca de gráfico.
    var color: Color {
        switch self {
        case .training: FJColor.training
        case .nutrition: FJColor.nutrition
        case .health: FJColor.health
        case .coach: FJColor.coach
        }
    }

    /// Tom para preenchimento com texto branco (botão principal, check concluído).
    var fill: Color {
        switch self {
        case .training: FJColor.trainingFill
        case .nutrition: FJColor.nutritionFill
        case .health: FJColor.healthFill
        case .coach: FJColor.coachFill
        }
    }

    /// Fundo suave de chip/etiqueta.
    var soft: Color { color.opacity(0.14) }

    var title: LocalizedStringKey {
        switch self {
        case .training: "Treinos"
        case .nutrition: "Dieta"
        case .health: "Saúde"
        case .coach: "Coach"
        }
    }

    var systemImage: String {
        switch self {
        case .training: "dumbbell.fill"
        case .nutrition: "fork.knife"
        case .health: "heart.fill"
        case .coach: "sparkles"
        }
    }
}

/// Tom de estado. A cor vai no símbolo e no fundo suave; o texto continua primário.
enum FJTone: String, CaseIterable, Sendable {
    case neutral, success, attention, destructive, record

    var color: Color {
        switch self {
        case .neutral: FJColor.textSecondary
        case .success: FJColor.success
        case .attention: FJColor.attention
        case .destructive: FJColor.destructive
        case .record: FJColor.record
        }
    }

    var soft: Color {
        self == .neutral ? FJColor.fill : color.opacity(0.14)
    }

    var systemImage: String {
        switch self {
        case .neutral: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .destructive: "xmark.octagon.fill"
        case .record: "trophy.fill"
        }
    }
}

/// Tipo de treino na aba Saúde: força x aeróbico. Sempre com símbolo e rótulo, nunca só cor.
enum FJWorkoutKind: String, CaseIterable, Sendable {
    case strength, aerobic

    var color: Color {
        switch self {
        case .strength: FJColor.training
        case .aerobic: FJColor.aerobic
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .strength: "Força"
        case .aerobic: "Aeróbico"
        }
    }

    var systemImage: String {
        switch self {
        case .strength: "dumbbell.fill"
        case .aerobic: "figure.run"
        }
    }
}

/// Zona de frequência cardíaca (1–5). Os limites em % da FC máx vêm do domínio; aqui só a aparência.
enum FJHeartRateZone: Int, CaseIterable, Sendable {
    case z1 = 1, z2, z3, z4, z5

    var color: Color {
        switch self {
        case .z1: FJColor.zone1
        case .z2: FJColor.zone2
        case .z3: FJColor.zone3
        case .z4: FJColor.zone4
        case .z5: FJColor.zone5
        }
    }

    /// "Z3" — sempre visível junto da cor.
    var shortLabel: String { "Z\(rawValue)" }

    var name: LocalizedStringKey {
        switch self {
        case .z1: "Muito leve"
        case .z2: "Leve"
        case .z3: "Moderada"
        case .z4: "Intensa"
        case .z5: "Máxima"
        }
    }
}
