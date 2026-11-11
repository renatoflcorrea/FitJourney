import Foundation
import HealthKit

/// `HealthStoreProtocol` real sobre um único `HKHealthStore` (a Apple recomenda um por app).
/// Não validável no simulador: exige iPhone (+ Apple Watch/sensor para FC).
@MainActor
final class HealthKitStore: HealthStoreProtocol, WatchAppLaunching {
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
            // Delegate definido aqui, de forma síncrona (nada que o relógio mande antes do salto ao
            // MainActor se perde: fica na fila do `MirroredWorkoutSession`).
            let remote = MirroredWorkoutSession(session: session)
            Task { @MainActor in handler(remote) }
        }
    }

    func startWatchApp(type: HealthWorkoutType) async throws {
        let configuration = type.workoutConfiguration
        let store = healthStore
        try await awaitCompletion { completion in
            store.startWatchApp(with: configuration, completion: completion)
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
                     start: start, end: max(start, end), metadata: [HealthMetadataKey.estimatedEnergy: NSNumber(value: true)])
}

@MainActor
private func finishBuilder(_ builder: HKWorkoutBuilder) async throws -> UUID? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID?, any Error>) in
        builder.finishWorkout { workout, error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: workout?.uuid) }
        }
    }
}

/// Executa os passos comuns a um builder (`HealthRecorderStep`).
@MainActor
private func perform(_ step: HealthRecorderStep, on builder: HKWorkoutBuilder, start: Date, end: Date,
                     events: [HKWorkoutEvent], metadata: HealthWorkoutMetadata, energy: HKQuantitySample?) async throws -> UUID? {
    switch step {
    case .beginCollection:
        try await awaitCompletion { builder.beginCollection(withStart: start, completion: $0) }
    case .addEnergy:
        if let energy { try await awaitCompletion { builder.add([energy], completion: $0) } }
    case .addEvents:
        try await awaitCompletion { builder.addWorkoutEvents(events, completion: $0) }
    case .addMetadata:
        let dictionary = UncheckedBox(metadata.dictionary)
        try await awaitCompletion { builder.addMetadata(dictionary.value, completion: $0) }
    case .endCollection:
        try await awaitCompletion { builder.endCollection(withEnd: end, completion: $0) }
    case .finishWorkout:
        return try await finishBuilder(builder)
    case .stopActivity, .endSession:
        break // só a sessão ao vivo
    }
    return nil
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
        if !recovered || builder.dataSource == nil {
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: session.workoutConfiguration)
        }
        let delegate = WorkoutDelegate(onUpdate: { [weak self] update in
            Task { @MainActor in self?.onLiveUpdate?(update) }
        })
        self.delegate = delegate
        session.delegate = delegate
        builder.delegate = delegate
    }

    var startDate: Date? { session.startDate }
    var isPaused: Bool { session.state == .paused }
    var isActive: Bool { session.state == .running || session.state == .paused }

    func start(at date: Date) async throws {
        guard !recovered else { return }
        session.prepare()
        session.startActivity(with: date)
        let builder = builder
        try await awaitCompletion { builder.beginCollection(withStart: date, completion: $0) }
    }

    func pause(at date: Date) { if session.state == .running { session.pause() } }
    func resume(at date: Date) { if session.state == .paused { session.resume() } }

    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? {
        let measured = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() != nil
        let energy = !measured && (estimatedEnergyKcal ?? 0) > 0
            ? energySample(kcal: estimatedEnergyKcal ?? 0, start: start, end: end) : nil
        let events = plan.workoutEvents
        var workoutID: UUID?
        for step in HealthRecorderStep.liveFinish(hasEvents: !events.isEmpty, addsEnergy: energy != nil) {
            switch step {
            case .stopActivity: session.stopActivity(with: end)
            case .endSession: session.end()
            default:
                if let id = try await perform(step, on: builder, start: start, end: end, events: events,
                                              metadata: metadata, energy: energy) {
                    workoutID = id
                }
            }
        }
        return workoutID
    }

    func discard() {
        if session.state != .ended { session.end() }
        builder.discardWorkout()
    }
}

