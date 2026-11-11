import Foundation
import HealthKit

// Ponte entre os tipos puros (`Domain/Health*.swift`) e o HealthKit.

/// Dados do Saúde que o app lê ou grava (SPEC §6.1). Rotas não são lidas.
enum HealthDataKind: String, Sendable, Hashable, CaseIterable {
    case heartRate, workouts, activeEnergy, restingHeartRate, heartRateVariability, steps, bodyMass

    var localizedName: String {
        switch self {
        case .heartRate: String(localized: "Frequência cardíaca")
        case .workouts: String(localized: "Treinos")
        case .activeEnergy: String(localized: "Energia ativa")
        case .restingHeartRate: String(localized: "FC em repouso")
        case .heartRateVariability: String(localized: "Variabilidade da FC")
        case .steps: String(localized: "Passos")
        case .bodyMass: String(localized: "Massa corporal")
        }
    }

    var objectType: HKObjectType { sampleType }

    var sampleType: HKSampleType {
        switch self {
        case .heartRate: HKQuantityType(.heartRate)
        case .workouts: HKObjectType.workoutType()
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .heartRateVariability: HKQuantityType(.heartRateVariabilitySDNN)
        case .steps: HKQuantityType(.stepCount)
        case .bodyMass: HKQuantityType(.bodyMass)
        }
    }
}

enum HealthUnits {
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let kilocalorie = HKUnit.kilocalorie()
    static let kilogram = HKUnit.gramUnit(with: .kilo)
    static let count = HKUnit.count()
}

/// Chaves de metadados próprias gravadas no `HKWorkout` e nos eventos.
enum HealthMetadataKey {
    static let routineName = "FJRoutineName"
    static let exerciseID = "FJSessionExerciseID"
    static let exerciseName = "FJExerciseName"
    static let exerciseIndex = "FJExerciseIndex"
    static let setID = "FJSetID"
    static let setNumber = "FJSetNumber"
    static let workoutType = "FJWorkoutType"
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

extension HealthWorkoutCategory {
    /// Força x aeróbico a partir do tipo do HealthKit (treinos do app, do Watch e de outros apps).
    init(activityType: HKWorkoutActivityType) {
        switch activityType {
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining:
            self = .strength
        case .crossTraining:
            self = .mixed
        case .flexibility, .yoga, .pilates, .mindAndBody, .taiChi, .barre, .preparationAndRecovery, .cooldown:
            self = .mobility
        case .running, .cycling, .walking, .hiking, .elliptical, .rowing, .stairClimbing, .stairs, .stepTraining,
             .swimming, .highIntensityIntervalTraining, .mixedCardio, .jumpRope, .cardioDance, .socialDance,
             .kickboxing, .boxing, .crossCountrySkiing, .handCycling, .wheelchairRunPace, .wheelchairWalkPace,
             .paddleSports, .waterFitness, .swimBikeRun, .skatingSports, .snowSports, .downhillSkiing,
             .snowboarding, .surfingSports, .trackAndField, .martialArts:
            self = .aerobic
        default:
            self = .other
        }
    }
}

extension HealthWorkoutRecord {
    /// Converte um `HKWorkout` (energia e FC média das estatísticas do próprio treino).
    init(workout: HKWorkout, appBundleIDPrefix: String? = Bundle.main.bundleIdentifier) {
        let bundleID = workout.sourceRevision.source.bundleIdentifier
        let metadata = workout.metadata ?? [:]
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?
            .doubleValue(for: HealthUnits.kilocalorie)
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?
            .doubleValue(for: HealthUnits.bpm)
        let isOwn = appBundleIDPrefix.map { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? false
        self.init(id: workout.uuid, start: workout.startDate, end: workout.endDate,
                  activityTypeRaw: workout.workoutActivityType.rawValue,
                  category: HealthWorkoutCategory(activityType: workout.workoutActivityType),
                  workoutType: HealthWorkoutType(activityType: workout.workoutActivityType),
                  sourceName: workout.sourceRevision.source.name, sourceBundleID: bundleID,
                  externalUUID: metadata[HKMetadataKeyExternalUUID] as? String, isFromThisApp: isOwn,
                  routineName: metadata[HealthMetadataKey.routineName] as? String,
                  activeEnergyKcal: energy, averageHeartRate: heartRate)
    }
}

extension HealthWorkoutMetadata {
    /// Metadados do `HKWorkout` (valores só NSString/NSNumber).
    var dictionary: [String: Any] {
        var result: [String: Any] = [
            HKMetadataKeyExternalUUID: sessionID.uuidString,
            HealthMetadataKey.workoutType: workoutType.rawValue,
            HKMetadataKeyIndoorWorkout: NSNumber(value: true),
        ]
        if !routineName.isEmpty { result[HealthMetadataKey.routineName] = routineName }
        return result
    }
}

extension HealthWorkoutEventPlan {
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
