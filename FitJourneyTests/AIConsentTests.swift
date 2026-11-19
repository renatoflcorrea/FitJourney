import Foundation
import Testing
@testable import FitJourney

@Suite struct AIConsentTests {
    @Test func openRouterDataCollectionPreferenceIsEncodedForEveryChatMode() throws {
        let configuration = EndpointConfiguration(
            provider: .openRouter, baseURL: try #require(URL(string: "https://openrouter.ai/api/v1")),
            auth: .none, quirks: ProviderQuirks(denyDataCollection: true))
        let gateway = OpenAICompatibleChatGateway(configuration: configuration)
        for stream in [false, true] {
            let request = try gateway.makeRequest(ChatRequest(model: "example/model", messages: [.user("oi")]), stream: stream)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let provider = try #require(json["provider"] as? [String: String])
            #expect(provider["data_collection"] == "deny")
        }
    }

    @Test func otherProvidersDoNotSendRouterPreference() throws {
        let configuration = EndpointConfiguration(
            provider: .openAI, baseURL: try #require(URL(string: "https://example.com/v1")), auth: .none)
        let request = try OpenAICompatibleChatGateway(configuration: configuration)
            .makeRequest(ChatRequest(model: "model", messages: [.user("oi")]), stream: false)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["provider"] == nil)
    }
}
