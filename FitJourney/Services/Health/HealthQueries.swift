import Foundation
import HealthKit

/// Leituras do Saúde para análise (SPEC §6.3). Nenhuma lança: erro/indisponível vira `.unavailable`,
/// consulta vazia vira `.noData` (pode ser leitura negada — não detectável). Nunca zero.
protocol HealthDataReading: Sendable {
    /// Amostras individuais de FC (séries do Watch expandidas) no intervalo, em ordem.
    func heartRateSamples(in interval: DateInterval) async -> HealthReading<[HeartRateSample]>
    /// FC agregada em baldes de `bucket` segundos (5 s na sessão, 5 min no dia).
    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async -> HealthReading<[HeartRateBucket]>
    /// Treinos que tocam o intervalo (do app, do Watch e de outros apps).
    func workouts(in interval: DateInterval) async -> HealthReading<[HealthWorkoutRecord]>
    func activeEnergyKcal(in interval: DateInterval) async -> HealthReading<Double>
    func steps(in interval: DateInterval) async -> HealthReading<Double>
    /// FC em repouso, um valor (média) por dia.
    func restingHeartRate(days interval: DateInterval) async -> HealthReading<[HealthDailyValue]>
    func latestBodyMassKg() async -> HealthReading<Double>
}

/// `HealthDataReading` real (HealthKit). Use `HealthQueries(store: HealthKitStore.shared.healthStore)`.
struct HealthQueries: HealthDataReading {
    let store: HKHealthStore
    var calendar: Calendar = .current

    init(store: HKHealthStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    private func predicate(_ interval: DateInterval) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
    }

    func heartRateSamples(in interval: DateInterval) async -> HealthReading<[HeartRateSample]> {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate(interval)),
            options: .orderByQuantitySampleStartDate)
        do {
            var samples: [HeartRateSample] = []
            for try await result in descriptor.results(for: store) {
                let date = result.dateInterval.start
                guard interval.contains(date) else { continue }
                samples.append(HeartRateSample(date: date, bpm: result.quantity.doubleValue(for: HealthUnits.bpm)))
            }
            samples.sort { $0.date < $1.date }
            return samples.isEmpty ? .noData : .available(samples)
        } catch {
            return .unavailable
        }
    }

    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async -> HealthReading<[HeartRateBucket]> {
        guard HKHealthStore.isHealthDataAvailable(), bucket >= 1 else { return .unavailable }
        let seconds = Int(bucket.rounded())
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate(interval)),
            options: [.discreteAverage, .discreteMin, .discreteMax], anchorDate: interval.start,
            intervalComponents: DateComponents(second: seconds))
        do {
            let collection = try await descriptor.result(for: store)
            var buckets: [HeartRateBucket] = []
            collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
                guard let average = statistics.averageQuantity()?.doubleValue(for: HealthUnits.bpm) else { return }
                buckets.append(HeartRateBucket(
                    interval: DateInterval(start: statistics.startDate, end: statistics.endDate), average: average,
                    minimum: statistics.minimumQuantity()?.doubleValue(for: HealthUnits.bpm) ?? average,
                    maximum: statistics.maximumQuantity()?.doubleValue(for: HealthUnits.bpm) ?? average))
            }
            return buckets.isEmpty ? .noData : .available(buckets)
        } catch {
            return .unavailable
        }
    }

    func workouts(in interval: DateInterval) async -> HealthReading<[HealthWorkoutRecord]> {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate(interval))],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        do {
            let workouts = try await descriptor.result(for: store).map { HealthWorkoutRecord(workout: $0) }
            return workouts.isEmpty ? .noData : .available(workouts)
        } catch {
            return .unavailable
        }
    }

    private func cumulativeSum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async -> HealthReading<Double> {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate(interval)), options: .cumulativeSum)
        do {
            guard let sum = try await descriptor.result(for: store)?.sumQuantity() else { return .noData }
            return .available(sum.doubleValue(for: unit))
        } catch {
            return .unavailable
        }
    }

    func activeEnergyKcal(in interval: DateInterval) async -> HealthReading<Double> {
        await cumulativeSum(.activeEnergyBurned, unit: HealthUnits.kilocalorie, in: interval)
    }

    func steps(in interval: DateInterval) async -> HealthReading<Double> {
        await cumulativeSum(.stepCount, unit: HealthUnits.count, in: interval)
    }

    func restingHeartRate(days interval: DateInterval) async -> HealthReading<[HealthDailyValue]> {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let anchor = calendar.startOfDay(for: interval.start)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.restingHeartRate), predicate: predicate(interval)),
            options: .discreteAverage, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
        do {
            let collection = try await descriptor.result(for: store)
            var values: [HealthDailyValue] = []
            collection.enumerateStatistics(from: anchor, to: interval.end) { statistics, _ in
                guard let average = statistics.averageQuantity()?.doubleValue(for: HealthUnits.bpm) else { return }
                values.append(HealthDailyValue(day: statistics.startDate, value: average))
            }
            return values.isEmpty ? .noData : .available(values)
        } catch {
            return .unavailable
        }
    }

    func latestBodyMassKg() async -> HealthReading<Double> {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        do {
            guard let sample = try await descriptor.result(for: store).first else { return .noData }
            return .available(sample.quantity.doubleValue(for: HealthUnits.kilogram))
        } catch {
            return .unavailable
        }
    }
}

// MARK: - Composições para a UI

extension HealthDataReading {
    /// FC da sessão com faixas por exercício e séries (detalhe da sessão, P4.2).
    func sessionHeartRate(_ timeline: HealthSessionTimeline, zones: HeartRateZones?,
                          now: Date = Date()) async -> HealthReading<SessionHeartRateAnalysis> {
        let interval = timeline.interval(now: now)
        return await heartRateSamples(in: interval).map {
            SessionHeartRateAnalyzer.analyze(timeline, samples: $0, zones: zones, now: now)
        }
    }

    /// Resumo de um dia (aba Saúde, P4.3): treinos vinculados/deduplicados, FC, energia, repouso, passos.
    /// `sessions`: `HealthSessionWindow.windows(in:context:)` do mesmo dia.
    func daySummary(_ day: Date, sessions: [HealthSessionWindow], calendar: Calendar = .current) async -> HealthDaySummary {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        async let workouts = workouts(in: interval)
        async let heartRate = heartRateSamples(in: interval)
        async let energy = activeEnergyKcal(in: interval)
        async let resting = restingHeartRate(days: interval)
        async let steps = steps(in: interval)
        return await HealthDayAnalyzer.summarize(
            day: interval, workouts: workouts.value ?? [], sessions: sessions, heartRate: heartRate.value ?? [],
            activeEnergyKcal: energy.value, restingHeartRate: resting.value?.last?.value, steps: steps.value)
    }
}

extension HealthDataReading where Self == HealthQueries {
    /// Leitor real sobre o `HKHealthStore` do app.
    @MainActor static var live: HealthQueries { HealthQueries(store: HealthKitStore.shared.healthStore) }
}
