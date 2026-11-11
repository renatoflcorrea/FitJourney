import ActivityKit
import Foundation

/// Atividade existente no sistema (para reconciliar ao reabrir o app).
struct LiveActivityRecord: Sendable, Hashable {
    var id: String
    var sessionID: UUID
}

/// Alerta de uma atualização (acende a tela e expande a ilha).
struct LiveActivityAlert: Sendable, Hashable {
    var title: String
    var body: String
}

enum LiveActivityDismissal: Sendable, Hashable {
    case immediate
    case after(Date)
}

/// Porta para o ActivityKit (fake nos testes).
@MainActor
protocol LiveActivityClient: AnyObject {
    /// Ajustes do iPhone › FitJourney › Atividades ao Vivo.
    var areActivitiesEnabled: Bool { get }
    func currentActivities() -> [LiveActivityRecord]
    /// Inicia (só funciona com o app em primeiro plano). Devolve o ID da atividade.
    func request(attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState,
                 staleDate: Date?) throws -> String
    /// Atualiza; `false` = a atividade não existe mais ou não está ativa (nada foi mostrado).
    func update(id: String, state: WorkoutActivityAttributes.ContentState, staleDate: Date?,
                alert: LiveActivityAlert?) async -> Bool
    /// Chama `onEnd` quando o sistema encerrar a atividade (dispensada pelo usuário, limite de 8 h…).
    func observeEnd(id: String, onEnd: @escaping @MainActor @Sendable (String) -> Void)
    /// Encerra com o estado final (`nil` = mantém o último) e a política de saída.
    func end(id: String, state: WorkoutActivityAttributes.ContentState?, dismissal: LiveActivityDismissal) async
}

/// Implementação com `Activity<WorkoutActivityAttributes>`.
@MainActor
final class ActivityKitLiveActivityClient: LiveActivityClient {
    private typealias WorkoutActivity = Activity<WorkoutActivityAttributes>
    private typealias Content = ActivityContent<WorkoutActivityAttributes.ContentState>

    init() {}

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func currentActivities() -> [LiveActivityRecord] {
        WorkoutActivity.activities
            .filter { $0.activityState == .active || $0.activityState == .stale || $0.activityState == .pending }
            .map { LiveActivityRecord(id: $0.id, sessionID: $0.attributes.sessionID) }
    }

    func request(attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState,
                 staleDate: Date?) throws -> String {
        let activity = try WorkoutActivity.request(attributes: attributes,
                                                   content: ActivityContent(state: state, staleDate: staleDate),
                                                   pushType: nil)
        return activity.id
    }

    func update(id: String, state: WorkoutActivityAttributes.ContentState, staleDate: Date?,
                alert: LiveActivityAlert?) async -> Bool {
        await Self.update(id: id, content: ActivityContent(state: state, staleDate: staleDate), alert: alert)
    }

    func observeEnd(id: String, onEnd: @escaping @MainActor @Sendable (String) -> Void) {
        Task.detached { await Self.watch(id: id, onEnd: onEnd) }
    }

    func end(id: String, state: WorkoutActivityAttributes.ContentState?, dismissal: LiveActivityDismissal) async {
        await Self.end(id: id, content: state.map { ActivityContent(state: $0, staleDate: nil) }, dismissal: dismissal)
    }

    // `Activity` não é `Sendable`: é buscada e usada fora do `@MainActor`, sem atravessar isolamento.

    private nonisolated static func watch(id: String, onEnd: @escaping @MainActor @Sendable (String) -> Void) async {
        guard let activity = WorkoutActivity.activities.first(where: { $0.id == id }) else {
            await onEnd(id)
            return
        }
        for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
            await onEnd(id)
            return
        }
    }

    private nonisolated static func update(id: String, content: Content, alert: LiveActivityAlert?) async -> Bool {
        guard let activity = WorkoutActivity.activities.first(where: { $0.id == id }),
              activity.activityState == .active || activity.activityState == .stale else { return false }
        let configuration = alert.map {
            AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title),
                               body: LocalizedStringResource(stringLiteral: $0.body), sound: .default)
        }
        await activity.update(content, alertConfiguration: configuration)
        return true
    }

    private nonisolated static func end(id: String, content: Content?, dismissal: LiveActivityDismissal) async {
        guard let activity = WorkoutActivity.activities.first(where: { $0.id == id }) else { return }
        let policy: ActivityUIDismissalPolicy = switch dismissal {
        case .immediate: .immediate
        case .after(let date): .after(date)
        }
        await activity.end(content, dismissalPolicy: policy)
    }
}
