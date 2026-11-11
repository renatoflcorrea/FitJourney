import AppIntents
import Foundation

/// Ação de descanso vinda de um botão da Atividade ao Vivo (§4.14 "Ações").
enum LiveActivityRestAction: Sendable, Hashable {
    /// +15 s (ou outro valor) no descanso em curso.
    case adjustRest(seconds: Int)
    case skipRest
}

/// Quem executa as ações no processo do app (o `LiveActivityController`, que passa pelo `SessionEngine`).
@MainActor
protocol LiveActivityRestActionHandling: AnyObject {
    func perform(_ action: LiveActivityRestAction, sessionID: UUID) async
}

/// Ponte entre os intents (compilados nos dois alvos) e o app.
///
/// Os intents são `LiveActivityIntent` e estão nos dois alvos (app e extensão): o sistema executa o
/// `perform()` **no processo do app**, sem abri-lo, inclusive com a tela bloqueada. O App instala o
/// `handler` no `init` (que roda também quando o sistema acorda o app só para o intent). Na extensão o
/// `handler` fica `nil` e o intent não faz nada.
@MainActor
enum LiveActivityIntentRouter {
    static var handler: (any LiveActivityRestActionHandling)?

    static func route(_ action: LiveActivityRestAction, sessionID: String) async {
        guard let id = UUID(uuidString: sessionID) else { return }
        await handler?.perform(action, sessionID: id)
    }
}

/// "+15 s" da Atividade ao Vivo: mesmo comando `adjustRest` do app e do relógio (idempotente pelo motor).
struct AdjustRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ajustar descanso"
    static let description = IntentDescription("Adiciona tempo ao descanso do treino em andamento.")
    /// Só para os botões da atividade (não aparece no app Atalhos).
    static let isDiscoverable = false

    @Parameter(title: "Sessão")
    var sessionID: String

    @Parameter(title: "Segundos", default: 15)
    var seconds: Int

    init() {}

    init(sessionID: UUID, seconds: Int = 15) {
        self.sessionID = sessionID.uuidString
        self.seconds = seconds
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityIntentRouter.route(.adjustRest(seconds: seconds), sessionID: sessionID)
        return .result()
    }
}

/// "Pular" da Atividade ao Vivo: encerra o descanso (a atividade passa a Série).
struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pular descanso"
    static let description = IntentDescription("Encerra o descanso do treino em andamento.")
    static let isDiscoverable = false

    @Parameter(title: "Sessão")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityIntentRouter.route(.skipRest, sessionID: sessionID)
        return .result()
    }
}
