import Foundation
import HealthKit

/// Leituras do Saúde para análise (SPEC §6.3). Erro, aparelho sem HealthKit ou "Conectar ao Saúde"
/// desligado → `.unavailable`; consulta vazia → `.noData` (pode ser leitura negada — não detectável).
/// Nunca zero. Os métodos só lançam `CancellationError` (tarefa cancelada não vira "indisponível").
protocol HealthDataReading: Sendable {
    /// Amostras individuais de FC (séries do Watch expandidas) no intervalo, em ordem.
    func heartRateSamples(in interval: DateInterval) async throws -> HealthReading<[HeartRateSample]>
    /// FC agregada em baldes de `bucket` segundos (5 s na sessão, 5 min no dia).
    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async throws -> HealthReading<[HeartRateBucket]>
    /// Treinos que tocam o intervalo (do app, do Watch e de outros apps).
    func workouts(in interval: DateInterval) async throws -> HealthReading<[HealthWorkoutRecord]>
    /// Pausas (`.pause` → `.resume`) gravadas num treino; pausa sem retomada vai até o fim do treino.
    func workoutPauses(workoutID: UUID) async throws -> HealthReading<[DateInterval]>
    func activeEnergyKcal(in interval: DateInterval) async throws -> HealthReading<Double>
    func steps(in interval: DateInterval) async throws -> HealthReading<Double>
    /// FC em repouso, um valor (média) por dia.
    func restingHeartRate(days interval: DateInterval) async throws -> HealthReading<[HealthDailyValue]>
    func latestBodyMassKg() async throws -> HealthReading<Double>
}

/// `HealthDataReading` real (HealthKit). Use `HealthQueries.live`.
struct HealthQueries: HealthDataReading {
    let store: HKHealthStore
    var calendar: Calendar
    /// "Conectar ao Saúde" ligado (padrão: a preferência em `UserDefaults.standard`).
    let isEnabled: @Sendable () -> Bool

    init(store: HKHealthStore, calendar: Calendar = .current,
         isEnabled: @escaping @Sendable () -> Bool = HealthQueries.connectionEnabledInDefaults) {
        self.store = store
        self.calendar = calendar
        self.isEnabled = isEnabled
    }

    @Sendable static func connectionEnabledInDefaults() -> Bool {
        UserDefaults.standard.bool(forKey: HealthAuthorization.connectionKey)
    }

    private var canRead: Bool { HKHealthStore.isHealthDataAvailable() && isEnabled() }

