import Foundation
import Observation
import SwiftUI

/// FC ao vivo (ciclo 4). Enquanto não houver fonte, o coordenador mantém `nil` e a tela mostra "—".
struct SessionHeartRate: Equatable, Sendable {
    var bpm: Int
    var zone: FJHeartRateZone?
}

/// Apresentação da sessão: tela cheia, acessório e hápticos dirigidos pelos eventos do motor.
///
/// API fixa (o supervisor liga no `AppRoot` e na aba Hoje):
/// - `start(routine:)` inicia (ou reabre) a sessão e a apresenta;
/// - `isPresented` controla a tela cheia (minimizada = acessório);
/// - `View.sessionHost(_:)` instala cover, acessório, treino esquecido e ciclo de vida.
///
/// Toda escrita na sessão passa por `engine.send` (via `send(_:)`).
@MainActor
@Observable
final class SessionCoordinator {
    @ObservationIgnored static let presentedKey = "fj.session.presented"

    let engine: SessionEngine
    /// Tela cheia aberta. Minimizar = `false` com sessão ativa (o acessório aparece).
    var isPresented = false {
        didSet {
            guard oldValue != isPresented, engine.snapshot != nil else { return }
            defaults.set(isPresented, forKey: Self.presentedKey)
        }
    }
    /// Ponto de ligação da FC (ciclo 4). `nil` = indisponível.
    var heartRate: SessionHeartRate?
    /// Autorização das notificações de fim de descanso (`nil` = ainda não consultada).
    private(set) var notificationAuthorization: RestNotificationAuthorization?
    /// Explicação contextual antes do pedido de permissão (1º descanso).
    var showsNotificationRationale = false

    /// A doca está mostrando o painel de descanso (que vibra e anuncia sozinho ao zerar).
    var restPanelVisible = false

    // Gatilhos de háptico (contadores: mudar dispara).
    private(set) var setCompletedTick = 0
    private(set) var restFinishedTick = 0
    private(set) var celebrationTick = 0
    private(set) var errorTick = 0
    /// Última falha de comando para a UI ("Não foi possível salvar").
    private(set) var lastRejection: SessionCommandRejection?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var restored = false

    init(engine: SessionEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
    }

    // MARK: Ciclo de vida

    /// Inicia a sessão da ficha (`nil` = treino livre). Se já há uma em andamento, só a reabre.
    func start(routine: Routine?) {
        let result = engine.send(.start(routineID: routine?.id))
        switch result {
        case .applied, .duplicate:
            present()
        case .rejected(.anotherSessionInProgress):
            present()
        case .rejected(let reason):
            fail(reason)
        }
    }

    func present() { isPresented = engine.snapshot != nil }

    func minimize() { isPresented = false }

