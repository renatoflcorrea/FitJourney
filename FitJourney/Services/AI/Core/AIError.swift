import Foundation

/// Erros da camada de IA. Mensagens nunca carregam segredos: corpos de erro passam por
/// `Redactor` e pela remoção das credenciais exatas do pedido (`HTTPClient`).
enum AIError: Error, Sendable, Hashable {
    /// Falta provedor, modelo ou chave.
    case notConfigured(reason: String)
    /// 401/403: chave inválida ou sem permissão.
    case unauthorized(message: String)
    /// Login do ChatGPT ausente, expirado ou recusado (refresh revogado, 401/403 mesmo após renovar):
    /// a UI pede "Entre de novo".
    case signInRequired
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
    /// A resposta terminou sem poder ser usada (limite de tamanho, recusa, filtro, limite de voltas).
    case incomplete(IncompleteReason)

    enum IncompleteReason: String, Sendable, Hashable {
        case length, refusal, contentFilter, toolRoundLimit
    }

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
        case .signInRequired:
            String(localized: "O login do ChatGPT expirou ou foi recusado. Entre de novo em Ajustes de IA.")
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
        case let .incomplete(reason):
            reason.localizedDescription
        }
    }
}

extension AIError.IncompleteReason {
    var localizedDescription: String {
        switch self {
        case .length: String(localized: "A resposta atingiu o limite de tamanho e foi interrompida.")
        case .refusal: String(localized: "O modelo não quis responder a este pedido. Tente reformular.")
        case .contentFilter: String(localized: "O provedor bloqueou a resposta pelo filtro de conteúdo.")
        case .toolRoundLimit:
            String(localized: "O Coach consultou dados demais nesta resposta e parou. Tente um pedido mais específico.")
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
