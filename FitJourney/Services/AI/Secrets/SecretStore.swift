import Foundation
import Security

/// Nome de um segredo no Keychain (conta). O valor nunca sai do Keychain exceto para o pedido HTTP.
struct SecretKey: RawRepresentable, Sendable, Hashable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static func apiKey(_ provider: AIProviderID) -> SecretKey { SecretKey(rawValue: "apiKey.\(provider.rawValue)") }
    /// Blob JSON com os tokens do login ChatGPT (`ChatGPTCredentials`). Nunca sai do Keychain.
    static let chatGPTAuth = SecretKey(rawValue: "chatGPT.auth")
}

/// Armazenamento de segredos. `set(nil)` apaga.
protocol SecretStore: Sendable {
    func string(for key: SecretKey) throws -> String?
    func set(_ value: String?, for key: SecretKey) throws
}

extension SecretStore {
    func contains(_ key: SecretKey) -> Bool {
        guard let value = try? string(for: key) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SecretStoreError: Error, Sendable, Hashable {
    case keychain(status: Int32)
}

/// Keychain (iOS: só o keychain de proteção de dados). Credenciais vivem aqui e em nenhum outro
/// lugar — nunca em UserDefaults, no banco, em log ou exportação.
struct KeychainSecretStore: SecretStore {
    static let defaultService = "br.com.renatocorrea.fitjourney"
    let service: String

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    func string(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status: status)
        }
    }

    func set(_ value: String?, for key: SecretKey) throws {
        let previous = try string(for: key)
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = previous != ((normalized?.isEmpty ?? true) ? nil : normalized)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status: status)
            }
            if status == errSecSuccess {
                if changed { clearModelCache(for: key, previous: previous, current: nil) }
                AIAvailability.postChange()
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Só neste aparelho, depois do primeiro desbloqueio; não vai para backup/iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(for: key)
            insert.merge(attributes) { current, _ in current }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        // A lista anterior pertence à credencial anterior, não à conta recém-configurada.
        if changed { clearModelCache(for: key, previous: previous, current: value) }
        AIAvailability.postChange()
    }

    private func clearModelCache(for key: SecretKey, previous: String?, current: String?) {
        if key == .chatGPTAuth,
           previous.flatMap(ChatGPTCredentials.decode)?.accountID != current.flatMap(ChatGPTCredentials.decode)?.accountID {
            ModelCache().clear(.chatGPT)
        }
        for provider in AIProviderID.allCases where key == .apiKey(provider) {
            ModelCache().clear(provider)
            if provider == .openCode { UserDefaults.standard.removeObject(forKey: OpenCodeModelCache.key) }
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            // Não sincronizável: a chave do provedor não deve migrar para outros aparelhos sem pedido.
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Em memória, para testes e previews.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    init(_ values: [SecretKey: String] = [:]) { self.values = values }

    func string(for key: SecretKey) throws -> String? { lock.withLock { values[key] } }

    func set(_ value: String?, for key: SecretKey) throws {
        lock.withLock { values[key] = (value?.isEmpty ?? true) ? nil : value }
    }
}
