import Foundation

/// Endereço da seção de IA da política, no idioma escolhido para o app.
enum AIConsentPresentation {
    static func appPolicyURL(language: String = AppLanguageCode.current) -> URL {
        let path = language == AppLanguageCode.english ? "en/privacy/#ai" : "pt/privacy/#ia"
        return URL(string: "https://renatocorrea.com.br/FitJourney/\(path)")!
    }
}
