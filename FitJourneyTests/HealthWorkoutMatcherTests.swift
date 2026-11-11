import Foundation
import HealthKit
import Testing
@testable import FitJourney

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func input(_ kind: MeasurementKind, _ name: String = "", muscles: [MuscleGroup] = [],
                   equipment: Equipment? = nil) -> HealthWorkoutTypeInput {
    HealthWorkoutTypeInput(measurementKind: kind, primaryMuscles: muscles, equipment: equipment, name: name)
}

struct HealthWorkoutTypeTests {
    @Test func strengthVariants() {
        #expect(HealthWorkoutType.derive(from: []) == .traditionalStrength)
        #expect(HealthWorkoutType.derive(from: [input(.repsAndLoad, equipment: .barbell), input(.repsAndLoad, equipment: .machine)])
            == .traditionalStrength)
        #expect(HealthWorkoutType.derive(from: [input(.repsOnly), input(.repsAndLoad, equipment: .kettlebell),
                                                input(.repsAndLoad, equipment: .barbell)]) == .functionalStrength)
        #expect(HealthWorkoutType.derive(from: [input(.isometric, muscles: [.abs]), input(.repsOnly, muscles: [.obliques]),
                                                input(.repsAndLoad, muscles: [.chest])]) == .core)
    }

    @Test func cardioByName() {
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Esteira")]) == .running)
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Bicicleta ergométrica")]) == .cycling)
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Elíptico")]) == .elliptical)
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Remo")]) == .rowing)
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Esteira"), input(.timeOrDistance, "Bike")]) == .mixedCardio)
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Pular corda livre")]) == .mixedCardio)
    }

    @Test func hiitAndFlexibility() {
        #expect(HealthWorkoutType.derive(from: [input(.timeOrDistance, "Bike"), input(.repsOnly), input(.repsAndLoad)]) == .hiit)
        #expect(HealthWorkoutType.derive(from: [input(.isometric, "Alongamento posterior"), input(.isometric, "Mobilidade de quadril"),
                                                input(.repsAndLoad)]) == .flexibility)
    }

    @Test func categories() {
        #expect(HealthWorkoutType.traditionalStrength.category == .strength)
        #expect(HealthWorkoutType.hiit.category == .aerobic)
        #expect(HealthWorkoutType.flexibility.category == .mobility)
    }

    @Test func healthKitMappingRoundTrips() {
        for type in HealthWorkoutType.allCases {
            #expect(HealthWorkoutType(activityType: type.activityType) == type)
            #expect(HealthWorkoutCategory(activityType: type.activityType) == type.category)
        }
        #expect(HealthWorkoutCategory(activityType: .running) == .aerobic)
        #expect(HealthWorkoutCategory(activityType: .crossTraining) == .mixed)
        #expect(HealthWorkoutCategory(activityType: .yoga) == .mobility)
        #expect(HealthWorkoutCategory(activityType: .golf) == .other)
        #expect(HealthWorkoutType(activityType: .golf) == nil)
    }
}

private func record(_ start: Double, _ end: Double, category: HealthWorkoutCategory = .strength, external: UUID? = nil,
                    own: Bool = false, id: UUID = UUID(), energy: Double? = nil) -> HealthWorkoutRecord {
    HealthWorkoutRecord(id: id, start: at(start), end: at(end), activityTypeRaw: 0, category: category, workoutType: nil,
                        sourceName: own ? "FitJourney" : "Apple Watch", sourceBundleID: own ? "app" : "com.apple.health",
                        externalUUID: external?.uuidString, isFromThisApp: own, routineName: nil,
                        activeEnergyKcal: energy, averageHeartRate: nil)
}

private func window(_ start: Double, _ end: Double, id: UUID = UUID(), linked: UUID? = nil,
                    category: HealthWorkoutCategory = .strength) -> HealthSessionWindow {
    HealthSessionWindow(sessionID: id, routineName: "A", start: at(start), end: at(end), category: category,
                        healthKitWorkoutID: linked)
}

struct HealthWorkoutMatcherTests {
    @Test func overlapIsOverShorter() {
        let a = DateInterval(start: at(0), end: at(60)), b = DateInterval(start: at(30), end: at(45))
        #expect(HealthWorkoutMatcher.overlap(a, b) == 1)
        #expect(HealthWorkoutMatcher.overlap(a, DateInterval(start: at(30), end: at(90))) == 0.5)
        #expect(HealthWorkoutMatcher.overlap(a, DateInterval(start: at(60), end: at(90))) == 0)
    }

