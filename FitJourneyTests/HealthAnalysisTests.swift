import Foundation
import HealthKit
import Testing
@testable import FitJourney

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
private func hr(_ seconds: TimeInterval, _ bpm: Double) -> HeartRateSample { HeartRateSample(date: at(seconds), bpm: bpm) }

struct HeartRateZoneTests {
    @Test func resolvesConfiguredThenAgeThenAsks() {
        #expect(HeartRateZones.resolve(configuredMax: 190, age: 40) == .resolved(bpm: 190, source: .configured))
        #expect(HeartRateZones.resolve(configuredMax: nil, age: 40) == .resolved(bpm: 180, source: .ageEstimate))
        // Valor configurado absurdo cai para a idade; sem nada válido → pedir.
        #expect(HeartRateZones.resolve(configuredMax: 20, age: 30) == .resolved(bpm: 190, source: .ageEstimate))
        #expect(HeartRateZones.resolve(configuredMax: nil, age: nil) == .needsInput)
        #expect(HeartRateZones.resolve(configuredMax: nil, age: 3) == .needsInput)
        #expect(MaxHeartRateResolution.needsInput.zones == nil)
    }

    @Test func ageFromBirthDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let birth = calendar.date(from: DateComponents(year: 1990, month: 6, day: 15))!
        let before = calendar.date(from: DateComponents(year: 2026, month: 6, day: 14))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        #expect(HeartRateZones.age(birthDate: birth, at: before, calendar: calendar) == 35)
        #expect(HeartRateZones.age(birthDate: birth, at: after, calendar: calendar) == 36)
    }

    @Test func zoneBoundaries() {
        let zones = HeartRateZones(maxHeartRate: 200)
        #expect(zones.zone(for: 99) == nil)
        #expect(zones.zone(for: 100) == .zone1)
        #expect(zones.zone(for: 119.9) == .zone1)
        #expect(zones.zone(for: 120) == .zone2)
        #expect(zones.zone(for: 150) == .zone3)
        #expect(zones.zone(for: 160) == .zone4)
        #expect(zones.zone(for: 180) == .zone5)
        #expect(zones.zone(for: 230) == .zone5)
        #expect(zones.range(for: .zone3) == 140...160)
        #expect(zones.range(for: .zone5) == 180...200)
    }
}

struct HeartRateAggregationTests {
    @Test func statsAreNilWithoutSamples() {
        #expect(HeartRateAnalysis.stats([]) == nil)
        #expect(HeartRateAnalysis.stats([hr(0, 100)], in: DateInterval(start: at(10), end: at(20))) == nil)
        let stats = HeartRateAnalysis.stats([hr(0, 100), hr(5, 120), hr(10, 140), hr(30, 200)],
                                            in: DateInterval(start: at(0), end: at(10)))
        #expect(stats == HeartRateStats(average: 120, minimum: 100, maximum: 140, sampleCount: 3))
    }

    @Test func timeInZonesCapsGapsAndUsesIntervalEnd() {
        let zones = HeartRateZones(maxHeartRate: 200)
        // 0–10 s Z1 (100), 10–70 s Z4 (165 → gap de 260 s limitado a 60), 270–300 s Z5 até o fim.
        let samples = [hr(0, 100), hr(10, 165), hr(270, 190)]
        let result = HeartRateAnalysis.timeInZones(samples, zones: zones, within: DateInterval(start: at(0), end: at(300)))
        #expect(result.duration(in: .zone1) == 10)
        #expect(result.duration(in: .zone4) == 60)
        #expect(result.duration(in: .zone5) == 30)
        #expect(result.total == 100)
        #expect(abs(result.fraction(in: .zone5) - 0.3) < 1e-9)
    }

    @Test func belowZonesCounted() {
        let zones = HeartRateZones(maxHeartRate: 200)
        let result = HeartRateAnalysis.timeInZones([hr(0, 80), hr(20, 80)], zones: zones)
        #expect(result.belowZones == 20)
        #expect(result.byZone.isEmpty)
    }

    @Test func bucketsGroupBy5Seconds() {
        let samples = [hr(0, 100), hr(2, 110), hr(6, 130), hr(14, 90)]
        let buckets = HeartRateAnalysis.buckets(samples, in: DateInterval(start: at(0), end: at(15)), width: 5)
        #expect(buckets.count == 3)
        #expect(buckets[0].average == 105)
        #expect(buckets[0].maximum == 110)
        #expect(buckets[1].interval.start == at(5))
        #expect(buckets[2].interval == DateInterval(start: at(10), end: at(15)))
    }
}

/// Supino: séries em 100, 200, 300 s; rosca: uma série em 500 s; prancha: nenhuma.
private func makeTimeline(end: TimeInterval? = 600) -> HealthSessionTimeline {
    let bench = HealthSessionTimeline.Exercise(id: UUID(), name: "Supino", measurementKind: .repsAndLoad, sets: [
        .init(id: UUID(), number: 2, completedAt: at(100)),
        .init(id: UUID(), number: 3, completedAt: at(200)),
        .init(id: UUID(), number: 4, completedAt: at(300)),
    ])
    let curl = HealthSessionTimeline.Exercise(id: UUID(), name: "Rosca", measurementKind: .repsAndLoad, sets: [
        .init(id: UUID(), number: 1, completedAt: at(500)),
    ])
    let plank = HealthSessionTimeline.Exercise(id: UUID(), name: "Prancha", measurementKind: .isometric, sets: [])
    return HealthSessionTimeline(sessionID: UUID(), routineName: "A", startedAt: at(0), endedAt: end.map(at),
                                 activeDuration: end, exercises: [bench, curl, plank])
}

