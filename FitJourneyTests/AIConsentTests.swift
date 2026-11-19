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

    @Test func openRouterNoEndpointsHasClearError() throws {
        let url = try #require(URL(string: "https://openrouter.ai"))
        let response = try #require(HTTPURLResponse(url: url,
                                                   statusCode: 404, httpVersion: nil, headerFields: nil))
        do {
            try HTTPClient.validate(response, data: Data("No endpoints found matching your data policy".utf8), errorDialect: .openRouter)
            Issue.record("Esperava erro de provedor")
        } catch let AIError.badRequest(_, message) {
            #expect(message.contains("não guardar seus dados"))
        }
    }
}

@MainActor
@Suite struct AIConsentCoreTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "ai-consent-\(UUID().uuidString)")! }
    private func recipient(_ provider: AIProviderID, _ model: String = "", url: String? = nil) -> AIRecipient {
        AIRecipientResolver.resolve(settings: ProviderSettings(provider: provider, models: model.isEmpty ? [:] : [provider: model],
                                                               customBaseURL: url.flatMap(URL.init(string:))))
    }

    @Test func resolutionAndStableKeys() throws {
        #expect(recipient(.openAI).key == "openAI")
        #expect(recipient(.anthropic).key == "anthropic")
        #expect(recipient(.chatGPT).key == "chatGPT")
        #expect(recipient(.chatGPT).key != recipient(.openAI).key)
        #expect(recipient(.openRouter, "google/gemini-a").key == "openRouter:google")
        #expect(recipient(.openCode, "claude-haiku").creator?.name == "Anthropic")
        #expect(recipient(.openCode, "gpt-6").creator?.article == "a")
        #expect(recipient(.custom, url: "http://192.168.1.3/v1").isLocalNetwork)
        #expect(!recipient(.custom, url: "https://example.com/v1").isLocalNetwork)
        #expect(recipient(.custom, url: "https://EXAMPLE.com/v1").key == "custom:example.com")
        #expect(recipient(.openAI, "gpt-5").key == recipient(.openAI, "gpt-6").key)
        #expect(recipient(.openRouter, "google/a").key == recipient(.openRouter, "google/b").key)
        #expect(recipient(.openRouter, "google/a").key != recipient(.openRouter, "openai/b").key)
        #expect(recipient(.openAI).privacyURL?.absoluteString == "https://openai.com/policies/privacy-policy/")
        #expect(recipient(.openRouter, "google/gemini").modelURL?.absoluteString == "https://openrouter.ai/google/gemini")
        for (model, creator) in [("gpt-x", "OpenAI"), ("claude-x", "Anthropic"), ("glm-x", "Z.ai"),
                                 ("qwen-x", "Alibaba (Qwen)"), ("mimo-x", "Xiaomi"), ("deepseek-x", "DeepSeek"),
                                 ("kimi-x", "Moonshot AI"), ("hy-x", "Tencent"), ("minimax-x", "MiniMax"),
                                 ("gemini-x", "Google"), ("grok-x", "xAI"), ("unknown", "unknown")] {
            #expect(recipient(.openCode, model).creator?.name == creator)
        }
    }

    @Test func migrationRevocationAndCategories() throws {
        let defaults = defaults()
        let profiles = CoachProfileStore(defaults: defaults)
        var profile = CoachProfile()
        profile.sharing = .init(workouts: true, nutrition: true)
        profiles.save(profile)
        defaults.set(Date.now, forKey: CoachProfileStore.consentKey)
        #expect(!profiles.hasConsented)
        #expect(profiles.load().sharing.workouts)
        let store = AIConsentStore(defaults: defaults)
        let google = recipient(.openRouter, "google/one")
        let same = recipient(.openRouter, "google/two")
        let other = recipient(.openRouter, "openai/one")
        store.grant(.coach, for: google, categories: [.workouts])
        let data = try #require(defaults.data(forKey: AIConsentStore.key))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect((json[google.key]?["features"] as? [String: Any])?["coach"] != nil)
        #expect(store.isGranted(.coach, for: same))
        #expect(!store.isGranted(.coach, for: other))
        #expect(throws: AIConsentRequired(feature: .coach, recipient: other)) {
            try AIConsentGate(store: store).require(.coach, recipient: other)
        }
        store.grant(.mealLog, for: google)
        store.grant(.importFiles, for: other)
        store.revoke(.coach, for: google)
        #expect(!store.isGranted(.coach, for: same))
        #expect(store.isGranted(.mealLog, for: same))
        #expect(store.categories(for: same) == [.workouts])
        store.forgetOthers(except: google)
        #expect(!store.isGranted(.importFiles, for: other))
        store.revokeAll(for: google)
        #expect(store.records.isEmpty)
    }

    @Test func coachRequiresProviderBeforeConsent() {
        #expect(CoachGate.evaluate(hasConsented: false, readiness: .missingAPIKey(.openAI)) == .needsProvider)
        #expect(CoachGate.evaluate(hasConsented: false, readiness: .ready) == .needsConsent)
    }

    @Test func importAnalyzeAndRevisionUseCurrentDestination() async throws {
        let fixture = try ImportFixture()
        let defaults = defaults()
        let store = AIConsentStore(defaults: defaults)
        let first = recipient(.openAI)
        let second = recipient(.anthropic)
        let current = RecipientBox(first)
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let session = ImportSession(kind: .program, context: fixture.context,
            resolveChat: { ResolvedChat(gateway: gateway, model: "model") }, recipient: { current.value },
            consentStore: store, store: fixture.store)
        try await session.add([fixture.pdf()])
        store.grant(.importFiles, for: second)
        await #expect(throws: ImportError.consentRequired(first)) { try await session.analyze() }
        #expect(gateway.requests.isEmpty)
        store.grant(.importFiles, for: first)
        try await session.analyze()
        try session.answer(.choice("0"), for: "ambiguity.0")
        store.revoke(.importFiles, for: second)
        current.value = second
        await #expect(throws: ImportError.consentRequired(second)) { try await session.reviseWithAI() }
        #expect(gateway.requests.count == 1)
    }

    @Test func mealAnalyzeAndCorrectionRespectRevocation() async throws {
        let fixture = try MealLogPlanFixture()
        let store = AIConsentStore(defaults: defaults())
        let destination = recipient(.openAI)
        let other = recipient(.anthropic)
        let json = FoodLogJSON.draft(meals: [FoodLogJSON.meal(items: [FoodLogJSON.item("Arroz")])])
        let gateway = MealLogFakeGateway([.tool(json)])
        let session = MealLogSession(day: fixture.today, context: fixture.context,
            resolveChat: { ResolvedChat(gateway: gateway, model: "gpt-5") }, isAIAvailable: { true },
            recipient: { destination }, consentStore: store, sharesNutrition: { false })
        session.text = "arroz"
        store.grant(.mealLog, for: other)
        await #expect(throws: MealLogError.consentRequired(destination)) { try await session.analyze() }
        store.grant(.mealLog, for: destination)
        try await session.analyze()
        #expect(session.phase.hasDraft)
        store.revoke(.mealLog, for: destination)
        await #expect(throws: MealLogError.consentRequired(destination)) { try await session.correct("integral") }
        #expect(gateway.requests.count == 1)
    }

    @Test func coachAndToolboxFollowDestination() async throws {
        let fixture = try ToolboxFixture()
        let defaults = defaults()
        let store = AIConsentStore(defaults: defaults)
        let first = recipient(.openAI)
        let second = recipient(.anthropic)
        let current = RecipientBox(first)
        store.grant(.coach, for: first, categories: [.workouts])
        let toolbox = FitnessToolbox(context: fixture.context, sharing: { .init(categories: store.categories(for: current.value)) })
        #expect(toolbox.specs.contains { $0.name == "list_programs" })
        let gateway = ScriptedCoachGateway([[.delta("ok"), .finished(reason: .stop)]])
        let service = CoachConversationService(context: fixture.context, toolbox: toolbox, recipient: { current.value },
            requireConsent: { try AIConsentGate(store: store).require(.coach, recipient: $0) },
            resolveChat: { ResolvedChat(gateway: gateway, model: "model") })
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation))
        current.value = second
        #expect(!toolbox.specs.contains { $0.name == "list_programs" })
        #expect(!(await service.send("oi", in: conversation)))
        #expect(service.lastConsentRequired == AIConsentRequired(feature: .coach, recipient: second))
    }

    @Test func backupDoesNotRestoreConsentAndEraseRemovesIt() async throws {
        let fixture = try BackupFixture(sample: false)
        let store = AIConsentStore(defaults: fixture.defaults)
        let destination = recipient(.openAI)
        store.grant(.coach, for: destination, categories: [.health])
        let prefs = BackupPreferences.collect(from: fixture.defaults)
        let encoded = try JSONEncoder().encode(prefs)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(AIConsentStore.key))
        let document = try await fixture.exporter().makeDocument()
        let exported = try JSONEncoder().encode(document)
        #expect(!String(decoding: exported, as: UTF8.self).contains(AIConsentStore.key))
        let other = defaults()
        BackupPreferences.apply(prefs, profile: BackupPreferences.collectProfile(from: fixture.defaults), mode: .replace, to: other)
        #expect(AIConsentStore(defaults: other).records.isEmpty)
        _ = try await fixture.eraser().eraseAll(options: .init(keepBuiltInCatalog: false))
        #expect(fixture.defaults.data(forKey: AIConsentStore.key) == nil)
    }
}

