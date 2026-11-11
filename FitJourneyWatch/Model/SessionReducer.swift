import Foundation

/// Aplica um `SessionCommand` a um `SessionSnapshot` localmente (otimismo do relógio, SPEC §6.4).
/// É uma aproximação das regras do `SessionEngine` do iPhone, que continua sendo a fonte de verdade:
/// o snapshot que chegar depois substitui o resultado daqui. Função pura; o tempo vem de `issuedAt`.
/// O `MockWatchTransport` reutiliza o mesmo redutor para simular o iPhone.
enum SessionReducer {
    /// Descanso padrão quando a série/exercício não prescreve (o iPhone usa a regra do app).
    static let fallbackRestSeconds = 0

    /// `nil` quando o comando não cabe (sessão diferente/ausente) — o snapshot fica como está.
    static func apply(_ command: SessionCommand, to snapshot: SessionSnapshot?, digest: ProgramDigest? = nil) -> SessionSnapshot? {
        if case .start(let routineID) = command.kind {
            guard snapshot == nil || snapshot?.status == .finished || snapshot?.status == .discarded else { return snapshot }
            return started(command, routineID: routineID, digest: digest) ?? snapshot
        }
        guard var s = snapshot, s.sessionID == command.sessionID, s.status == .active || s.status == .paused else { return snapshot }
        let at = command.issuedAt

        switch command.kind {
        case .start:
            break
        case .completeSet(let setID, let reps, let load, let duration, let distance):
            resumeIfNeeded(&s, at: at)
            guard let location = locate(setID, in: s), !s.exercises[location.e].sets[location.s].isCompleted else { return s }
            mutate(&s, location) {
                $0.isCompleted = true
                $0.completedAt = at
                if let reps { $0.reps = reps }
                if let load { $0.load = load }
                if let duration { $0.durationSeconds = duration }
                if let distance { $0.distanceMeters = distance }
            }
            s.holdSetID = nil
            s.holdStartedAt = nil
            let set = s.exercises[location.e].sets[location.s]
            let rest = set.restSeconds ?? s.exercises[location.e].restSeconds ?? fallbackRestSeconds
            if rest > 0 { s.restEndsAt = at.addingTimeInterval(Double(rest)) }
            advance(&s, after: location.e)
        case .uncompleteSet(let setID):
            guard let location = locate(setID, in: s) else { return s }
            mutate(&s, location) { $0.isCompleted = false; $0.completedAt = nil }
            retarget(&s, preferring: s.exercises[location.e].id)
        case .updateSet(let setID, let reps, let load, let duration, let distance):
            guard let location = locate(setID, in: s) else { return s }
            mutate(&s, location) {
                $0.reps = reps
                $0.load = load
                $0.durationSeconds = duration
                $0.distanceMeters = distance
            }
        case .adjustLoad(let setID, let delta):
            guard let location = locate(setID, in: s) else { return s }
            mutate(&s, location) { set in
                let base = set.load ?? set.plannedLoad ?? WatchLoad(value: 0)
                var adjusted = base
                adjusted.value = WatchLoadStepping.clamp(base.value + delta, for: base)
                set.load = adjusted
            }
        case .startRest(let seconds):
            let rest = seconds ?? s.currentExercise?.restSeconds ?? fallbackRestSeconds
            s.restEndsAt = rest > 0 ? at.addingTimeInterval(Double(rest)) : nil
        case .adjustRest(let seconds):
            if let end = s.restEndsAt { s.restEndsAt = max(at, end.addingTimeInterval(Double(seconds))) }
        case .skipRest:
            s.restEndsAt = nil
        case .startHold(let setID):
            resumeIfNeeded(&s, at: at)
            guard locate(setID, in: s) != nil else { return s }
            s.holdSetID = setID
            s.holdStartedAt = at
        case .endHold(let setID):
            guard s.holdSetID == setID, let started = s.holdStartedAt else { return s }
            var completion = command
            completion.kind = .completeSet(setID: setID, reps: nil, load: nil,
                                           durationSeconds: max(0, at.timeIntervalSince(started)), distanceMeters: nil)
            return apply(completion, to: s)
        case .skipExercise(let exerciseID, _):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            s.exercises[index].status = .skipped
            if s.currentExerciseID == exerciseID { retarget(&s, preferring: nil, after: index) }
        case .completeExercise(let exerciseID):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            let allDone = s.exercises[index].sets.allSatisfy(\.isCompleted)
            s.exercises[index].status = allDone ? .completed : .partial
            if s.currentExerciseID == exerciseID { retarget(&s, preferring: nil, after: index) }
        case .focusExercise(let exerciseID):
            guard s.exercises.contains(where: { $0.id == exerciseID }) else { return s }
            s.currentExerciseID = exerciseID
            s.currentSetID = s.exercises.first { $0.id == exerciseID }?.sets.first { !$0.isCompleted }?.id
        case .addSet(let exerciseID, let kind):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }), var copy = s.exercises[index].sets.last else { return s }
            copy.id = UUID()
            copy.isCompleted = false
            copy.completedAt = nil
            copy.reps = nil
            copy.durationSeconds = nil
            copy.distanceMeters = nil
            if let kind { copy.kind = kind }
            s.exercises[index].sets.append(copy)
        case .addExercise, .substituteExercise:
            break // exigem o catálogo: só o iPhone aplica; o relógio espera o snapshot.
        case .reorderExercise(let exerciseID, let toIndex):
            guard let from = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            let item = s.exercises.remove(at: from)
            s.exercises.insert(item, at: min(max(toIndex, 0), s.exercises.count))
        case .pause:
            guard s.status == .active else { return s }
            s.status = .paused
            s.pausedAt = at
        case .resume:
            resume(&s, at: at)
        case .finish:
            resumeIfNeeded(&s, at: at)
            s.status = .finished
            s.endedAt = at
            s.restEndsAt = nil
            s.holdSetID = nil
            s.holdStartedAt = nil
        case .discard:
            s.status = .discarded
            s.endedAt = at
            s.restEndsAt = nil
        }
        s.metrics = metrics(of: s)
        return s
    }

    // MARK: Início

    private static func started(_ command: SessionCommand, routineID: UUID?, digest: ProgramDigest?) -> SessionSnapshot? {
        guard let routineID, let routine = digest?.routines.first(where: { $0.id == routineID }) else { return nil }
        let exercises = routine.exercises.map { exercise in
            SessionSnapshot.Exercise(
                id: exercise.id, exerciseID: exercise.exerciseID, name: exercise.name,
                measurementKind: exercise.measurementKind, status: .pending, groupID: exercise.groupID,
                restSeconds: exercise.restSeconds,
                sets: exercise.sets.map { set in
                    SessionSnapshot.ExerciseSet(
                        id: set.id, kind: set.kind, targetText: set.targetText, repTarget: set.repTarget, effort: set.effort,
                        plannedLoad: set.load, load: set.load, reps: nil, targetHoldSeconds: set.holdSeconds,
                        durationSeconds: nil, distanceMeters: nil, restSeconds: set.restSeconds, isCompleted: false, completedAt: nil)
                })
        }
        var snapshot = SessionSnapshot(
            sessionID: command.sessionID, revision: 0, status: .active, routineID: routine.id, routineName: routine.name,
            startedAt: command.issuedAt, endedAt: nil, pausedAt: nil, accumulatedPauseSeconds: 0, restEndsAt: nil,
            holdSetID: nil, holdStartedAt: nil, currentExerciseID: nil, currentSetID: nil, exercises: exercises,
            metrics: .init(completedSets: 0, totalSets: 0, exercisesDone: 0, exercisesTotal: 0, volumeKg: 0, hasEstimatedVolume: false),
            loadProposals: [])
        retarget(&snapshot, preferring: nil, after: -1)
        snapshot.metrics = metrics(of: snapshot)
        return snapshot
    }

    // MARK: Auxiliares

    private struct Location { var e: Int; var s: Int }

    private static func locate(_ setID: UUID, in s: SessionSnapshot) -> Location? {
        for (e, exercise) in s.exercises.enumerated() {
            if let index = exercise.sets.firstIndex(where: { $0.id == setID }) { return Location(e: e, s: index) }
        }
        return nil
    }

    private static func mutate(_ s: inout SessionSnapshot, _ location: Location, _ body: (inout SessionSnapshot.ExerciseSet) -> Void) {
        body(&s.exercises[location.e].sets[location.s])
    }

    private static func resumeIfNeeded(_ s: inout SessionSnapshot, at: Date) {
        if s.status == .paused, let pausedAt = s.pausedAt, at > pausedAt { resume(&s, at: at) }
    }

    private static func resume(_ s: inout SessionSnapshot, at: Date) {
        guard s.status == .paused, let pausedAt = s.pausedAt else { return }
        let gap = max(0, at.timeIntervalSince(pausedAt))
        s.accumulatedPauseSeconds += gap
        if let end = s.restEndsAt { s.restEndsAt = end.addingTimeInterval(gap) }
        s.status = .active
        s.pausedAt = nil
    }

    /// Depois de concluir uma série: o exercício atual continua enquanto houver série pendente.
    private static func advance(_ s: inout SessionSnapshot, after exerciseIndex: Int) {
        let exercise = s.exercises[exerciseIndex]
        if exercise.sets.allSatisfy(\.isCompleted) {
            s.exercises[exerciseIndex].status = .completed
            if s.currentExerciseID == exercise.id || s.currentExerciseID == nil {
                retarget(&s, preferring: nil, after: exerciseIndex)
            }
        } else {
            s.exercises[exerciseIndex].status = .inProgress
            if s.currentExerciseID == nil || s.currentExerciseID == exercise.id {
                s.currentExerciseID = exercise.id
                s.currentSetID = exercise.sets.first { !$0.isCompleted }?.id
            }
        }
    }

    /// Escolhe o exercício atual: `preferring` se ainda tem série pendente; senão o próximo aberto depois de `after`.
    private static func retarget(_ s: inout SessionSnapshot, preferring: UUID?, after: Int? = nil) {
        func isOpen(_ e: SessionSnapshot.Exercise) -> Bool {
            e.status != .skipped && e.status != .completed && e.sets.contains { !$0.isCompleted }
        }
        var pick: SessionSnapshot.Exercise?
        if let preferring, let e = s.exercises.first(where: { $0.id == preferring }) {
            pick = e
            if e.status == .completed || e.status == .skipped { s.exercises[s.exercises.firstIndex { $0.id == preferring }!].status = .inProgress }
        } else {
            let start = (after ?? -1) + 1
            pick = s.exercises.dropFirst(start).first(where: isOpen) ?? s.exercises.first(where: isOpen)
        }
        s.currentExerciseID = pick?.id
        s.currentSetID = pick?.sets.first { !$0.isCompleted }?.id
    }

    static func metrics(of s: SessionSnapshot) -> SessionSnapshot.Metrics {
        var done = 0, total = 0, volume = 0.0, estimated = false
        for exercise in s.exercises where exercise.status != .skipped {
            for set in exercise.sets {
                total += 1
                guard set.isCompleted else { continue }
                done += 1
                guard let load = set.load, !load.isBodyweight, load.unit == .kg else { continue }
                if let reps = set.reps {
                    volume += load.value * Double(reps)
                } else if let floor = repFloor(set.repTarget) {
                    volume += load.value * Double(floor)
                    estimated = true
                }
            }
        }
        let closed = s.exercises.filter { [.completed, .partial, .skipped].contains($0.status) }.count
        return .init(completedSets: done, totalSets: total, exercisesDone: closed, exercisesTotal: s.exercises.count,
                     volumeKg: volume, hasEstimatedVolume: estimated)
    }

    private static func repFloor(_ target: WatchRepTarget?) -> Int? {
        switch target {
        case .fixed(let reps): reps
        case .range(let min, _): min
        case .amrap, nil: nil
        }
    }
}
