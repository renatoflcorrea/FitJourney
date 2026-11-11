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
/// Todas têm consumidor: `weightUnit` e `loadStep` (exibição e steppers), `weekStart` (`AppCalendar`),
/// `defaultRestSeconds` (`RestPreference`: motor da sessão e padrões do editor), `restSound`
/// (`RestPreference`: notificação de fim de descanso e alerta da Atividade ao Vivo), `restAlertRepeat`
/// (`RestPreference`: alerta insistente na sessão e no relógio), `maxHeartRate` (aba
/// Saúde e zona ao vivo na sessão), `liveActivity` (`LiveActivityController`) e `mealReminders`
/// (`MealReminderScheduler`).
enum AppPreferenceKeys {
    /// "kg" | "lb" (ver `WeightUnitPreference`).
    static let weightUnit = WeightUnitPreference.key
    /// Passo de carga na unidade exibida; 0/ausente = padrão (0,5 kg / 1 lb).
    static let loadStep = "fj.loadStep"
    /// "monday" (padrão) | "sunday". Consumido por `AppCalendar.current` (faixa da Dieta, aderência
    /// semanal, Saúde, calendário do histórico) e pela ordem dos dias em seletores e pontos
    /// (`Weekday.displayOrder`). Os dias gravados nas fichas não mudam.
    static let weekStart = "fj.weekStart"
    /// Descanso padrão em segundos quando a série, a ficha e o exercício não definem (padrão 90), pela
    /// `RestPolicy` (`SessionEngine`/`SessionStore`, editor, estimativa de duração, relógio). Vale a
    /// partir do próximo descanso; um descanso em andamento não muda.
    static let defaultRestSeconds = "fj.defaultRestSeconds"
    /// Som ao fim do descanso (padrão ligado; ausente = ligado). Consumido por `RestPreference.soundEnabled`:
    /// notificação de fim de descanso (`UserNotificationRestScheduler`) e alerta da Atividade ao Vivo.
    /// Lido ao agendar: vale a partir do próximo descanso.
    static let restSound = "fj.restSound"
    /// Alerta insistente no fim do descanso (padrão ligado; ausente = ligado). Ligado: o relógio e a tela da
    /// sessão no iPhone vibram em laço e mostram "Descanso concluído" até um toque (teto de 60 s). Desligado:
    /// uma vibração só. Consumidores: `SessionCoordinator` (iPhone) e `SessionSnapshot.restAlertRepeat`
    /// (relógio, pelo `SessionEngine`); o relógio recebe a mudança no snapshot seguinte.
    static let restAlertRepeat = "fj.restAlertRepeat"
    /// FC máxima manual em bpm; 0/ausente = pela idade (aba Saúde e zona ao vivo na sessão).
    static let maxHeartRate = "fj.maxHeartRate"
    /// Atividade ao Vivo + Dynamic Island da sessão (padrão ligado; ausente = ligado). Consumidor:
    /// `LiveActivityController` (pede/encerra a atividade; a notificação de descanso segue sem ela).
    static let liveActivity = "fj.liveActivity"
    /// Lembretes de refeição globais (padrão ligado). Consumidor: `MealReminderScheduler`
    /// (`MealReminderScheduler.enabledKey` tem o mesmo valor).
    static let mealReminders = "fj.mealReminders"

    static let defaultRestOptions = [30, 45, 60, 75, 90, 120, 150, 180, 240]
}

enum WeekStart: String, CaseIterable, Sendable {
    case monday, sunday

    static var current: WeekStart { resolved(.standard) }

    /// Preferência gravada em `defaults`; ausente ou inválida = segunda (SPEC §11 Q2).
    static func resolved(_ defaults: UserDefaults) -> WeekStart {
        defaults.string(forKey: AppPreferenceKeys.weekStart).flatMap(WeekStart.init(rawValue:)) ?? .monday
    }
}

/// Leitura das preferências de descanso (Ajustes › Treino).
enum RestPreference {
    static let fallbackSeconds = 90

