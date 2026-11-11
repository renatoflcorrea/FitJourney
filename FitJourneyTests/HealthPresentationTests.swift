import Foundation
import Testing
@testable import FitJourney

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

struct HealthReadingDisplayTests {
    @Test func availableShowsValue() {
        let display = HealthPresentation.display(HealthReading<Double>.available(318.4), format: HealthPresentation.wholeNumber)
        #expect(display.value == "318")
        #expect(display.note == nil)
        #expect(!display.offersPermissionReview)
    }

    @Test func noDataIsDashWithPermissionReviewNeverZero() {
        let display = HealthPresentation.display(HealthReading<Double>.noData, format: HealthPresentation.wholeNumber)
        #expect(display.value == nil)
        #expect(display.note == HealthReadingDisplay.noDataNote)
        #expect(display.offersPermissionReview)
    }

    @Test func unavailableIsDashWithoutReviewOffer() {
        let display = HealthPresentation.display(HealthReading<Double>.unavailable, format: HealthPresentation.wholeNumber)
        #expect(display.value == nil)
        #expect(display.note == HealthReadingDisplay.unavailableNote)
        #expect(!display.offersPermissionReview)
    }

    @Test func bpmRangeAndMinutes() {
        #expect(HealthPresentation.bpmRange(HeartRateStats(average: 100, minimum: 58.2, maximum: 163.6, sampleCount: 3)) == "58–164")
        #expect(HealthPresentation.bpmRange(HeartRateStats(average: 72, minimum: 72, maximum: 72, sampleCount: 1)) == "72")
        #expect(HealthPresentation.minutes(52).contains("52"))
        let long = HealthPresentation.minutes(65)
        #expect(long.contains("1") && long.contains("5"))
    }
}

struct HealthComparisonTests {
    @Test func aboveBelowAndOnAverage() {
        let week = [100.0, 100, 100, 100, 100, 100, 100]
        let above = HealthPresentation.compare(today: 174, previousDays: week, unit: .kcal)
        #expect(above.kind == .above)
        #expect(above.text.hasPrefix("↑ 74 kcal"))
        #expect(HealthPresentation.compare(today: 101, previousDays: week, unit: .kcal).kind == .onAverage)
        #expect(HealthPresentation.compare(today: 90, previousDays: week, unit: .bpm).text.hasPrefix("↓ 10 bpm"))
    }

    @Test func fewDaysSkipsComparison() {
        let result = HealthPresentation.compare(today: 500, previousDays: [400, 410], unit: .kcal)
        #expect(result.kind == .fewDays)
    }

    @Test func partialDayIsFlagged() {
        #expect(HealthPresentation.compare(today: 200, previousDays: [100, 100, 100], unit: .kcal, partialDay: true).text.contains("até agora"))
    }
}

struct HealthZonesPresentationTests {
    @Test func noMaxHeartRateNeedsInput() {
        #expect(HealthPresentation.resolveZones(storedMax: 0) == .needsInput)
        #expect(HealthPresentation.resolveZones(storedMax: 0).zones == nil)
        // FC máxima fora do intervalo válido não vale.
        #expect(HealthPresentation.resolveZones(storedMax: 50) == .needsInput)
    }

    @Test func storedMaxResolvesZones() {
        let resolution = HealthPresentation.resolveZones(storedMax: 190)
        #expect(resolution == .resolved(bpm: 190, source: .configured))
        let lines = HealthPresentation.zoneLines(HeartRateZones(maxHeartRate: 200))
        #expect(lines.map(\.zone) == [.zone2, .zone3, .zone4, .zone5])
        #expect(lines.map(\.bpm) == [120, 140, 160, 180])
    }

    @Test func zoneMapsToDesignSystem() {
        for zone in HeartRateZone.allCases { #expect(HealthPresentation.designZone(zone).rawValue == zone.rawValue) }
    }
}

struct HealthBandsTests {
    private func timeline() -> HealthSessionTimeline {
        func exercise(_ name: String, _ minutes: [Double]) -> HealthSessionTimeline.Exercise {
            HealthSessionTimeline.Exercise(
                id: UUID(), catalogExerciseID: nil, name: name, measurementKind: .repsAndLoad,
                sets: minutes.enumerated().map { .init(id: UUID(), number: $0 + 1, completedAt: at($1)) })
        }
        return HealthSessionTimeline(sessionID: UUID(), routineName: "A", startedAt: at(0), endedAt: at(60), activeDuration: nil,
                                     exercises: [exercise("Supino", [5, 8, 11]), exercise("Pulado", []), exercise("Crucifixo", [20, 24])])
    }

