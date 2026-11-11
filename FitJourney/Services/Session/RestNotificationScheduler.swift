import Foundation
import UserNotifications

/// Situação da permissão de notificações, do ponto de vista do descanso.
enum RestNotificationAuthorization: Sendable, Hashable {
    /// Ainda não perguntado: a UI pode pedir no contexto (ex.: no primeiro descanso).
    case notDetermined
    case authorized
    case denied
}

/// Notificação local de fim de descanso (SPEC D4).
///
/// Decisão: agendar **sempre** que houver descanso em curso (não só ao ir para segundo plano), com
/// **identificador fixo** — cada novo agendamento substitui o anterior e cancelar é um único
/// identificador. Com o app em primeiro plano o sistema não mostra o banner (não há
/// `willPresent` configurado), e o háptico vem do evento `restFinished` do `SessionEngine`; em
/// segundo plano, com o app suspenso ou encerrado, a notificação dispara no horário certo sem
/// depender de o app acordar. Só agenda com permissão já concedida: nunca pergunta sozinho.
@MainActor
protocol RestNotificationScheduling: AnyObject {
    func authorization() async -> RestNotificationAuthorization
    /// Pede permissão (chamar de um gesto/contexto da UI). Devolve se ficou autorizado.
    func requestAuthorization() async -> Bool
    /// Agenda (ou reagenda) o aviso de fim de descanso.
    func scheduleRestEnd(at date: Date, nextExerciseName: String?)
    func cancelRestEnd()
}

/// Implementação nula (testes, previews).
@MainActor
final class NoopRestNotificationScheduler: RestNotificationScheduling {
    init() {}
    func authorization() async -> RestNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func scheduleRestEnd(at date: Date, nextExerciseName: String?) {}
    func cancelRestEnd() {}
}

/// Implementação com `UNUserNotificationCenter`.
@MainActor
final class UserNotificationRestScheduler: RestNotificationScheduling {
    static let identifier = "br.com.renatocorrea.fitjourney.rest-end"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorization() async -> RestNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func scheduleRestEnd(at date: Date, nextExerciseName: String?) {
        let interval = date.timeIntervalSinceNow
        guard interval > 0.5 else { cancelRestEnd(); return }
        let body = nextExerciseName.map { String(localized: "Hora da próxima série: \($0)") }
            ?? String(localized: "Hora da próxima série.")
        enqueue { scheduler in
            let status = await scheduler.center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Descanso encerrado")
            content.body = body
            content.sound = .default
            content.threadIdentifier = "rest"
            let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            try? await scheduler.center.add(request)
        }
    }

    func cancelRestEnd() {
        enqueue { scheduler in
            scheduler.center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            scheduler.center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        }
    }

    /// Serializa agendar/cancelar: um cancelamento logo após agendar nunca perde a corrida.
    private var tail: Task<Void, Never>?

    private func enqueue(_ operation: @escaping @MainActor (UserNotificationRestScheduler) async -> Void) {
        let previous = tail
        tail = Task { [self] in
            await previous?.value
            await operation(self)
        }
    }
}
