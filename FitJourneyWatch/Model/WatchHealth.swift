import Foundation

/// Acesso ao Saúde no relógio (DESIGN §9.5). Negado = a sessão funciona sem `HKWorkoutSession`.
enum WatchHealthAccess: Sendable, Equatable {
    case notDetermined, authorized, denied
}

/// Métricas ao vivo da `HKWorkoutSession` do relógio. Sem leitura = `nil` (a tela mostra "—", nunca "0 bpm").
struct WatchLiveMetrics: Sendable, Equatable {
    var heartRate: Int?
    /// 1…5.
    var heartRateZone: Int?
    var activeKilocalories: Double?
    var averageHeartRate: Int?

    static let empty = WatchLiveMetrics()
}

/// O que o provedor precisa para gravar o treino de uma sessão.
struct WatchWorkoutContext: Sendable, Equatable {
    var sessionID: UUID
    var startedAt: Date
    var routineName: String
    /// `HealthWorkoutType.rawValue` (vem do digest/snapshot; `nil` = força tradicional).
    var workoutType: String?
    /// A sessão já está pausada (retomada no relógio: começar pausado).
    var pausedAt: Date?
}

/// PONTO DE INJEÇÃO (W3b): autorização do Saúde e `HKWorkoutSession` do relógio.
///
/// Implementação real: `WatchWorkoutProvider` (`HKWorkoutSession` + `HKLiveWorkoutBuilder`, espelhada no
/// iPhone). O modelo chama `workoutDidBegin` só para as sessões que o relógio grava (regra em
/// `WatchWorkoutStatus`): iniciadas aqui, ou iniciadas no iPhone quando o usuário pede "gravar no relógio".
/// Pausa/retomada seguem o estado exibido da sessão (inclusive pausas feitas no iPhone).
@MainActor
protocol WatchHealthProvider: AnyObject {
    var access: WatchHealthAccess { get }
    func requestAccess() async -> WatchHealthAccess
    /// Sessão cujo treino está sendo gravado (inclui a recuperada depois de o app ter sido encerrado).
    var activeWorkoutSessionID: UUID? { get }
    func workoutDidBegin(_ context: WatchWorkoutContext)
    func workoutDidPause(at date: Date)
    func workoutDidResume(at date: Date)
    /// Fim da gravação. `final` = snapshot terminal confirmado pelo iPhone: `finished` grava o `HKWorkout`
    /// (com eventos por exercício/série); `discarded`/`nil` descarta sem gravar.
    func workoutDidEnd(final: SessionSnapshot?)
    /// O provedor entrega métricas por aqui (definido pelo modelo ao instalar).
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)? { get set }
    /// Estado da gravação para o iPhone (o modelo repassa pelo transporte como `.workoutStatus`).
    var onStatus: (@MainActor (WatchWorkoutStatus) -> Void)? { get set }
}

/// Sem `HKWorkoutSession` (previews/simulador sem Saúde). Pede acesso → `.denied` honesto (métricas "—").
@MainActor
final class UnavailableHealthProvider: WatchHealthProvider {
    private(set) var access: WatchHealthAccess = .notDetermined
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    var onStatus: (@MainActor (WatchWorkoutStatus) -> Void)?
    let activeWorkoutSessionID: UUID? = nil
    func requestAccess() async -> WatchHealthAccess {
        access = .denied
        return access
    }
    func workoutDidBegin(_ context: WatchWorkoutContext) {
        onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .notRecording))
    }
    func workoutDidPause(at date: Date) {}
    func workoutDidResume(at date: Date) {}
    func workoutDidEnd(final: SessionSnapshot?) {}
}

/// Provedor fixo (previews, testes, harness): registra as chamadas.
@MainActor
final class FixedHealthProvider: WatchHealthProvider {
    private(set) var access: WatchHealthAccess
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    var onStatus: (@MainActor (WatchWorkoutStatus) -> Void)?
    private(set) var began = 0, ended = 0, paused = 0, resumed = 0
    private(set) var lastContext: WatchWorkoutContext?
    private(set) var lastFinal: SessionSnapshot?
    /// Simula uma sessão recuperada (ou em gravação).
    var activeWorkoutSessionID: UUID?
    init(access: WatchHealthAccess) { self.access = access }
    func requestAccess() async -> WatchHealthAccess { access == .notDetermined ? .authorized : access }
    func workoutDidBegin(_ context: WatchWorkoutContext) {
        began += 1
        lastContext = context
        activeWorkoutSessionID = context.sessionID
    }
    func workoutDidPause(at date: Date) { paused += 1 }
    func workoutDidResume(at date: Date) { resumed += 1 }
    func workoutDidEnd(final: SessionSnapshot?) {
        ended += 1
        lastFinal = final
        activeWorkoutSessionID = nil
    }
}
