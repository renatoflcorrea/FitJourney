import Foundation

struct AIConsentRequired: Error, Sendable, Hashable {
    let feature: AIFeature
    let recipient: AIRecipient
}

struct AIConsentGate {
    let store: AIConsentStore
    init(store: AIConsentStore = AIConsentStore()) { self.store = store }
    func require(_ feature: AIFeature, recipient: AIRecipient) throws {
        guard store.isGranted(feature, for: recipient) else {
            throw AIConsentRequired(feature: feature, recipient: recipient)
        }
    }
}
