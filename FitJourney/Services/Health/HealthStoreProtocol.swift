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
    /// Início da sessão do Saúde (`nil` = ainda não iniciada / gravador simples).
    var startDate: Date? { get }
    /// Sessão do Saúde pausada.
    var isPaused: Bool { get }
    /// Sessão do Saúde rodando ou pausada (não encerrada) — valida uma sessão recuperada.
    var isActive: Bool { get }
    /// Chamado no MainActor a cada atualização ao vivo.
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)? { get set }

    func start(at date: Date) async throws
    func pause(at date: Date)
    func resume(at date: Date)
    /// Grava o `HKWorkout` seguindo `HealthRecorderStep` (eventos/metadados/energia **antes** de
    /// `endCollection`); devolve o `uuid` gravado.
    /// - Parameter estimatedEnergyKcal: usado só quando nada foi medido (sem Watch/sensor).
    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID?
    /// Descarta sem gravar nada (sessão ao vivo: `end()` + `discardWorkout()`).
    func discard()
}

/// Passos da gravação, na ordem exigida pelo HealthKit: tudo que é adicionado ao builder vem antes de
/// `endCollection`, e `finishWorkout` por último. Os gravadores reais executam exatamente estas listas.
enum HealthRecorderStep: String, Sendable, Hashable {
    case beginCollection, addEnergy, addEvents, addMetadata, stopActivity, endSession, endCollection, finishWorkout

    /// Sessão ao vivo (a coleta já começou no `start`).
    static func liveFinish(hasEvents: Bool, addsEnergy: Bool) -> [HealthRecorderStep] {
        (hasEvents ? [.addEvents] : []) + [.addMetadata] + (addsEnergy ? [.addEnergy] : [])
            + [.stopActivity, .endSession, .endCollection, .finishWorkout]
    }

    /// Gravador simples (tudo no fim).
    static func basicFinish(hasEvents: Bool, addsEnergy: Bool) -> [HealthRecorderStep] {
        [.beginCollection] + (addsEnergy ? [.addEnergy] : []) + (hasEvents ? [.addEvents] : [])
            + [.addMetadata, .endCollection, .finishWorkout]
    }
}

/// Sessão do relógio espelhada no iPhone (ciclo 4b): só o canal. O protocolo de dados (comandos,
/// snapshots, métricas) é do W2. FC/energia do relógio não vêm daqui: o W2 as recebe pelo canal e
/// entrega em `HealthWorkoutController.receiveRemoteMetrics(_:)`.
@MainActor
protocol HealthRemoteWorkoutSession: AnyObject {
    var startDate: Date? { get }
    /// Pacotes recebidos do relógio (`didReceiveDataFromRemoteWorkoutSession`), em ordem.
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
