import Foundation
import Observation

/// O que o início automático usa do transporte do relógio (`PhoneWatchLink`).
@MainActor
protocol WatchAutoStartLink: AnyObject {
    /// Relógio pareado com o app do FitJourney instalado.
    var isWatchAppInstalled: Bool { get }
    /// Sessão cujo treino o relógio confirmou que grava (`workoutStatus(.recording)`).
    var watchRecordingSessionID: UUID? { get }
}

extension PhoneWatchLink: WatchAutoStartLink {}

/// O que o início automático usa do Saúde (`HealthWorkoutController`).
@MainActor
protocol WatchAutoStartHealth: AnyObject {
    /// Saúde disponível, "Conectar ao Saúde" ligado e escrita de treinos autorizada.
    var canRecordWorkouts: Bool { get }
}

extension HealthWorkoutController: WatchAutoStartHealth {}

/// Inicia o treino no Apple Watch automaticamente ao começar uma sessão no iPhone (P2.8).
///
/// Apps de terceiros não podem abrir o app Exercício da Apple; o que dá é abrir **o próprio app no relógio**
/// pronto para gravar: `HKHealthStore.startWatchApp(with:)` com a configuração do tipo do treino. No relógio,
/// `WKApplicationDelegate.handle(_ workoutConfiguration:)` pede o snapshot e grava a sessão em andamento pelo fluxo
/// de "gravar no relógio" (`HKWorkoutSession` espelhada; `workoutStatus(.recording)` → o iPhone adota a gravação
/// remota e descarta a dele — nunca grava duas vezes).
///
/// Só age quando: preferência `fj.autoStartWatchWorkout` ligada (padrão), sessão iniciada **no iPhone**
/// (`SessionEngine.startOrigin`), app do relógio instalado e Saúde conectado com escrita autorizada.
/// Falha ao abrir ou o relógio não confirma em `confirmationTimeout` → nada muda: o iPhone segue gravando
/// (comportamento de antes). Uma confirmação atrasada continua valendo (o iPhone adota quando chegar).
@MainActor
@Observable
final class WatchAutoStarter {
    enum SkipReason: String, Sendable, Hashable {
        case disabled, startedOnWatch, watchAppNotInstalled, healthNotAuthorized, alreadyRecording
    }

    enum State: Sendable, Hashable {
        case idle
        case skipped(sessionID: UUID, reason: SkipReason)
        case launching(sessionID: UUID)
        /// App do relógio aberto; aguardando `workoutStatus(.recording)`.
        case awaitingWatch(sessionID: UUID)
        /// O relógio grava a sessão.
        case watchRecording(sessionID: UUID)
        /// O relógio não confirmou a tempo: o iPhone segue gravando.
        case timedOut(sessionID: UUID)
        case failed(sessionID: UUID, message: String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored var confirmationTimeout: Duration = .seconds(20)

    @ObservationIgnored private let engine: SessionEngine
    @ObservationIgnored private weak var link: (any WatchAutoStartLink)?
    @ObservationIgnored private weak var health: (any WatchAutoStartHealth)?
    @ObservationIgnored private let launcher: any WatchAppLaunching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(engine: SessionEngine, link: any WatchAutoStartLink, health: any WatchAutoStartHealth,
         launcher: any WatchAppLaunching, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.link = link
        self.health = health
        self.launcher = launcher
        self.defaults = defaults
    }

    /// Preferência (ausente = ligada).
    var isEnabled: Bool { defaults.object(forKey: AppPreferenceKeys.autoStartWatchWorkout) as? Bool ?? true }

    /// Assina os eventos do motor (substitui uma assinatura anterior).
    func attach() {
        listener?.cancel()
        let events = engine.events()
        listener = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case .sessionStarted(let id) = event { await self.sessionStarted(id) }
            }
        }
    }

    func detach() {
        listener?.cancel()
        listener = nil
    }

    /// Reage a uma sessão nova (exposto para testes). Volta depois da confirmação ou do prazo.
    func sessionStarted(_ sessionID: UUID) async {
        if let reason = skipReason(for: sessionID) {
            state = .skipped(sessionID: sessionID, reason: reason)
            return
        }
        state = .launching(sessionID: sessionID)
        do {
            try await launcher.startWatchApp(type: workoutType(for: sessionID))
        } catch {
            state = .failed(sessionID: sessionID, message: String(describing: error))
            return
        }
        guard state == .launching(sessionID: sessionID) else { return }
        state = .awaitingWatch(sessionID: sessionID)
        let deadline = ContinuousClock.now.advanced(by: confirmationTimeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if link?.watchRecordingSessionID == sessionID { break }
            try? await Task.sleep(for: min(.milliseconds(250), confirmationTimeout))
        }
        guard state == .awaitingWatch(sessionID: sessionID) else { return }
        state = link?.watchRecordingSessionID == sessionID ? .watchRecording(sessionID: sessionID) : .timedOut(sessionID: sessionID)
    }

    private func skipReason(for sessionID: UUID) -> SkipReason? {
        guard isEnabled else { return .disabled }
        guard engine.startOrigin(of: sessionID) == .phone else { return .startedOnWatch }
        guard link?.isWatchAppInstalled == true else { return .watchAppNotInstalled }
        guard health?.canRecordWorkouts == true else { return .healthNotAuthorized }
        guard link?.watchRecordingSessionID != sessionID else { return .alreadyRecording }
        return nil
    }

    /// Tipo do treino pela ficha (o mesmo que o Saúde usa); sem snapshot, força tradicional.
    private func workoutType(for sessionID: UUID) -> HealthWorkoutType {
        guard let snapshot = engine.snapshot, snapshot.sessionID == sessionID,
              let raw = snapshot.workoutType, let type = HealthWorkoutType(rawValue: raw) else { return .traditionalStrength }
        return type
    }
}
