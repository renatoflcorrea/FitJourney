import Foundation
import HealthKit

/// Treino no relógio (W3b): `HKWorkoutSession` + `HKLiveWorkoutBuilder` com o tipo derivado da ficha
/// (`WatchWorkoutContext.workoutType`, calculado no iPhone pela mesma regra do Saúde), espelhada no iPhone
/// (`startMirroringToCompanionDevice`). Também é o canal de dados do espelhamento para o transporte
/// (`WatchWorkoutDataChannel`).
///
/// - Início: avisa `.recording` na hora (o iPhone não inicia a gravação dele) e depois sobe a sessão do Saúde
///   com a data de início da sessão do app; falhou ou sem permissão → `.notRecording` (o iPhone grava).
/// - Ao vivo: FC (e zona pela FC máxima 220 − idade do Saúde), FC média e energia ativa → `onMetrics`
///   (o modelo repassa ao iPhone). Sem leitura = `nil`, nunca zero.
/// - Pausa/retomada: `pause()`/`resume()` da sessão do Saúde (eventos gerados pelo próprio HealthKit).
/// - Fim com snapshot `finished`: eventos `.segment` por exercício e `.marker` por série
///   (`HealthWorkoutEventPlan`, as mesmas regras do iPhone), metadados com `HKMetadataKeyExternalUUID` =
///   ID da sessão, e `finishWorkout` → `.saved(workoutID)` (o iPhone vincula com `linkWorkout`). Falha → `.failed`.
///   Descartada → `discardWorkout`, nada gravado.
/// - Recuperação: o contexto fica em `UserDefaults`; `recoverActiveWorkout()` (chamado pelo delegate do app em
///   `handleActiveWorkoutRecovery`) reassume a sessão do Saúde depois de o app do relógio ter sido encerrado.
@MainActor
final class WatchWorkoutProvider: NSObject, WatchHealthProvider, WatchWorkoutDataChannel {
    static let contextKey = "watchWorkout.context"

    var onMetrics: (@MainActor (WatchLiveMetrics) -> Void)?
    var onStatus: (@MainActor (WatchWorkoutStatus) -> Void)?
    var onDataFromPhone: (@MainActor (Data) -> Void)?
    var onMirroringChange: (@MainActor (Bool) -> Void)?
    private(set) var isMirroring = false {
        didSet { if oldValue != isMirroring { onMirroringChange?(isMirroring) } }
    }
    /// Sessão do app cujo treino está sendo gravado aqui.
    var activeWorkoutSessionID: UUID? { context?.sessionID }

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var context: WatchWorkoutContext?
    private var zones: HeartRateZones?
    private var metrics = WatchLiveMetrics.empty

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    // MARK: Autorização

