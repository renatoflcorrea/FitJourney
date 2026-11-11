import Foundation

/// Rastro de uma sessão descartada (o registro SwiftData é apagado, SPEC §4.3).
struct SessionTombstone: Codable, Sendable, Hashable {
    var sessionID: UUID
    /// Revisão terminal (a do snapshot `discarded`).
    var lastRevision: Int
    /// `commandID`s aplicados à sessão, incluindo o `discard`.
    var commandIDs: [UUID]
    var discardedAt: Date
}

/// Lista curta e persistida (UserDefaults) de sessões descartadas: comandos atrasados delas são
/// respondidos como duplicados com a revisão terminal e um `start` com o mesmo `sessionID` não a
/// ressuscita — mesmo depois de reabrir o app. `defaults == nil` guarda só em memória.
@MainActor
final class SessionTombstones {
    static let key = "sessionEngine.tombstones"
    /// Sessões descartadas lembradas (as mais recentes).
    static let limit = 5

    private let defaults: UserDefaults?
    private var items: [SessionTombstone]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SessionTombstone].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    func tombstone(for sessionID: UUID) -> SessionTombstone? {
        items.first { $0.sessionID == sessionID }
    }

    func add(_ tombstone: SessionTombstone) {
        items.removeAll { $0.sessionID == tombstone.sessionID }
        items.append(tombstone)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        if let data = try? JSONEncoder().encode(items) { defaults?.set(data, forKey: Self.key) }
    }
}
