import Foundation

/// Preferência global de unidade de carga (kg padrão). Muda só a exibição: cada carga guarda a unidade
/// em que foi digitada e o histórico nunca é reescrito.
enum WeightUnitPreference {
    static let key = "fj.weightUnit"

    static var current: WeightUnit {
        UserDefaults.standard.string(forKey: key).flatMap(WeightUnit.init(rawValue:)) ?? .kg
    }
}

/// Chaves e padrões das preferências de Ajustes (todas começam com `fj.`: "Apagar tudo" as remove).
///
/// Hoje têm efeito: `weightUnit`, `loadStep` (editor de ficha), `maxHeartRate` (aba Saúde e zona ao vivo
/// na sessão) e `mealReminders` (desligar cancela os avisos). As demais ficam gravadas para o domínio
/// ler: `defaultRestSeconds`, `restSound`, `weekStart`, `liveActivity`.
enum AppPreferenceKeys {
    /// "kg" | "lb" (ver `WeightUnitPreference`).
    static let weightUnit = WeightUnitPreference.key
    /// Passo de carga na unidade exibida; 0/ausente = padrão (0,5 kg / 1 lb).
    static let loadStep = "fj.loadStep"
    /// "monday" (padrão) | "sunday". O domínio (`ScheduleResolver`, calendários de Hoje/Saúde/Dieta,
    /// sequência semanal) ainda assume segunda e deve ler esta chave.
    static let weekStart = "fj.weekStart"
    /// Descanso padrão em segundos quando o exercício não define (padrão 90).
    /// Consumidor: `SessionEngine.defaultRestSeconds(for:)`.
    static let defaultRestSeconds = "fj.defaultRestSeconds"
    /// Som ao fim do descanso (padrão ligado). Consumidor: notificação de fim de descanso e áudio da sessão.
    static let restSound = "fj.restSound"
    /// FC máxima manual em bpm; 0/ausente = pela idade (aba Saúde e zona ao vivo na sessão).
    static let maxHeartRate = "fj.maxHeartRate"
    /// Atividade ao Vivo (ciclo 6; só a preferência por enquanto, padrão ligado).
    static let liveActivity = "fj.liveActivity"
    /// Lembretes de refeição globais (padrão ligado). Consumidor: `MealReminderScheduler.reschedule`
    /// deve não agendar nada quando desligado.
    static let mealReminders = "fj.mealReminders"

    static let defaultRestOptions = [30, 45, 60, 75, 90, 120, 150, 180, 240]
}

enum WeekStart: String, CaseIterable, Sendable {
    case monday, sunday

    static var current: WeekStart {
        UserDefaults.standard.string(forKey: AppPreferenceKeys.weekStart).flatMap(WeekStart.init(rawValue:)) ?? .monday
    }
}

/// Passo de carga e conversão para exibição.
enum LoadDisplay {
    static let stepOptions: [Double] = [0.5, 1, 2, 2.5, 5]

    /// Passo efetivo na unidade: o escolhido (se válido) ou 0,5 kg / 1 lb.
    static func step(for unit: WeightUnit, stored: Double) -> Double {
        stepOptions.contains(stored) ? stored : (unit == .kg ? 0.5 : 1)
    }

    static func step(for unit: WeightUnit, defaults: UserDefaults = .standard) -> Double {
        step(for: unit, stored: defaults.double(forKey: AppPreferenceKeys.loadStep))
    }

    /// Valor na unidade de exibição. Mesma unidade = valor original; outra = convertido e arredondado ao passo.
    static func value(_ value: Double, from unit: WeightUnit, to display: WeightUnit, step: Double) -> Double {
        guard unit != display else { return value }
        let converted = display.fromKilograms(unit.toKilograms(value))
        guard step > 0 else { return converted }
        return (converted / step).rounded() * step
    }

    /// Carga reexpressa na unidade de exibição (mesma unidade = intacta).
    static func load(_ load: Load, in display: WeightUnit, step: Double) -> Load {
        switch load {
        case .weight(let v, let unit): .weight(value: value(v, from: unit, to: display, step: step), unit: display)
        case .bodyweight(let d, let unit): .bodyweight(delta: value(d, from: unit, to: display, step: step), unit: display)
        }
    }
}
