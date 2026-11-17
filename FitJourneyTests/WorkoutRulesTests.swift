import Foundation
import Testing
@testable import FitJourney

struct WorkoutMetricsTests {
    @Test func volumeCountsOnlyCompletedWorkingSets() {
        let sets = [
            PerformedSet(kind: .warmup, reps: 15, load: .kg(20)),
            PerformedSet(kind: .feeder, reps: 5, load: .kg(25)),
            PerformedSet(kind: .working, reps: 10, load: .kg(30)),
            PerformedSet(kind: .dropSet, reps: 8, load: .kg(20)),
            PerformedSet(kind: .working, reps: 10, load: .kg(30), isCompleted: false),
            PerformedSet(kind: .working, reps: nil, load: .kg(30)),
        ]
        #expect(WorkoutMetrics.volumeKg(sets) == 300 + 160)
    }

    @Test func bodyweightCountsOnlyPositiveDelta() {
        let sets = [
            PerformedSet(reps: 10, load: .bodyweight(delta: 0, unit: .kg)),
            PerformedSet(reps: 8, load: .bodyweight(delta: 10, unit: .kg)),
            PerformedSet(reps: 8, load: .bodyweight(delta: -20, unit: .kg)),
        ]
        #expect(WorkoutMetrics.volumeKg(sets) == 80)
    }

    @Test func poundsAreConvertedToKilograms() {
        let volume = WorkoutMetrics.volumeKg([PerformedSet(reps: 1, load: .weight(value: 220.462_262_18, unit: .lb))])
        #expect(abs(volume - 100) < 0.001)
    }

    @Test func epley() {
        #expect(WorkoutMetrics.epley1RM(loadKg: 100, reps: 1) == 100)
        #expect(abs(WorkoutMetrics.epley1RM(loadKg: 100, reps: 10)! - 133.333) < 0.01)
        #expect(WorkoutMetrics.epley1RM(loadKg: 100, reps: 0) == nil)
        #expect(WorkoutMetrics.epley1RM(loadKg: 0, reps: 5) == nil)
    }

    @Test func personalRecordsVsHistory() {
        let ex = UUID(), fresh = UUID()
        let history = [
            ex: WorkoutMetrics.bests(history: [
                [PerformedSet(reps: 10, load: .kg(30)), PerformedSet(reps: 10, load: .kg(30))],
                [PerformedSet(reps: 5, load: .kg(35))],
            ]),
        ]
        #expect(history[ex]?.heaviestLoadKg == 35)
        #expect(history[ex]?.bestSessionVolumeKg == 600)

        let session: [UUID: [PerformedSet]] = [
            ex: [PerformedSet(reps: 10, load: .kg(32)), PerformedSet(reps: 10, load: .kg(32))],
            fresh: [PerformedSet(reps: 10, load: .kg(50))],
        ]
        let records = WorkoutMetrics.personalRecords(session: session, history: history)
        #expect(Set(records.map(\.kind)) == [.bestVolume, .estimated1RM]) // 32 < 35: sem recorde de carga
        #expect(records.allSatisfy { $0.exerciseID == ex }) // primeira vez não é recorde
        #expect(records.first { $0.kind == .bestVolume }?.valueKg == 640)
    }

    @Test func warmupNeverSetsRecords() {
        let ex = UUID()
        let history = [ex: WorkoutMetrics.bests(of: [PerformedSet(reps: 10, load: .kg(30))])]
        let session = [ex: [PerformedSet(kind: .warmup, reps: 1, load: .kg(100))]]
        #expect(WorkoutMetrics.personalRecords(session: session, history: history).isEmpty)
    }

    @Test func routineEstimate() {
        #expect(RoutineEstimate.durationSeconds(restSeconds: [60, 60, 90]) == 3 * 40 + 210)
    }
}

struct CurrentLoadPolicyTests {
    let p1 = UUID(), p2 = UUID(), p3 = UUID()

