import Foundation

/// Fim de descanso com Atividade ao Vivo: um aviso só (§4.14 "Quando o descanso termina").
///
/// Decorador do `RestNotificationScheduling` instalado no `SessionEngine` (sem mudar o motor nem o
/// `UserNotificationRestScheduler`):
/// - sem atividade ativa: repassa tudo (só a notificação local, como antes);
/// - com atividade ativa: a notificação do descanso é agendada `grace` segundos **depois** do fim.
///   Se o app está vivo no fim (primeiro plano ou `HKWorkoutSession` em segundo plano), o motor emite
///   `restFinished`, a atividade dá o alerta e o controlador chama `suppressCurrentRestEnd()`, que
///   cancela a notificação antes de ela disparar. Com o app suspenso, ninguém cancela: a notificação
///   toca (com `grace` de atraso) e a atividade já se redesenhou sozinha pelo `staleDate`.
@MainActor
final class LiveActivityRestNotificationGate: RestNotificationScheduling {
    /// Atraso da notificação com a atividade ativa (folga para o app cancelá-la).
    static let defaultGrace: TimeInterval = 3

    private let wrapped: any RestNotificationScheduling
    private let grace: TimeInterval
    /// Ligado pelo `LiveActivityController` enquanto há atividade da sessão.
    var isLiveActivityActive = false

    init(wrapping wrapped: any RestNotificationScheduling, grace: TimeInterval = LiveActivityRestNotificationGate.defaultGrace) {
        self.wrapped = wrapped
        self.grace = grace
    }

    func authorization() async -> RestNotificationAuthorization { await wrapped.authorization() }

    func requestAuthorization() async -> Bool { await wrapped.requestAuthorization() }

    func scheduleRestEnd(at date: Date, nextExerciseName: String?) {
        wrapped.scheduleRestEnd(at: isLiveActivityActive ? date.addingTimeInterval(grace) : date,
                                nextExerciseName: nextExerciseName)
    }

    func cancelRestEnd() { wrapped.cancelRestEnd() }

    /// A atividade deu o alerta de fim de descanso: cancela a notificação daquele descanso.
    func suppressCurrentRestEnd() { wrapped.cancelRestEnd() }
}