/// `HKWorkoutBuilder` montado no fim (sem sessão ao vivo).
@MainActor
private final class BasicWorkoutRecorder: HealthWorkoutRecorder {
    let isLive = false
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?
    var startDate: Date? { nil }
    var isPaused: Bool { false }
    var isActive: Bool { false }

    private let healthStore: HKHealthStore
    private let type: HealthWorkoutType

    init(healthStore: HKHealthStore, type: HealthWorkoutType) {
        self.healthStore = healthStore
        self.type = type
    }

    func start(at date: Date) async throws {}
    func pause(at date: Date) {}
    func resume(at date: Date) {}

    /// Pausas vêm de `plan.pauses` (registradas pelo controller).
    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? {
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: type.workoutConfiguration, device: .local())
        let energy = (estimatedEnergyKcal ?? 0) > 0 ? energySample(kcal: estimatedEnergyKcal ?? 0, start: start, end: end) : nil
        let events = plan.pauseEvents + plan.workoutEvents
        var workoutID: UUID?
        for step in HealthRecorderStep.basicFinish(hasEvents: !events.isEmpty, addsEnergy: energy != nil) {
            if let id = try await perform(step, on: builder, start: start, end: end, events: events,
                                          metadata: metadata, energy: energy) {
                workoutID = id
            }
        }
        return workoutID
    }

    func discard() {}
}

// MARK: - Espelhamento (ciclo 4b)

/// Fila thread-safe entre o delegate (fila do HealthKit) e o MainActor; preserva a ordem.
private final class MirrorInbox: @unchecked Sendable {
    enum Item: Sendable {
        case data([Data])
        case end(String?)
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var sink: (@Sendable () -> Void)?

    func push(_ item: Item) {
        lock.lock()
        items.append(item)
        let sink = sink
        lock.unlock()
        sink?()
    }

    func setSink(_ sink: @escaping @Sendable () -> Void) {
        lock.lock()
        self.sink = sink
        let pending = !items.isEmpty
        lock.unlock()
        if pending { sink() }
    }

    func popAll() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let result = items
        items = []
        return result
    }
}

/// `HKWorkoutSession` espelhada do relógio. Só o canal: o W2 define o conteúdo dos pacotes.
/// O delegate é instalado no `init` (síncrono, ainda na fila do `workoutSessionMirroringStartHandler`).
@MainActor
private final class MirroredWorkoutSession: HealthRemoteWorkoutSession {
    var onRemoteData: (([Data]) -> Void)? { didSet { deliver() } }
    var onEnd: ((String?) -> Void)? { didSet { deliver() } }

    private let session: HKWorkoutSession
    private let delegate: WorkoutDelegate
    private let inbox: MirrorInbox
    /// Itens já tirados da fila, aguardando um receptor.
    private var pending: [MirrorInbox.Item] = []

    nonisolated init(session: HKWorkoutSession) {
        self.session = session
        let inbox = MirrorInbox()
        self.inbox = inbox
        let delegate = WorkoutDelegate(onUpdate: { _ in }, onRemoteData: { inbox.push(.data($0)) },
                                       onEnd: { inbox.push(.end($0)) })
        self.delegate = delegate
        session.delegate = delegate
        inbox.setSink { [weak self] in Task { @MainActor in self?.deliver() } }
    }

    var startDate: Date? { session.startDate }

    private func deliver() {
        pending += inbox.popAll()
        while let item = pending.first {
            switch item {
            case .data(let data):
                guard let onRemoteData else { return }
                pending.removeFirst()
                onRemoteData(data)
            case .end(let error):
                guard let onEnd else { return }
                pending.removeFirst()
                onEnd(error)
            }
        }
    }

    func send(_ data: Data) async throws {
        let session = session
        try await awaitCompletion { session.sendToRemoteWorkoutSession(data: data, completion: $0) }
    }
}
