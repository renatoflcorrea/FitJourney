import Foundation

/// Código de idioma trocado entre iPhone e relógio ("pt-BR" | "en") e o mapeamento para `AppleLanguages`.
/// Só Foundation: compilado no app e no relógio.
enum AppLanguageCode {
    static let portuguese = "pt-BR"
    static let english = "en"
    /// Preferência própria gravada pelo app (`nil`/ausente = Sistema).
    static let preferenceKey = "fj.appLanguage"

    /// Código efetivo de uma lista de localizações (`Bundle.preferredLocalizations`): pt* = "pt-BR", resto = "en".
    static func effective(from localizations: [String]) -> String {
        (localizations.first ?? "pt").lowercased().hasPrefix("pt") ? portuguese : english
    }

    /// Código efetivo do app em execução.
    static var current: String { effective(from: Bundle.main.preferredLocalizations) }

    /// Valor de `AppleLanguages` para um código; `nil` = remover a chave (idioma do sistema). Código inválido = `nil`.
    static func appleLanguages(for code: String?) -> [String]? {
        guard let code = normalized(code) else { return nil }
        return [code]
    }

    /// "pt", "pt-BR", "pt_BR" → "pt-BR"; "en", "en-US" → "en"; outro/vazio → `nil`.
    static func normalized(_ code: String?) -> String? {
        guard let lower = code?.lowercased(), !lower.isEmpty else { return nil }
        if lower.hasPrefix("pt") { return portuguese }
        if lower.hasPrefix("en") { return english }
        return nil
    }

    /// Relógio: só grava `AppleLanguages` quando o código recebido difere do idioma em uso (não fixa à toa na
    /// primeira recepção). Devolve `true` quando gravou algo novo (vale no próximo lançamento). Ausente/inválido = nada.
    @discardableResult
    static func applyReceived(_ code: String?, running: String = AppLanguageCode.current,
                              defaults: UserDefaults = .standard) -> Bool {
        guard let code = normalized(code) else { return false }
        let stored = defaults.string(forKey: preferenceKey)
        if code == running {
            // Já em uso: só desfaz uma gravação anterior pendente (iPhone voltou atrás), sem avisar.
            if let stored, stored != code { write(code, defaults) }
            return false
        }
        guard stored != code else { return false }
        write(code, defaults)
        return true
    }

    private static func write(_ code: String, _ defaults: UserDefaults) {
        defaults.set(code, forKey: preferenceKey)
        defaults.set([code], forKey: "AppleLanguages")
    }
}
