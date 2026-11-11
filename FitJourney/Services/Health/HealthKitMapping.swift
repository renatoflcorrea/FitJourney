import Foundation
import HealthKit

// Ponte entre os tipos puros (`Domain/Health*.swift`) e o HealthKit.

/// Dados do Saúde que o app lê ou grava (SPEC §6.1). Rotas não são lidas; VFC fica fora até haver uso.
enum HealthDataKind: String, Sendable, Hashable, CaseIterable {
    case heartRate, workouts, activeEnergy, restingHeartRate, steps, bodyMass

    var localizedName: String {
        switch self {
        case .heartRate: String(localized: "Frequência cardíaca")
        case .workouts: String(localized: "Treinos")
        case .activeEnergy: String(localized: "Energia ativa")
        case .restingHeartRate: String(localized: "FC em repouso")
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

// `HealthMetadataKey`, `HealthWorkoutType.activityType`/`workoutConfiguration` e os eventos do plano ficam em
// `Shared/Health/HealthKitWorkoutMapping.swift` (compilado também no relógio).
