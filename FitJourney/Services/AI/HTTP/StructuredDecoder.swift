import Foundation

/// Decodifica saída de modelo que deveria ser JSON mas pode não ser (porta do fireplaice):
/// remove cercas Markdown, acha o primeiro objeto balanceado e decodifica.
enum StructuredDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let json = extractJSONObject(from: raw) else {
            throw AIError.decoding(context: "\(T.self)", message: "no JSON object found in the response")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw AIError.decoding(context: "\(T.self)", message: "\(error)")
        }
    }

    /// Primeiro objeto JSON balanceado do texto, ignorando chaves dentro de strings.
    static func extractJSONObject(from raw: String) -> String? {
        let stripped = stripCodeFences(raw)
        var scanner = ObjectScanner()
        for index in stripped.indices {
            switch scanner.consume(stripped[index], at: index) {
            case .keepScanning: continue
            case .unbalanced: return nil
            case let .finished(start): return String(stripped[start ... index])
            }
        }
        return nil
    }

    static func stripCodeFences(_ raw: String) -> String {
        guard raw.contains("```") else { return raw }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n")
    }
}

/// Conta a profundidade de chaves ignorando as que aparecem dentro de strings.
private struct ObjectScanner {
    enum Outcome {
        case keepScanning
        case finished(start: String.Index)
        case unbalanced
    }

    private var depth = 0
    private var start: String.Index?
    private var inString = false
    private var escaped = false

    mutating func consume(_ character: Character, at index: String.Index) -> Outcome {
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            return .keepScanning
        }
        switch character {
        case "\"":
            inString = true
        case "{":
            if depth == 0 { start = index }
            depth += 1
        case "}":
            depth -= 1
            if depth == 0, let start { return .finished(start: start) }
            if depth < 0 { return .unbalanced }
        default:
            break
        }
        return .keepScanning
    }
}
