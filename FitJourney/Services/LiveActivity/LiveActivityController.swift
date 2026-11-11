import Foundation
import SwiftData
import UIKit

/// O que o controlador usa do `SessionEngine` (fake nos testes).
@MainActor
protocol LiveActivitySessionSource: AnyObject {
    var snapshot: SessionSnapshot? { get }
    var activeSessionID: UUID? { get }
    func snapshots() -> AsyncStream<SessionSnapshot>
    func events() -> AsyncStream<SessionEvent>
    func restore()
    @discardableResult
    func send(_ kind: SessionCommand.Kind, issuedAt: Date?) -> SessionApplyResult
}

extension SessionEngine: LiveActivitySessionSource {}

/// Atividade ao Vivo + Dynamic Island da sessão (P6.4, DESIGN_DIRECTION §4.14).
///
/// - **Uma atividade por sessão.** Pedida no primeiro snapshot ativo de uma sessão (início no iPhone,
///   ou ao abrir o app numa sessão começada no relógio), com `fj.liveActivity` ligado (padrão: ligado)
///   e Atividades ao Vivo permitidas nos Ajustes do iPhone. Sem permissão do sistema para pedir (app em
///   segundo plano), tenta de novo no próximo `handleForeground()`. Atividade que o sistema encerrou
///   (dispensada pelo usuário, limite de 8 h) não é pedida de novo para a mesma sessão.
/// - **Atualiza só quando o que a atividade mostra muda**: cada snapshot vira um `ContentState`
///   (`LiveActivityStateMapper`, estável — não depende do relógio) e só um estado diferente do último
///   enviado gera `update`. Nada de temporizador por segundo: os contadores são desenhados pelo sistema.
/// - Descanso: `staleDate = restEndsAt` (o sistema redesenha como "Descanso concluído" mesmo com o
///   app suspenso). No `restFinished` (app vivo) atualiza para "Descanso concluído"; **com alerta** só se
///   o evento é recente (< `alertWindow`) e o app não está em primeiro plano. Se o alerta foi mostrado
///   numa atividade ativa, cancela a notificação local daquele descanso (`LiveActivityRestNotificationGate`).
///   Depois de `restDoneHold`, volta a "Série".
/// - Fim: `finish` encerra com "Treino concluído" (some em 5 min); `discard` encerra na hora.
/// - Ao reabrir o app (`start()`/`handleForeground()`): adota a atividade da sessão em andamento e
///   encerra as de sessões antigas.
/// - Botões +15 s / Pular: `AdjustRestIntent`/`SkipRestIntent` → `perform(_:sessionID:)` → `onWake`
///   (serviços sem UI, como o canal do relógio) → `SessionEngine.send(.adjustRest/.skipRest)` no processo
///   do app. Toques repetidos da mesma ação em < `tapDebounce` contam uma vez. Sessão já encerrada =
///   encerra a atividade.
///
/// Ligações: o App cria o controlador no `init`, instala `LiveActivityIntentRouter.handler` e `onWake`,
/// chama `start()` no launch e `handleForeground()` quando a cena fica ativa.
@MainActor
final class LiveActivityController: LiveActivityRestActionHandling {
    typealias State = WorkoutActivityAttributes.ContentState

    /// Quanto tempo "Descanso concluído" fica antes de voltar a "Série".
    static let restDoneHold: Duration = .seconds(10)
    /// "Treino concluído" fica na Tela Bloqueada por 5 min (ou até ser dispensado).
    static let finishedLinger: TimeInterval = 5 * 60
    /// `restFinished` mais velho que isso não alerta (só atualiza).
    static let alertWindow: TimeInterval = 2
    /// Toques repetidos da mesma ação dentro disso contam uma vez.
    static let tapDebounce: TimeInterval = 0.3

    /// Atividade em curso desta sessão. `state == nil` = adotada ao reabrir, ainda sem estado enviado.
    struct Current: Equatable {
        var id: String
        var sessionID: UUID
        var state: State?
        var revision: Int
    }