    private func predicate(_ interval: DateInterval) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
    }

    /// Roda a consulta: cancelamento propaga; outros erros viram `.unavailable`.
    private func read<T: Sendable>(_ body: () async throws -> HealthReading<T>) async throws -> HealthReading<T> {
        guard canRead else { return .unavailable }
        try Task.checkCancellation()
        do {
            return try await body()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .unavailable
        }
    }

    func heartRateSamples(in interval: DateInterval) async throws -> HealthReading<[HeartRateSample]> {
        try await read {
            let descriptor = HKQuantitySeriesSampleQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate(interval)),
                options: .orderByQuantitySampleStartDate)
            var samples: [HeartRateSample] = []
            for try await result in descriptor.results(for: store) {
                let date = result.dateInterval.start
                guard interval.contains(date) else { continue }
                samples.append(HeartRateSample(date: date, bpm: result.quantity.doubleValue(for: HealthUnits.bpm)))
            }
            samples = HeartRateAnalysis.valid(samples)
            return samples.isEmpty ? .noData : .available(samples)
        }
    }

    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async throws -> HealthReading<[HeartRateBucket]> {
        guard bucket >= 1 else { return .unavailable }
        return try await read {
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate(interval)),
                options: [.discreteAverage, .discreteMin, .discreteMax], anchorDate: interval.start,
                intervalComponents: DateComponents(second: Int(bucket.rounded())))
            let collection = try await descriptor.result(for: store)
            var buckets: [HeartRateBucket] = []
            collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
                guard let average = statistics.averageQuantity()?.doubleValue(for: HealthUnits.bpm), average > 0 else { return }
                buckets.append(HeartRateBucket(
                    interval: DateInterval(start: statistics.startDate, end: statistics.endDate), average: average,
                    minimum: statistics.minimumQuantity()?.doubleValue(for: HealthUnits.bpm) ?? average,
                    maximum: statistics.maximumQuantity()?.doubleValue(for: HealthUnits.bpm) ?? average))
            }
            return buckets.isEmpty ? .noData : .available(buckets)
        }
    }

    func workouts(in interval: DateInterval) async throws -> HealthReading<[HealthWorkoutRecord]> {
        try await read {
            let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate(interval))],
                                                     sortDescriptors: [SortDescriptor(\.startDate)])
            let workouts = try await descriptor.result(for: store).map { HealthWorkoutRecord(workout: $0) }
            return workouts.isEmpty ? .noData : .available(workouts)
        }
    }

    func workoutPauses(workoutID: UUID) async throws -> HealthReading<[DateInterval]> {
        try await read {
            let descriptor = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: workoutID))],
                                                     sortDescriptors: [], limit: 1)
            guard let workout = try await descriptor.result(for: store).first else { return .noData }
            var pauses: [DateInterval] = []
            var openPause: Date?
            for event in (workout.workoutEvents ?? []).sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
                switch event.type {
                case .pause, .motionPaused:
                    if openPause == nil { openPause = event.dateInterval.start }
                case .resume, .motionResumed:
                    if let start = openPause {
                        pauses.append(DateInterval(start: start, end: max(start, event.dateInterval.start)))
                        openPause = nil
                    }
                default:
                    continue
                }
            }
            if let start = openPause { pauses.append(DateInterval(start: start, end: max(start, workout.endDate))) }
            return .available(pauses)
        }
    }

    private func cumulativeSum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                               in interval: DateInterval) async throws -> HealthReading<Double> {
        try await read {
            let descriptor = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate(interval)), options: .cumulativeSum)
            guard let sum = try await descriptor.result(for: store)?.sumQuantity() else { return .noData }
            return .available(sum.doubleValue(for: unit))
        }
    }

    func activeEnergyKcal(in interval: DateInterval) async throws -> HealthReading<Double> {
        try await cumulativeSum(.activeEnergyBurned, unit: HealthUnits.kilocalorie, in: interval)
    }

    func steps(in interval: DateInterval) async throws -> HealthReading<Double> {
        try await cumulativeSum(.stepCount, unit: HealthUnits.count, in: interval)
    }

    func restingHeartRate(days interval: DateInterval) async throws -> HealthReading<[HealthDailyValue]> {
        try await read {
            let anchor = calendar.startOfDay(for: interval.start)
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(.restingHeartRate), predicate: predicate(interval)),
                options: .discreteAverage, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            let collection = try await descriptor.result(for: store)
            var values: [HealthDailyValue] = []
            collection.enumerateStatistics(from: anchor, to: interval.end) { statistics, _ in
                guard let average = statistics.averageQuantity()?.doubleValue(for: HealthUnits.bpm) else { return }
                values.append(HealthDailyValue(day: statistics.startDate, value: average))
            }
            return values.isEmpty ? .noData : .available(values)
        }
    }

    func latestBodyMassKg() async throws -> HealthReading<Double> {
        try await read {
            let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                                                     sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
            guard let sample = try await descriptor.result(for: store).first else { return .noData }
            return .available(sample.quantity.doubleValue(for: HealthUnits.kilogram))
        }
    }
}

// MARK: - Composições para a UI

extension HealthDataReading {
    /// FC da sessão com faixas por exercício e séries (detalhe da sessão, P4.2).
    /// - Parameter workoutID: `WorkoutSession.healthKitWorkoutID`; se informado e a linha do tempo não
    ///   trouxer pausas, as pausas do treino gravado são excluídas das contas.
    func sessionHeartRate(_ timeline: HealthSessionTimeline, zones: HeartRateZones?, workoutID: UUID? = nil,
                          now: Date = Date()) async throws -> HealthReading<SessionHeartRateAnalysis> {
        var timeline = timeline
        if timeline.pauses.isEmpty, let workoutID, let pauses = try await workoutPauses(workoutID: workoutID).value {
            timeline.pauses = pauses
        }
        let interval = timeline.interval(now: now)
        let resolved = timeline
        return try await heartRateSamples(in: interval).map {
            SessionHeartRateAnalyzer.analyze(resolved, samples: $0, zones: zones, now: now)
        }
    }

    /// Resumo de um dia (aba Saúde, P4.3): treinos vinculados/deduplicados, FC (baldes de 5 min), energia,
    /// repouso, passos — cada um com seu estado de leitura.
    /// `sessions`: `HealthSessionWindow.windows(in:context:)` do mesmo dia.
    func daySummary(_ day: Date, sessions: [HealthSessionWindow], calendar: Calendar = .current) async throws -> HealthDaySummary {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        async let workouts = workouts(in: interval)
        async let heartRate = heartRateBuckets(in: interval, bucket: 300)
        async let energy = activeEnergyKcal(in: interval)
        async let resting = restingHeartRate(days: interval)
        async let steps = steps(in: interval)
        let restingValue: HealthReading<Double> = switch try await resting {
        case .available(let values): values.last.map { .available($0.value) } ?? .noData
        case .noData: .noData
        case .unavailable: .unavailable
        }
        return try await HealthDayAnalyzer.summarize(
            day: interval, workouts: workouts, sessions: sessions, heartRate: heartRate,
            activeEnergyKcal: energy, restingHeartRate: restingValue, steps: steps)
    }
}

extension HealthDataReading where Self == HealthQueries {
    /// Leitor real sobre o `HKHealthStore` do app (respeita "Conectar ao Saúde").
    @MainActor static var live: HealthQueries { HealthQueries(store: HealthKitStore.shared.healthStore) }
}
