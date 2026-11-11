import Foundation
import SwiftData

// Conversões entre o domínio do app e os tipos de fio de `Shared/WatchLink` (só Foundation).

extension WatchLoad {
    init(_ load: Load) {
        switch load {
        case .weight(let value, let unit):
            self.init(value: value, unit: WatchWeightUnit(unit), isBodyweight: false)
        case .bodyweight(let delta, let unit):
            self.init(value: delta, unit: WatchWeightUnit(unit), isBodyweight: true)
        }
    }

    var load: Load {
        let unit: WeightUnit = unit == .kg ? .kg : .lb
        return isBodyweight ? .bodyweight(delta: value, unit: unit) : .weight(value: value, unit: unit)
    }
}

extension WatchWeightUnit {
    init(_ unit: WeightUnit) { self = unit == .kg ? .kg : .lb }
}

extension WatchRepTarget {
    init(_ target: RepTarget) {
        switch target {
        case .fixed(let reps): self = .fixed(reps: reps)
        case .range(let min, let max): self = .range(min: min, max: max)
        case .amrap: self = .amrap
        }
    }
}

extension WatchEffort {
    init(_ effort: EffortTarget) {
        switch effort {
        case .rir(let value): self = .rir(value)
        case .rpe(let value): self = .rpe(value)
        }
    }
}

extension WatchMeasurementKind {
    init(_ kind: MeasurementKind) {
        switch kind {
        case .repsAndLoad: self = .repsAndLoad
        case .repsOnly: self = .repsOnly
        case .isometric: self = .isometric
        case .timeOrDistance: self = .timeOrDistance
        }
    }
}

extension WatchSetKind {
    init(_ kind: SetKind) { self = WatchSetKind(rawValue: kind.rawValue) ?? .working }
    var setKind: SetKind { SetKind(rawValue: rawValue) ?? .working }
}

extension WatchExerciseStatus {
    init(_ status: SessionExerciseStatus) { self = WatchExerciseStatus(rawValue: status.rawValue) ?? .pending }
}

extension WatchSkipReason {
    var skipReason: SkipReason { SkipReason(rawValue: rawValue) ?? .other }
}