    @Test func proposesUsedLoadWhenAllWorkingSetsDone() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: UUID(), kind: .warmup, currentLoad: .kg(20), usedLoad: .kg(25), isCompleted: true),
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(32), isCompleted: true),
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(30), usedLoad: .kg(30), isCompleted: true),
            .init(prescriptionID: p3, kind: .working, currentLoad: nil, usedLoad: .kg(32), isCompleted: true),
        ])
        let proposals = CurrentLoadPolicy.proposals(for: [entry])
        // 17/11: carga ajustada → a mesma carga final (última concluída) em todas as válidas.
        #expect(proposals.map(\.prescriptionID) == [p1, p2, p3])
        #expect(proposals.first?.from == .kg(30))
        #expect(proposals.allSatisfy { $0.to == .kg(32) })
    }

    @Test func noProposalWhenAWorkingSetIsPending() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(32), isCompleted: true),
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(30), usedLoad: nil, isCompleted: false),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [entry]).isEmpty)
    }

    @Test func ignoresIneligibleExtraAndEquivalentLoads() {
        let skipped = CurrentLoadPolicy.ExerciseEntry(exerciseName: "X", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(40), isCompleted: true),
        ], isEligible: false)
        let extra = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Y", sets: [
            .init(prescriptionID: nil, kind: .working, currentLoad: nil, usedLoad: .kg(40), isCompleted: true),
        ])
        let sameInPounds = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Z", sets: [
            .init(prescriptionID: p2, kind: .working, currentLoad: .kg(100),
                  usedLoad: .weight(value: 220.462_262_18, unit: .lb), isCompleted: true),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [skipped, extra, sameInPounds]).isEmpty)
    }

    @Test func extraSetsDoNotBlockProposals() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Supino", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .kg(30), usedLoad: .kg(32), isCompleted: true),
            .init(prescriptionID: nil, kind: .working, currentLoad: nil, usedLoad: nil, isCompleted: false),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [entry]).map(\.prescriptionID) == [p1])
    }

    @Test func bodyweightDeltaChangeIsProposed() {
        let entry = CurrentLoadPolicy.ExerciseEntry(exerciseName: "Barra", sets: [
            .init(prescriptionID: p1, kind: .working, currentLoad: .bodyweight(delta: 0, unit: .kg),
                  usedLoad: .bodyweight(delta: 5, unit: .kg), isCompleted: true),
        ])
        #expect(CurrentLoadPolicy.proposals(for: [entry]).first?.to == .bodyweight(delta: 5, unit: .kg))
    }
}

struct ProgressionSuggestionTests {
    let enabled = ProgressionSuggestion.Settings(isEnabled: true)

    @Test func disabledByDefault() {
        let sets = [PerformedSet(reps: 12, load: .kg(30))]
        #expect(ProgressionSuggestion.evaluate(target: .range(min: 8, max: 12), sets: sets, currentLoad: .kg(30)) == nil)
    }

    @Test func suggestsIncrementAtTopOfRange() {
        let sets = [PerformedSet(kind: .warmup, reps: 5, load: .kg(20)),
                    PerformedSet(reps: 12, load: .kg(30)), PerformedSet(reps: 13, load: .kg(30))]
        let s = ProgressionSuggestion.evaluate(target: .range(min: 8, max: 12), sets: sets, currentLoad: .kg(30), settings: enabled)
        #expect(s?.suggested == .kg(32.5))
        let lb = ProgressionSuggestion.evaluate(target: .fixed(reps: 10), sets: [PerformedSet(reps: 10, load: nil)],
                                                currentLoad: .weight(value: 100, unit: .lb), settings: enabled)
        #expect(lb?.suggested == .weight(value: 105, unit: .lb))
    }

    @Test func noSuggestionBelowTopOrAmrap() {
        let below = [PerformedSet(reps: 12, load: .kg(30)), PerformedSet(reps: 11, load: .kg(30))]
        #expect(ProgressionSuggestion.evaluate(target: .range(min: 8, max: 12), sets: below, currentLoad: .kg(30), settings: enabled) == nil)
        #expect(ProgressionSuggestion.evaluate(target: .amrap, sets: [PerformedSet(reps: 20, load: nil)], currentLoad: .kg(0), settings: enabled) == nil)
        #expect(ProgressionSuggestion.evaluate(target: .fixed(reps: 10), sets: [PerformedSet(reps: 10, load: nil)], currentLoad: nil, settings: enabled) == nil)
    }
}

