import Foundation

/// Perfil opcional usado como contexto do Coach (SPEC §7). Tudo opcional; nada é obrigatório.
/// Guardado em UserDefaults (não é segredo; é dado pessoal que só vai ao provedor quando o
/// modelo chama `get_profile` e o usuário permitiu compartilhar).
struct CoachProfile: Codable, Sendable, Hashable {
    enum Sex: String, Codable, Sendable, Hashable, CaseIterable { case female, male, other }
    enum Level: String, Codable, Sendable, Hashable, CaseIterable { case beginner, intermediate, advanced }

    var age: Int?
    var sex: Sex?
    var heightCm: Double?
    var weightKg: Double?
    var level: Level?
    var goal: String?
    /// Restrições, lesões, condições de saúde (texto livre).
    var restrictions: String?
    /// Equipamentos disponíveis (texto livre: "academia completa", "halteres em casa"…).
    var equipment: String?
    var daysPerWeek: Int?
    var minutesPerSession: Int?
    /// Preferências alimentares e alergias.
    var foodPreferences: String?

    /// O que o usuário aceita enviar ao provedor (SPEC §7, privacidade). **Tudo nasce desligado**;
    /// a UI pede consentimento na primeira abertura (`CoachProfileStore.grantConsent(sharing:)`).
    var sharing: Sharing = Sharing()

    struct Sharing: Codable, Sendable, Hashable {
        var profile: Bool = false
        var workouts: Bool = false
        var nutrition: Bool = false
        var health: Bool = false

        init(profile: Bool = false, workouts: Bool = false, nutrition: Bool = false, health: Bool = false) {
            self.profile = profile
            self.workouts = workouts
            self.nutrition = nutrition
            self.health = health
        }

        static let none = Sharing()
    }

    init() {}

    var isEmpty: Bool {
        age == nil && sex == nil && heightCm == nil && weightKg == nil && level == nil
            && (goal ?? "").isEmpty && (restrictions ?? "").isEmpty && (equipment ?? "").isEmpty
            && daysPerWeek == nil && minutesPerSession == nil && (foodPreferences ?? "").isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case age, sex, heightCm, weightKg, level, goal, restrictions, equipment, daysPerWeek, minutesPerSession
        case foodPreferences, sharing
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age = try? c.decodeIfPresent(Int.self, forKey: .age)
        sex = try? c.decodeIfPresent(Sex.self, forKey: .sex)
        heightCm = try? c.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg = try? c.decodeIfPresent(Double.self, forKey: .weightKg)
        level = try? c.decodeIfPresent(Level.self, forKey: .level)
        goal = try? c.decodeIfPresent(String.self, forKey: .goal)
        restrictions = try? c.decodeIfPresent(String.self, forKey: .restrictions)
        equipment = try? c.decodeIfPresent(String.self, forKey: .equipment)
        daysPerWeek = try? c.decodeIfPresent(Int.self, forKey: .daysPerWeek)
        minutesPerSession = try? c.decodeIfPresent(Int.self, forKey: .minutesPerSession)
        foodPreferences = try? c.decodeIfPresent(String.self, forKey: .foodPreferences)
        sharing = (try? c.decodeIfPresent(Sharing.self, forKey: .sharing)) ?? Sharing()
    }
}

/// Persistência do perfil e do consentimento em UserDefaults (chaves versionadas).
struct CoachProfileStore {
    static let key = "coach.profile.v1"
    static let consentKey = "coach.consent.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// O usuário já passou pela tela de consentimento (aceitando ou não compartilhar dados).
    var hasConsented: Bool { defaults.object(forKey: Self.consentKey) as? Date != nil }

    /// Registra o consentimento e o que o usuário escolheu compartilhar.
    func grantConsent(sharing: CoachProfile.Sharing, at date: Date = .now) {
        var profile = load()
        profile.sharing = sharing
        save(profile)
        defaults.set(date, forKey: Self.consentKey)
    }

    /// Revoga: desliga todo compartilhamento e volta a pedir consentimento.
    func revokeConsent() {
        var profile = load()
        profile.sharing = .none
        save(profile)
        defaults.removeObject(forKey: Self.consentKey)
    }

    func load() -> CoachProfile {
        guard let data = defaults.data(forKey: Self.key),
              let profile = try? JSONDecoder().decode(CoachProfile.self, from: data) else { return CoachProfile() }
        return profile
    }

    func save(_ profile: CoachProfile) {
        defaults.set(try? JSONEncoder().encode(profile), forKey: Self.key)
    }
}
