import Foundation

/// Entrada numérica de dieta (kcal, gramas, ml): aceita "2.600", "2600", "1.234,5", "12,5", "12.5".
/// Texto inválido não vira zero: devolve `.invalid` para a UI mostrar erro e manter o valor anterior.
enum NutritionInput {
    enum Field {
        case kcal, grams, milliliters

        /// Teto plausível por campo.
        var maximum: Double {
            switch self {
            case .kcal: 20_000
            case .grams: 5_000
            case .milliliters: 10_000
            }
        }
    }

    enum ParseResult: Equatable {
        case empty
        case value(Double)
        case invalid
    }

    static func parse(_ text: String, field: Field) -> ParseResult {
        parse(text, maximum: field.maximum)
    }

    static func parse(_ text: String, maximum: Double) -> ParseResult {
        let t = text.filter { !$0.isWhitespace }
        if t.isEmpty { return .empty }
        guard t.allSatisfy({ "0123456789.,".contains($0) }) else { return .invalid }

        let normalized: String
        let hasDot = t.contains("."), hasComma = t.contains(",")
        if hasDot && hasComma {
            // O último separador é o decimal; o outro é milhar (grupos de 3).
            let decimalIsComma = t.lastIndex(of: ",")! > t.lastIndex(of: ".")!
            let decimal: Character = decimalIsComma ? "," : "."
            let thousands: Character = decimalIsComma ? "." : ","
            let parts = t.split(separator: decimal, omittingEmptySubsequences: false)
            guard parts.count == 2, let integer = thousandsGrouped(String(parts[0]), separator: thousands) else { return .invalid }
            normalized = integer + "." + parts[1]
        } else if hasComma {
            let parts = t.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .invalid }
            normalized = "\(parts[0].isEmpty ? "0" : String(parts[0])).\(parts[1])"
        } else if hasDot {
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            if let integer = thousandsGrouped(t, separator: "."), parts.count >= 2, parts[0] != "0" {
                normalized = integer // "2.600" = 2600
            } else if parts.count == 2 {
                normalized = "\(parts[0].isEmpty ? "0" : String(parts[0])).\(parts[1])"
            } else {
                return .invalid
            }
        } else {
            normalized = t
        }
        guard let value = Double(normalized), value.isFinite, value >= 0, value <= maximum else { return .invalid }
        return .value(value)
    }

    /// "1.234.567" → "1234567"; nil se os grupos não forem 1–3 dígitos seguidos de grupos de exatamente 3.
    private static func thousandsGrouped(_ text: String, separator: Character) -> String? {
        let groups = text.split(separator: separator, omittingEmptySubsequences: false)
        guard let first = groups.first, (1...3).contains(first.count), first.allSatisfy(\.isNumber) else { return nil }
        for group in groups.dropFirst() where group.count != 3 || !group.allSatisfy(\.isNumber) { return nil }
        return groups.joined()
    }

    /// Texto editável de um valor (sem separador de milhar, no máximo 1 casa), para ida e volta com `parse`.
    static func format(_ value: Double?) -> String {
        value.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) } ?? ""
    }
}