    /// Ao abrir o app: carrega a sessão e reabre a tela como estava (cheia ou minimizada).
    func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        engine.restore()
        if engine.snapshot != nil, engine.staleSessionPrompt == nil {
            isPresented = defaults.object(forKey: Self.presentedKey) as? Bool ?? true
        }
        Task { await refreshNotificationAuthorization() }
    }

    func handleForeground() {
        engine.handleForeground()
        Task { await refreshNotificationAuthorization() }
    }

    // MARK: Comandos

    /// Envia um comando ao motor. `false` = recusado (háptico de erro e `lastRejection`).
    @discardableResult
    func send(_ kind: SessionCommand.Kind) -> Bool {
        let result = engine.send(kind)
        if let reason = result.rejection {
            fail(reason)
            return false
        }
        lastRejection = nil
        return true
    }

    /// Conclui/desfaz uma série pelo check. O `FJCheckButton` vibra sozinho ao ir para "concluída",
    /// qualquer que seja a origem, enquanto a linha está na tela; por isso o evento só vibra com a tela fechada.
    func toggleSet(_ set: SessionSnapshot.ExerciseSet) {
        if set.isCompleted {
            send(.uncompleteSet(setID: set.id))
        } else {
            send(.completeSet(setID: set.id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil))
        }
    }

    private func fail(_ reason: SessionCommandRejection) {
        lastRejection = reason
        errorTick += 1
    }

    // MARK: Eventos

    /// Consome os eventos do motor (hápticos, permissão contextual, fechar a tela). Roda até cancelar.
    func listen() async {
        for await event in engine.events() {
            handle(event)
        }
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .sessionStarted:
            present()
        case .setCompleted:
            // Com a tela aberta o check da linha já vibra (inclusive para séries vindas do relógio).
            if !isPresented { setCompletedTick += 1 }
        case .restStarted:
            Task { await askNotificationPermissionIfNeeded() }
        case .restFinished:
            // O painel do descanso já vibra e anuncia sozinho; fora dele (outro modo da doca ou tela fechada) vibra aqui.
            if !(isPresented && restPanelVisible) { restFinishedTick += 1 }
        case .sessionFinished:
            isPresented = false
            celebrationTick += 1
        case .sessionDiscarded:
            isPresented = false
        case .restAdjusted, .restSkipped, .holdStarted, .sessionPaused, .sessionResumed:
            break
        }
    }

    // MARK: Permissão de notificação (contextual)

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await engine.notificationAuthorization()
    }

    /// Na 1ª vez que um descanso começa: explica o porquê antes do pedido do sistema.
    func askNotificationPermissionIfNeeded() async {
        await refreshNotificationAuthorization()
        guard notificationAuthorization == .notDetermined,
              !defaults.bool(forKey: "fj.session.restPermissionExplained") else { return }
        defaults.set(true, forKey: "fj.session.restPermissionExplained")
        showsNotificationRationale = true
    }

    func confirmNotificationPermission() async {
        showsNotificationRationale = false
        _ = await engine.requestNotificationPermission()
        await refreshNotificationAuthorization()
    }
}

// MARK: - Host

extension View {
    /// Instala a sessão na raiz: tela cheia, acessório acima da tab bar, treino esquecido e
    /// ciclo de vida (`scenePhase` → `handleForeground`). Aplique no `TabView` do `AppRoot`.
    func sessionHost(_ coordinator: SessionCoordinator) -> some View {
        modifier(SessionHostModifier(coordinator: coordinator))
    }
}

private struct SessionHostModifier: ViewModifier {
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private var engine: SessionEngine { coordinator.engine }

    @State private var staleVisible = false
    @State private var coverShown = false

    private var coverIsUp: Bool {
        coordinator.isPresented && engine.snapshot != nil && engine.staleSessionPrompt == nil
    }

    /// O treino esquecido fecha o cover sem apagar `isPresented`: o sheet abre no `onDismiss`.
    private var coverBinding: Binding<Bool> {
        Binding(
            get: { coverIsUp },
            set: { if !$0, engine.staleSessionPrompt == nil { coordinator.isPresented = false } }
        )
    }

    private var staleBinding: Binding<Bool> {
        Binding(get: { staleVisible && engine.staleSessionPrompt != nil }, set: { _ in })
    }

    private var showsAccessory: Bool {
        engine.snapshot != nil && !coordinator.isPresented
    }

