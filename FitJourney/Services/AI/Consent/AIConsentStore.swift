import Foundation

enum AIFeature: String, Codable, Sendable, Hashable, CaseIterable { case importFiles, mealLog, coach }
enum AIDataCategory: String, Codable, Sendable, Hashable, CaseIterable { case profile, workouts, nutrition, health }

extension Notification.Name {
    static let aiConsentChanged = Notification.Name("coach.aiConsentChanged")
}

struct AIConsentStore {
    static let key = "coach.aiConsent.v2"
    struct Record: Codable, Sendable, Equatable {
        var features: [String: Date] = [:]
        var categories: Set<AIDataCategory> = []
        var displayName: String
        var updatedAt: Date
    }
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var records: [String: Record] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }
    func isGranted(_ feature: AIFeature, for recipient: AIRecipient) -> Bool {
        records[recipient.key]?.features[feature.rawValue] != nil
    }
    func categories(for recipient: AIRecipient) -> Set<AIDataCategory> { records[recipient.key]?.categories ?? [] }
    func grant(_ feature: AIFeature, for recipient: AIRecipient, categories: Set<AIDataCategory>? = nil, at: Date = .now) {
        guard recipient.provider != .custom || !(recipient.host ?? "").isEmpty else { return }
        var all = records
        var record = all[recipient.key] ?? Record(displayName: recipient.displayName, updatedAt: at)
        record.features[feature.rawValue] = at
        if let categories { record.categories = categories }
        record.displayName = recipient.displayName
        record.updatedAt = at
        all[recipient.key] = record
        save(all)
    }
    func setCategories(_ categories: Set<AIDataCategory>, for recipient: AIRecipient, at: Date = .now) {
        var all = records
        guard recipient.provider != .custom || !(recipient.host ?? "").isEmpty else { return }
        var record = all[recipient.key] ?? Record(displayName: recipient.displayName, updatedAt: at)
        record.categories = categories
        record.updatedAt = at
        all[recipient.key] = record
        save(all)
    }
    func revoke(_ feature: AIFeature, for recipient: AIRecipient, at: Date = .now) {
        var all = records
        guard var record = all[recipient.key] else { return }
        record.features[feature.rawValue] = nil
        record.updatedAt = at
        all[recipient.key] = record
        save(all)
    }
    func revokeAll(for recipient: AIRecipient) {
        var all = records
        all[recipient.key] = nil
        save(all)
    }
    func forgetOthers(except recipient: AIRecipient) {
        let all = records.filter { $0.key == recipient.key }
        save(all)
    }
    private func save(_ all: [String: Record]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: .aiConsentChanged, object: nil)
        NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
    }
}

extension CoachProfile.Sharing {
    var categories: Set<AIDataCategory> {
        var result: Set<AIDataCategory> = []
        if profile { result.insert(.profile) }
        if workouts { result.insert(.workouts) }
        if nutrition { result.insert(.nutrition) }
        if health { result.insert(.health) }
        return result
    }
    init(categories: Set<AIDataCategory>) {
        self.init(profile: categories.contains(.profile), workouts: categories.contains(.workouts),
                  nutrition: categories.contains(.nutrition), health: categories.contains(.health))
    }
}
