import Foundation
import SwiftData

// Fakes para previews, testes e o harness de screenshots: o simulador não tem Saúde real.

/// Leitor do Saúde com resultados fixos.
struct FakeHealthReader: HealthDataReading {
    var samples: HealthReading<[HeartRateSample]> = .noData
    var buckets: HealthReading<[HeartRateBucket]> = .noData
    var workouts: HealthReading<[HealthWorkoutRecord]> = .noData
    var pauses: HealthReading<[DateInterval]> = .noData
    var energy: HealthReading<Double> = .noData
    /// Energia por dia (quando definida, substitui `energy` nos intervalos de 1 dia).
    var energyByDay: [Date: Double] = [:]
    var stepCount: HealthReading<Double> = .noData
    var resting: HealthReading<[HealthDailyValue]> = .noData
    var bodyMass: HealthReading<Double> = .noData
    var calendar: Calendar = .current

    func heartRateSamples(in interval: DateInterval) async throws -> HealthReading<[HeartRateSample]> {
        samples.map { all in all.filter { interval.contains($0.date) } }.emptyAsNoData
    }

    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async throws -> HealthReading<[HeartRateBucket]> {
        buckets.map { all in all.filter { $0.interval.start >= interval.start && $0.interval.start < interval.end } }.emptyAsNoData
    }

    func workouts(in interval: DateInterval) async throws -> HealthReading<[HealthWorkoutRecord]> {
        workouts.map { all in all.filter { $0.interval.intersection(with: interval) != nil } }.emptyAsNoData
    }

    func workoutPauses(workoutID: UUID) async throws -> HealthReading<[DateInterval]> { pauses }

    func activeEnergyKcal(in interval: DateInterval) async throws -> HealthReading<Double> {
        if let value = energyByDay[calendar.startOfDay(for: interval.start)] { return .available(value) }
        return energyByDay.isEmpty ? energy : .noData
    }

    func steps(in interval: DateInterval) async throws -> HealthReading<Double> { stepCount }

    func restingHeartRate(days interval: DateInterval) async throws -> HealthReading<[HealthDailyValue]> {
        resting.map { all in all.filter { $0.day >= calendar.startOfDay(for: interval.start) && $0.day < interval.end } }.emptyAsNoData
    }

    func latestBodyMassKg() async throws -> HealthReading<Double> { bodyMass }
}

/// Dados de exemplo coerentes para previews e screenshots.
enum HealthSampleData {
    /// FC de uma sessão: sobe a cada série, desce no descanso.
    static func sessionSamples(start: Date, end: Date, setDates: [Date], seed: Double = 0) -> [HeartRateSample] {
        var result: [HeartRateSample] = []
        var date = start
        while date < end {
            let nearest = setDates.map { abs($0.timeIntervalSince(date)) }.min() ?? 600
            let effort = max(0, 1 - nearest / 90)
            let wobble = sin(date.timeIntervalSinceReferenceDate / 23 + seed) * 4
            result.append(HeartRateSample(date: date, bpm: (92 + effort * 58 + wobble).rounded()))
            date = date.addingTimeInterval(5)
        }
        return result
    }

    /// FC do dia em baldes de 5 min, com leituras só quando o relógio estava no pulso.
    static func dayBuckets(day: Date, workouts: [DateInterval], upTo limit: Date? = nil, calendar: Calendar = .current) -> [HeartRateBucket] {
        let start = calendar.startOfDay(for: day)
        var result: [HeartRateBucket] = []
        for index in 0..<288 {
            let bucketStart = start.addingTimeInterval(Double(index) * 300)
            if let limit, bucketStart >= limit { break }
            let hour = Double(index) / 12
            guard hour >= 6.5 else { continue }
            let training = workouts.contains { $0.contains(bucketStart) }
            let base = training ? 128 + sin(Double(index)) * 14 : 70 + sin(Double(index) / 3) * 8 + (hour > 12 && hour < 14 ? 10 : 0)
            result.append(HeartRateBucket(interval: DateInterval(start: bucketStart, duration: 300), average: base,
                                          minimum: base - (training ? 18 : 8), maximum: base + (training ? 30 : 14)))
        }
        return result
    }

