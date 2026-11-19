import Foundation
import Testing
@testable import FitJourney

struct AIOpenCodeTests {
    private let fixture = #"{"object":"list","data":[{"id":"gpt-6-luna","type":"chat","modalities":{"input":["text","image/jpeg","application/pdf"]},"capabilities":{"structured_output":true},"cost":{"text":{"input":{"price":0.1},"output":{"price":0.5}}},"go":{"training":false,"zdr":false}},{"id":"glm-5.3","type":"chat","modalities":{"input":["text"]}},{"id":"muse-spark-1.3-contributor","type":"chat","modalities":{"input":["image/png"]},"go":{"training":true}},{"id":"hy4-flash-free","type":"chat","cost":null,"go":null},{"id":"other","type":"embedding"},{"id":"gpt-6-luna"},{"id":"cheap","modalities":{"input":["image/png"]},"cost":{"text":{"input":{"price":0.01}}}},{"id":"gpt-text","modalities":{"input":["text"]}}]}"#

    @Test func parseAndPicker() {
        let models = OpenCodeModelCatalog.parse(Data(fixture.utf8))
        #expect(models.count == 5)
        #expect(models[0].readsImages && models[0].structuredOutput)
        #expect(models[2].trainsOnData)
        #expect(OpenCodeModelCatalog.pickerModels(discovered: models) == ["gpt-6-luna", "cheap"])
        #expect(OpenCodeModelCatalog.pickerModels(discovered: nil) == OpenCodeGo.suggestedModels)
        let cache = OpenCodeModelCache.Snapshot(fetchedAt: .now, models: models)
        #expect(!OpenCodeModelCatalog.capabilities(model: "gpt-text", cache: cache).supportsImages)
        #expect(OpenCodeModelCatalog.capabilities(model: "gpt-unknown", cache: cache).supportsImages)
        #expect(!OpenCodeModelCatalog.capabilities(model: "gpt-6-luna", cache: cache).supportsPDF)
        #expect(OpenCodeModelCatalog.trainsOnData(model: "muse-spark-1.3-contributor", cache: cache))
    }
    @Test func errorDialect() throws {
        let url = URL(string: "https://example.com")!
        func error(_ status: Int, _ body: String = "", _ retry: String? = nil, dialect: HTTPClient.ErrorDialect = .openCode) -> AIError? {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: retry.map { ["Retry-After": $0] })!
            do { try HTTPClient.validate(response, data: Data(body.utf8), errorDialect: dialect); return nil }
            catch { return error as? AIError }
        }
        if case .unauthorized = error(401) {} else { Issue.record("401") }
        if case .notConfigured = error(403, "free tier") {} else { Issue.record("403 free") }
        if case .unauthorized = error(403) {} else { Issue.record("403") }
        if case .notConfigured = error(402) {} else { Issue.record("402") }
        #expect(error(429, "", "5") == .rateLimited(retryAfter: 5))
        #expect(error(429) == .usageLimitReached(retryAfter: nil))
        #expect(error(429, "", "3600") == .usageLimitReached(retryAfter: 3600))
        #expect(error(429, dialect: .standard) == .rateLimited(retryAfter: nil))
        #expect(HTTPClient.RetryPolicy.standard.delay(for: AIError.usageLimitReached(retryAfter: 3600), attempt: 0) == nil)
    }
    @Test func listerCacheAndFailure() async {
        let suite = "OpenCodeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = OpenCodeGo.modelsURL.host()!
        let client = HTTPClient(session: StubURLProtocol.makeSession())
        StubURLProtocol.enqueue([.json(fixture)], host: host)
        let lister = OpenCodeModelLister(apiKey: "test", client: client, defaults: UserDefaults(suiteName: suite)!)
        let first = await lister.discover()
        #expect(first.models.count == 5 && !first.keyRejected)
        _ = await lister.discover()
        #expect(StubURLProtocol.requests(host: host).count == 1)
        let cache = OpenCodeModelCache(defaults: defaults)
        cache.save(.init(fetchedAt: .distantPast, models: first.models))
        StubURLProtocol.enqueue([.json("{}", status: 401)], host: host)
        let rejected = await lister.discover()
        #expect(rejected.keyRejected && rejected.models == first.models)
        #expect(cache.load()?.fetchedAt == .distantPast)
    }
}
