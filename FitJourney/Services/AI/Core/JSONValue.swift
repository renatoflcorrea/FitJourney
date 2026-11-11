import Foundation

/// Árvore JSON mínima, para passar schemas e argumentos sem dependência.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value):
            // Inteiros saem sem ".0" (alguns provedores validam `integer` estritamente).
            if value.rounded() == value, abs(value) < 9e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Lê um documento JSON (schema embutido, argumentos de ferramenta).
    static func parse(_ raw: String) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        return convert(object)
    }

    static func convert(_ value: Any) -> JSONValue {
        switch value {
        case let value as String: .string(value)
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: .array(value.map(convert))
        case let value as [String: Any]: .object(value.mapValues(convert))
        default: .null
        }
    }

    /// JSON compacto com chaves ordenadas.
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    var objectValue: [String: JSONValue]? { if case let .object(o) = self { o } else { nil } }
    var arrayValue: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
}