/// Textos de alvo "como prescrito" (SPEC D2).
enum SessionDisplay {
    /// "8–12", "10", "AMRAP" (reps); "45 s" (isométrico); "20 min" / "5 km" (cardio).
    static func targetText(measurement: MeasurementKind, repTarget: RepTarget?, holdSeconds: Int?,
                           cardio: CardioTarget?) -> String {
        switch measurement {
        case .repsAndLoad, .repsOnly:
            return repTarget?.displayText ?? ""
        case .isometric:
            if let holdSeconds { return "\(holdSeconds) s" }
            return repTarget?.displayText ?? ""
        case .timeOrDistance:
            if let seconds = cardio?.durationSeconds {
                return seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
            if let meters = cardio?.distanceMeters {
                return meters >= 1_000 ? "\((meters / 1_000).formatted(.number.precision(.fractionLength(0...2)))) km"
                                       : "\(Int(meters)) m"
            }
            return ""
        }
    }
}

// MARK: Snapshot

@MainActor
enum SessionSnapshotBuilder {
    static func make(session: WorkoutSession, store: SessionStore, status: SessionSnapshot.Status? = nil,
                     revision: Int? = nil) -> SessionSnapshot {
        let exercises = session.sortedExercises
        let prescriptions = (try? prescriptions(ids: Set(exercises.flatMap { ($0.sets ?? []).compactMap(\.prescriptionID) }),
                                                context: store.context)) ?? [:]
        let currentID = SessionFlow.currentExerciseID(session.flowStates, focused: session.focusedExerciseID)
        let current = exercises.first { $0.id == currentID }
        let allSets = exercises.flatMap(\.sortedSets)
        let performed = allSets.map(\.performed)
        let progress = session.exerciseProgress
        let resolvedStatus: SessionSnapshot.Status = status ?? {
            switch session.status {
            case .completed: .finished
            case .discarded: .discarded
            case .inProgress: session.pausedAt == nil ? .active : .paused
            }
        }()
        let proposals = session.status == .inProgress ? ((try? store.loadProposals(for: session)) ?? []) : []
        let workoutType = HealthSessionTimeline.make(session: session, context: store.context).workoutType

        var snapshot = SessionSnapshot(
            sessionID: session.id,
            revision: revision ?? session.revision,
            status: resolvedStatus,
            routineID: session.routineID,
            routineName: session.routineName,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            pausedAt: session.pausedAt,
            accumulatedPauseSeconds: session.accumulatedPauseSeconds,
            restEndsAt: session.restEndsAt,
            holdSetID: session.holdSetID,
            holdStartedAt: session.holdStartedAt,
            currentExerciseID: currentID,
            currentSetID: current?.sortedSets.first { !$0.isCompleted }?.id,
            exercises: exercises.map { exercise in
                SessionSnapshot.Exercise(
                    id: exercise.id,
                    exerciseID: exercise.exerciseID,
                    name: exercise.name,
                    measurementKind: WatchMeasurementKind(exercise.measurementKind),
                    status: WatchExerciseStatus(exercise.status),
                    groupID: exercise.groupID,
                    restSeconds: exercise.restSeconds,
                    sets: exercise.sortedSets.map { log in
                        let repTarget = log.repTarget
                        let cardio = log.cardioTarget
                        return SessionSnapshot.ExerciseSet(
                            id: log.id,
                            kind: WatchSetKind(log.kind),
                            targetText: SessionDisplay.targetText(measurement: exercise.measurementKind,
                                                                  repTarget: repTarget,
                                                                  holdSeconds: log.targetHoldSeconds,
                                                                  cardio: log.cardioTarget),
                            repTarget: repTarget.map(WatchRepTarget.init),
                            effort: log.prescriptionID.flatMap { prescriptions[$0]?.effort }.map(WatchEffort.init),
                            plannedLoad: log.plannedLoad.map(WatchLoad.init),
                            load: log.load.map(WatchLoad.init),
                            reps: log.reps,
                            targetHoldSeconds: log.targetHoldSeconds,
                            durationSeconds: log.durationSeconds,
                            distanceMeters: log.distanceMeters,
                            restSeconds: log.restSeconds ?? exercise.restSeconds,
                            isCompleted: log.isCompleted,
                            completedAt: log.completedAt,
                            targetDurationSeconds: cardio?.durationSeconds,
                            targetDistanceMeters: cardio?.distanceMeters,
                            level: log.level,
                            speedKmh: log.speedKmh,
                            inclinePercent: log.inclinePercent)
                    },
                    notes: exercise.notes.isEmpty ? nil : exercise.notes,
                    painLocation: exercise.painLocation,
                    painScore: exercise.painLevel)
            },
            metrics: SessionSnapshot.Metrics(
                completedSets: allSets.filter(\.isCompleted).count,
                totalSets: allSets.count,
                exercisesDone: progress.done,
                exercisesTotal: progress.total,
                volumeKg: WorkoutMetrics.volumeKg(performed),
                hasEstimatedVolume: WorkoutMetrics.hasEstimatedVolume(performed)),
            loadProposals: proposals.map {
                SessionSnapshot.LoadProposal(prescriptionID: $0.prescriptionID, exerciseName: $0.exerciseName,
                                             from: $0.from.map(WatchLoad.init), to: WatchLoad($0.to))
            })
        snapshot.focusedExerciseID = session.focusedExerciseID
        snapshot.restTotalSeconds = session.restEndsAt == nil ? nil : session.restTotalSeconds
        snapshot.appliedCommandIDs = Array(session.appliedCommandIDs.suffix(SessionSnapshot.appliedCommandWindow))
        snapshot.currentGroup = SessionSnapshot.groupRound(exercises: snapshot.exercises, currentID: currentID)
        snapshot.notes = session.notes.isEmpty ? nil : session.notes
        snapshot.workoutType = workoutType.rawValue
        return snapshot
    }

