import Foundation

/// Codificação dos valores de domínio guardados nos modelos SwiftData.
///
/// Enums simples ficam como `rawValue` String; tipos com valores associados e structs
/// ficam como JSON (`Data`) — formato estável, compatível com CloudKit e exportável.
enum StorageCoding {
    static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Lista de enums como "a,b,c" (ordem preservada; valores desconhecidos são ignorados).
    static func encodeList<T: RawRepresentable>(_ values: some Sequence<T>) -> String where T.RawValue == String {
        values.map(\.rawValue).joined(separator: ",")
    }

    static func decodeList<T: RawRepresentable>(_ type: T.Type, from raw: String) -> [T] where T.RawValue == String {
        raw.split(separator: ",").compactMap { T(rawValue: String($0)) }
    }

    static func encodeWeekdays(_ weekdays: Set<Weekday>) -> String {
        encodeList(weekdays.sorted())
    }

    static func decodeWeekdays(_ raw: String) -> Set<Weekday> {
        Set(decodeList(Weekday.self, from: raw))
    }
}
