import Foundation

/// Idioma do app (Ajustes › Geral › Idioma). Sistema (padrão) segue o iPhone; Português (Brasil) e English
/// fixam o idioma do app. O iOS só aplica `AppleLanguages` ao reabrir, então a troca pede reinício.
enum AppLanguagePreference: String, CaseIterable, Sendable {
    case system, portuguese, english

    static let key = AppLanguageCode.preferenceKey
    static let appleLanguagesKey = "AppleLanguages"

    /// Código de fio ("pt-BR"/"en"); `nil` = Sistema.
    var code: String? {
        switch self {
        case .system: nil
        case .portuguese: AppLanguageCode.portuguese
        case .english: AppLanguageCode.english
        }
    }

    /// Preferência gravada (`fj.appLanguage`); ausente/inválida = Sistema.
    static func current(_ defaults: UserDefaults = .standard) -> AppLanguagePreference {
        switch AppLanguageCode.normalized(defaults.string(forKey: key)) {
        case AppLanguageCode.portuguese: .portuguese
        case AppLanguageCode.english: .english
        default: .system
        }
    }

    /// Grava a escolha: `fj.appLanguage` + `AppleLanguages` (`["pt-BR"]`/`["en"]`) ou remove ambos (Sistema).
    func apply(to defaults: UserDefaults = .standard) {
        if let code {
            defaults.set(code, forKey: Self.key)
            defaults.set(AppLanguageCode.appleLanguages(for: code), forKey: Self.appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        }
    }

    /// Texto do seletor (cada idioma no próprio nome; Sistema localizado pelo catálogo).
    var title: String {
        switch self {
        case .system: String(localized: "Sistema")
        case .portuguese: "Português (Brasil)"
        case .english: "English"
        }
    }
}
