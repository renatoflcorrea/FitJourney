import Foundation
import SwiftData

// Monta os retratos puros (`HealthSessionTimeline`, `HealthSessionWindow`) a partir do SwiftData.

extension HealthSessionTimeline {
    /// - Parameter catalog: exercícios do catálogo por ID (músculos/equipamento para o tipo do treino).
    @MainActor
    init(session: WorkoutSession, catalog: [UUID: FitJourney.Exercise] = [:]) {
        let exercises = session.sortedExercises.map { exercise in
            let catalogEntry = exercise.exerciseID.flatMap { catalog[$0] }
            let marks = exercise.sortedSets.enumerated().compactMap { offset, set -> SetMark? in
                guard set.isCompleted, let completedAt = set.completedAt else { return nil }
                return SetMark(id: set.id, number: offset + 1, completedAt: completedAt, isWorking: set.kind.isWorking)
            }.sorted { $0.completedAt < $1.completedAt }
            return HealthSessionTimeline.Exercise(id: exercise.id, catalogExerciseID: exercise.exerciseID, name: exercise.name,
                                                  measurementKind: exercise.measurementKind,
                                                  primaryMuscles: catalogEntry?.primaryMuscles ?? [],
                                                  equipment: catalogEntry?.equipment, sets: marks)
        }
        let active = session.endedAt.map { session.clock.elapsed(at: $0) }
        self.init(sessionID: session.id, routineName: session.routineName, startedAt: session.startedAt,
                  endedAt: session.endedAt, activeDuration: active, exercises: exercises)
    }

    /// Busca os exercícios do catálogo usados na sessão e monta a linha do tempo.
    @MainActor
    static func make(session: WorkoutSession, context: ModelContext) -> HealthSessionTimeline {
        let ids = Set(session.sortedExercises.compactMap(\.exerciseID))
        var catalog: [UUID: FitJourney.Exercise] = [:]
        if !ids.isEmpty {
            let descriptor = FetchDescriptor<FitJourney.Exercise>(predicate: #Predicate { ids.contains($0.id) })
            for exercise in (try? context.fetch(descriptor)) ?? [] { catalog[exercise.id] = exercise }
        }
        return HealthSessionTimeline(session: session, catalog: catalog)
    }
}

extension HealthSessionWindow {
    @MainActor
    init(session: WorkoutSession, category: HealthWorkoutCategory = .strength, now: Date = Date()) {
        self.init(sessionID: session.id, routineName: session.routineName, start: session.startedAt,
                  end: max(session.startedAt, session.endedAt ?? now), category: category,
                  healthKitWorkoutID: session.healthKitWorkoutID)
    }

    /// Sessões (concluídas ou em andamento, nunca descartadas) que tocam o intervalo — para o vínculo
    /// e a aba Saúde. A categoria vem do tipo derivado da ficha.
    @MainActor
    static func windows(in interval: DateInterval, context: ModelContext, now: Date = Date()) -> [HealthSessionWindow] {
        let end = interval.end
        // Sessões começam no máximo 1 dia antes do intervalo (evita varrer o histórico inteiro).
        let lower = interval.start.addingTimeInterval(-86_400)
        let discarded = SessionStatus.discarded.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.startedAt < end && $0.startedAt > lower && $0.statusRaw != discarded },
            sortBy: [SortDescriptor(\.startedAt)])
        let sessions = (try? context.fetch(descriptor)) ?? []
        return sessions.compactMap { session in
            let window = HealthSessionWindow(session: session, now: now)
            guard window.end >= interval.start else { return nil }
            var result = window
            result.category = HealthSessionTimeline.make(session: session, context: context).workoutType.category
            return result
        }
    }
}

extension WorkoutSession {
    /// Linha do tempo para análise de FC/eventos do Saúde.
    @MainActor
    func healthTimeline(context: ModelContext) -> HealthSessionTimeline {
        HealthSessionTimeline.make(session: self, context: context)
    }
}