    @Test func bandsSpanFirstToLastSetAndKeepListNumbering() {
        let bands = HealthPresentation.bands(timeline())
        #expect(bands.map(\.number) == [1, 3])
        #expect(bands[0].interval == DateInterval(start: at(5), end: at(11)))
        #expect(bands[1].name == "Crucifixo")
    }

    @Test func narrowBandHidesItsNumber() {
        let total = DateInterval(start: at(0), end: at(60))
        // 60 min em 300 pt = 5 pt por minuto: 3 min = 15 pt (< 16), 4 min = 20 pt.
        #expect(!HealthPresentation.showsBandLabel(band: DateInterval(start: at(0), end: at(3)), total: total, plotWidth: 300))
        #expect(HealthPresentation.showsBandLabel(band: DateInterval(start: at(0), end: at(4)), total: total, plotWidth: 300))
        // Treino longo: a janela visível (60 min) é que conta.
        let long = DateInterval(start: at(0), end: at(180))
        #expect(HealthPresentation.showsBandLabel(band: DateInterval(start: at(0), end: at(4)), total: long, plotWidth: 300, visibleSeconds: 3_600))
    }

    @Test func selectionTitleFormat() {
        let stats = HeartRateStats(average: 131.2, minimum: 100, maximum: 142.4, sampleCount: 5)
        #expect(HealthPresentation.selectionTitle(number: 2, exercise: "Supino inclinado", setNumber: 3, stats: stats)
            == "2 · Supino inclinado — série 3 · média 131 · máx 142 bpm")
        #expect(HealthPresentation.selectionTitle(number: nil, exercise: "Treino", setNumber: nil, stats: nil) == "Treino")
    }

    @Test func gapsSplitTheLine() {
        let samples = [0, 5, 10, 200, 205].map { HeartRateSample(date: t0.addingTimeInterval(Double($0)), bpm: 100) }
        #expect(HealthPresentation.segments(samples).map(\.count) == [3, 2])
        #expect(HealthPresentation.segments([]).isEmpty)
    }
}

struct HealthDayRowsTests {
    private func record(_ start: Double, _ end: Double, category: HealthWorkoutCategory = .aerobic, id: UUID = UUID(),
                        energy: Double? = 300, avg: Double? = 128) -> HealthWorkoutRecord {
        HealthWorkoutRecord(id: id, start: at(start), end: at(end), activityTypeRaw: 0, category: category, workoutType: nil,
                            sourceName: "Apple Watch", sourceBundleID: "com.apple.health", externalUUID: nil, isFromThisApp: false,
                            routineName: nil, activeEnergyKcal: energy, averageHeartRate: avg)
    }

    private func summary(workouts: [HealthWorkoutRecord], sessions: [HealthSessionWindow]) -> HealthDaySummary {
        HealthDayAnalyzer.summarize(day: DateInterval(start: at(-60), end: at(600)),
                                    workouts: workouts.isEmpty ? .noData : .available(workouts), sessions: sessions,
                                    heartRate: .noData, activeEnergyKcal: .noData, restingHeartRate: .noData, steps: .noData)
    }

    @Test func highConfidenceLinksIntoOneRow() {
        let session = HealthSessionWindow(sessionID: UUID(), routineName: "A — Peito", start: at(0), end: at(60))
        let watch = record(2, 62, category: .strength)
        let rows = HealthPresentation.rows(summary(workouts: [watch], sessions: [session]), dismissedPairs: [])
        #expect(rows.count == 1)
        #expect(rows[0].origin == .appAndWatch)
        #expect(rows[0].linkedSuggestion?.workout.id == watch.id)
        #expect(rows[0].energyKcal == 300)
    }

