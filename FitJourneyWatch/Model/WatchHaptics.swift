import Foundation
import WatchKit

/// Eventos hápticos do relógio (DESIGN §9.6).
enum WatchHapticEvent: Sendable, Hashable {
    case detent, setCompleted, restEnded, countdownTick, countdownGo, holdTargetReached, stopped, resumed, saved, failure, lightNotice
}

@MainActor
protocol WatchHaptics: AnyObject {
    func play(_ event: WatchHapticEvent)
}

/// Háptico real via `WKInterfaceDevice` (o detente da Coroa é do sistema, via `digitalCrownRotation`).
@MainActor
final class SystemWatchHaptics: WatchHaptics {
    func play(_ event: WatchHapticEvent) {
        let device = WKInterfaceDevice.current()
        switch event {
        case .detent: break
        case .setCompleted, .saved: device.play(.success)
        case .restEnded:
            device.play(.notification)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                device.play(.notification)
            }
        case .countdownTick: device.play(.click)
        case .countdownGo, .resumed: device.play(.start)
        case .holdTargetReached: device.play(.directionUp)
        case .stopped: device.play(.stop)
        case .failure: device.play(.failure)
        case .lightNotice: device.play(.click)
        }
    }
}

/// Registra os eventos (testes e previews).
@MainActor
final class RecordingHaptics: WatchHaptics {
    private(set) var events: [WatchHapticEvent] = []
    func play(_ event: WatchHapticEvent) { events.append(event) }
}
