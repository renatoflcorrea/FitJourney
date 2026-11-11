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

/// PONTO DE INJEÇÃO (W3b): autorização do Saúde e `HKWorkoutSession`.
///
/// O W3b implementa isto com `HKHealthStore` + `HKWorkoutSession`/`HKLiveWorkoutBuilder` (e o espelhamento
/// com o iPhone) e empurra `WatchSessionModel.liveMetrics`/`healthAccess` a partir de `onMetrics`.
/// `begin`/`pause`/`resume`/`end` são chamados pelo modelo nas transições da sessão.
@MainActor
protocol WatchHealthProvider: AnyObject {
    var access: WatchHealthAccess { get }
    func requestAccess() async -> WatchHealthAccess
    /// Chamado quando o modelo vê uma sessão começar (iniciada aqui ou no iPhone).
    func workoutDidBegin(sessionID: UUID, startedAt: Date)
    func workoutDidPause()
    func workoutDidResume()
    func workoutDidEnd()
    /// O provedor entrega métricas por aqui (definido pelo modelo ao instalar).
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)? { get set }
}

/// Provedor de W3a: não há `HKWorkoutSession` ainda. Pede acesso → `.denied` honesto (métricas "—").
@MainActor
final class UnavailableHealthProvider: WatchHealthProvider {
    private(set) var access: WatchHealthAccess = .notDetermined
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    func requestAccess() async -> WatchHealthAccess {
        access = .denied
        return access
    }
    func workoutDidBegin(sessionID: UUID, startedAt: Date) {}
    func workoutDidPause() {}
    func workoutDidResume() {}
    func workoutDidEnd() {}
}

/// Provedor fixo (previews, testes, harness).
@MainActor
final class FixedHealthProvider: WatchHealthProvider {
    private(set) var access: WatchHealthAccess
    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    private(set) var began = 0, ended = 0
    init(access: WatchHealthAccess) { self.access = access }
    func requestAccess() async -> WatchHealthAccess { access == .notDetermined ? .authorized : access }
    func workoutDidBegin(sessionID: UUID, startedAt: Date) { began += 1 }
    func workoutDidPause() {}
    func workoutDidResume() {}
    func workoutDidEnd() { ended += 1 }
}