struct SessionHeartRateAnalyzerTests {
    @Test func bandsAndSetWindows() throws {
        let timeline = makeTimeline()
        // FC: 100 bpm de base; pico 160 logo depois de cada série do supino; rosca 140.
        var samples = stride(from: 0.0, through: 600, by: 5).map { hr($0, 100) }
        samples += [hr(105, 160), hr(205, 165), hr(305, 170), hr(505, 140)]
        let analysis = SessionHeartRateAnalyzer.analyze(timeline, samples: samples, zones: HeartRateZones(maxHeartRate: 200))
        #expect(analysis.hasHeartRate)
        #expect(analysis.exercises.count == 2) // prancha sem série não tem faixa
        let bench = analysis.exercises[0]
        #expect(bench.band == DateInterval(start: at(100), end: at(300)))
        #expect(bench.analysisInterval == DateInterval(start: at(40), end: at(315)))
        #expect(bench.stats?.maximum == 170)
        // Série 3: 60 s antes (140, depois da série anterior em 100) até 15 s depois.
        #expect(bench.sets[1].window == DateInterval(start: at(140), end: at(215)))
        #expect(bench.sets[1].stats?.maximum == 165)
        #expect(bench.sets[1].number == 3)
        let curl = analysis.exercises[1]
        #expect(curl.band.duration == 0)
        #expect(curl.stats?.maximum == 140)
        #expect(analysis.timeInZones?.total ?? 0 > 0)

        let lookup = try #require(analysis.lookup(at: at(210)))
        #expect(lookup.exercise.name == "Supino")
        #expect(lookup.set?.number == 3)
        #expect(analysis.lookup(at: at(400)) == nil)
    }

    @Test func setWindowNeverOverlapsPreviousSet() {
        let timeline = HealthSessionTimeline(sessionID: UUID(), routineName: "", startedAt: at(0), endedAt: at(100), exercises: [
            .init(id: UUID(), name: "X", measurementKind: .repsAndLoad, sets: [
                .init(id: UUID(), number: 1, completedAt: at(10)), .init(id: UUID(), number: 2, completedAt: at(30)),
            ]),
        ])
        let analysis = SessionHeartRateAnalyzer.analyze(timeline, samples: [], zones: nil)
        #expect(analysis.exercises[0].sets[0].window.start == at(0)) // limitada ao início da sessão
        #expect(analysis.exercises[0].sets[1].window.start == at(10))
        #expect(!analysis.hasHeartRate)
        #expect(analysis.timeInZones == nil)
    }

    @Test func noZonesWithoutMaxHeartRate() {
        let analysis = SessionHeartRateAnalyzer.analyze(makeTimeline(), samples: [hr(10, 120), hr(20, 130)], zones: nil)
        #expect(analysis.overall?.average == 125)
        #expect(analysis.timeInZones == nil)
    }
}

struct HealthWorkoutEventPlanTests {
    @Test func segmentsPerExerciseAndMarkersPerSet() {
        let timeline = makeTimeline()
        let plan = HealthWorkoutEventPlan.make(timeline, workout: DateInterval(start: at(0), end: at(600)))
        #expect(plan.segments.count == 2)
        #expect(plan.segments[0].interval == DateInterval(start: at(100), end: at(300)))
        #expect(plan.segments[0].index == 1)
        // Uma série só: segmento mínimo de 30 s para trás.
        #expect(plan.segments[1].interval == DateInterval(start: at(470), end: at(500)))
        #expect(plan.segments[1].index == 2)
        #expect(plan.markers.map(\.date) == [at(100), at(200), at(300), at(500)])
        #expect(plan.markers[1].setNumber == 3)
    }

    @Test func eventsAreClippedToWorkout() {
        let plan = HealthWorkoutEventPlan.make(makeTimeline(), workout: DateInterval(start: at(150), end: at(250)))
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].interval == DateInterval(start: at(150), end: at(250)))
        #expect(plan.markers.map(\.date) == [at(200)])
    }

    @Test func hkEventsCarryMetadata() {
        let plan = HealthWorkoutEventPlan.make(makeTimeline(), workout: DateInterval(start: at(0), end: at(600)))
        let events = plan.workoutEvents
        #expect(events.filter { $0.type == .segment }.count == 2)
        #expect(events.filter { $0.type == .marker }.count == 4)
        #expect(events.first?.metadata?[HealthMetadataKey.exerciseName] as? String == "Supino")
    }

    @Test func metadataHasExternalUUID() {
        let id = UUID()
        let dictionary = HealthWorkoutMetadata(sessionID: id, routineName: "Treino A", workoutType: .traditionalStrength).dictionary
        #expect(dictionary[HKMetadataKeyExternalUUID] as? String == id.uuidString)
        #expect(dictionary[HealthMetadataKey.routineName] as? String == "Treino A")
    }
}

struct HealthEnergyEstimateTests {
    @Test func needsBodyMass() {
        #expect(HealthEnergyEstimate.activeKilocalories(type: .traditionalStrength, activeDuration: 3_600, bodyMassKg: nil) == nil)
        #expect(HealthEnergyEstimate.activeKilocalories(type: .traditionalStrength, activeDuration: 0, bodyMassKg: 80) == nil)
        // (3,5 − 1) × 80 kg × 1 h = 200 kcal.
        #expect(HealthEnergyEstimate.activeKilocalories(type: .traditionalStrength, activeDuration: 3_600, bodyMassKg: 80) == 200)
    }
}
