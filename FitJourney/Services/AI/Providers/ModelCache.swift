import Foundation
import CryptoKit

struct ModelCache {
    struct Snapshot: Codable, Sendable {
        var models: [String]
        var fetchedAt: Date
        var credentialHash: String
        var baseURL: String?
        /// Metadados explícitos quando o endpoint os fornece; snapshots antigos continuam legíveis.
        var capabilities: [String: AttachmentCapabilities]? = nil
    }
    static let ttl: TimeInterval = 24 * 3600
    var defaults: UserDefaults = .standard
    func key(_ provider: AIProviderID) -> String { "coach.models.\(provider.rawValue).v1" }
    func load(_ provider: AIProviderID) -> Snapshot? {
        guard let data = defaults.data(forKey: key(provider)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    func save(_ snapshot: Snapshot, provider: AIProviderID) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(provider))
        AIAvailability.postChange()
    }
    func clear(_ provider: AIProviderID) {
        defaults.removeObject(forKey: key(provider))
        defaults.removeObject(forKey: key(provider) + ".generation")
    }

    /// Invalida respostas que ainda estavam em voo quando a conta ou a URL mudou. O marcador não
    /// contém credenciais e também é removido ao apagar a chave no Keychain.
    func activate(_ provider: AIProviderID, identity: String) -> String {
        let markerKey = key(provider) + ".generation"
        let prefix = Self.fingerprint(identity) + ":"
        if let marker = defaults.string(forKey: markerKey), marker.hasPrefix(prefix) { return marker }
        let marker = prefix + UUID().uuidString
        defaults.set(marker, forKey: markerKey)
        return marker
    }
    func isCurrent(_ marker: String, provider: AIProviderID) -> Bool {
        defaults.string(forKey: key(provider) + ".generation") == marker
    }
    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