    func body(content: Content) -> some View {
        content
            .modifier(SessionAccessoryModifier(coordinator: coordinator, isEnabled: showsAccessory))
            .fullScreenCover(isPresented: coverBinding, onDismiss: {
                coverShown = false
                if engine.staleSessionPrompt != nil { staleVisible = true }
            }) {
                SessionView(coordinator: coordinator)
                    .onAppear { coverShown = true }
            }
            .background {
                Color.clear.sheet(isPresented: staleBinding) {
                    if let prompt = engine.staleSessionPrompt {
                        StaleSessionSheet(prompt: prompt, engine: engine, onContinue: { coordinator.present() })
                    }
                }
            }
            .fjHaptic(.setCompleted, trigger: coordinator.setCompletedTick)
            .fjHaptic(.timerFinished, trigger: coordinator.restFinishedTick)
            .fjHaptic(.celebration, trigger: coordinator.celebrationTick)
            .fjHaptic(.error, trigger: coordinator.errorTick)
            .task {
                coordinator.restoreIfNeeded()
                if engine.staleSessionPrompt != nil { staleVisible = true }
                await coordinator.listen()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { coordinator.handleForeground() }
            }
            .onChange(of: engine.snapshot?.sessionID) { _, id in
                if id == nil { coordinator.isPresented = false }
            }
            .onChange(of: engine.staleSessionPrompt?.sessionID) { _, id in
                // Sem cover aberto o sheet entra já; com cover, entra no `onDismiss`.
                staleVisible = id != nil && !coverShown
            }
    }
}

/// Acessório flutuante acima da tab bar. `isEnabled:` só existe a partir do iOS 26.1.
private struct SessionAccessoryModifier: ViewModifier {
    let coordinator: SessionCoordinator
    let isEnabled: Bool

    @ViewBuilder
    private var accessory: some View {
        if let snapshot = coordinator.engine.snapshot {
            Button { coordinator.present() } label: {
                FJSessionAccessory(
                    routineName: SessionPresentation.routineTitle(snapshot),
                    startedAt: snapshot.startedAt,
                    pausedSeconds: snapshot.accumulatedPauseSeconds,
                    pausedAt: snapshot.pausedAt,
                    detail: SessionPresentation.accessoryDetail(snapshot),
                    restEndsAt: snapshot.restEndsAt
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) { accessory }
        } else if isEnabled {
            content.tabViewBottomAccessory { accessory }
        } else {
            content
        }
    }
}

// MARK: - Treino esquecido

/// "Você tem um treino em aberto desde ontem, 19:40" (D4).
struct StaleSessionSheet: View {
    let prompt: StaleSessionPrompt
    let engine: SessionEngine
    var onContinue: () -> Void = {}
    @State private var confirmsDiscard = false
    @State private var failed = false

    private func resolve(_ resolution: StaleSessionResolution) {
        failed = false
        if engine.resolveStaleSession(resolution) {
            if case .keepGoing = resolution { onContinue() }
        } else {
            failed = true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FJSpacing.l) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(FJColor.attention)
                    .accessibilityHidden(true)
                Text("Você tem um treino em aberto")
                    .font(FJFont.screenTitle)
                Text("\(prompt.routineName.isEmpty ? String(localized: "Treino livre") : prompt.routineName), iniciado e sem registro desde \(Self.when(prompt.lastActivityAt)).")
                    .font(FJFont.body)
                    .foregroundStyle(FJColor.textSecondary)
                Spacer(minLength: 0)
                if failed {
                    FJBanner("Não foi possível concluir", message: "Tente de novo. Seu treino continua salvo.", tone: .destructive)
                }
                VStack(spacing: FJSpacing.s) {
                    Button {
                        resolve(.finishAtLastSet())
                    } label: {
                        Text("Finalizar às \(prompt.suggestedEndAt.formatted(date: .omitted, time: .shortened)), na última série")
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.fjPrimary(.training))
                    Button("Continuar treino") { resolve(.keepGoing) }
                        .buttonStyle(.fjSecondary())
                    Button("Descartar treino", role: .destructive) { confirmsDiscard = true }
                        .frame(minHeight: FJSize.minTap)
                }
            }
            .padding(FJSpacing.screenMargin)
            .fjScreenBackground()
            .confirmationDialog("Descartar este treino?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Descartar treino", role: .destructive) { resolve(.discard) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Nada será salvo no histórico.")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .tint(FJColor.training)
    }

    /// "ontem, 19:40" / "seg., 19:40".
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "hoje, \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "ontem, \(time)")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
    }
}
