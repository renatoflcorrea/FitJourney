import Foundation

/// Codificação dos valores de domínio guardados nos modelos SwiftData.
///
/// Enums simples ficam como `rawValue` String; tipos com valores associados e structs
/// ficam como JSON (`Data`) — formato estável, compatível com CloudKit e exportável.
///
/// Tolerância: leitura nunca quebra (dado corrompido/desconhecido → `nil`/`[]` ou só os
/// elementos válidos) e **escrita de listas nunca perde dado desconhecido** — elementos que
/// esta versão não entende (ex.: caso novo gravado por versão futura via sync) são preservados.
enum StorageCoding {
    static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }

    /// Valor único: dado ilegível → `nil` (a escrita seguinte substitui por decisão explícita do usuário).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Listas JSON tolerantes

    /// Chave usada para guardar um blob inteiro ilegível como elemento desconhecido.
    static let corruptBlobKey = "_unreadable"

    /// Decodifica elemento a elemento: devolve os válidos e ignora (sem apagar) os demais.
    static func decodeList<T: Decodable>(_ type: T.Type, from data: Data?) -> [T] {
        rawElements(from: data).compactMap { decodeElement(type, from: $0) }
    }

    /// Grava `values` mantendo, ao fim, os elementos de `existing` que esta versão não entende.
    /// Se `existing` inteiro estiver ilegível, ele é preservado como elemento `{"_unreadable": base64}`.
    static func encodeList<T: Codable>(_ values: [T], preservingUnknownIn existing: Data?) -> Data? {
        let unknown: [Any]
        if let existing, !existing.isEmpty, (try? JSONSerialization.jsonObject(with: existing)) as? [Any] == nil {
            unknown = [[corruptBlobKey: existing.base64EncodedString()]]
        } else {
            unknown = rawElements(from: existing).filter { decodeElement(T.self, from: $0) == nil }
        }
        let known: [Any] = values.compactMap { value in
            encode([value]).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?.first
        }
        let all = known + unknown
        guard !all.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
    }

    private static func rawElements(from data: Data?) -> [Any] {
        guard let data, let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array
    }

    private static func decodeElement<T: Decodable>(_ type: T.Type, from element: Any) -> T? {
        guard JSONSerialization.isValidJSONObject([element]),
              let data = try? JSONSerialization.data(withJSONObject: [element]) else { return nil }
        return (try? JSONDecoder().decode([T].self, from: data))?.first
    }

    // MARK: Listas de enums "a,b,c"

    /// Valores conhecidos, na ordem gravada (desconhecidos são ignorados na leitura).
    static func decodeList<T: RawRepresentable>(_ type: T.Type, from raw: String) -> [T] where T.RawValue == String {
        raw.split(separator: ",").compactMap { T(rawValue: String($0)) }
    }

    /// Grava `values` mantendo os tokens desconhecidos de `existing` (ex.: músculo novo de versão futura).
    static func encodeList<T: RawRepresentable>(_ values: some Sequence<T>, preservingUnknownIn existing: String = "") -> String
    where T.RawValue == String {
        var tokens = values.map(\.rawValue)
        for token in existing.split(separator: ",").map(String.init)
        where T(rawValue: token) == nil && !tokens.contains(token) {
            tokens.append(token)
        }
        return tokens.joined(separator: ",")
    }

    static func encodeWeekdays(_ weekdays: Set<Weekday>, preservingUnknownIn existing: String = "") -> String {
        encodeList(weekdays.sorted(), preservingUnknownIn: existing)
    }

    static func decodeWeekdays(_ raw: String) -> Set<Weekday> {
        Set(decodeList(Weekday.self, from: raw))
    }
}
