import Foundation
import HealthKit

/// `HealthStoreProtocol` real sobre um único `HKHealthStore` (a Apple recomenda um por app).
/// Não validável no simulador: exige iPhone (+ Apple Watch/sensor para FC).
@MainActor
final class HealthKitStore: HealthStoreProtocol {
    /// Instância única do app.
    static let shared = HealthKitStore()

    nonisolated let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async throws {
        try await healthStore.requestAuthorization(toShare: Set(share.map(\.sampleType)), read: Set(read.map(\.objectType)))
    }

    func requestStatus(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async -> HealthRequestStatus {
        let status = try? await healthStore.statusForAuthorizationRequest(toShare: Set(share.map(\.sampleType)),
                                                                          read: Set(read.map(\.objectType)))
        switch status {
        case .shouldRequest?: return .shouldRequest
        case .unnecessary?: return .unnecessary
        default: return .unknown
        }
    }

    func sharingStatus(for kind: HealthDataKind) -> HealthSharingStatus {
        switch healthStore.authorizationStatus(for: kind.objectType) {
        case .sharingAuthorized: .authorized
        case .sharingDenied: .denied
        default: .notDetermined
        }
    }

    func makeLiveRecorder(type: HealthWorkoutType) throws -> any HealthWorkoutRecorder {
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: type.workoutConfiguration)
        return LiveWorkoutRecorder(session: session, healthStore: healthStore)
    }

    func makeBasicRecorder(type: HealthWorkoutType) -> any HealthWorkoutRecorder {
        BasicWorkoutRecorder(healthStore: healthStore, type: type)
    }

    func recoverLiveRecorder() async -> (any HealthWorkoutRecorder)? {
        let box: UncheckedBox<HKWorkoutSession>? = await withCheckedContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, _ in
                continuation.resume(returning: session.map(UncheckedBox.init))
            }
        }
        guard let session = box?.value else { return nil }
        return LiveWorkoutRecorder(session: session, healthStore: healthStore, recovered: true)
    }

    func setMirroringStartHandler(_ handler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?) {
        guard let handler else {
            healthStore.workoutSessionMirroringStartHandler = nil
            return
        }
        healthStore.workoutSessionMirroringStartHandler = { session in
            let box = UncheckedBox(session)
            Task { @MainActor in handler(MirroredWorkoutSession(session: box.value)) }
        }
    }

    func latestBodyMassKg() async -> Double? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        let sample = try? await descriptor.result(for: healthStore).first
        return sample?.quantity.doubleValue(for: HealthUnits.kilogram)
    }
}

/// Atravessa uma fronteira de isolamento com objetos do HealthKit que não são `Sendable` mas são
/// usados só do outro lado (entregues pelo sistema numa fila qualquer).
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Delegado (filas do HealthKit → MainActor)

/// Recebe callbacks do `HKWorkoutSession`/`HKLiveWorkoutBuilder` (fila arbitrária), extrai só valores
/// `Sendable` e repassa ao MainActor.
private final class WorkoutDelegate: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, @unchecked Sendable {
    let onUpdate: @Sendable (HealthLiveUpdate) -> Void
    let onRemoteData: @Sendable ([Data]) -> Void
    let onEnd: @Sendable (String?) -> Void

