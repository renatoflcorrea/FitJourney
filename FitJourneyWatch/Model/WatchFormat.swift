import Foundation

/// Passo e limites da carga ajustada pela Digital Crown (SPEC D3: 0,5 kg por detente).
enum WatchLoadStepping {
    static let step = 0.5
    /// Carga absoluta: 0 … 1000. Peso corporal (lastro/assistência): −150 … +150.
    static let absoluteRange: ClosedRange<Double> = 0...1000
    static let bodyweightRange: ClosedRange<Double> = -150...150

    static func range(for load: WatchLoad) -> ClosedRange<Double> {
        load.isBodyweight ? bodyweightRange : absoluteRange
    }

    /// Arredonda ao passo e limita ao intervalo da carga.
    static func clamp(_ value: Double, for load: WatchLoad) -> Double {
        let snapped = (value / step).rounded() * step
        let range = range(for: load)
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// Formatação em pt-BR para o relógio (números do SF Rounded ficam por conta das views).
enum WatchFormat {
    static let locale = Locale(identifier: "pt_BR")

    static func number(_ value: Double, minFraction: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minFraction
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func unit(_ load: WatchLoad) -> String { load.unit == .kg ? "kg" : "lb" }

    /// "26,0 kg" · "PC" · "PC +10 kg" · "PC −10 kg". `compact` usa uma casa só quando há fração.
    static func load(_ load: WatchLoad?, compact: Bool = false) -> String {
        guard let load else { return "—" }
        let minFraction = compact ? 0 : 1
        if load.isBodyweight {
            if load.value == 0 { return "PC" }
            let sign = load.value > 0 ? "+" : "−"
            return "PC \(sign)\(number(abs(load.value), minFraction: 0)) \(unit(load))"
        }
        return "\(number(load.value, minFraction: minFraction)) \(unit(load))"
    }

    /// Para VoiceOver: "26 quilos".
    static func spokenLoad(_ load: WatchLoad?) -> String {
        guard let load else { return "sem carga" }
        let word = load.unit == .kg ? "quilos" : "libras"
        if load.isBodyweight {
            if load.value == 0 { return "peso corporal" }
            let side = load.value > 0 ? "mais" : "menos"
            return "peso corporal \(side) \(number(abs(load.value))) \(word)"
        }
        return "\(number(load.value)) \(word)"
    }

    /// "32:14" ou "1:02:14".
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Duração alvo de cardio como o iPhone escreve (`SessionDisplay.targetText`): "20 min" ou "2:30".
    static func cardioTargetText(seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Alvo como prescrito: "alvo 8–12 · RIR 2".
    static func target(text: String, effort: WatchEffort?) -> String {
        var parts = ["alvo \(text)"]
        switch effort {
        case .rir(let rir): parts.append("RIR \(rir)")
        case .rpe(let rpe): parts.append("RPE \(number(rpe))")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// Spoken version: "alvo 8 a 12 repetições".
    static func spokenTarget(text: String) -> String {
        let spoken = text.replacingOccurrences(of: "–", with: " a ")
        return text.hasSuffix(" s") || text.contains("min") ? "alvo \(spoken)" : "alvo \(spoken) repetições"
    }

    static func setKindLabel(_ kind: WatchSetKind) -> String? {
        switch kind {
        case .warmup: "Aquecimento"
        case .feeder: "Aproximação"
        case .working, .unknown: nil
        case .dropSet: "Drop set"
        case .restPause: "Rest-pause"
        case .toFailure: "Até a falha"
        case .backOff: "Back-off"
        }
    }

    /// RPE 1–10 com rótulo ("7 · Muito difícil").
    static func rpeLabel(_ rpe: Int) -> String {
        switch rpe {
        case ...2: "Muito leve"
        case 3...4: "Leve"
        case 5...6: "Moderado"
        case 7: "Difícil"
        case 8: "Muito difícil"
        case 9: "Quase máximo"
        default: "Máximo"
        }
    }

    /// "atualizado há 5 min" / "atualizado ontem".
    static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "atualizado agora" }
        if seconds < 3600 { return "atualizado há \(Int(seconds / 60)) min" }
        if seconds < 24 * 3600 { return "atualizado há \(Int(seconds / 3600)) h" }
        return Calendar.current.isDate(date, inSameDayAs: now.addingTimeInterval(-24 * 3600)) ? "atualizado ontem"
            : "atualizado há \(Int(seconds / (24 * 3600))) dias"
    }
}
