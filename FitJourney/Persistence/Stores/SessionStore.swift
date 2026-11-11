import Foundation
import SwiftData

enum SessionStoreError: Error, Equatable {
    /// Já existe uma sessão em andamento (SPEC §4.1: só uma por vez).
    case sessionAlreadyInProgress
    /// Operação exige sessão em andamento.
    case sessionNotInProgress
}

/// Resumo exibido em "Finalizar treino" (SPEC §4.3). Cargas/volume em kg.
struct SessionSummary: Sendable, Hashable {
    var durationSeconds: TimeInterval
    var volumeKg: Double
    var completedSets: Int
    var totalSets: Int
    var skippedExercises: [String]
    var personalRecords: [PersonalRecord]
    /// Propostas de atualização de carga atual (R-T2) — padrão: todas marcadas.
    var loadProposals: [LoadUpdateProposal]
}

/// Ciclo de vida da sessão de treino. Persiste a cada mudança; relógio só por datas.
@MainActor
struct SessionStore {
    let context: ModelContext

    init(context: ModelContext) { self.context = context }

    // MARK: Leitura

    func inProgressSession() throws -> WorkoutSession? {
        let raw = SessionStatus.inProgress.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == raw })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Sessões concluídas, mais recentes primeiro.
    func completedSessions(limit: Int? = nil) throws -> [WorkoutSession] {
        let raw = SessionStatus.completed.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == raw },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Última execução concluída de um exercício ("última vez: 3×10 com 32 kg").
    func lastPerformance(exerciseID: UUID, before date: Date = .distantFuture) throws -> SessionExercise? {
        let completed = SessionStatus.completed.rawValue
        let skipped = SessionExerciseStatus.skipped.rawValue
        let eid: UUID? = exerciseID
        var descriptor = FetchDescriptor<SessionExercise>(
            predicate: #Predicate { item in
                item.exerciseID == eid && item.statusRaw != skipped
                    && item.session?.statusRaw == completed
                    && (item.session?.startedAt ?? date) < date
            },
            sortBy: [SortDescriptor(\.session?.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Início

    /// Inicia a sessão copiando a prescrição da ficha (snapshot). `routine == nil` = treino livre.
    /// Cada `SetLog` nasce com `plannedLoad` = carga atual (ou inicial) da série prescrita.
    @discardableResult
    func start(routine: Routine?, at date: Date = .now) throws -> WorkoutSession {
        guard try inProgressSession() == nil else { throw SessionStoreError.sessionAlreadyInProgress }
        let session = WorkoutSession(routineName: routine?.name ?? String(localized: "Treino livre"), startedAt: date)
        session.routineID = routine?.id
        session.programID = routine?.program?.id
        context.insert(session)
        session.routine = routine

        for item in routine?.sortedExercises ?? [] {
            let exercise = item.exercise
            let snapshot = SessionExercise(name: item.displayName,
                                           measurementKind: exercise?.measurementKind ?? .repsAndLoad,
                                           sortIndex: item.sortIndex)
            snapshot.exerciseID = exercise?.id
            snapshot.routineExerciseID = item.id
            snapshot.laterality = exercise?.laterality ?? .bilateral
            snapshot.groupID = item.groupID
            snapshot.restSeconds = item.restSeconds ?? exercise?.defaultRestSeconds
            snapshot.notes = item.notes
            context.insert(snapshot)
            snapshot.session = session

            for prescription in item.sortedSets {
                let log = SetLog(sortIndex: prescription.sortIndex, kind: prescription.kind,
                                 repTarget: prescription.repTarget, plannedLoad: prescription.effectiveLoad,
                                 prescriptionID: prescription.id)
                log.targetHoldSeconds = prescription.holdSeconds
                log.restSeconds = prescription.restSeconds ?? snapshot.restSeconds
                log.cardioTarget = prescription.cardio
                context.insert(log)
                log.sessionExercise = snapshot
            }
        }
        try context.save()
        return session
    }

    // MARK: Durante

    /// Conclui a série com os valores exibidos (padrão: alvo/carga planejada) e inicia o descanso.
    func completeSet(_ log: SetLog, reps: Int? = nil, load: Load? = nil, durationSeconds: Double? = nil,
                     distanceMeters: Double? = nil, at date: Date = .now, startRest: Bool = true) throws {
        log.reps = reps ?? log.reps ?? log.repTarget?.defaultReps
        log.load = load ?? log.load ?? log.plannedLoad
        if let durationSeconds { log.durationSeconds = durationSeconds }
        else if log.durationSeconds == nil, let hold = log.targetHoldSeconds { log.durationSeconds = Double(hold) }
        if let distanceMeters { log.distanceMeters = distanceMeters }
        log.isCompleted = true
        log.completedAt = date
        markEditedIfFinished(log, at: date)
        if let exercise = log.sessionExercise {
            refreshStatus(exercise, at: date)
            if startRest, let session = exercise.session, session.status == .inProgress {
                var clock = session.clock
                // Em bi-set/circuito, descanso só ao fim da rodada: o último exercício do grupo descansa.
                if isEndOfRound(exercise) {
                    clock.startRest(seconds: log.restSeconds ?? exercise.restSeconds ?? 0, at: date)
                } else {
                    clock.skipRest()
                }
                session.clock = clock
            }
        }
        try context.save()
    }

    func uncompleteSet(_ log: SetLog, at date: Date = .now) throws {
        log.isCompleted = false
        log.completedAt = nil
        markEditedIfFinished(log, at: date)
        if let exercise = log.sessionExercise { refreshStatus(exercise, at: date) }
        try context.save()
    }

    /// Edita valores realizados (antes ou depois de concluir). Em sessão encerrada marca "editado".
    func updateSet(_ log: SetLog, reps: Int?, load: Load?, durationSeconds: Double? = nil,
                   distanceMeters: Double? = nil, at date: Date = .now) throws {
        log.reps = reps
        log.load = load
        log.durationSeconds = durationSeconds
        log.distanceMeters = distanceMeters
        markEditedIfFinished(log, at: date)
        try context.save()
    }

    /// Série extra (copia alvo/carga da última). Sem `prescriptionID`: não atualiza a ficha.
    @discardableResult
    func addSet(to exercise: SessionExercise, kind: SetKind = .working) throws -> SetLog {
        let last = exercise.sortedSets.last
        let log = SetLog(sortIndex: (last?.sortIndex ?? -1) + 1, kind: kind,
                         repTarget: last?.repTarget, plannedLoad: last?.load ?? last?.plannedLoad)
        log.restSeconds = last?.restSeconds ?? exercise.restSeconds
        log.targetHoldSeconds = last?.targetHoldSeconds
        context.insert(log)
        log.sessionExercise = exercise
        refreshStatus(exercise, at: .now)
        try context.save()
        return log
    }

    func removeSet(_ log: SetLog) throws {
        let exercise = log.sessionExercise
        context.delete(log)
        if let exercise {
            exercise.sets?.removeAll { $0.persistentModelID == log.persistentModelID }
            refreshStatus(exercise, at: .now)
        }
        try context.save()
    }

    /// Adiciona um exercício não previsto (ou o primeiro do treino livre) com `setCount` séries.
    @discardableResult
    func addExercise(_ exercise: Exercise, to session: WorkoutSession, setCount: Int = 3,
                     repTarget: RepTarget = .fixed(reps: 10)) throws -> SessionExercise {
        let snapshot = SessionExercise(name: exercise.name, measurementKind: exercise.measurementKind,
                                       sortIndex: (session.exercises ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0)
        snapshot.exerciseID = exercise.id
        snapshot.laterality = exercise.laterality
        snapshot.restSeconds = exercise.defaultRestSeconds
        context.insert(snapshot)
        snapshot.session = session
        for index in 0..<max(0, setCount) {
            let log = SetLog(sortIndex: index, kind: .working, repTarget: repTarget)
            log.restSeconds = exercise.defaultRestSeconds
            context.insert(log)
            log.sessionExercise = snapshot
        }
        try context.save()
        return snapshot
    }

    /// Troca o exercício na hora; a origem fica registrada e a série perde o vínculo com a ficha.
    func substitute(_ sessionExercise: SessionExercise, with exercise: Exercise) throws {
        if sessionExercise.substitutedFromExerciseID == nil && sessionExercise.substitutedFromName == nil {
            sessionExercise.substitutedFromExerciseID = sessionExercise.exerciseID
            sessionExercise.substitutedFromName = sessionExercise.name
        }
        sessionExercise.exerciseID = exercise.id
        sessionExercise.name = exercise.name
        sessionExercise.measurementKind = exercise.measurementKind
        sessionExercise.laterality = exercise.laterality
        for log in sessionExercise.sets ?? [] {
            log.prescriptionID = nil
            if !log.isCompleted { log.plannedLoad = nil }
        }
        sessionExercise.updatedAt = .now
        try context.save()
    }

    func skipExercise(_ exercise: SessionExercise, reason: SkipReason? = nil, text: String? = nil) throws {
        exercise.status = .skipped
        exercise.skipReason = reason
        exercise.skipReasonText = text
        exercise.updatedAt = .now
        try context.save()
    }

    /// Retoma um exercício pulado.
    func unskipExercise(_ exercise: SessionExercise) throws {
        exercise.status = .pending
        exercise.skipReason = nil
        exercise.skipReasonText = nil
        refreshStatus(exercise, at: .now)
        try context.save()
    }

    /// Conclusão manual: com séries pendentes vira "concluído parcialmente".
    func completeExercise(_ exercise: SessionExercise) throws {
        let sets = exercise.sets ?? []
        exercise.status = SessionExerciseRules.manualCompletionStatus(
            completedSets: sets.filter(\.isCompleted).count, totalSets: sets.count)
        exercise.updatedAt = .now
        try context.save()
    }

    // MARK: Relógio

    func pause(_ session: WorkoutSession, at date: Date = .now) throws {
        try mutateClock(session) { $0.pause(at: date) }
    }

    func resume(_ session: WorkoutSession, at date: Date = .now) throws {
        try mutateClock(session) { $0.resume(at: date) }
    }

    func startRest(_ session: WorkoutSession, seconds: Int, at date: Date = .now) throws {
        try mutateClock(session) { $0.startRest(seconds: seconds, at: date) }
    }

    /// +15 / −15 s.
    func adjustRest(_ session: WorkoutSession, by seconds: Int, at date: Date = .now) throws {
        try mutateClock(session) { $0.adjustRest(by: seconds, at: date) }
    }

    func skipRest(_ session: WorkoutSession) throws {
        try mutateClock(session) { $0.skipRest() }
    }

    // MARK: Encerrar

    /// Resumo para a tela de fim (não altera nada).
    func summary(for session: WorkoutSession, at date: Date = .now) throws -> SessionSummary {
        let exercises = session.sortedExercises
        let allSets = exercises.flatMap(\.sortedSets)
        let performedByExercise = Dictionary(grouping: exercises.filter { $0.exerciseID != nil }, by: { $0.exerciseID! })
            .mapValues { $0.flatMap(\.performedSets) }
        return SessionSummary(
            durationSeconds: session.clock.elapsed(at: date),
            volumeKg: WorkoutMetrics.volumeKg(allSets.map(\.performed)),
            completedSets: allSets.filter(\.isCompleted).count,
            totalSets: allSets.count,
            skippedExercises: exercises.filter { $0.status == .skipped }.map(\.name),
            personalRecords: WorkoutMetrics.personalRecords(
                session: performedByExercise,
                history: try historyBests(exerciseIDs: Set(performedByExercise.keys), excluding: session)),
            loadProposals: try loadProposals(for: session)
        )
    }

    /// Propostas de `currentLoad` (R-T2) segundo `CurrentLoadPolicy`.
    func loadProposals(for session: WorkoutSession) throws -> [LoadUpdateProposal] {
        let prescriptions = try prescriptionsByID(for: session)
        let entries = session.sortedExercises.map { exercise in
            CurrentLoadPolicy.ExerciseEntry(
                exerciseName: exercise.name,
                sets: exercise.sortedSets.map { log in
                    let prescription = log.prescriptionID.flatMap { prescriptions[$0] }
                    return CurrentLoadPolicy.SetEntry(prescriptionID: prescription?.id, kind: log.kind,
                                                      currentLoad: prescription?.effectiveLoad,
                                                      usedLoad: log.load, isCompleted: log.isCompleted)
                },
                isEligible: exercise.status != .skipped && exercise.substitutedFromName == nil
            )
        }
        return CurrentLoadPolicy.proposals(for: entries)
    }

    /// Finaliza: grava fim, RPE/humor/nota e aplica as propostas de carga confirmadas pelo usuário.
    func finish(_ session: WorkoutSession, at date: Date = .now, sessionRPE: Int? = nil, mood: Int? = nil,
                notes: String? = nil, applying proposals: [LoadUpdateProposal] = []) throws {
        guard session.status == .inProgress else { throw SessionStoreError.sessionNotInProgress }
        var clock = session.clock
        clock.finish(at: date)
        session.clock = clock
        session.status = .completed
        session.sessionRPE = sessionRPE.map { min(10, max(1, $0)) }
        session.mood = mood.map { min(5, max(1, $0)) }
        if let notes { session.notes = notes }
        session.updatedAt = date
        for exercise in session.exercises ?? [] where exercise.status == .inProgress {
            exercise.status = .partial
        }

        if !proposals.isEmpty {
            let ids = Set(proposals.map(\.prescriptionID))
            let prescriptions = try context.fetch(FetchDescriptor<SetPrescription>(predicate: #Predicate { ids.contains($0.id) }))
            let byID = Dictionary(prescriptions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for proposal in proposals {
                guard let prescription = byID[proposal.prescriptionID] else { continue }
                prescription.currentLoad = proposal.to
                prescription.updatedAt = date
            }
        }
        try context.save()
    }

    /// Descarta a sessão em andamento: nada fica no histórico (o registro é apagado).
    func discard(_ session: WorkoutSession) throws {
        guard session.status == .inProgress else { throw SessionStoreError.sessionNotInProgress }
        context.delete(session)
        try context.save()
    }

    // MARK: Internos

    private func mutateClock(_ session: WorkoutSession, _ change: (inout SessionClock) -> Void) throws {
        var clock = session.clock
        change(&clock)
        session.clock = clock
        session.updatedAt = .now
        try context.save()
    }

    private func refreshStatus(_ exercise: SessionExercise, at date: Date) {
        let sets = exercise.sets ?? []
        exercise.status = SessionExerciseRules.automaticStatus(
            current: exercise.status, completedSets: sets.filter(\.isCompleted).count, totalSets: sets.count)
        exercise.updatedAt = date
        exercise.session?.updatedAt = date
    }

    private func markEditedIfFinished(_ log: SetLog, at date: Date) {
        log.updatedAt = date
        if log.sessionExercise?.session?.status == .completed { log.edited = true }
    }

    /// Último exercício do grupo (ou exercício sem grupo) = fim da rodada.
    private func isEndOfRound(_ exercise: SessionExercise) -> Bool {
        guard let groupID = exercise.groupID, let session = exercise.session else { return true }
        let group = session.sortedExercises.filter { $0.groupID == groupID }
        return group.last?.persistentModelID == exercise.persistentModelID
    }

    private func prescriptionsByID(for session: WorkoutSession) throws -> [UUID: SetPrescription] {
        let ids = Set((session.exercises ?? []).flatMap { ($0.sets ?? []).compactMap(\.prescriptionID) })
        guard !ids.isEmpty else { return [:] }
        let found = try context.fetch(FetchDescriptor<SetPrescription>(predicate: #Predicate { ids.contains($0.id) }))
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Melhores marcas históricas (sessões concluídas, exceto esta) dos exercícios informados.
    /// Busca só os `SessionExercise` desses exercícios e agrupa por sessão — o mesmo exercício
    /// feito 2× numa sessão soma num único volume da sessão.
    private func historyBests(exerciseIDs: Set<UUID>, excluding session: WorkoutSession) throws -> [UUID: ExerciseBests] {
        guard !exerciseIDs.isEmpty else { return [:] }
        let ids: [UUID?] = exerciseIDs.map { $0 }
        let completed = SessionStatus.completed.rawValue
        let current: UUID? = session.id
        let items = try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { item in
                ids.contains(item.exerciseID) && item.session?.statusRaw == completed && item.session?.id != current
            }
        ))
        struct Key: Hashable { var exerciseID: UUID; var sessionID: UUID }
        var bySession: [Key: [PerformedSet]] = [:]
        for item in items {
            guard let exerciseID = item.exerciseID, let sessionID = item.session?.id else { continue }
            bySession[Key(exerciseID: exerciseID, sessionID: sessionID), default: []].append(contentsOf: item.performedSets)
        }
        var perExercise: [UUID: [[PerformedSet]]] = [:]
        for (key, sets) in bySession { perExercise[key.exerciseID, default: []].append(sets) }
        return perExercise.mapValues { WorkoutMetrics.bests(history: $0) }
    }
}
