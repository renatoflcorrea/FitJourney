import Foundation

/// Fim de descanso com Atividade ao Vivo: um aviso só (§4.14 "Quando o descanso termina").
///
/// Decorador do `RestNotificationScheduling` instalado no `SessionEngine` (sem mudar o motor nem o
/// `UserNotificationRestScheduler`):
/// - sem atividade ativa: repassa tudo (só a notificação local, como antes);
/// - com atividade ativa: a notificação do descanso é agendada `grace` segundos **depois** do fim.
///   Se o app está vivo no fim (primeiro plano ou `HKWorkoutSession` em segundo plano), o motor emite
///   `restFinished`, a atividade dá o alerta e o controlador chama `suppressRestEnd(endingAt:)`, que
///   cancela a notificação antes de ela disparar. Com o app suspenso, ninguém cancela: a notificação
///   toca (com `grace` de atraso) e a atividade já se redesenhou sozinha pelo `staleDate`.
/// - Lembra o último agendamento (`lastRest`): quando a atividade liga ou desliga com um descanso já
///   agendado (sessão restaurada antes da reconciliação, pedido repetido no primeiro plano, preferência
///   ligada no meio do descanso), reagenda com ou sem a folga.
@MainActor
final class LiveActivityRestNotificationGate: RestNotificationScheduling {
    /// Atraso da notificação com a atividade ativa (folga para o app cancelá-la).
    static let defaultGrace: TimeInterval = 3

    private let wrapped: any RestNotificationScheduling
    private let grace: TimeInterval
    private let now: () -> Date
    /// Último descanso agendado (fim real, sem a folga); `nil` depois de cancelar.
    private(set) var lastRest: (endsAt: Date, nextExerciseName: String?)?

    /// Ligado pelo `LiveActivityController` enquanto há atividade da sessão. Mudar reagenda o descanso em curso.
    var isLiveActivityActive = false {
        didSet {
            guard oldValue != isLiveActivityActive, let lastRest, lastRest.endsAt > now() else { return }
            wrapped.scheduleRestEnd(at: target(for: lastRest.endsAt), nextExerciseName: lastRest.nextExerciseName)
        }
    }

    init(wrapping wrapped: any RestNotificationScheduling, grace: TimeInterval = LiveActivityRestNotificationGate.defaultGrace,
         now: @escaping () -> Date = { Date() }) {
        self.wrapped = wrapped
        self.grace = grace
        self.now = now
    }

    private func target(for end: Date) -> Date {
        isLiveActivityActive ? end.addingTimeInterval(grace) : end
    }

    func authorization() async -> RestNotificationAuthorization { await wrapped.authorization() }

    func requestAuthorization() async -> Bool { await wrapped.requestAuthorization() }

    func scheduleRestEnd(at date: Date, nextExerciseName: String?) {
        lastRest = (date, nextExerciseName)
        wrapped.scheduleRestEnd(at: target(for: date), nextExerciseName: nextExerciseName)
    }

    func cancelRestEnd() {
        lastRest = nil
        wrapped.cancelRestEnd()
    }

    /// A atividade deu o alerta do fim do descanso que termina em `end`: cancela a notificação dele
    /// (se outro descanso já foi agendado depois, não mexe).
    func suppressRestEnd(endingAt end: Date?) {
        if let lastRest, let end, lastRest.endsAt != end { return }
        lastRest = nil
        wrapped.cancelRestEnd()
    }
}
