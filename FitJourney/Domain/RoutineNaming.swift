import Foundation

/// Regra de nome repetido ao copiar uma ficha para outro programa (DESIGN §4.2.1).
/// Função pura: a folha usa para mostrar "Entra como…" antes de confirmar e o `ProgramStore` usa ao gravar.
///
/// Comparação sem diferenciar maiúsculas nem acentos e ignorando espaços nas pontas. Repetido vira
/// "Nome (2)", depois "(3)"…; nome que já termina em "(n)" incrementa ("Peito (2)" → "Peito (3)").
enum RoutineNaming {
    /// Forma comparável de um nome.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Nome final de `name` num destino que já tem os nomes `existing`. Sem repetição, devolve `name` igual.
    static func uniqueName(_ name: String, among existing: [String]) -> String {
        let taken = Set(existing.map(key))
        guard taken.contains(key(name)) else { return name }
        let (base, number) = split(name)
        var next = (number ?? 1) + 1
        while taken.contains(key("\(base) (\(next))")) { next += 1 }
        return "\(base) (\(next))"
    }

    /// Nomes finais de várias fichas na ordem dada: cada uma conta o destino e as anteriores da lista.
    static func uniqueNames(_ names: [String], among existing: [String]) -> [String] {
        var taken = existing
        var result: [String] = []
        for name in names {
            let final = uniqueName(name, among: taken)
            result.append(final)
            taken.append(final)
        }
        return result
    }

    /// "Peito (2)" → ("Peito", 2); sem sufixo numérico → (nome sem espaços nas pontas, nil).
    static func split(_ name: String) -> (base: String, number: Int?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return (trimmed, nil) }
        let digits = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let base = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits) else { return (trimmed, nil) }
        return (base, number)
    }
}
