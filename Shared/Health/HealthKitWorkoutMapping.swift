import Foundation
import HealthKit

// Ponte HealthKit dos tipos puros de treino, compartilhada entre iPhone e relógio (W3b): o relógio grava o
// `HKWorkout` com as mesmas chaves de metadados, o mesmo tipo e os mesmos eventos por exercício/série.
// Depende de `Domain/HealthWorkoutType.swift` e `Domain/HealthAnalysis.swift` (também compilados no relógio).

/// Chaves de metadados próprias gravadas no `HKWorkout` e nos eventos.
enum HealthMetadataKey {
    static let routineName = "FJRoutineName"
    static let exerciseID = "FJSessionExerciseID"
    static let exerciseName = "FJExerciseName"
    static let exerciseIndex = "FJExerciseIndex"
    static let setID = "FJSetID"
    static let setNumber = "FJSetNumber"
    static let workoutType = "FJWorkoutType"
    /// `true` na amostra de energia ativa estimada pelo app (sem medição de Watch/sensor).
    static let estimatedEnergy = "FJEstimatedEnergy"
}

extension HealthWorkoutType {
    var activityType: HKWorkoutActivityType {
        switch self {
        case .traditionalStrength: .traditionalStrengthTraining
        case .functionalStrength: .functionalStrengthTraining
        case .hiit: .highIntensityIntervalTraining
        case .core: .coreTraining
        case .flexibility: .flexibility
        case .running: .running
        case .cycling: .cycling
        case .elliptical: .elliptical
        case .rowing: .rowing
        case .stairClimbing: .stairClimbing
        case .walking: .walking
        case .mixedCardio: .mixedCardio
        }
    }

    /// Tipo do FitJourney que gera este `HKWorkoutActivityType` (`nil` se nenhum).
    init?(activityType: HKWorkoutActivityType) {
        guard let match = HealthWorkoutType.allCases.first(where: { $0.activityType == activityType }) else { return nil }
        self = match
    }

    var workoutConfiguration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        // Academia: indoor, exceto cardio que pode ser na rua (corrida/caminhada/bicicleta sem GPS aqui).
        configuration.locationType = .indoor
        return configuration
    }
}

extension HealthWorkoutEventPlan {
    /// `.pause`/`.resume` (só para o gravador simples; a sessão ao vivo gera os seus).
    var pauseEvents: [HKWorkoutEvent] {
        pauses.map {
            HKWorkoutEvent(type: $0.kind == .pause ? .pause : .resume,
                           dateInterval: DateInterval(start: $0.date, duration: 0), metadata: nil)
        }
    }

    /// `HKWorkoutEvent`s: `.segment` por exercício e `.marker` por série.
    var workoutEvents: [HKWorkoutEvent] {
        let segmentEvents = segments.map { segment in
            HKWorkoutEvent(type: .segment, dateInterval: segment.interval, metadata: [
                HealthMetadataKey.exerciseID: segment.exerciseID.uuidString,
                HealthMetadataKey.exerciseName: segment.exerciseName,
                HealthMetadataKey.exerciseIndex: NSNumber(value: segment.index),
            ])
        }
        let markerEvents = markers.map { marker in
            HKWorkoutEvent(type: .marker, dateInterval: DateInterval(start: marker.date, duration: 0), metadata: [
                HealthMetadataKey.setID: marker.setID.uuidString,
                HealthMetadataKey.exerciseID: marker.exerciseID.uuidString,
                HealthMetadataKey.exerciseName: marker.exerciseName,
                HealthMetadataKey.setNumber: NSNumber(value: marker.setNumber),
            ])
        }
        return segmentEvents + markerEvents
    }
}