struct SessionClockTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func elapsedIsDerivedFromDates() {
        let clock = SessionClock(startedAt: t0)
        #expect(clock.elapsed(at: t0.addingTimeInterval(600)) == 600)
        #expect(clock.elapsed(at: t0.addingTimeInterval(-5)) == 0)
    }

    @Test func pauseAndResumeExcludePausedTime() {
        var clock = SessionClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(100))
        #expect(clock.isPaused)
        #expect(clock.elapsed(at: t0.addingTimeInterval(500)) == 100)
        clock.resume(at: t0.addingTimeInterval(400))
        #expect(clock.elapsed(at: t0.addingTimeInterval(500)) == 200)
        clock.finish(at: t0.addingTimeInterval(1_000))
        #expect(clock.elapsed(at: t0.addingTimeInterval(9_999)) == 700)
    }

    @Test func finishWhilePausedDoesNotCountPause() {
        var clock = SessionClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(100))
        clock.finish(at: t0.addingTimeInterval(300))
        #expect(clock.elapsed(at: t0.addingTimeInterval(1_000)) == 100)
        #expect(!clock.isPaused)
    }

    @Test func restCountdownAdjustAndSkip() {
        var clock = SessionClock(startedAt: t0)
        clock.startRest(seconds: 90, at: t0.addingTimeInterval(60))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(100)) == 50)
        clock.adjustRest(by: 15, at: t0.addingTimeInterval(100))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(100)) == 65)
        clock.adjustRest(by: -15, at: t0.addingTimeInterval(100))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(150)) == nil) // venceu
        #expect(!clock.isResting(at: t0.addingTimeInterval(151)))
        clock.startRest(seconds: 60, at: t0.addingTimeInterval(200))
        clock.adjustRest(by: -90, at: t0.addingTimeInterval(210))
        #expect(clock.restEndsAt == nil)
        clock.startRest(seconds: 60, at: t0.addingTimeInterval(300))
        clock.skipRest()
        #expect(clock.restRemaining(at: t0.addingTimeInterval(301)) == nil)
    }

    @Test func restFreezesDuringPauseAndShiftsOnResume() {
        var clock = SessionClock(startedAt: t0)
        clock.startRest(seconds: 60, at: t0)
        clock.pause(at: t0.addingTimeInterval(20))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(500)) == 40)
        clock.resume(at: t0.addingTimeInterval(120))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(130)) == 30)
    }

    @Test func startAndAdjustRestWhilePaused() {
        var clock = SessionClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(100))
        clock.startRest(seconds: 60, at: t0.addingTimeInterval(130)) // conta a partir da pausa
        #expect(clock.restRemaining(at: t0.addingTimeInterval(500)) == 60)
        clock.adjustRest(by: 15, at: t0.addingTimeInterval(500))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(500)) == 75)
        clock.adjustRest(by: -100, at: t0.addingTimeInterval(500))
        #expect(clock.restEndsAt == nil)
        clock.startRest(seconds: 30, at: t0.addingTimeInterval(500))
        clock.resume(at: t0.addingTimeInterval(200))
        #expect(clock.restRemaining(at: t0.addingTimeInterval(210)) == 20)
    }

    @Test func finishClearsRestAndIgnoresLaterTransitions() {
        var clock = SessionClock(startedAt: t0)
        clock.startRest(seconds: 90, at: t0.addingTimeInterval(10))
        clock.finish(at: t0.addingTimeInterval(50))
        #expect(clock.restEndsAt == nil)
        #expect(clock.restRemaining(at: t0.addingTimeInterval(60)) == nil)
        clock.startRest(seconds: 90, at: t0.addingTimeInterval(60))
        clock.pause(at: t0.addingTimeInterval(70))
        #expect(clock.restEndsAt == nil && !clock.isPaused)
        #expect(clock.elapsed(at: t0.addingTimeInterval(1_000)) == 50)
    }

    @Test func exerciseStatusRules() {
        #expect(SessionExerciseRules.automaticStatus(current: .pending, completedSets: 0, totalSets: 3) == .pending)
        #expect(SessionExerciseRules.automaticStatus(current: .pending, completedSets: 1, totalSets: 3) == .inProgress)
        #expect(SessionExerciseRules.automaticStatus(current: .inProgress, completedSets: 3, totalSets: 3) == .completed)
        #expect(SessionExerciseRules.automaticStatus(current: .skipped, completedSets: 3, totalSets: 3) == .skipped)
        #expect(SessionExerciseRules.manualCompletionStatus(completedSets: 1, totalSets: 3) == .partial)
        #expect(SessionExerciseRules.manualCompletionStatus(completedSets: 3, totalSets: 3) == .completed)
    }
}

struct PrescriptionValueTests {
    @Test func repTargetDefaults() {
        #expect(RepTarget.range(min: 8, max: 12).defaultReps == 8)
        #expect(RepTarget.range(min: 8, max: 12).topReps == 12)
        #expect(RepTarget.amrap.defaultReps == nil)
        #expect(RepTarget.range(min: 8, max: 12).displayText == "8–12")
    }

    @Test func codableRoundTrip() throws {
        let values: [Load] = [.kg(32.5), .weight(value: 70, unit: .lb), .bodyweight(delta: -20, unit: .kg)]
        #expect(try JSONDecoder().decode([Load].self, from: JSONEncoder().encode(values)) == values)
        let targets: [RepTarget] = [.fixed(reps: 10), .range(min: 8, max: 12), .amrap]
        #expect(try JSONDecoder().decode([RepTarget].self, from: JSONEncoder().encode(targets)) == targets)
        let effort: [EffortTarget] = [.rir(2), .rpe(8.5)]
        #expect(try JSONDecoder().decode([EffortTarget].self, from: JSONEncoder().encode(effort)) == effort)
    }

    @Test func setKindWorking() {
        #expect(!SetKind.warmup.isWorking && !SetKind.feeder.isWorking)
        #expect(SetKind.allCases.filter(\.isWorking).count == 5)
    }
}
