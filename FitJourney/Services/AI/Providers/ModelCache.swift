import Foundation
import CryptoKit

struct ModelCache {
    struct Snapshot: Codable, Sendable {
        var models: [String]
        var fetchedAt: Date
        var credentialHash: String
        var baseURL: String?
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
    func clear(_ provider: AIProviderID) { defaults.removeObject(forKey: key(provider)) }
    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