    private(set) var current: Current?
    /// Serviços que não dependem de UI (canal do relógio, Saúde) — chamado quando um intent acorda o app.
    var onWake: (@MainActor () -> Void)?

    private let engine: any LiveActivitySessionSource
    private let client: any LiveActivityClient
    private let gate: LiveActivityRestNotificationGate?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let unit: () -> WeightUnit
    private let routineColorName: (UUID?) -> String?
    private let isAppActive: () -> Bool
    private let restDoneHold: Duration

    private var started = false
    private var listeners: [Task<Void, Never>] = []
    private var tail: Task<Void, Never>?
    private var restDoneRevert: Task<Void, Never>?
    /// Sessão cujo `request` falhou (app em segundo plano): não insiste até o próximo primeiro plano.
    private var failedRequestSessionID: UUID?
    /// Sessão cuja atividade o sistema encerrou: não pede outra.
    private var systemEndedSessionID: UUID?
    /// Atividades que mandamos encerrar e cujo `end` ainda não terminou (não repete).
    private(set) var ending: Set<String> = []
    private var lastTap: (action: LiveActivityRestAction, sessionID: UUID, at: Date)?
    private var preferenceObserver: (any NSObjectProtocol)?
    private var lastPreference: Bool?

    init(engine: any LiveActivitySessionSource,
         client: any LiveActivityClient = ActivityKitLiveActivityClient(),
         gate: LiveActivityRestNotificationGate? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { Date() },
         unit: @escaping () -> WeightUnit = { WeightUnitPreference.current },
         routineColorName: @escaping (UUID?) -> String? = { _ in nil },
         isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         restDoneHold: Duration = LiveActivityController.restDoneHold) {
        self.engine = engine
        self.client = client
        self.gate = gate
        self.defaults = defaults
        self.now = now
        self.unit = unit
        self.routineColorName = routineColorName
        self.isAppActive = isAppActive
        self.restDoneHold = restDoneHold
    }