private struct SwitchingConsentGateway: ChatGateway, StructuredCompleting {
    let onFirstCall: @MainActor @Sendable () -> Void
    var provider: AIProviderID { .openAI }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await onFirstCall()
                continuation.yield(.toolCall(id: "call", name: "list_exercises", argumentsJSON: #"{"query":null}"#))
                continuation.yield(.finished(reason: .toolCalls))
                continuation.finish()
            }
        }
    }
    func complete(_ request: ChatRequest) async throws -> ChatCompletion { throw AIError.cancelled }
}

@MainActor private final class RecipientBox {
    var value: AIRecipient
    init(_ value: AIRecipient) { self.value = value }
}

extension AIConsentCoreTests {
    @Test func coachStopsWhenProviderChangesBetweenRounds() async throws {
        let fixture = try ToolboxFixture()
        let first = AIRecipientResolver.resolve(settings: ProviderSettings(provider: .openAI))
        let second = AIRecipientResolver.resolve(settings: ProviderSettings(provider: .anthropic))
        let box = RecipientBox(first)
        let store = AIConsentStore(defaults: UserDefaults(suiteName: "coach-switch-\(UUID().uuidString)")!)
        store.grant(.coach, for: first)
        let gateway = SwitchingConsentGateway { box.value = second }
        let service = CoachConversationService(context: fixture.context, toolbox: fixture.toolbox(), recipient: { box.value },
            requireConsent: { try AIConsentGate(store: store).require(.coach, recipient: $0) },
            resolveChat: { ResolvedChat(gateway: gateway, model: "model") })
        let conversation = try service.createConversation()
        #expect(!(await service.send("oi", in: conversation)))
        #expect(service.lastConsentRequired == AIConsentRequired(feature: .coach, recipient: second))
        #expect(!conversation.sortedMessages.contains { $0.role == .tool })
    }
}