    @Test func dismissedHighConfidenceSplitsIntoTwoRows() {
        let session = HealthSessionWindow(sessionID: UUID(), routineName: "A", start: at(0), end: at(60))
        let watch = record(2, 62, category: .strength)
        let key = HealthPresentation.pairKey(sessionID: session.sessionID, workoutID: watch.id)
        let rows = HealthPresentation.rows(summary(workouts: [watch], sessions: [session]), dismissedPairs: [key])
        #expect(rows.count == 2)
        #expect(rows.first { $0.sessionID != nil }?.origin == .app)
        #expect(rows.first { $0.sessionID == nil }?.origin == .external("Apple Watch"))
    }

    @Test func uncertainSuggestionStaysPendingUntilDismissed() {
        let session = HealthSessionWindow(sessionID: UUID(), routineName: "A", start: at(0), end: at(60))
        let run = record(0, 60, category: .aerobic)
        let pending = HealthPresentation.rows(summary(workouts: [run], sessions: [session]), dismissedPairs: [])
        #expect(pending.count == 2)
        #expect(pending.first { $0.sessionID == nil }?.pendingSuggestion != nil)
        let key = HealthPresentation.pairKey(sessionID: session.sessionID, workoutID: run.id)
        let dismissed = HealthPresentation.rows(summary(workouts: [run], sessions: [session]), dismissedPairs: [key])
        #expect(dismissed.first { $0.sessionID == nil }?.pendingSuggestion == nil)
    }

    @Test func rowDetailOmitsMissingValues() {
        let row = HealthPresentation.WorkoutRow(id: UUID(), title: "Corrida", category: .aerobic, interval: DateInterval(start: at(0), end: at(42)),
                                                origin: .external("Apple Watch"), averageHeartRate: nil, energyKcal: nil)
        let text = HealthPresentation.rowDetail(row)
        #expect(text.contains("42 min"))
        #expect(!text.contains("FC média"))
        #expect(!text.contains("kcal"))
    }

    @Test func categoryMapsToStrengthOrAerobicOnly() {
        #expect(HealthPresentation.kind(.strength) == .strength)
        #expect(HealthPresentation.kind(.aerobic) == .aerobic)
        #expect(HealthPresentation.kind(.mobility) == nil)
    }

    @Test func weeklyMinutesUseUnionPerKind() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: t0)
        let start = day.addingTimeInterval(10 * 3_600)
        let intervals: [HealthPresentation.CategorizedInterval] = [
            (.strength, DateInterval(start: start, duration: 3_600)),
            (.strength, DateInterval(start: start.addingTimeInterval(1_800), duration: 3_600)), // sobrepõe 30 min
            (.aerobic, DateInterval(start: start.addingTimeInterval(7_200), duration: 1_800)),
        ]
        let days = [day, day.addingTimeInterval(86_400)]
        let result = HealthPresentation.dailyMinutes(intervals, days: days, calendar: calendar)
        #expect(result[0][.strength] == 90)
        #expect(result[0][.aerobic] == 30)
        #expect(result[1].isEmpty)
        // Total do dia pela união geral: 10:00–11:30 (força) + 12:00–12:30 (aeróbico) = 120 min.
        #expect(HealthPresentation.dailyTotals(intervals, days: days, calendar: calendar) == [120, 0])
    }

    @Test func otherCategoriesCountAsOthersAndWeekAverageUsesElapsedDays() {
        #expect(HealthPresentation.minutesKind(.mixed) == .other)
        #expect(HealthPresentation.minutesKind(.mobility) == .other)
        let days = (0..<7).map { t0.addingTimeInterval(Double($0) * 86_400) }
        // Só os 3 primeiros dias decorridos: média de 60+0+30 / 3.
        let average = HealthPresentation.weekAverage(totals: [60, 0, 30, 0, 0, 0, 0], days: days, now: days[2])
        #expect(average == 30)
    }

    @Test func movingAverageUsesAvailableDaysOnly() {
        let values = (0..<3).map { HealthDailyValue(day: t0.addingTimeInterval(Double($0) * 86_400), value: Double(60 + $0 * 2)) }
        #expect(HealthPresentation.movingAverage(values).map(\.value) == [60, 61, 62])
    }
}
