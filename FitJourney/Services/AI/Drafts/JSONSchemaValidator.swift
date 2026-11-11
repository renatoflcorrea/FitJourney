import Foundation

/// Validador do subconjunto de JSON Schema usado nos contratos (o mesmo do modo estrito da OpenAI):
/// `type` (único ou lista), `enum`, `properties`, `required`, `additionalProperties: false`,
/// `items`, `minItems`/`maxItems`, `minimum`/`maximum`, `minLength`/`maxLength`, `pattern`,
/// `anyOf` e `$ref` local (`#/$defs/...`). Palavras-chave desconhecidas são ignoradas.
struct JSONSchemaValidator: Sendable {
    let root: JSONValue

    init(schema: JSONValue) { self.root = schema }

    init(schemaJSON: String) throws { self.root = try JSONValue.parse(schemaJSON) }

    /// Lista de problemas (`caminho: mensagem`), no máximo `limit`. Vazio = válido.
    func validate(_ value: JSONValue, limit: Int = 20) -> [String] {
        var issues: [String] = []
        check(value, against: root, path: "$", issues: &issues, depth: 0)
        return Array(issues.prefix(limit))
    }

    private func resolve(_ schema: JSONValue) -> JSONValue {
        guard let ref = schema["$ref"]?.stringValue, ref.hasPrefix("#/") else { return schema }
        var node: JSONValue? = root
        for part in ref.dropFirst(2).split(separator: "/") { node = node?[String(part)] }
        return node ?? .object([:])
    }

    private func check(_ value: JSONValue, against rawSchema: JSONValue, path: String, issues: inout [String], depth: Int) {
        guard depth < 64, issues.count < 50 else { return }
        let schema = resolve(rawSchema)

        if let options = schema["anyOf"]?.arrayValue {
            let matches = options.contains { option in
                var scratch: [String] = []
                check(value, against: option, path: path, issues: &scratch, depth: depth + 1)
                return scratch.isEmpty
            }
            if !matches {
                // Mostra o motivo da primeira alternativa não nula, que costuma ser a útil.
                if case .null = value { issues.append("\(path): não pode ser null") } else if let first = options.first(where: { $0["type"]?.stringValue != "null" }) {
                    check(value, against: first, path: path, issues: &issues, depth: depth + 1)
                } else {
                    issues.append("\(path): não corresponde a nenhuma alternativa")
                }
            }
            return
        }

        if let type = schema["type"] {
            let allowed: [String] = type.stringValue.map { [$0] } ?? (type.arrayValue ?? []).compactMap(\.stringValue)
            guard allowed.contains(where: { Self.matches(value, type: $0) }) else {
                issues.append("\(path): esperado \(allowed.joined(separator: " ou ")), veio \(Self.typeName(value))")
                return
            }
        }

        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            let list = options.compactMap(\.stringValue).joined(separator: ", ")
            issues.append("\(path): valor fora de [\(list)]")
        }

        switch value {
        case let .object(object):
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) where object[key] == nil {
                issues.append("\(path).\(key): obrigatório")
            }
            if case .bool(false) = schema["additionalProperties"] {
                for key in object.keys.sorted() where properties[key] == nil {
                    issues.append("\(path).\(key): propriedade não permitida")
                }
            }
            for key in object.keys.sorted() {
                if let child = properties[key], let item = object[key] {
                    check(item, against: child, path: "\(path).\(key)", issues: &issues, depth: depth + 1)
                }
            }
        case let .array(array):
            if let min = Self.number(schema["minItems"]), Double(array.count) < min {
                issues.append("\(path): mínimo de \(Int(min)) itens")
            }
            if let max = Self.number(schema["maxItems"]), Double(array.count) > max {
                issues.append("\(path): máximo de \(Int(max)) itens")
            }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() {
                    check(item, against: items, path: "\(path)[\(index)]", issues: &issues, depth: depth + 1)
                }
            }
        case let .number(number):
            if let min = Self.number(schema["minimum"]), number < min { issues.append("\(path): mínimo \(Self.format(min))") }
            if let max = Self.number(schema["maximum"]), number > max { issues.append("\(path): máximo \(Self.format(max))") }
        case let .string(string):
            if let min = Self.number(schema["minLength"]), Double(string.count) < min { issues.append("\(path): curto demais") }
            if let max = Self.number(schema["maxLength"]), Double(string.count) > max { issues.append("\(path): longo demais") }
            if let pattern = schema["pattern"]?.stringValue,
               string.range(of: pattern, options: .regularExpression) == nil {
                issues.append("\(path): formato inválido")
            }
        default:
            break
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
             ("number", .number):
            true
        case let ("integer", .number(n)):
            n.rounded() == n
        default:
            false
        }
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .bool: "boolean"
        case .null: "null"
        case .number: "number"
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        if case let .number(n)? = value { return n }
        return nil
    }

    private static func format(_ n: Double) -> String {
        n.rounded() == n ? String(Int(n)) : String(n)
    }
}

/// Validação completa de um argumento de proposta: schema → Codable → regras semânticas.
enum DraftValidation {
    enum Outcome<T: Sendable>: Sendable {
        case valid(T)
        case invalid([String])
    }

    static func validate<T: Decodable & Sendable>(_ json: String, schema: String, as type: T.Type,
                                                   semantic: (T) -> [String]) -> Outcome<T> {
        guard let extracted = StructuredDecoder.extractJSONObject(from: json),
              let value = try? JSONValue.parse(extracted) else {
            return .invalid(["$: JSON inválido"])
        }
        guard let validator = try? JSONSchemaValidator(schemaJSON: schema) else { return .invalid(["schema interno ilegível"]) }
        let schemaIssues = validator.validate(value)
        guard schemaIssues.isEmpty else { return .invalid(schemaIssues) }
        let decoded: T
        do {
            decoded = try JSONDecoder().decode(T.self, from: Data(extracted.utf8))
        } catch {
            return .invalid(["$: \(error.localizedDescription)"])
        }
        let issues = semantic(decoded)
        return issues.isEmpty ? .valid(decoded) : .invalid(issues)
    }

    static func program(_ json: String) -> Outcome<ProgramDraft> {
        validate(json, schema: DraftSchemas.programDraftV1, as: ProgramDraft.self) { $0.validationIssues() }
    }

    static func nutritionPlan(_ json: String) -> Outcome<NutritionPlanDraft> {
        validate(json, schema: DraftSchemas.nutritionPlanDraftV1, as: NutritionPlanDraft.self) { $0.validationIssues() }
    }

    /// Schema do contrato sem metadados (`$schema`, `$id`) — forma usada como parâmetros de ferramenta.
    static func toolParameters(fromContract schema: String) -> String {
        guard case var .object(object) = (try? JSONValue.parse(schema)) ?? .null else { return schema }
        object.removeValue(forKey: "$schema")
        object.removeValue(forKey: "$id")
        return JSONValue.object(object).jsonString()
    }
}
