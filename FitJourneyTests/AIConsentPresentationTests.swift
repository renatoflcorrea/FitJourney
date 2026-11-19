import Foundation
import Testing
@testable import FitJourney

@Suite struct AIConsentPresentationTests {
    @Test func policyURLUsesAppLanguage() {
        #expect(AIConsentPresentation.appPolicyURL(language: AppLanguageCode.portuguese).absoluteString ==
                "https://renatocorrea.com.br/FitJourney/pt/privacy/#ia")
        #expect(AIConsentPresentation.appPolicyURL(language: AppLanguageCode.english).absoluteString ==
                "https://renatocorrea.com.br/FitJourney/en/privacy/#ai")
    }
}