    @Test func ownWorkoutByExternalUUIDOrLinkedID() {
        let session = window(0, 60)
        #expect(HealthWorkoutMatcher.match(record(0, 60, external: session.sessionID, own: true), sessions: [session])
            == .own(sessionID: session.sessionID))
        let watchID = UUID()
        let linked = window(0, 60, linked: watchID)
        #expect(HealthWorkoutMatcher.match(record(2, 58, id: watchID), sessions: [linked]) == .own(sessionID: linked.sessionID))
        // Treino do app de outra sessão (fora da lista) não vira sugestão.
        #expect(HealthWorkoutMatcher.match(record(0, 60, external: UUID(), own: true), sessions: [session]) == .unrelated)
    }

    @Test func watchWorkoutOverlapGivesHighConfidence() {
        let session = window(0, 60)
        let match = HealthWorkoutMatcher.match(record(2, 62), sessions: [session])
        #expect(match.sessionID == session.sessionID)
        guard case .suggestion(_, let confidence, let overlap) = match else { Issue.record("\(match)"); return }
        #expect(confidence == .high)
        #expect(overlap > 0.9)
    }

    @Test func uncertainWhenTypeDiffersOrPartialOverlap() {
        let session = window(0, 60)
        // Corrida do Watch no mesmo horário: tipo diferente → incerta.
        guard case .suggestion(_, .uncertain, _) = HealthWorkoutMatcher.match(record(0, 60, category: .aerobic), sessions: [session])
        else { Issue.record("esperava incerta"); return }
        // Sobreposição parcial (30 %).
        guard case .suggestion(_, .uncertain, _) = HealthWorkoutMatcher.match(record(42, 102), sessions: [session])
        else { Issue.record("esperava incerta"); return }
        // Pouca sobreposição → nada.
        #expect(HealthWorkoutMatcher.match(record(55, 115), sessions: [session]) == .unrelated)
        // Sessão já vinculada a outro treino não recebe sugestão.
        #expect(HealthWorkoutMatcher.match(record(0, 60), sessions: [window(0, 60, linked: UUID())]) == .unrelated)
    }

    @Test func picksBestSession() {
        let morning = window(0, 60), evening = window(600, 660)
        let match = HealthWorkoutMatcher.match(record(605, 650), sessions: [morning, evening])
        #expect(match.sessionID == evening.sessionID)
    }
}

struct HealthDayAnalyzerTests {
    @Test func entriesNeverDuplicateAndMinutesUseUnion() {
        let session = window(0, 60)
        let own = record(0, 60, external: session.sessionID, own: true, energy: 300)
        let watch = record(1, 61, energy: 320)
        let run = record(120, 150, category: .aerobic, energy: 250)
        let day = DateInterval(start: at(-600), end: at(840))
        let samples = [HeartRateSample(date: at(10), bpm: 120), HeartRateSample(date: at(130), bpm: 150)]
        let summary = HealthDayAnalyzer.summarize(day: day, workouts: [own, watch, run], sessions: [session], heartRate: samples,
                                                  activeEnergyKcal: nil, restingHeartRate: 58, steps: nil)
        #expect(summary.entries.count == 2)
        guard case .session(_, let linkedOwn, let suggestions) = summary.entries[0] else { Issue.record("sessão"); return }
        #expect(linkedOwn?.id == own.id)
        #expect(suggestions.map(\.workout.id) == [watch.id])
        #expect(summary.entries[0].activeEnergyKcal == 300)
        #expect(summary.minutesByCategory[.strength] == 60)
        #expect(summary.minutesByCategory[.aerobic] == 30)
        #expect(summary.totalWorkoutMinutes == 90)
        #expect(summary.averageHeartRateByEntry[session.sessionID] == 120)
        #expect(summary.averageHeartRateByEntry[run.id] == 150)
        // Indisponível ≠ zero.
        #expect(summary.activeEnergyKcal == nil)
        #expect(summary.steps == nil)
        #expect(summary.restingHeartRate == 58)
    }

    @Test func unionDuration() {
        let intervals = [DateInterval(start: at(0), end: at(10)), DateInterval(start: at(5), end: at(20)),
                         DateInterval(start: at(30), end: at(40))]
        #expect(DateIntervalMath.unionDuration(intervals) == 30 * 60)
        #expect(DateIntervalMath.unionDuration(intervals, clippedTo: DateInterval(start: at(15), end: at(35))) == 10 * 60)
        #expect(DateIntervalMath.unionDuration([]) == 0)
    }

    @Test func restingTrend() {
        func values(_ list: [Double]) -> [HealthDailyValue] {
            list.enumerated().map { HealthDailyValue(day: t0.addingTimeInterval(Double($0.offset) * 86_400), value: $0.element) }
        }
        #expect(HealthTrend.direction(values([60, 60, 60])) == nil)
        #expect(HealthTrend.direction(values([60, 60, 60, 60, 57, 57, 57]), window: 3) == .down)
        #expect(HealthTrend.direction(values([60, 60, 60, 60.5, 60.5, 60.5]), window: 3) == .stable)
        #expect(HealthTrend.direction(values([55, 55, 55, 60, 60, 60]), window: 3) == .up)
    }
}
