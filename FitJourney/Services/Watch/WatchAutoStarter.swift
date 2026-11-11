import Foundation
import Observation

/// O que o início automático usa do transporte do relógio (`PhoneWatchLink`).
@MainActor
protocol WatchAutoStartLink: AnyObject {
    /// Relógio pareado com o app do FitJourney instalado.
    var isWatchAppInstalled: Bool { get }
    /// Sessão cujo treino o relógio confirmou que grava (`workoutStatus(.recording)`).
    var watchRecordingSessionID: UUID? { get }
    /// Pede ao relógio para gravar a sessão em andamento (`recordingRequest` com o `sessionID`); `false` = relógio
    /// fora de alcance.
    @discardableResult func requestWatchRecording() -> Bool
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
/// A configuração do `startWatchApp` não leva o ID da sessão: assim que o relógio fica alcançável, o iPhone manda
/// também `recordingRequest(sessionID)` e o relógio grava exatamente essa sessão (sem o pedido, vale a janela do
/// relógio para o próximo snapshot).
/// Falha ao abrir, `startWatchApp` sem resposta em `launchTimeout`, ou o relógio sem confirmar em
/// `confirmationTimeout` → nada muda: o iPhone segue gravando (comportamento de antes). Uma confirmação atrasada
/// continua valendo (o iPhone adota quando chegar). Cada sessão roda numa tarefa própria (o fluxo de eventos não
/// espera); `detach()` cancela e o estado volta a `.idle`.
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
    /// Prazo para o `startWatchApp` responder (a completion pode nunca voltar).
    @ObservationIgnored var launchTimeout: Duration = .seconds(10)

    @ObservationIgnored private let engine: SessionEngine
    @ObservationIgnored private weak var link: (any WatchAutoStartLink)?
    @ObservationIgnored private weak var health: (any WatchAutoStartHealth)?
    @ObservationIgnored private let launcher: any WatchAppLaunching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var attempt: Task<Void, Never>?

    enum LaunchError: Error { case timedOut }

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
                // Tarefa própria: a espera pela confirmação não segura os próximos eventos.
                if case .sessionStarted(let id) = event { self.attempt(for: id) }
            }
        }
    }

    func detach() {
        listener?.cancel()
        listener = nil
        attempt?.cancel()
        attempt = nil
        resetIfInFlight()
    }

    /// Começa a tentativa de uma sessão (cancela a anterior, que fica obsoleta).
    func attempt(for sessionID: UUID) {
        attempt?.cancel()
        attempt = Task { [weak self] in await self?.sessionStarted(sessionID) }
    }

    /// Reage a uma sessão nova (exposto para testes). Volta depois da confirmação ou do prazo.
    func sessionStarted(_ sessionID: UUID) async {
        if let reason = skipReason(for: sessionID) {
            state = .skipped(sessionID: sessionID, reason: reason)
            return
        }
        state = .launching(sessionID: sessionID)
        do {
            try await launchWithTimeout(type: workoutType(for: sessionID))
        } catch {
            guard !Task.isCancelled else { return resetIfInFlight() }
            state = .failed(sessionID: sessionID, message: String(describing: error))
            return
        }
        guard !Task.isCancelled else { return resetIfInFlight() }
        guard state == .launching(sessionID: sessionID) else { return }
        state = .awaitingWatch(sessionID: sessionID)
        var requested = false
        let deadline = ContinuousClock.now.advanced(by: confirmationTimeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if link?.watchRecordingSessionID == sessionID { break }
            // Casa a gravação com esta sessão assim que o relógio estiver alcançável.
            if !requested { requested = link?.requestWatchRecording() ?? false }
            try? await Task.sleep(for: min(.milliseconds(250), confirmationTimeout))
        }
        guard !Task.isCancelled else { return resetIfInFlight() }
        guard state == .awaitingWatch(sessionID: sessionID) else { return }
        state = link?.watchRecordingSessionID == sessionID ? .watchRecording(sessionID: sessionID) : .timedOut(sessionID: sessionID)
    }

    /// Cancelado no meio (detach/sessão nova): não deixa "abrindo"/"aguardando" pendurado.
    private func resetIfInFlight() {
        switch state {
        case .launching, .awaitingWatch: state = .idle
        default: break
        }
    }

    /// `startWatchApp` com prazo: a completion do HealthKit pode nunca voltar. Quem chegar primeiro decide; o
    /// outro é ignorado.
    private func launchWithTimeout(type: HealthWorkoutType) async throws {
        let launcher = launcher
        let timeout = launchTimeout
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.continuation = continuation
            Task { @MainActor in
                do {
                    try await launcher.startWatchApp(type: type)
                    once.resume(with: .success(()))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(with: .failure(LaunchError.timedOut))
            }
        }
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

/// Continuação retomada uma única vez (corrida entre o `startWatchApp` e o prazo).
@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, any Error>?

    func resume(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