    /// Descanso padrão (`fj.defaultRestSeconds`); ausente ou inválido = 90 s.
    static func defaultSeconds(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: AppPreferenceKeys.defaultRestSeconds)
        return stored > 0 ? stored : fallbackSeconds
    }

    /// Som ao fim do descanso (`fj.restSound`); ausente = ligado.
    static func soundEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppPreferenceKeys.restSound) as? Bool ?? true
    }

    /// Alerta insistente no fim do descanso (`fj.restAlertRepeat`); ausente = ligado.
    static func alertRepeatEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppPreferenceKeys.restAlertRepeat) as? Bool ?? true
    }
}

/// Passo de carga e conversão para exibição. Único ponto de conversão kg/lb da UI (Programas, editor,
/// Sessão, Histórico, Encerramento e a ferramenta de histórico do Coach).
enum LoadDisplay {
    static let stepOptions: [Double] = [0.5, 1, 2, 2.5, 5]

    /// Passo padrão da unidade: 0,5 kg / 1 lb.
    static func defaultStep(for unit: WeightUnit) -> Double { unit == .kg ? 0.5 : 1 }

    /// Passo escolhido em Ajustes (na unidade preferida) válido ou o padrão da unidade.
    static func step(for unit: WeightUnit, stored: Double) -> Double {
        stepOptions.contains(stored) ? stored : defaultStep(for: unit)
    }

    /// Passo para editar uma carga guardada em `loadUnit`: o escolhido só vale quando a carga está na
    /// unidade preferida (o passo é "em kg" ou "em lb"); em outra unidade volta ao padrão dela.
    static func step(forLoadIn loadUnit: WeightUnit, preferred: WeightUnit, stored: Double) -> Double {
        loadUnit == preferred ? step(for: preferred, stored: stored) : defaultStep(for: loadUnit)
    }

    static func step(forLoadIn loadUnit: WeightUnit, defaults: UserDefaults = .standard) -> Double {
        let preferred = defaults.string(forKey: AppPreferenceKeys.weightUnit).flatMap(WeightUnit.init(rawValue:)) ?? .kg
        return step(forLoadIn: loadUnit, preferred: preferred, stored: defaults.double(forKey: AppPreferenceKeys.loadStep))
    }

    /// Valor na unidade de exibição. Mesma unidade = valor original; outra = convertido e arredondado a 0,1.
    static func value(_ value: Double, from unit: WeightUnit, to display: WeightUnit) -> Double {
        guard unit != display else { return value }
        return (display.fromKilograms(unit.toKilograms(value)) * 10).rounded() / 10
    }

    /// Carga reexpressa na unidade de exibição (mesma unidade = intacta).
    static func load(_ load: Load, in display: WeightUnit) -> Load {
        switch load {
        case .weight(let v, let unit): .weight(value: value(v, from: unit, to: display), unit: display)
        case .bodyweight(let d, let unit): .bodyweight(delta: value(d, from: unit, to: display), unit: display)
        }
    }

    /// Quilos (valores calculados em kg: volume, recordes) no texto da unidade preferida: "8.420 kg" / "18.563 lb".
    static func kgText(_ kg: Double, maxFractionDigits: Int = 1, display: WeightUnit = WeightUnitPreference.current) -> String {
        "\(kgNumber(kg, maxFractionDigits: maxFractionDigits, display: display)) \(symbol(display))"
    }

    /// Só o número de `kgText`.
    static func kgNumber(_ kg: Double, maxFractionDigits: Int = 1, display: WeightUnit = WeightUnitPreference.current) -> String {
        let shown = display == .kg ? kg : display.fromKilograms(kg)
        return FJFormat.number(shown, maxFractionDigits: maxFractionDigits)
    }

    static func symbol(_ unit: WeightUnit = WeightUnitPreference.current) -> String { unit == .kg ? "kg" : "lb" }

    /// Valor e unidade prontos para texto (`display` padrão = preferência de Ajustes).
    static func shown(_ value: Double, unit: WeightUnit, display: WeightUnit = WeightUnitPreference.current)
        -> (value: Double, unit: WeightUnit) {
        (Self.value(value, from: unit, to: display), display)
    }
}
