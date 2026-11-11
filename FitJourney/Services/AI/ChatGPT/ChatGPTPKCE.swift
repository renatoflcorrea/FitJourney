import CryptoKit
import Foundation

/// PKCE (RFC 7636) com S256 para o login ChatGPT (porta de `FireplaceProviders/ChatGPT/ChatGPTPKCE.swift`;
/// aqui o SHA-256 vem do CryptoKit, já que o app é só iOS).
struct ChatGPTPKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Verificador de 64 bytes aleatórios (86 caracteres base64url, dentro do limite 43…128).
    static func generate() -> ChatGPTPKCE {
        ChatGPTPKCE(verifier: base64URL(randomBytes(64)))
    }

    static func randomState() -> String {
        base64URL(randomBytes(32))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
