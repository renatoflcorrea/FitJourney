import Foundation

/// Formatação de apresentação compartilhada pelos componentes.
enum FJFormat {
    /// "1:05" ou "1:02:03". Segundos negativos viram zero.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        guard h > 0 else { return "\(m):\(ss)" }
        let mm = m < 10 ? "0\(m)" : "\(m)"
        return "\(h):\(mm):\(ss)"
    }

    /// Número no formato local, sem zeros à direita ("32,5").
    static func number(_ value: Double, maxFractionDigits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...max(0, maxFractionDigits))))
    }

    /// Duração por extenso para VoiceOver ("1 minuto e 5 segundos").
    static func spokenDuration(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