    private var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)] }
    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType(),
         HKCharacteristicType(.dateOfBirth)]
    }

    var access: WatchHealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        default: return .notDetermined
        }
    }

    func requestAccess() async -> WatchHealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        try? await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        loadZones()
        return access
    }

    private func loadZones() {
        let birth = try? store.dateOfBirthComponents()
        let age = birth?.date.flatMap { HeartRateZones.age(birthDate: $0, at: Date()) }
        zones = HeartRateZones.resolve(configuredMax: nil, age: age).zones
    }

    // MARK: Ciclo do treino

    func workoutDidBegin(_ context: WatchWorkoutContext) {
        if self.context?.sessionID == context.sessionID, session != nil { return } // já gravando (ex.: recuperada)
        if session != nil { discardCurrent() }
        guard access == .authorized else {
            onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .notRecording))
            return
        }
        self.context = context
        persist(context)
        metrics = .empty
        onMetrics?(metrics)
        // Intenção primeiro: o iPhone não liga a gravação dele para esta sessão.
        onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .recording))
        Task { await start(context) }
    }

    private func start(_ context: WatchWorkoutContext) async {
        if zones == nil { loadZones() }
        let type = context.workoutType.flatMap(HealthWorkoutType.init(rawValue:)) ?? .traditionalStrength
        let configuration = type.workoutConfiguration
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            session.startActivity(with: context.startedAt)
            try await Self.beginCollection(builder, at: context.startedAt)
            guard self.context?.sessionID == context.sessionID else { return } // trocou/encerrou enquanto iniciava
            if context.pausedAt != nil { session.pause() }
            await mirror(session)
        } catch {
            guard self.context?.sessionID == context.sessionID else { return }
            discardCurrent()
            onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .notRecording))
        }
    }

    private func mirror(_ session: HKWorkoutSession) async {
        do {
            try await Self.startMirroring(session)
            if self.session === session { isMirroring = true }
        } catch {
            isMirroring = false // segue gravando; o transporte usa o WatchConnectivity
        }
    }

    func workoutDidPause(at date: Date) { session?.pause() }
    func workoutDidResume(at date: Date) { session?.resume() }

    func workoutDidEnd(final: SessionSnapshot?) {
        guard let context else { return }
        guard let final, final.status == .finished, final.sessionID == context.sessionID, let session, let builder else {
            discardCurrent()
            return
        }
        self.session = nil
        self.builder = nil
        self.context = nil
        clearPersisted()
        isMirroring = false
        Task { await finish(final, context: context, session: session, builder: builder) }
    }

    private func finish(_ final: SessionSnapshot, context: WatchWorkoutContext, session: HKWorkoutSession,
                        builder: HKLiveWorkoutBuilder) async {
        let end = max(final.startedAt, final.endedAt ?? Date())
        let interval = DateInterval(start: min(context.startedAt, end), end: end)
        let timeline = Self.timeline(from: final)
        let plan = HealthWorkoutEventPlan.make(timeline, workout: interval)
        let type = context.workoutType.flatMap(HealthWorkoutType.init(rawValue:)) ?? timeline.workoutType
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: final.sessionID.uuidString,
            HealthMetadataKey.workoutType: type.rawValue,
            HKMetadataKeyIndoorWorkout: NSNumber(value: true),
        ]
        if !final.routineName.isEmpty { metadata[HealthMetadataKey.routineName] = final.routineName }
        do {
            let events = plan.workoutEvents
            if !events.isEmpty { try await Self.addEvents(builder, events) }
            try await Self.addMetadata(builder, metadata)
            session.stopActivity(with: end)
            session.end()
            try await Self.endCollection(builder, at: end)
            let workout = try await Self.finishWorkout(builder)
            onStatus?(WatchWorkoutStatus(sessionID: final.sessionID, state: .saved(workoutID: workout)))
        } catch {
            session.end()
            builder.discardWorkout()
            onStatus?(WatchWorkoutStatus(sessionID: final.sessionID, state: .failed))
        }
    }

    private func discardCurrent() {
        session?.end()
        builder?.discardWorkout()
        session = nil
        builder = nil
        context = nil
        clearPersisted()
        isMirroring = false
        metrics = .empty
    }

    /// Linha do tempo pura a partir do snapshot terminal (exercícios + séries concluídas em ordem).
    static func timeline(from snapshot: SessionSnapshot) -> HealthSessionTimeline {
        let exercises = snapshot.exercises.map { exercise in
            let marks = exercise.sets.enumerated().compactMap { offset, set -> HealthSessionTimeline.SetMark? in
                guard set.isCompleted, let completedAt = set.completedAt else { return nil }
                let isWorking = set.kind != .warmup && set.kind != .feeder
                return .init(id: set.id, number: offset + 1, completedAt: completedAt, isWorking: isWorking)
            }.sorted { $0.completedAt < $1.completedAt }
            return HealthSessionTimeline.Exercise(id: exercise.id, catalogExerciseID: exercise.exerciseID, name: exercise.name,
                                                  measurementKind: MeasurementKind(rawValue: exercise.measurementKind.rawValue) ?? .repsAndLoad,
                                                  sets: marks)
        }
        return HealthSessionTimeline(sessionID: snapshot.sessionID, routineName: snapshot.routineName,
                                     startedAt: snapshot.startedAt, endedAt: snapshot.endedAt,
                                     activeDuration: snapshot.endedAt.map { snapshot.elapsed(at: $0) }, exercises: exercises)
    }

    // MARK: Recuperação

    /// App do relógio reaberto com treino em curso (delegate `handleActiveWorkoutRecovery`).
    func recoverActiveWorkout() async {
        guard session == nil, let saved = persistedContext() else { return }
        guard let recovered = try? await store.recoverActiveWorkoutSession() else {
            clearPersisted()
            return
        }
        context = saved
        session = recovered
        builder = recovered.associatedWorkoutBuilder()
        recovered.delegate = self
        builder?.delegate = self
        if zones == nil { loadZones() }
        await mirror(recovered)
    }

    private func persist(_ context: WatchWorkoutContext) {
        let stored = StoredContext(sessionID: context.sessionID, startedAt: context.startedAt,
                                   routineName: context.routineName, workoutType: context.workoutType)
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.contextKey)
    }

    private func persistedContext() -> WatchWorkoutContext? {
        guard let data = defaults.data(forKey: Self.contextKey),
              let stored = try? JSONDecoder().decode(StoredContext.self, from: data) else { return nil }
        return WatchWorkoutContext(sessionID: stored.sessionID, startedAt: stored.startedAt, routineName: stored.routineName,
                                   workoutType: stored.workoutType, pausedAt: nil)
    }

    private func clearPersisted() { defaults.removeObject(forKey: Self.contextKey) }

    private struct StoredContext: Codable {
        var sessionID: UUID
        var startedAt: Date
        var routineName: String
        var workoutType: String?
    }

    // MARK: Canal de dados (espelhamento)

    func sendToPhone(_ data: Data) async throws {
        guard let session, isMirroring else { throw WatchWorkoutError.notMirroring }
        try await Self.send(session, data)
    }

    // MARK: Métricas

    fileprivate func collected(heartRate: Double?, average: Double?, energy: Double?) {
        if let heartRate, heartRate > 0 {
            metrics.heartRate = Int(heartRate.rounded())
            metrics.heartRateZone = zones?.zone(for: heartRate)?.rawValue
        }
        if let average, average > 0 { metrics.averageHeartRate = Int(average.rounded()) }
        if let energy { metrics.activeKilocalories = energy }
        onMetrics?(metrics)
    }

    fileprivate func remoteDisconnected() { isMirroring = false }

    fileprivate func failed(_ session: HKWorkoutSession) {
        guard session === self.session, let context else { return }
        discardCurrent()
        onStatus?(WatchWorkoutStatus(sessionID: context.sessionID, state: .failed))
    }

    // MARK: Pontes para APIs com callback (fora do ator: os callbacks vêm em filas do HealthKit)

    nonisolated private static func beginCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: date) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func endCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: date) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func addEvents(_ builder: HKLiveWorkoutBuilder, _ events: [HKWorkoutEvent]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addWorkoutEvents(events) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func addMetadata(_ builder: HKLiveWorkoutBuilder, _ metadata: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func finishWorkout(_ builder: HKLiveWorkoutBuilder) async throws -> UUID {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
            builder.finishWorkout { workout, error in
                if let workout { continuation.resume(returning: workout.uuid) }
                else { continuation.resume(throwing: error ?? WatchWorkoutError.saveFailed) }
            }
        }
    }

    nonisolated private static func startMirroring(_ session: HKWorkoutSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.startMirroringToCompanionDevice { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func send(_ session: HKWorkoutSession, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.sendToRemoteWorkoutSession(data: data) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

enum WatchWorkoutError: Error {
    case notMirroring
    case saveFailed
}

// MARK: Delegates (callbacks em filas do HealthKit: extraem valores e pulam para o MainActor)

extension WatchWorkoutProvider: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, ObjectIdentifier(session) == id else { return }
            self.failed(session)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor [weak self] in
            for packet in data { self?.onDataFromPhone?(packet) }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        Task { @MainActor [weak self] in self?.remoteDisconnected() }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartType = HKQuantityType(.heartRate)
        let energyType = HKQuantityType(.activeEnergyBurned)
        var heartRate: Double?, average: Double?, energy: Double?
        if collectedTypes.contains(heartType), let statistics = workoutBuilder.statistics(for: heartType) {
            heartRate = statistics.mostRecentQuantity()?.doubleValue(for: bpm)
            average = statistics.averageQuantity()?.doubleValue(for: bpm)
        }
        if collectedTypes.contains(energyType), let statistics = workoutBuilder.statistics(for: energyType) {
            energy = statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
        }
        guard heartRate != nil || average != nil || energy != nil else { return }
        Task { @MainActor [weak self] in self?.collected(heartRate: heartRate, average: average, energy: energy) }
    }
}