    static func prescriptions(ids: Set<UUID>, context: ModelContext) throws -> [UUID: SetPrescription] {
        guard !ids.isEmpty else { return [:] }
        let found = try context.fetch(FetchDescriptor<SetPrescription>(predicate: #Predicate { ids.contains($0.id) }))
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: ProgramDigest

@MainActor
enum ProgramDigestBuilder {
    /// Resumo do programa ativo (`nil` sem programa ativo) para o relógio fora de sessão.
    static func make(context: ModelContext, now: Date = .now, calendar: Calendar = .current,
                     fallbackRest: Int = RestPreference.defaultSeconds()) throws -> ProgramDigest? {
        let programs = ProgramStore(context: context)
        guard let program = try programs.activeProgram() else { return nil }
        let suggestion = try programs.todaySuggestion(for: program, on: now, calendar: calendar)
        let lastCompleted = try programs.lastCompletionByRoutine(programID: program.id)
        return ProgramDigest(
            generatedAt: now,
            programID: program.id,
            name: program.name,
            scheduleMode: program.scheduleMode.rawValue,
            suggestedRoutineIDs: suggestion.routineIDs,
            routines: program.sortedRoutines.map { routine in
                ProgramDigest.Routine(
                    id: routine.id,
                    name: routine.name,
                    symbol: routine.symbol,
                    lastCompletedAt: lastCompleted[routine.id],
                    estimatedDurationSeconds: routine.estimatedDurationSeconds(fallbackRest: fallbackRest),
                    exercises: routine.sortedExercises.map { item in
                        let kind = item.exercise?.measurementKind ?? .repsAndLoad
                        let rest = RestPolicy.effective(set: nil, routineExercise: item.restSeconds,
                                                  exercise: item.exercise?.defaultRestSeconds, fallback: fallbackRest)
                        return ProgramDigest.Exercise(
                            id: item.id,
                            exerciseID: item.exercise?.id,
                            name: item.displayName,
                            measurementKind: WatchMeasurementKind(kind),
                            groupID: item.groupID,
                            restSeconds: rest,
                            sets: item.sortedSets.map { set in
                                ProgramDigest.ExerciseSet(
                                    id: set.id,
                                    kind: WatchSetKind(set.kind),
                                    targetText: SessionDisplay.targetText(measurement: kind, repTarget: set.repTarget,
                                                                          holdSeconds: set.holdSeconds, cardio: set.cardio),
                                    repTarget: set.repTarget.map(WatchRepTarget.init),
                                    effort: set.effort.map(WatchEffort.init),
                                    load: set.effectiveLoad.map(WatchLoad.init),
                                    holdSeconds: set.holdSeconds,
                                    restSeconds: set.restSeconds ?? rest,
                                    targetDurationSeconds: set.cardio?.durationSeconds,
                                    targetDistanceMeters: set.cardio?.distanceMeters)
                            })
                    },
                    workoutType: workoutType(of: routine).rawValue,
                    colorName: routine.colorName.isEmpty ? nil : routine.colorName)
            })
    }

    /// Mesma regra do Saúde no fim da sessão (`HealthWorkoutType.derive`), pela ficha.
    static func workoutType(of routine: Routine) -> HealthWorkoutType {
        HealthWorkoutType.derive(from: routine.sortedExercises.map { item in
            HealthWorkoutTypeInput(measurementKind: item.exercise?.measurementKind ?? .repsAndLoad,
                                   primaryMuscles: item.exercise?.primaryMuscles ?? [],
                                   equipment: item.exercise?.equipment, name: item.displayName)
        })
    }
}
