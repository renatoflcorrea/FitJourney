import SwiftData
import SwiftUI

/// Monta a `MealLogSession` de produção (Keychain, rede do importador, `AIAvailability`). Em DEBUG com
/// `-fj.seedDemo YES` troca o provedor por um rascunho falso (capturas e QA, sem rede nem chave).
@MainActor
enum MealLogSessionFactory {
    static func make(day: Date, context: ModelContext, availability: AIAvailability?,
                     network: ImportNetworkMonitor?, text: String = "") -> MealLogSession {
        let isOnline: @MainActor () -> Bool = { network?.isOnline ?? true }
        let isAvailable: @MainActor () -> Bool = { availability?.isAvailable == true }
        #if DEBUG
        if StoreDemo.isEnabled {
            // Só o gateway fictício recebe esta concessão, num domínio isolado de demonstração.
            let defaults = UserDefaults(suiteName: "coach.mealDemo.\(UUID().uuidString)")!
            let recipient = AIRecipientResolver.resolve(settings: ProviderSettings(provider: .openAI))
            let consent = AIConsentStore(defaults: defaults)
            consent.grant(.mealLog, for: recipient)
            let session = MealLogSession(day: day, context: context,
                                         resolveChat: { ResolvedChat(gateway: DemoMealLogGateway(), model: "gpt-5") },
                                         isAIAvailable: isAvailable, recipient: { recipient }, consentStore: consent,
                                         sharesNutrition: { false }, isOnline: isOnline)
            session.text = text
            return session
        }
        #endif
        let session = MealLogSession(day: day, context: context,
                                     resolveChat: { try ProviderFactory.makeChat(secrets: KeychainSecretStore()) },
                                     isAIAvailable: isAvailable, isOnline: isOnline)
        session.text = text
        return session
    }
}

#if DEBUG
/// Provedor falso das capturas: devolve sempre o mesmo rascunho depois de ~2 s.
struct DemoMealLogGateway: ChatGateway, StructuredCompleting {
    var provider: AIProviderID { .openAI }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(id: "demo", model: request.model))
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return continuation.finish(throwing: CancellationError()) }
                continuation.yield(.toolCall(id: "demo-call", name: MealLogPrompt.submitTool, argumentsJSON: Self.draft))
                continuation.yield(.finished(reason: .toolCalls))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        throw AIError.server(status: 500, message: "demo")
    }

    private static func item(_ name: String, _ quantity: String, _ unit: String, _ kcal: Int, _ confidence: String,
                             range: (Int, Int)? = nil, note: String? = nil) -> String {
        """
        {"name":"\(name)","quantity":\(quantity),"unit":"\(unit)","kcal":\(kcal),"kcalMin":\(range.map { String($0.0) } ?? "null"),\
        "kcalMax":\(range.map { String($0.1) } ?? "null"),"protein":null,"carbs":null,"fat":null,"fiber":null,\
        "confidence":"\(confidence)","note":\(note.map { "\"\($0)\"" } ?? "null"),"plannedItemId":null}
        """
    }

    private static var draft: String {
        let breakfast = [item("Ovos mexidos", "2", "unit", 180, "high"), item("Pão francês", "1", "unit", 140, "high"),
                         item("Manteiga", "10", "grams", 70, "medium", range: (50, 90), note: "quantidade não informada"),
                         item("Café com leite", "200", "milliliters", 90, "high")]
        let acai = [item("Açaí com granola", "null", "milliliters", 390, "low", range: (300, 520))]
        return """
        {"status":"ok","reason":null,"meals":[\
        {"slot":"breakfast","label":null,"time":"07:30","plannedMealId":null,"asPlanned":false,"items":[\(breakfast.joined(separator: ","))]},\
        {"slot":"other","label":"Açaí com granola","time":"16:00","plannedMealId":null,"asPlanned":false,"items":[\(acai.joined(separator: ","))]}\
        ],"notSeen":[],"questions":[{"mealIndex":1,"itemIndex":0,"text":"Tamanho não informado. Qual foi?","options":["200 ml","300 ml","500 ml"]}]}
        """
    }
}
#endif
