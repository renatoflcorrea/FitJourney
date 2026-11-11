#if DEBUG
import Foundation
import SwiftData

/// Dados para previews e testes de apresentação do Coach: container em memória, `UserDefaults` isolado
/// e propostas de exemplo. Nunca usa rede nem o Keychain real.
@MainActor
enum CoachPreviewData {
    static func defaults(consented: Bool, ready: Bool = true) -> UserDefaults {
        let name = "coach.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        if consented { CoachProfileStore(defaults: defaults).grantConsent(sharing: .init(profile: true, workouts: true)) }
        if ready { ProviderSettingsStore(defaults: defaults).save(.default) }
        return defaults
    }

    static func readySecrets() -> InMemorySecretStore {
        InMemorySecretStore([SecretKey.apiKey(.openAI): "sk-preview-0000000000"])
    }

    static func container(withConversations: Bool) -> ModelContainer {
        guard let container = try? PersistenceController.makeContainer(inMemory: true) else {
            fatalError("Container de preview")
        }
        if withConversations { insertConversations(into: container.mainContext) }
        return container
    }

    static func service(_ container: ModelContainer) -> CoachConversationService {
        let context = container.mainContext
        return CoachConversationService(
            context: context, toolbox: FitnessToolbox(context: context),
            resolveChat: { throw AIError.notConfigured(reason: "preview") })
    }

    static func insertConversations(into context: ModelContext) {
        let chat = ChatConversation(title: "ABC de hipertrofia, 4x/semana")
        context.insert(chat)
        func add(_ role: LLMRole, _ content: String, state: ChatMessageState = .complete) -> ChatMessage {
            let message = ChatMessage(role: role, content: content, state: state, sortIndex: chat.nextSortIndex)
            context.insert(message)
            message.conversation = chat
            return message
        }
        _ = add(.user, "Monte um ABC de hipertrofia, 4x/semana, 60 min")
        _ = add(.assistant, "Montei um **ABC** com *4 sessões* por semana, ~60 min cada. Revise o rascunho abaixo; nada é salvo sem a sua confirmação.")
        let tool = add(.tool, "{\"ok\":true}")
        tool.proposal = programProposal()
        let second = ChatConversation(title: "Dieta de 2.200 kcal", createdAt: .now.addingTimeInterval(-86_400 * 2))
        context.insert(second)
        let question = ChatMessage(role: .user, content: "Ajuste minha dieta para 2.200 kcal", sortIndex: 0)
        context.insert(question)
        question.conversation = second
        let answer = ChatMessage(role: .assistant, content: "Claro! Vou olhar seu plano atual e propor ajustes.", sortIndex: 1)
        context.insert(answer)
        answer.conversation = second
        try? context.save()
    }

    static func programProposal(id: String = "call-program") -> CoachProposal {
        let json = """
        {"name":"ABC Hipertrofia","goal":"hypertrophy","scheduleMode":"sequential","durationWeeks":8,
         "routines":[
          {"name":"A — Peito e tríceps","symbol":"A","weekdays":[],"exercises":[
            {"name":"Supino reto","catalogKey":null,"sets":[
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":12},"load":null},
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":12},"load":null},
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":12},"load":null},
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":12},"load":null}]},
            {"name":"Crucifixo no cabo inventado","sets":[
              {"kind":"working","repTarget":{"kind":"fixed","reps":12}},
              {"kind":"working","repTarget":{"kind":"fixed","reps":12}},
              {"kind":"working","repTarget":{"kind":"fixed","reps":12}}]}]},
          {"name":"B — Costas e bíceps","symbol":"B","weekdays":[],"exercises":[
            {"name":"Remada curvada","sets":[
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":10}},
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":10}},
              {"kind":"working","repTarget":{"kind":"range","min":8,"max":10}}]}]}]}
        """
        let draft = try! JSONDecoder().decode(ProgramDraft.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
        return CoachProposal(id: id, content: .program(draft), createdAt: .now)
    }

    static func planProposal(id: String = "call-plan") -> CoachProposal {
        let json = """
        {"name":"Cutting 2.200 kcal","goal":"Perder gordura","targets":{"kcal":2200,"protein":160,"carbs":220,"fat":70},
         "days":[{"name":"Todos os dias","weekdays":[],"meals":[
           {"name":"Café da manhã","time":"07:30","items":[{"name":"Ovos","quantity":3,"unit":"unit","substitutions":[]}]},
           {"name":"Almoço","time":"12:30","items":[{"name":"Arroz","quantity":150,"unit":"grams","substitutions":[]},
                                                    {"name":"Frango","quantity":150,"unit":"grams","substitutions":[]}]}]}]}
        """
        let draft = try! JSONDecoder().decode(NutritionPlanDraft.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
        return CoachProposal(id: id, content: .nutritionPlan(draft), createdAt: .now)
    }
}
#endif
