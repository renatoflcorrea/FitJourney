import Foundation

/// Erros da camada de IA. Mensagens nunca carregam segredos: corpos de erro passam por
/// `Redactor` e pela remoção das credenciais exatas do pedido (`HTTPClient`).
enum AIError: Error, Sendable, Hashable {
    /// Falta provedor, modelo ou chave.
    case notConfigured(reason: String)
    /// 401/403: chave inválida ou sem permissão.
    case unauthorized(message: String)
    /// 429, com o atraso sugerido pelo servidor.
    case rateLimited(retryAfter: TimeInterval?)
    /// Demais 4xx: o pedido está errado.
    case badRequest(status: Int, message: String)
    /// 5xx ou erro do provedor no meio do stream (ex.: `overloaded_error`).
    case server(status: Int, message: String)
    /// Falha de transporte (`URLError.Code.rawValue`).
    case network(code: Int, retryable: Bool)
    /// Resposta ilegível.
    case decoding(context: String, message: String)
    case cancelled

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server: true
        case let .network(_, retryable): retryable
        default: false
        }
    }
}

extension AIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .notConfigured(reason):
            String(localized: "Coach não configurado: \(reason)")
        case .unauthorized:
            String(localized: "A chave do provedor foi recusada. Confira a chave em Ajustes.")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                String(localized: "Limite de uso do provedor atingido. Tente de novo em \(Int(retryAfter.rounded())) s.")
            } else {
                String(localized: "Limite de uso do provedor atingido. Tente de novo em instantes.")
            }
        case let .badRequest(status, message):
            String(localized: "O provedor recusou o pedido (\(status)): \(message)")
        case let .server(status, message):
            String(localized: "O provedor está com problemas (\(status)): \(message)")
        case .network:
            String(localized: "Sem conexão com o provedor. Verifique a internet.")
        case .decoding:
            String(localized: "Não foi possível ler a resposta do provedor.")
        case .cancelled:
            String(localized: "Interrompido.")
        }
    }
}

/// Remove padrões de credenciais conhecidos de textos que podem ir para log/UI.
enum Redactor {
    private static let patterns: [String] = [
        #"sk-ant-[A-Za-z0-9._-]{8,}"#,
        #"sk-or-[A-Za-z0-9._-]{8,}"#,
        #"sk-[A-Za-z0-9._-]{8,}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#,
        #"(?i)bearer\s+[A-Za-z0-9._/+-]{12,}"#,
        #"(?i)(x-api-key|authorization)\s*[:=]\s*\S+"#,
        #"[A-Za-z0-9+/_-]{32,}={0,2}"#,
    ]

    static func redact(_ input: String) -> String {
        patterns.reduce(input) { partial, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return partial }
            let range = NSRange(partial.startIndex..., in: partial)
            return regex.stringByReplacingMatches(in: partial, range: range, withTemplate: "<redacted>")
        }
    }
}