    init(onUpdate: @escaping @Sendable (HealthLiveUpdate) -> Void,
         onRemoteData: @escaping @Sendable ([Data]) -> Void = { _ in },
         onEnd: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.onUpdate = onUpdate
        self.onRemoteData = onRemoteData
        self.onEnd = onEnd
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended || toState == .stopped { onEnd(nil) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        onUpdate(.failed(error.localizedDescription))
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        onRemoteData(data)
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        onEnd(error?.localizedDescription ?? "disconnected")
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        if collectedTypes.contains(heartRateType), let stats = workoutBuilder.statistics(for: heartRateType),
           let quantity = stats.mostRecentQuantity() {
            let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
            onUpdate(.heartRate(HeartRateSample(date: date, bpm: quantity.doubleValue(for: HealthUnits.bpm))))
        }
        let energyType = HKQuantityType(.activeEnergyBurned)
        if collectedTypes.contains(energyType), let sum = workoutBuilder.statistics(for: energyType)?.sumQuantity() {
            onUpdate(.activeEnergy(kilocalories: sum.doubleValue(for: HealthUnits.kilocalorie)))
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Gravadores

/// Completion do HealthKit → async, sem enviar o objeto não-Sendable para fora do MainActor.
@MainActor
private func awaitCompletion(_ call: (@escaping @Sendable (Bool, (any Error)?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        call { success, error in
            if success { continuation.resume() } else { continuation.resume(throwing: error ?? HealthRecorderError.failed) }
        }
    }
}

enum HealthRecorderError: Error {
    case failed
}

private func energySample(kcal: Double, start: Date, end: Date) -> HKQuantitySample {
    HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: HealthUnits.kilocalorie, doubleValue: kcal),
                     start: start, end: max(start, end))
}

/// `HKWorkoutSession` + `HKLiveWorkoutBuilder` no iPhone (iOS 26+).
@MainActor
private final class LiveWorkoutRecorder: HealthWorkoutRecorder {
    let isLive = true
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?

    private let session: HKWorkoutSession
    private let builder: HKLiveWorkoutBuilder
    private var delegate: WorkoutDelegate?
    private let recovered: Bool

    init(session: HKWorkoutSession, healthStore: HKHealthStore, recovered: Bool = false) {
        self.session = session
        self.recovered = recovered
        builder = session.associatedWorkoutBuilder()
        if !recovered {
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: session.workoutConfiguration)
        }
        let delegate = WorkoutDelegate(onUpdate: { [weak self] update in
            Task { @MainActor in self?.onLiveUpdate?(update) }
        })
        self.delegate = delegate
        session.delegate = delegate
        builder.delegate = delegate
    }

    func start(at date: Date) async throws {
        guard !recovered else { return }
        session.prepare()
        session.startActivity(with: date)
        let builder = builder
        try await awaitCompletion { builder.beginCollection(withStart: date, completion: $0) }
    }

    func pause(at date: Date) { session.pause() }
    func resume(at date: Date) { session.resume() }

    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? {
        session.stopActivity(with: end)
        session.end()
        let builder = builder
        try await awaitCompletion { builder.endCollection(withEnd: end, completion: $0) }
        let events = plan.workoutEvents
        if !events.isEmpty { try await awaitCompletion { builder.addWorkoutEvents(events, completion: $0) } }
        let dictionary = UncheckedBox(metadata.dictionary)
        try await awaitCompletion { builder.addMetadata(dictionary.value, completion: $0) }
        let measured = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() != nil
        if !measured, let estimatedEnergyKcal, estimatedEnergyKcal > 0 {
            let sample = energySample(kcal: estimatedEnergyKcal, start: start, end: end)
            try await awaitCompletion { builder.add([sample], completion: $0) }
        }
        return try await finishBuilder(builder)
    }

    func discard() {
        session.end()
        builder.discardWorkout()
    }
}

/// `HKWorkoutBuilder` montado no fim (sem sessão ao vivo).
@MainActor
private final class BasicWorkoutRecorder: HealthWorkoutRecorder {
    let isLive = false
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?

    private let healthStore: HKHealthStore
    private let type: HealthWorkoutType
    private var pauses: [(type: HKWorkoutEventType, date: Date)] = []

    init(healthStore: HKHealthStore, type: HealthWorkoutType) {
        self.healthStore = healthStore
        self.type = type
    }

    func start(at date: Date) async throws {}
    func pause(at date: Date) { pauses.append((.pause, date)) }
    func resume(at date: Date) { pauses.append((.resume, date)) }

    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? {
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: type.workoutConfiguration, device: .local())
        try await awaitCompletion { builder.beginCollection(withStart: start, completion: $0) }
        if let estimatedEnergyKcal, estimatedEnergyKcal > 0 {
            let sample = energySample(kcal: estimatedEnergyKcal, start: start, end: end)
            try await awaitCompletion { builder.add([sample], completion: $0) }
        }
        let pauseEvents = pauses.filter { $0.date >= start && $0.date <= end }.map {
            HKWorkoutEvent(type: $0.type, dateInterval: DateInterval(start: $0.date, duration: 0), metadata: nil)
        }
        let events = pauseEvents + plan.workoutEvents
        if !events.isEmpty { try await awaitCompletion { builder.addWorkoutEvents(events, completion: $0) } }
        let dictionary = UncheckedBox(metadata.dictionary)
        try await awaitCompletion { builder.addMetadata(dictionary.value, completion: $0) }
        try await awaitCompletion { builder.endCollection(withEnd: end, completion: $0) }
        return try await finishBuilder(builder)
    }

    func discard() { pauses = [] }
}

@MainActor
private func finishBuilder(_ builder: HKWorkoutBuilder) async throws -> UUID? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID?, any Error>) in
        builder.finishWorkout { workout, error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: workout?.uuid) }
        }
    }
}

// MARK: - Espelhamento (ciclo 4b)

/// `HKWorkoutSession` espelhada do relógio. Só o canal: o W2 define o conteúdo dos pacotes.
@MainActor
private final class MirroredWorkoutSession: HealthRemoteWorkoutSession {
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?
    var onRemoteData: (([Data]) -> Void)?
    var onEnd: ((String?) -> Void)?

    private let session: HKWorkoutSession
    /// Builder da sessão espelhada (FC/energia do relógio); mantido vivo aqui (delegate é fraco).
    private let builder: HKLiveWorkoutBuilder
    private var delegate: WorkoutDelegate?

    init(session: HKWorkoutSession) {
        self.session = session
        builder = session.associatedWorkoutBuilder()
        let delegate = WorkoutDelegate(
            onUpdate: { [weak self] update in Task { @MainActor in self?.onLiveUpdate?(update) } },
            onRemoteData: { [weak self] data in Task { @MainActor in self?.onRemoteData?(data) } },
            onEnd: { [weak self] error in Task { @MainActor in self?.onEnd?(error) } })
        self.delegate = delegate
        session.delegate = delegate
        builder.delegate = delegate
    }

    var startDate: Date? { session.startDate }

    func send(_ data: Data) async throws {
        let session = session
        try await awaitCompletion { session.sendToRemoteWorkoutSession(data: data, completion: $0) }
    }
}
