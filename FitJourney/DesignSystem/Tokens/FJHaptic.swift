import SwiftUI

/// Hápticos com significado (DESIGN_DIRECTION §2.4). Declarativos, via `sensoryFeedback`.
enum FJHaptic: Sendable {
    /// Série concluída.
    case setCompleted
    /// Descanso ou sustentação terminou.
    case timerFinished
    /// Passo de +/− em carga ou reps.
    case stepUp, stepDown
    /// Seleção (chip, RPE, segmento).
    case selection
    /// Exercício concluído.
    case exerciseCompleted
    /// Sessão finalizada / recorde pessoal.
    case celebration
    /// Alteração do copiloto aplicada (cartão de alteração, §4.15.8). Desfazer não vibra.
    case changeApplied
    case warning
    case error

    var feedback: SensoryFeedback {
        switch self {
        case .setCompleted: .impact(weight: .medium)
        case .timerFinished: .warning
        case .stepUp: .increase
        case .stepDown: .decrease
        case .selection: .selection
        case .exerciseCompleted: .impact(weight: .heavy)
        case .celebration: .success
        case .changeApplied: .impact(weight: .medium)
        case .warning: .warning
        case .error: .error
        }
    }
}

extension View {
    /// Dispara o háptico quando `trigger` muda.
    func fjHaptic<T: Equatable>(_ haptic: FJHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }

    /// Dispara o háptico só quando a mudança satisfaz `condition` (ex.: vibrar ao concluir, não ao desfazer).
    func fjHaptic<T: Equatable>(
        _ haptic: FJHaptic,
        trigger: T,
        when condition: @escaping (_ old: T, _ new: T) -> Bool
    ) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in
            condition(old, new) ? haptic.feedback : nil
        }
    }
}
