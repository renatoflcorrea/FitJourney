import Foundation
import Testing
@testable import FitJourney

/// Cópia do consentimento de IA (proposta `ai-consent-review.md` §3). O esquema de testes roda em pt-BR.
@MainActor
@Suite struct AIConsentPresentationTests {
    private func recipient(_ provider: AIProviderID, _ model: String = "", url: String? = nil) -> AIRecipient {
        AIRecipientResolver.resolve(settings: ProviderSettings(provider: provider, models: model.isEmpty ? [:] : [provider: model],
                                                               customBaseURL: url.flatMap(URL.init(string:))))
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "ai-consent-ui-\(UUID().uuidString)")! }

    // MARK: Política do FitJourney

    @Test func policyURLUsesAppLanguage() {
        #expect(AIConsentPresentation.appPolicyURL(language: AppLanguageCode.portuguese).absoluteString ==
                "https://renatocorrea.com.br/FitJourney/pt/privacy/#ia")
        #expect(AIConsentPresentation.appPolicyURL(language: AppLanguageCode.english).absoluteString ==
                "https://renatocorrea.com.br/FitJourney/en/privacy/#ai")
    }

    @Test func acceptanceSentenceNamesThePolicyAndLinksToIt() {
        let acceptance = AIConsentPresentation.acceptance(language: AppLanguageCode.portuguese)
        #expect(acceptance.sentence == "Ao tocar em Permitir, você concorda com o envio descrito acima e com a Política de Privacidade do FitJourney.")
        #expect(acceptance.sentence.contains(acceptance.linkTitle))
        #expect(acceptance.url.absoluteString.hasSuffix("/pt/privacy/#ia"))
        #expect(AIConsentPresentation.acceptance(language: AppLanguageCode.english).url.absoluteString.hasSuffix("/en/privacy/#ai"))
        let content = AIConsentPresentation.content(for: .coach(previous: nil), recipient: recipient(.openAI, "gpt-6-luna"))
        #expect(content.acceptance == AIConsentPresentation.acceptance())
    }

    // MARK: Os seis destinos

    @Test func openAIAndAnthropicAreOneCompanyHop() throws {
        for (provider, name, policy) in [(AIProviderID.openAI, "OpenAI", "https://openai.com/policies/privacy-policy/"),
                                         (.anthropic, "Anthropic", "https://www.anthropic.com/legal/privacy")] {
            let target = recipient(provider, "modelo-x")
            #expect(AIConsentPresentation.destination(target, language: AppLanguageCode.portuguese) == "a \(name)")
            #expect(AIConsentPresentation.destination(target, language: AppLanguageCode.english) == name)
            let hops = AIConsentPresentation.hops(target)
            #expect(hops.count == 1)
            let hop = try #require(hops.first)
            #expect(hop.kind == .company)
            #expect(hop.name == name)
            #expect(hop.role == "Executa o modelo modelo-x.")
            #expect(hop.links.map(\.url.absoluteString) == [policy])
            #expect(hop.links.first?.identifier == "aiConsent.policyLink.primary")
            #expect(hop.links.first?.accessibilityLabel == "Política de privacidade: \(name)")
            #expect(AIConsentPresentation.note(target) == nil)
        }
    }

    @Test func openRouterShowsRouterAndModelCreator() throws {
        let target = recipient(.openRouter, "google/gemini-3-flash")
        #expect(AIConsentPresentation.destination(target, language: AppLanguageCode.portuguese) == "o OpenRouter")
        #expect(AIConsentPresentation.company(target) == "OpenRouter")
        let hops = AIConsentPresentation.hops(target)
        #expect(hops.map(\.kind) == [.router, .modelHost])
        #expect(hops[0].name == "OpenRouter")
        #expect(hops[0].role.contains("não guarda seus dados"))
        #expect(hops[0].links.first?.url.absoluteString == "https://openrouter.ai/privacy")
        #expect(hops[1].name == "Google")
        #expect(hops[1].role == "Criou o modelo google/gemini-3-flash.")
        let modelLink = try #require(hops[1].links.first)
        #expect(modelLink.identifier == "aiConsent.policyLink.secondary")
        #expect(modelLink.url.absoluteString == "https://openrouter.ai/google/gemini-3-flash")
        #expect(modelLink.title == "Quem executa este modelo")
    }

    @Test func openCodeShowsAnomalyAndModelCreator() {
        let target = recipient(.openCode, "claude-haiku-5-5")
        #expect(AIConsentPresentation.destination(target, language: AppLanguageCode.portuguese) == "o OpenCode")
        let hops = AIConsentPresentation.hops(target)
        #expect(hops.map(\.name) == ["OpenCode (Anomaly)", "Anthropic"])
        #expect(hops[0].role == "Recebe e repassa ao serviço que executa o modelo.")
        #expect(hops[0].links.map(\.url.absoluteString) == ["https://opencode.ai/legal/privacy-policy"])
        #expect(hops[1].role == "Criou o modelo claude-haiku-5-5.")
        #expect(hops[1].links.isEmpty)
        let notice = AIConsentPresentation.importNotice(target)
        #expect(notice.message.hasSuffix("OpenCode repassa ao serviço que executa o modelo (Anthropic)."))
    }

    @Test func customServerShowsHostAndUnknownOperatorNote() {
        let local = recipient(.custom, "llama3.1", url: "http://192.168.0.10:11434/v1")
        let internet = recipient(.custom, "llama3.1", url: "https://llm.example.com/v1")
        #expect(AIConsentPresentation.destination(local) == "o servidor em 192.168.0.10")
        let localHops = AIConsentPresentation.hops(local)
        #expect(localHops.map(\.kind) == [.localServer])
        #expect(localHops[0].name == "192.168.0.10")
        #expect(localHops[0].role == "Servidor na sua rede local, configurado por você.")
        #expect(localHops[0].links.isEmpty)
        let internetHops = AIConsentPresentation.hops(internet)
        #expect(internetHops.map(\.kind) == [.server])
        #expect(internetHops[0].name == "llm.example.com")
        #expect(internetHops[0].role == "Servidor que você configurou.")
        for target in [local, internet] {
            #expect(AIConsentPresentation.note(target) == "O FitJourney não sabe quem opera este servidor nem como ele trata os dados.")
        }
    }

    @Test func chatGPTLoginIsOpenAIAccountWithDataControlsNote() {
        let target = recipient(.chatGPT, "gpt-6-luna")
        #expect(AIConsentPresentation.destination(target) == "a OpenAI (conta ChatGPT)")
        let hops = AIConsentPresentation.hops(target)
        #expect(hops.count == 1)
        #expect(hops[0].name == "OpenAI (sua conta ChatGPT)")
        #expect(hops[0].links.first?.url.absoluteString == "https://openai.com/policies/privacy-policy/")
        #expect(AIConsentPresentation.note(target) == "Os controles de dados da sua conta ChatGPT valem para estes envios.")
    }

    @Test func portugueseArticleFollowsTheRecipient() {
        let openAI = recipient(.openAI)
        let content = AIConsentPresentation.content(for: .importFiles(kind: .program, fileCount: 1), recipient: openAI,
                                                    language: AppLanguageCode.portuguese)
        #expect(content.title == "Enviar a ficha para a OpenAI?")
        let router = AIConsentPresentation.content(for: .importFiles(kind: .nutrition, fileCount: 1),
                                                   recipient: recipient(.openRouter, "openai/gpt-6-luna"))
        #expect(router.title == "Enviar a dieta para o OpenRouter?")
        #expect(router.footnote.hasPrefix("Sua escolha vale para as próximas importações com o OpenRouter;"))
    }

    // MARK: Linhas por uso

    @Test func importRowsCountFilesAndListWhatIsNotSent() {
        let target = recipient(.openAI)
        let one = AIConsentPresentation.content(for: .importFiles(kind: .program, fileCount: 1), recipient: target)
        #expect(one.rows.map(\.id) == ["files", "answers", "catalog"])
        #expect(one.rows[0].title == "O arquivo que você escolheu")
        #expect(one.notSent?.isSent == false)
        #expect(one.notSent?.title.contains("Saúde") == true)
        #expect(one.categories.isEmpty)
        let three = AIConsentPresentation.content(for: .importFiles(kind: .program, fileCount: 3), recipient: target)
        #expect(three.rows[0].title == "Os 3 arquivos que você escolheu")
        let diet = AIConsentPresentation.content(for: .importFiles(kind: .nutrition, fileCount: 2), recipient: target)
        #expect(diet.rows.map(\.id) == ["files", "answers"], "o catálogo de exercícios só vai na importação de treino")
        #expect(one.hops == AIConsentPresentation.hops(target))
    }

    @Test func mealLogDietRowOnlyWhenDietIsAllowed() {
        let target = recipient(.anthropic)
        let without = AIConsentPresentation.content(for: .mealLog(sharesDiet: false), recipient: target)
        #expect(without.title == "Enviar a refeição para a Anthropic?")
        #expect(without.rows.map(\.id) == ["text", "photos", "date"])
        #expect(without.notSent?.title.contains("plano alimentar") == true)
        let with = AIConsentPresentation.content(for: .mealLog(sharesDiet: true), recipient: target)
        #expect(with.rows.map(\.id) == ["text", "photos", "date", "plan"])
        #expect(with.rows.last?.detail == "Porque você permitiu Dieta para a Anthropic.")
        #expect(with.notSent?.title.contains("plano alimentar") == false)
    }

    @Test func coachHasFourCategoriesAndExtraHistoryRowWhenRecipientChanged() {
        let current = recipient(.openAI)
        let content = AIConsentPresentation.content(for: .coach(previous: nil), recipient: current)
        #expect(content.title == "Enviar suas mensagens para a OpenAI?")
        #expect(content.rows.map(\.id) == ["messages"])
        #expect(content.categories.map(\.category) == [.profile, .workouts, .nutrition, .health])
        #expect(content.categoriesCaption == "O Coach também pode ler, se você ligar:")
        let sameRecipient = AIConsentPresentation.content(for: .coach(previous: recipient(.openAI, "outro")), recipient: current)
        #expect(sameRecipient.rows.count == 1)
        let changed = AIConsentPresentation.content(for: .coach(previous: recipient(.anthropic)), recipient: current)
        #expect(changed.rows.map(\.id) == ["messages", "history"])
        #expect(changed.rows[1].title == "O histórico desta conversa, que começou com a Anthropic")
    }

    @Test func healthCopyMatchesWhatTheToolsSend() {
        let health = AIConsentPresentation.category(.health).detail
        #expect(!health.localizedCaseInsensitiveContains("sono"))
        for item in ["treinos", "minutos", "FC média e em repouso", "energia ativa", "passos"] {
            #expect(health.contains(item))
        }
    }

    @Test func dietCategorySheetNamesRecipient() {
        let content = AIConsentPresentation.content(for: .dietCategory, recipient: recipient(.openCode, "glm-5"))
        #expect(content.title == "Permitir que o OpenCode veja sua dieta?")
        #expect(content.rows.map(\.id) == ["nutrition"])
        #expect(content.hops.last?.name == "Z.ai")
    }

    // MARK: Permitir e negar

    @Test func allowGrantsOnlyThatFeatureForThatRecipient() {
        let store = AIConsentStore(defaults: defaults())
        let openAI = recipient(.openAI)
        let anthropic = recipient(.anthropic)
        AIConsentPresentation.grant(.importFiles(kind: .program, fileCount: 1), for: openAI, store: store)
        #expect(store.isGranted(.importFiles, for: openAI))
        #expect(!store.isGranted(.mealLog, for: openAI))
        #expect(!store.isGranted(.coach, for: openAI))
        #expect(!store.isGranted(.importFiles, for: anthropic))
        #expect(store.categories(for: openAI).isEmpty)

        AIConsentPresentation.grant(.dietCategory, for: anthropic, store: store)
        #expect(store.categories(for: anthropic) == [.nutrition])
        #expect(AIFeature.allCases.allSatisfy { !store.isGranted($0, for: anthropic) }, "a categoria não concede uso")

        AIConsentPresentation.grant(.coach(previous: nil), for: anthropic, categories: [.workouts], store: store)
        #expect(store.isGranted(.coach, for: anthropic))
        #expect(store.categories(for: anthropic) == [.workouts])
    }

    @Test func coachTogglesStartFromStoredOrLegacyChoices() {
        let legacy = CoachProfile.Sharing(workouts: true, health: true)
        #expect(AIConsentPresentation.initialCoachCategories(stored: [], legacy: legacy) == [.workouts, .health])
        #expect(AIConsentPresentation.initialCoachCategories(stored: [.nutrition], legacy: legacy) == [.nutrition])
        #expect(AIConsentPresentation.initialCoachCategories(stored: [], legacy: .init()).isEmpty)
    }

    @Test func promptStateDenyShowsNoticeAndAllowClearsIt() {
        var state = AIConsentPromptState()
        let target = recipient(.openAI)
        state.ask(.importFiles(kind: .program, fileCount: 2), recipient: target)
        #expect(state.prompt?.recipient == target)
        state.deny()
        #expect(state.prompt == nil)
        #expect(state.denied)
        state.ask(.importFiles(kind: .program, fileCount: 2), recipient: target)
        #expect(state.denied, "o aviso continua até permitir")
        state.allow()
        #expect(state.prompt == nil)
        #expect(!state.denied)
    }

    @Test func deniedImportKeepsTheFilesAndSendsNothing() async throws {
        let fixture = try ImportFixture()
        let store = AIConsentStore(defaults: defaults())
        let target = recipient(.openCode, "claude-haiku-5-5")
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let session = ImportSession(kind: .program, context: fixture.context,
                                    resolveChat: { ResolvedChat(gateway: gateway, model: "claude-haiku-5-5") },
                                    recipient: { target }, consentStore: store, store: fixture.store)
        try await session.add([fixture.pdf(), fixture.pdf()])
        var state = AIConsentPromptState()
        do {
            try await session.analyze()
            Issue.record("Esperava pedir permissão")
        } catch let ImportError.consentRequired(asked) {
            state.ask(.importFiles(kind: session.kind, fileCount: session.attachments.count), recipient: asked)
        }
        #expect(state.prompt?.recipient == target)
        state.deny()
        #expect(state.denied)
        #expect(session.attachments.count == 2)
        #expect(session.phase == .selecting)
        #expect(gateway.requests.isEmpty)
        #expect(!store.isGranted(.importFiles, for: target))
        let notice = AIConsentPresentation.importDenied(kind: .program)
        #expect(notice.title == "Nada foi enviado")
        #expect(notice.message.contains("à mão"))

        // Analisar de novo pergunta outra vez; depois de Permitir, segue com os mesmos arquivos.
        await #expect(throws: ImportError.consentRequired(target)) { try await session.analyze() }
        AIConsentPresentation.grant(.importFiles(kind: .program, fileCount: 2), for: target, store: store)
        state.allow()
        try await session.analyze()
        #expect(gateway.requests.count == 1)
    }

    // MARK: Ajustes

    @Test func settingsSummaryListsFeaturesAndCategories() {
        let target = recipient(.openAI)
        #expect(AIConsentPresentation.settingsSummary(recipient: target, record: nil) == "Nada permitido")
        let record = AIConsentStore.Record(features: [AIFeature.importFiles.rawValue: .now, AIFeature.coach.rawValue: .now],
                                           categories: [.nutrition, .workouts], displayName: "OpenAI", updatedAt: .now)
        #expect(AIConsentPresentation.settingsSummary(recipient: target, record: record) == "OpenAI · Importar, Coach (Treinos, Dieta)")
        #expect(AIConsentPresentation.permissionSummary(features: [], categories: [.nutrition]) == "(Dieta)")
    }

    @Test func storedKeysRoundTripToRecipients() throws {
        for target in [recipient(.openAI), recipient(.anthropic), recipient(.chatGPT), recipient(.openRouter, "google/gemini"),
                       recipient(.openCode, "glm-5"), recipient(.custom, url: "https://llm.example.com/v1")] {
            let rebuilt = try #require(AIConsentPresentation.recipient(forKey: target.key))
            #expect(rebuilt.key == target.key)
        }
        #expect(AIConsentPresentation.recipient(forKey: "desconhecido") == nil)
    }

    @Test func conversationRecipientComesFromTheSavedProvider() {
        let previous = AIConsentPresentation.conversationRecipient(providerRaw: "anthropic", model: "claude-haiku-5-5",
                                                                   current: ProviderSettings(provider: .openAI))
        #expect(previous?.key == "anthropic")
        #expect(AIConsentPresentation.conversationRecipient(providerRaw: nil, model: nil, current: .default) == nil)
        let header = AIConsentPresentation.conversationHeader(recipient: recipient(.openAI), categories: [.workouts, .nutrition])
        #expect(header == "Enviando para OpenAI. Esta conversa pode ler: Treinos · Dieta.")
    }
}