    /// Cor da ficha a partir do banco (`Routine.colorName`).
    static func routineColorLookup(context: ModelContext) -> (UUID?) -> String? {
        { id in
            guard let id else { return nil }
            var descriptor = FetchDescriptor<Routine>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).first)?.colorName
        }
    }

    /// Preferência do FitJourney (`fj.liveActivity`, padrão ligado) e permissão do sistema.
    var isEnabled: Bool {
        Self.isPreferenceOn(defaults) && client.areActivitiesEnabled
    }

    static func isPreferenceOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: AppPreferenceKeys.liveActivity) as? Bool ?? true
    }

    // MARK: Ciclo de vida

    /// Carrega a sessão (se o motor ainda não carregou), reconcilia atividades existentes e passa a
    /// acompanhar snapshots e eventos. Idempotente.
    func start() {
        guard !started else { return }
        started = true
        if engine.activeSessionID == nil { engine.restore() }
        reconcile()
        lastPreference = Self.isPreferenceOn(defaults)
        // Ajustes › Treino › Atividade ao Vivo mudou com o app aberto: liga/desliga já.
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceMayHaveChanged() }
        }
        let snapshots = engine.snapshots()
        let events = engine.events()
        listeners = [
            Task { [weak self] in
                for await snapshot in snapshots {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(snapshot)
                }
            },
            Task { [weak self] in
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(event)
                }
            },
        ]
    }

    /// Reaplica o estado quando `fj.liveActivity` muda (ligar no meio da sessão pede; desligar encerra).
    func preferenceMayHaveChanged() {
        let value = Self.isPreferenceOn(defaults)
        guard value != lastPreference else { return }
        lastPreference = value
        if value { failedRequestSessionID = nil }
        if let snapshot = engine.snapshot { handle(snapshot) }
    }

    /// Cena ativa: tenta de novo o pedido que falhou, reconcilia e reaplica o estado atual
    /// ("Descanso concluído" vira "Série" ao abrir o app).
    func handleForeground() {
        failedRequestSessionID = nil
        if started { reconcile() } else { start() }
        if let snapshot = engine.snapshot {
            handle(snapshot)
        } else if let current {
            end(current.id, state: nil, dismissal: .immediate)
            self.current = nil
            syncGate()
        }
    }

    /// Espera as chamadas ao ActivityKit enfileiradas (testes e intents).
    func waitUntilIdle() async {
        while let pending = tail {
            await pending.value
            if tail == pending { tail = nil }
        }
    }

    // MARK: Snapshots e eventos

    func handle(_ snapshot: SessionSnapshot) {
        if let current, current.sessionID == snapshot.sessionID, snapshot.revision < current.revision { return }
        switch snapshot.status {
        case .finished:
            finish(snapshot)
        case .discarded:
            endActivities(of: snapshot.sessionID)
        case .active, .paused:
            show(snapshot)
        case .unknown:
            return
        }
        syncGate()
    }

    func handle(_ event: SessionEvent) {
        guard case .restFinished(let at) = event else { return }
        guard var current, current.sessionID == engine.activeSessionID,
              let state = current.state, state.phase == .resting else { return }
        let done = LiveActivityStateMapper.restDone(from: state)
        current.state = done
        self.current = current
        let shouldAlert = now().timeIntervalSince(at) < Self.alertWindow && !isAppActive()
        let alert = shouldAlert
            ? LiveActivityAlert(title: String(localized: "Descanso concluído"),
                                body: LiveActivityStateMapper.restDoneAlertBody(done))
            : nil
        let id = current.id
        let restEnd = state.restEndsAt
        enqueue { [weak self] client in
            let shown = await client.update(id: id, state: done, staleDate: nil, alert: alert)
            // Um aviso só: a atividade alertou de fato, a notificação local daquele descanso sai.
            if shown, alert != nil { self?.gate?.suppressRestEnd(endingAt: restEnd) }
        }
        restDoneRevert?.cancel()
        let hold = restDoneHold
        restDoneRevert = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self, let snapshot = self.engine.snapshot else { return }
            self.handle(snapshot)
        }
    }

    /// O sistema encerrou a atividade (dispensada, 8 h…): esquece-a e não pede outra para a sessão.
    func systemEnded(_ id: String) {
        guard !ending.contains(id), let current, current.id == id else { return }
        systemEndedSessionID = current.sessionID
        self.current = nil
        restDoneRevert?.cancel()
        restDoneRevert = nil
        syncGate()
    }

    // MARK: Intents

    func perform(_ action: LiveActivityRestAction, sessionID: UUID) async {
        onWake?()
        start()
        let at = now()
        if let lastTap, lastTap.action == action, lastTap.sessionID == sessionID,
           abs(at.timeIntervalSince(lastTap.at)) < Self.tapDebounce { return }
        lastTap = (action, sessionID, at)
        guard engine.activeSessionID == sessionID else {
            // A sessão já acabou: o toque não faz nada e a atividade sai.
            endActivities(of: sessionID)
            syncGate()
            await waitUntilIdle()
            return
        }
        switch action {
        case .adjustRest(let seconds): engine.send(.adjustRest(seconds: seconds), issuedAt: nil)
        case .skipRest: engine.send(.skipRest, issuedAt: nil)
        }
        // Atualiza já (o app pode ser suspenso logo depois do intent); o fluxo de snapshots deduplica.
        if let snapshot = engine.snapshot { handle(snapshot) }
        await waitUntilIdle()
    }

    // MARK: Apoio

    private func show(_ snapshot: SessionSnapshot) {
        guard isEnabled else {
            if let current {
                end(current.id, state: nil, dismissal: .immediate)
                self.current = nil
            }
            return
        }
        guard let state = LiveActivityStateMapper.state(for: snapshot, now: now(), unit: unit()) else { return }
        let staleDate = LiveActivityStateMapper.staleDate(for: state)
        if var current, current.sessionID == snapshot.sessionID {
            current.revision = snapshot.revision
            defer { self.current = current }
            guard state != current.state else { return }
            restDoneRevert?.cancel()
            restDoneRevert = nil
            current.state = state
            let id = current.id
            enqueue { _ = await $0.update(id: id, state: state, staleDate: staleDate, alert: nil) }
            return
        }
        if let current {
            end(current.id, state: nil, dismissal: .immediate)
            self.current = nil
        }
        guard failedRequestSessionID != snapshot.sessionID, systemEndedSessionID != snapshot.sessionID else { return }
        let attributes = LiveActivityStateMapper.attributes(for: snapshot,
                                                            routineColorName: routineColorName(snapshot.routineID))
        do {
            let id = try client.request(attributes: attributes, state: state, staleDate: staleDate)
            current = Current(id: id, sessionID: snapshot.sessionID, state: state, revision: snapshot.revision)
            observe(id)
        } catch {
            failedRequestSessionID = snapshot.sessionID
        }
    }

    private func finish(_ snapshot: SessionSnapshot) {
        restDoneRevert?.cancel()
        restDoneRevert = nil
        guard let current, current.sessionID == snapshot.sessionID else {
            endActivities(of: snapshot.sessionID)
            return
        }
        let state = LiveActivityStateMapper.state(for: snapshot, now: now(), unit: unit())
        let end = snapshot.endedAt ?? now()
        self.end(current.id, state: state, dismissal: .after(end.addingTimeInterval(Self.finishedLinger)))
        self.current = nil
    }

    /// Encerra na hora toda atividade da sessão (atual e órfãs).
    private func endActivities(of sessionID: UUID) {
        restDoneRevert?.cancel()
        restDoneRevert = nil
        var ids = client.currentActivities().filter { $0.sessionID == sessionID }.map(\.id)
        if let current, current.sessionID == sessionID {
            if !ids.contains(current.id) { ids.append(current.id) }
            self.current = nil
        }
        for id in ids { end(id, state: nil, dismissal: .immediate) }
    }

    /// Adota a atividade da sessão em andamento (se houver e estiver habilitada); encerra as demais.
    /// A atual que sumiu do sistema conta como encerrada por ele.
    private func reconcile() {
        let active = engine.activeSessionID
        let records = client.currentActivities()
        if let current, !records.contains(where: { $0.id == current.id }), !ending.contains(current.id) {
            systemEnded(current.id)
        }
        if let current, current.sessionID != active {
            end(current.id, state: nil, dismissal: .immediate)
            self.current = nil
        }
        for record in records where record.id != current?.id {
            if record.sessionID == active, current == nil, isEnabled, systemEndedSessionID != active {
                current = Current(id: record.id, sessionID: record.sessionID, state: nil, revision: -1)
                observe(record.id)
            } else {
                end(record.id, state: nil, dismissal: .immediate)
            }
        }
        syncGate()
    }

    private func observe(_ id: String) {
        client.observeEnd(id: id) { [weak self] endedID in self?.systemEnded(endedID) }
    }

    private func end(_ id: String, state: State?, dismissal: LiveActivityDismissal) {
        guard ending.insert(id).inserted else { return }
        enqueue { [weak self] client in
            await client.end(id: id, state: state, dismissal: dismissal)
            self?.ending.remove(id)
        }
    }

    private func syncGate() {
        gate?.isLiveActivityActive = current != nil
    }

    /// Serializa as chamadas assíncronas ao ActivityKit (a ordem das atualizações é a dos eventos).
    private func enqueue(_ operation: @escaping @MainActor (any LiveActivityClient) async -> Void) {
        let previous = tail
        let client = client
        tail = Task {
            await previous?.value
            await operation(client)
        }
    }
}
