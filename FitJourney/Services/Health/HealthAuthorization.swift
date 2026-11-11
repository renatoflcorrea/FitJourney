import Foundation
import Observation

/// Permissões e conexão com o Saúde (SPEC §6.1).
///
/// - Pedido **contextual**: a UI chama `request()` ao ativar "Conectar ao Saúde" em Ajustes ou no
///   primeiro "Finalizar treino" (`shouldAskBeforeFinishing`) — nunca na abertura do app.
/// - Escrita é detectável (`canWriteWorkouts`); **leitura não**: o HealthKit não informa negação de
///   leitura, então "sem dados" pode ser negação. A UI mostra "Sem dados do Saúde" com um atalho para
///   revisar permissões (Ajustes › Saúde › Acesso a Dados), nunca zero.
/// - `isConnectionEnabled` é a preferência do app ("Conectar ao Saúde"): desligada, nada é lido nem
///   gravado, mesmo com permissão do sistema.
@MainActor
@Observable
final class HealthAuthorization {
    static let readKinds: Set<HealthDataKind> = [.heartRate, .workouts, .activeEnergy, .restingHeartRate,
                                                  .heartRateVariability, .steps, .bodyMass]
    static let shareKinds: Set<HealthDataKind> = [.workouts, .activeEnergy]
    static let connectionKey = "health.connectionEnabled"

    enum Access: Sendable, Hashable {
        /// Aparelho sem HealthKit (iPad antigo etc.).
        case unavailable
        /// A folha de permissões ainda não foi mostrada.
        case notDetermined
        /// A folha já foi mostrada. Leitura: desconhecida (pode estar negada → "sem dados").
        case requested(canWriteWorkouts: Bool)
    }

    private(set) var access: Access = .notDetermined

    /// "Conectar ao Saúde" (preferência do app).
    var isConnectionEnabled: Bool {
        didSet { defaults.set(isConnectionEnabled, forKey: Self.connectionKey) }
    }

    @ObservationIgnored private let store: any HealthStoreProtocol
    @ObservationIgnored private let defaults: UserDefaults

    init(store: any HealthStoreProtocol, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        isConnectionEnabled = defaults.bool(forKey: Self.connectionKey)
        if !store.isHealthDataAvailable { access = .unavailable }
    }

    var isAvailable: Bool { access != .unavailable }

    /// Gravar treinos: conexão ligada e escrita de treinos autorizada.
    var canWriteWorkouts: Bool {
        guard isConnectionEnabled, case .requested(let canWrite) = access else { return false }
        return canWrite
    }

    /// Ler: conexão ligada e folha já mostrada. Não garante dados (leitura negada = sem dados).
    var canAttemptReading: Bool {
        guard isConnectionEnabled, case .requested = access else { return false }
        return true
    }

    /// No primeiro "Finalizar treino": conectar ainda não foi decidido → pedir antes de gravar.
    var shouldAskBeforeFinishing: Bool { isAvailable && access == .notDetermined }

    /// Atualiza `access` (chamar ao voltar ao primeiro plano: o usuário pode ter mudado em Ajustes).
    func refresh() async {
        guard store.isHealthDataAvailable else {
            access = .unavailable
            return
        }
        let status = await store.requestStatus(share: Self.shareKinds, read: Self.readKinds)
        access = Self.access(status: status, sharing: store.sharingStatus(for: .workouts))
    }

    /// Mostra a folha do sistema (se ainda houver o que pedir) e liga a conexão.
    @discardableResult
    func request() async -> Access {
        guard store.isHealthDataAvailable else {
            access = .unavailable
            return access
        }
        do {
            try await store.requestAuthorization(share: Self.shareKinds, read: Self.readKinds)
            isConnectionEnabled = true
        } catch {
            // Falha da folha (ex.: textos de uso ausentes): segue com o estado atual.
        }
        await refresh()
        return access
    }

    /// Desliga a conexão no app (as permissões do sistema só mudam em Ajustes › Saúde).
    func disconnect() { isConnectionEnabled = false }

    static func access(status: HealthRequestStatus, sharing: HealthSharingStatus) -> Access {
        switch (status, sharing) {
        case (_, .authorized): .requested(canWriteWorkouts: true)
        case (_, .denied): .requested(canWriteWorkouts: false)
        case (.unnecessary, _): .requested(canWriteWorkouts: false)
        case (.shouldRequest, _), (.unknown, _): .notDetermined
        }
    }
}
