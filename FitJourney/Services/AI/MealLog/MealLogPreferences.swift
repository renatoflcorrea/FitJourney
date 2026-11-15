import Foundation

/// Preferências do registro com IA: "Dieta" compartilhada (o plano do dia vai ao provedor) e a oferta única de
/// liberá-la (SPEC §7.x: oferece uma vez, sem insistir). O consentimento e o compartilhamento são os do Coach.
struct MealLogPreferences {
    /// Já mostramos "Permitir comparar com o plano" (persistido; não volta a aparecer).
    static let dietSharingOfferedKey = "fj.mealLog.dietSharingOffered"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var profiles: CoachProfileStore { CoachProfileStore(defaults: defaults) }

    /// "Dieta" ligada em Coach e IA (com consentimento): o plano do dia vai ao provedor.
    var sharesNutrition: Bool { profiles.hasConsented && profiles.load().sharing.nutrition }

    var hasOfferedDietSharing: Bool { defaults.bool(forKey: Self.dietSharingOfferedKey) }

    /// A revisão deve oferecer "Permitir comparar com o plano": há plano no dia, "Dieta" desligada e nunca ofereceu.
    func shouldOfferDietSharing(hasPlan: Bool) -> Bool { hasPlan && !sharesNutrition && !hasOfferedDietSharing }

    /// O usuário viu a oferta (aceitando ou não): não volta a aparecer.
    func markDietSharingOffered() { defaults.set(true, forKey: Self.dietSharingOfferedKey) }

    /// Liga "Dieta" (registra o consentimento se ainda não houver, sem ligar os outros compartilhamentos).
    func enableDietSharing(at date: Date = .now) {
        var sharing = profiles.hasConsented ? profiles.load().sharing : .none
        sharing.nutrition = true
        if profiles.hasConsented {
            var profile = profiles.load()
            profile.sharing = sharing
            profiles.save(profile)
        } else {
            profiles.grantConsent(sharing: sharing, at: date)
        }
        markDietSharingOffered()
        NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
    }

    /// Aceite do aviso "o texto e as fotos vão ao provedor" no primeiro envio: vale como consentimento do Coach com
    /// os quatro compartilhamentos desligados (como a decisão 33).
    func grantConsent(at date: Date = .now) {
        guard !profiles.hasConsented else { return }
        profiles.grantConsent(sharing: .none, at: date)
        NotificationCenter.default.post(name: .coachConsentChanged, object: nil)
    }
}
