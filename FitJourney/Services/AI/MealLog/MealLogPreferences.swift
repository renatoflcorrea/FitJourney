import Foundation

/// Preferências do registro com IA: "Dieta" compartilhada (o plano do dia vai ao provedor) e a oferta única de
/// liberá-la (SPEC §7.x: oferece uma vez, sem insistir). Dieta é uma categoria do destino atual.
struct MealLogPreferences {
    /// Já mostramos "Permitir comparar com o plano" (persistido; não volta a aparecer).
    static let dietSharingOfferedKey = "fj.mealLog.dietSharingOffered"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// "Dieta" ligada em Coach e IA (com consentimento): o plano do dia vai ao provedor.
    private var recipient: AIRecipient { AIRecipientResolver.resolve(settings: ProviderSettingsStore(defaults: defaults).load()) }
    var sharesNutrition: Bool { AIConsentStore(defaults: defaults).categories(for: recipient).contains(.nutrition) }

    var hasOfferedDietSharing: Bool { defaults.bool(forKey: Self.dietSharingOfferedKey) }

    /// A revisão deve oferecer "Permitir comparar com o plano": há plano no dia, "Dieta" desligada e nunca ofereceu.
    func shouldOfferDietSharing(hasPlan: Bool) -> Bool { hasPlan && !sharesNutrition && !hasOfferedDietSharing }

    /// O usuário viu a oferta (aceitando ou não): não volta a aparecer.
    func markDietSharingOffered() { defaults.set(true, forKey: Self.dietSharingOfferedKey) }

    /// Liga somente a categoria Dieta, sem conceder qualquer uso.
    func enableDietSharing(at date: Date = .now) {
        let store = AIConsentStore(defaults: defaults)
        var categories = store.categories(for: recipient)
        categories.insert(.nutrition)
        store.setCategories(categories, for: recipient, at: date)
        markDietSharingOffered()
        NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
    }

    /// Aceite do aviso de envio do registro, apenas para esse uso e destino.
    func grantConsent(at date: Date = .now) {
        AIConsentStore(defaults: defaults).grant(.mealLog, for: recipient, at: date)
        NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
    }
}
