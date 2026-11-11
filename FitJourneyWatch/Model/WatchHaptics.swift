import Foundation
import WatchKit

/// Eventos hápticos do relógio (DESIGN §9.6).
enum WatchHapticEvent: Sendable, Hashable {
    case detent, setCompleted, restEnded, countdownTick, countdownGo, holdTargetReached, stopped, resumed, saved, failure, lightNotice
    /// Segundo toque do alerta insistente de fim de descanso (alterna com `restEnded` no laço).
    case restAlertRetry
}

@MainActor
protocol WatchHaptics: AnyObject {
    func play(_ event: WatchHapticEvent)
    /// Cancela o que ainda ia tocar de um evento composto (o 2º toque de `restEnded`).
    func cancelPending()
}

extension WatchHaptics {
    func cancelPending() {}
}

/// Padrão do alerta insistente (DESIGN §9.6): pulsos alternados, como o timer do iPhone, até o usuário
/// interagir ou o teto vencer.
enum WatchRestAlertPattern {
    /// Intervalo entre pulsos.
    static let interval: TimeInterval = 1.8
    /// Teto de segurança, contado do fim do descanso: depois disso o laço para sozinho e a tela fica.
    static let ceiling: TimeInterval = 60

    /// Pulso `index` (0 = o do fim do descanso): `.notification` duplo nos pares, `.retry` nos ímpares.
    static func event(forPulse index: Int) -> WatchHapticEvent {
        index.isMultiple(of: 2) ? .restEnded : .restAlertRetry
    }
}

/// Laço cancelável: chama `tick` a cada `interval` até `cancel()`.
@MainActor
final class WatchHapticLoop {
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    var isRunning: Bool { task != nil }

    func start(every interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Háptico real via `WKInterfaceDevice` (o detente da Coroa é do sistema, via `digitalCrownRotation`).
@MainActor
final class SystemWatchHaptics: WatchHaptics {
    private var trailing: Task<Void, Never>?

    func play(_ event: WatchHapticEvent) {
        let device = WKInterfaceDevice.current()
        switch event {
        case .detent: break
        case .setCompleted, .saved: device.play(.success)
        case .restEnded:
            device.play(.notification)
            trailing?.cancel()
            trailing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                device.play(.notification)
            }
        case .restAlertRetry: device.play(.retry)
        case .countdownTick: device.play(.click)
        case .countdownGo, .resumed: device.play(.start)
        case .holdTargetReached: device.play(.directionUp)
        case .stopped: device.play(.stop)
        case .failure: device.play(.failure)
        case .lightNotice: device.play(.click)
        }
    }

    func cancelPending() {
        trailing?.cancel()
        trailing = nil
    }
}

/// Registra os eventos (testes e previews).
@MainActor
final class RecordingHaptics: WatchHaptics {
    private(set) var events: [WatchHapticEvent] = []
    private(set) var cancelCount = 0
    func play(_ event: WatchHapticEvent) { events.append(event) }
    func cancelPending() { cancelCount += 1 }
}
