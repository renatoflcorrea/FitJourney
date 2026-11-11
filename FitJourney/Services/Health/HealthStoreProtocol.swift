import Foundation

// Abstrações sobre o HealthKit para o `HealthWorkoutController` e a `HealthAuthorization`.
// Sem tipos do HealthKit nas assinaturas: os testes usam fakes (o simulador não tem Saúde real).
// Implementação real: `HealthKitStore` (HealthKitStore.swift).

/// Estado de autorização de **escrita** de um tipo (detectável pelo HealthKit).
/// A de leitura não é: negada e "sem dados" são indistinguíveis.
enum HealthSharingStatus: Sendable, Hashable {
    case notDetermined, denied, authorized
}

/// Se ainda há algo a pedir (folha de permissões do sistema).
enum HealthRequestStatus: Sendable, Hashable {
    /// A folha ainda não foi mostrada para algum dos tipos.
    case shouldRequest
    /// Já foi mostrada para todos (o usuário pode ter negado leitura — não dá para saber).
    case unnecessary
    case unknown
}

/// Metadados do `HKWorkout` gravado (SPEC §6.2).
struct HealthWorkoutMetadata: Sendable, Hashable {
    /// Vai em `HKMetadataKeyExternalUUID`: identifica o treino como do app (dedup).
    var sessionID: UUID
    var routineName: String
    var workoutType: HealthWorkoutType
}

/// Atualização ao vivo vinda do `HKLiveWorkoutBuilder` (local ou espelhado do relógio).
enum HealthLiveUpdate: Sendable, Hashable {
    case heartRate(HeartRateSample)
    /// Energia ativa acumulada no treino, em kcal.
    case activeEnergy(kilocalories: Double)
    case failed(String)
}

/// Gravador de um treino no Saúde. Duas implementações reais:
/// - ao vivo: `HKWorkoutSession` + `HKLiveWorkoutBuilder` no iPhone (iOS 26+), com FC de Watch/sensor;
/// - simples: `HKWorkoutBuilder` montado só no fim (sem FC ao vivo).
@MainActor
protocol HealthWorkoutRecorder: AnyObject {
    /// `true` = sessão ao vivo (publica FC/energia).
    var isLive: Bool { get }
    /// Chamado no MainActor a cada atualização ao vivo.
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)? { get set }

    func start(at date: Date) async throws
    func pause(at date: Date)
    func resume(at date: Date)
    /// Encerra e grava o `HKWorkout`; devolve o `uuid` gravado.
    /// - Parameter estimatedEnergyKcal: usado só quando nada foi medido (sem Watch/sensor).
    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID?
    /// Descarta sem gravar nada.
    func discard()
}

/// Sessão do relógio espelhada no iPhone (ciclo 4b). O protocolo de dados (comandos/snapshots)
/// é do W2; aqui só o canal.
@MainActor
protocol HealthRemoteWorkoutSession: AnyObject {
    var startDate: Date? { get }
    /// FC/energia do relógio (via `associatedWorkoutBuilder()` da sessão espelhada).
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)? { get set }
    /// Pacotes recebidos do relógio (`didReceiveDataFromRemoteWorkoutSession`).
    var onRemoteData: (([Data]) -> Void)? { get set }
    /// Sessão terminou no relógio ou desconectou (`nil` = término normal).
    var onEnd: ((_ error: String?) -> Void)? { get set }

    /// `sendToRemoteWorkoutSession(data:)`.
    func send(_ data: Data) async throws
}

/// Acesso ao Saúde usado pelo controller e pela autorização.
@MainActor
protocol HealthStoreProtocol: AnyObject {
    var isHealthDataAvailable: Bool { get }
    func requestAuthorization(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async throws
    func requestStatus(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async -> HealthRequestStatus
    func sharingStatus(for kind: HealthDataKind) -> HealthSharingStatus

    /// Sessão ao vivo no iPhone. Lança se o aparelho não suporta.
    func makeLiveRecorder(type: HealthWorkoutType) throws -> any HealthWorkoutRecorder
    /// Gravação simples no fim (fallback).
    func makeBasicRecorder(type: HealthWorkoutType) -> any HealthWorkoutRecorder
    /// Sessão ao vivo que sobreviveu a um encerramento do app (`recoverActiveWorkoutSession`).
    func recoverLiveRecorder() async -> (any HealthWorkoutRecorder)?

    /// Registra (ou remove) o receptor de sessões espelhadas do relógio
    /// (`workoutSessionMirroringStartHandler`). Deve ser chamado logo no lançamento do app.
    func setMirroringStartHandler(_ handler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?)

    /// Massa corporal mais recente em kg (para estimar energia); `nil` = sem dados.
    func latestBodyMassKg() async -> Double?
}