    static func record(start: Date, minutes: Double, category: HealthWorkoutCategory = .aerobic,
                       type: HealthWorkoutType? = .running, source: String = "Apple Watch",
                       averageHeartRate: Double? = 152, energy: Double? = 310) -> HealthWorkoutRecord {
        HealthWorkoutRecord(id: UUID(), start: start, end: start.addingTimeInterval(minutes * 60), activityTypeRaw: 37,
                            category: category, workoutType: type, sourceName: source, sourceBundleID: "com.apple.health",
                            externalUUID: nil, isFromThisApp: false, routineName: nil, activeEnergyKcal: energy,
                            averageHeartRate: averageHeartRate)
    }
}

/// Armazenamento do Saúde falso: só o necessário para `HealthAuthorization` nas previews.
@MainActor
final class PreviewHealthStore: HealthStoreProtocol {
    var isHealthDataAvailable = true
    var status: HealthRequestStatus = .shouldRequest
    var sharing: HealthSharingStatus = .notDetermined

    init(status: HealthRequestStatus = .shouldRequest, sharing: HealthSharingStatus = .notDetermined, available: Bool = true) {
        self.status = status
        self.sharing = sharing
        isHealthDataAvailable = available
    }

    func requestAuthorization(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async throws {
        status = .unnecessary
        sharing = .authorized
    }

    func requestStatus(share: Set<HealthDataKind>, read: Set<HealthDataKind>) async -> HealthRequestStatus { status }
    func sharingStatus(for kind: HealthDataKind) -> HealthSharingStatus { sharing }

    struct Unsupported: Error {}

    func makeLiveRecorder(type: HealthWorkoutType) throws -> any HealthWorkoutRecorder { throw Unsupported() }
    func makeBasicRecorder(type: HealthWorkoutType) -> any HealthWorkoutRecorder { PreviewRecorder() }
    func recoverLiveRecorder() async -> (any HealthWorkoutRecorder)? { nil }
    func setMirroringStartHandler(_ handler: (@MainActor (any HealthRemoteWorkoutSession) -> Void)?) {}
    func latestBodyMassKg() async -> Double? { nil }
}

@MainActor
final class PreviewRecorder: HealthWorkoutRecorder {
    var isLive = false
    var startDate: Date?
    var isPaused = false
    var isActive = false
    var onLiveUpdate: ((HealthLiveUpdate) -> Void)?
    func start(at date: Date) async throws {}
    func pause(at date: Date) {}
    func resume(at date: Date) {}
    func finish(start: Date, end: Date, plan: HealthWorkoutEventPlan, metadata: HealthWorkoutMetadata,
                estimatedEnergyKcal: Double?) async throws -> UUID? { nil }
    func discard() {}
}

// MARK: - Fixtures de preview/harness

@MainActor
enum HealthPreviewFixtures {
    /// Autorização "conectada" (folha mostrada, escrita liberada) para previews e screenshots.
    static func connectedAuthorization(suite: String = "preview-health") -> HealthAuthorization {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.set(true, forKey: HealthAuthorization.connectionKey)
        let authorization = HealthAuthorization(store: PreviewHealthStore(status: .unnecessary, sharing: .authorized), defaults: defaults)
        Task { await authorization.refresh() }
        return authorization
    }

    static func disconnectedAuthorization(suite: String = "preview-health-off") -> HealthAuthorization {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removeObject(forKey: HealthAuthorization.connectionKey)
        return HealthAuthorization(store: PreviewHealthStore(), defaults: defaults)
    }

    /// Leitor com a FC da sessão (esforço a cada série).
    static func reader(for session: WorkoutSession, context: ModelContext) -> FakeHealthReader {
        let timeline = session.healthTimeline(context: context)
        let setDates = timeline.exercises.flatMap(\.sets).map(\.completedAt)
        let end = timeline.endedAt ?? timeline.startedAt.addingTimeInterval(3_000)
        return FakeHealthReader(samples: .available(HealthSampleData.sessionSamples(start: timeline.startedAt, end: end, setDates: setDates)))
    }
}
