import Foundation

/// Aplica um `SessionCommand` a um `SessionSnapshot` localmente (otimismo do relógio, SPEC §6.4).
/// É uma aproximação das regras do `SessionEngine` do iPhone, que continua sendo a fonte de verdade:
/// o snapshot que chegar depois substitui o resultado daqui. Função pura; o tempo vem de `issuedAt`.
/// O `MockWatchTransport` reutiliza o mesmo redutor para simular o iPhone.
///
/// IDs (protocolo v2): o `start` e o `addSet` usam `WatchLinkIDs`, os mesmos que o iPhone grava — o
/// snapshot otimista e o do iPhone citam as mesmas séries.
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
            let isIsometric = s.exercises[location.e].measurementKind == .isometric
            let shownBefore = shownLoad(s.exercises[location.e].sets[location.s])
            defer { if load != nil { propagateLoad(&s, from: location, previous: shownBefore) } }
            mutate(&s, location) {
                $0.isCompleted = true
                $0.completedAt = at
                if let reps { $0.reps = reps }
                if let load { $0.load = load }
                // Isométrico concluído sem medição: usa o alvo como duração (mesma regra do iPhone).
                if let duration { $0.durationSeconds = duration } else if isIsometric, let hold = $0.targetHoldSeconds { $0.durationSeconds = Double(hold) }
                if let distance { $0.distanceMeters = distance }
            }
            s.holdSetID = nil
            s.holdStartedAt = nil
            let set = s.exercises[location.e].sets[location.s]
            let rest = set.restSeconds ?? s.exercises[location.e].restSeconds ?? fallbackRestSeconds
            // No grupo, a escolha manual cede à alternância por rodada (mesma regra do iPhone).
            if let group = s.exercises[location.e].groupID, let focused = s.focusedExerciseID,
               s.exercises.contains(where: { $0.id == focused && $0.groupID == group }) {
                s.focusedExerciseID = nil
            }
            advance(&s, after: location.e)
            // Bi-set/circuito: o descanso só começa no fim da rodada (`SessionFlow.isEndOfRound`).
            if isEndOfRound(s, after: location.e) {
                s.restEndsAt = rest > 0 ? at.addingTimeInterval(Double(rest)) : nil
                s.restTotalSeconds = rest > 0 ? Double(rest) : nil
            } else {
                s.restEndsAt = nil
                s.restTotalSeconds = nil
            }
        case .uncompleteSet(let setID):
            guard let location = locate(setID, in: s) else { return s }
            mutate(&s, location) { $0.isCompleted = false; $0.completedAt = nil }
            reopen(&s, exerciseAt: location.e)
        case .updateSet(let setID, let reps, let load, let duration, let distance):
            guard let location = locate(setID, in: s) else { return s }
            let shownBefore = shownLoad(s.exercises[location.e].sets[location.s])
            defer { propagateLoad(&s, from: location, previous: shownBefore) }
            mutate(&s, location) {
                $0.reps = reps
                $0.load = load
                $0.durationSeconds = duration
                $0.distanceMeters = distance
            }
        case .adjustLoad(let setID, let delta):
            guard let location = locate(setID, in: s) else { return s }
            let shownBefore = shownLoad(s.exercises[location.e].sets[location.s])
            defer { propagateLoad(&s, from: location, previous: shownBefore) }
            let base = loadBase(at: location, in: s)
            mutate(&s, location) { set in
                var adjusted = base
                adjusted.value = WatchLoadStepping.clamp(base.value + delta, for: base)
                set.load = adjusted
            }
        case .startRest(let seconds):
            let rest = seconds ?? s.currentExercise?.restSeconds ?? fallbackRestSeconds
            s.restEndsAt = rest > 0 ? (s.pausedAt ?? at).addingTimeInterval(Double(rest)) : nil
            s.restTotalSeconds = rest > 0 ? Double(rest) : nil
        case .adjustRest(let seconds):
            if let end = s.restEndsAt {
                let adjusted = end.addingTimeInterval(Double(seconds))
                let reference = s.pausedAt ?? at
                if adjusted > reference {
                    s.restEndsAt = adjusted
                    let remaining = adjusted.timeIntervalSince(reference)
                    s.restTotalSeconds = max(remaining, (s.restTotalSeconds ?? remaining - Double(seconds)) + Double(seconds))
                } else {
                    s.restEndsAt = nil
                    s.restTotalSeconds = nil
                }
            }
        case .skipRest:
            s.restEndsAt = nil
            s.restTotalSeconds = nil
        case .startHold(let setID):
            resumeIfNeeded(&s, at: at)
            guard let location = locate(setID, in: s), !s.exercises[location.e].sets[location.s].isCompleted else { return s }
            s.holdSetID = setID
            s.holdStartedAt = at
            s.restEndsAt = nil
            s.restTotalSeconds = nil
        case .endHold(let setID):
            guard s.holdSetID == setID, let started = s.holdStartedAt else { return s }
            // Pausada: conta até o início da pausa (o início já foi deslocado pelas retomadas).
            let end = s.pausedAt.map { min($0, at) } ?? at
            var completion = command
            completion.kind = .completeSet(setID: setID, reps: nil, load: nil,
                                           durationSeconds: max(0, end.timeIntervalSince(started)), distanceMeters: nil)
            return apply(completion, to: s)
        case .updateHoldTarget(let setID, let seconds):
            guard seconds > 0, let location = locate(setID, in: s) else { return s }
            let isCardio = s.exercises[location.e].measurementKind == .timeOrDistance
            mutate(&s, location) {
                if isCardio { $0.targetDurationSeconds = seconds } else { $0.targetHoldSeconds = seconds }
                $0.targetText = isCardio ? WatchFormat.cardioTargetText(seconds: seconds) : "\(seconds) s"
            }
        case .updateCardio(let setID, let level, let speed, let incline):
            guard let location = locate(setID, in: s) else { return s }
            mutate(&s, location) {
                $0.level = level
                $0.speedKmh = speed
                $0.inclinePercent = incline
            }
        case .removeSet(let setID):
            guard let location = locate(setID, in: s) else { return s }
            s.exercises[location.e].sets.remove(at: location.s)
            if s.holdSetID == setID {
                s.holdSetID = nil
                s.holdStartedAt = nil
            }
            refreshStatus(&s, exerciseAt: location.e)
            selectCurrent(&s)
        case .changeSetKind(let setID, let kind):
            guard kind != .unknown, let location = locate(setID, in: s) else { return s }
            mutate(&s, location) { $0.kind = kind }
        case .setExerciseNote(let exerciseID, let text):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            s.exercises[index].notes = text.isEmpty ? nil : text
        case .setPain(let exerciseID, let location, let score):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            s.exercises[index].painLocation = location
            s.exercises[index].painScore = score
        case .setSessionNote(let text):
            s.notes = text.isEmpty ? nil : text
        case .skipExercise(let exerciseID, _):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            s.exercises[index].status = .skipped
            if s.focusedExerciseID == exerciseID { s.focusedExerciseID = nil }
            if s.currentExerciseID == exerciseID { selectCurrent(&s) }
        case .completeExercise(let exerciseID):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }) else { return s }
            let allDone = s.exercises[index].sets.allSatisfy(\.isCompleted)
            s.exercises[index].status = allDone ? .completed : .partial
            if s.focusedExerciseID == exerciseID { s.focusedExerciseID = nil }
            if s.currentExerciseID == exerciseID { selectCurrent(&s) }
        case .focusExercise(let exerciseID):
            guard s.exercises.contains(where: { $0.id == exerciseID }) else { return s }
            if let index = s.exercises.firstIndex(where: { $0.id == exerciseID }), s.exercises[index].status == .skipped {
                s.exercises[index].status = .inProgress // escolher um pulado o retoma
            }
            s.focusedExerciseID = exerciseID
            s.currentExerciseID = exerciseID
            s.currentSetID = s.exercises.first { $0.id == exerciseID }?.sets.first { !$0.isCompleted }?.id
        case .addSet(let exerciseID, let kind):
            guard let index = s.exercises.firstIndex(where: { $0.id == exerciseID }), var copy = s.exercises[index].sets.last else { return s }
            copy.id = WatchLinkIDs.extraSetID(sessionID: s.sessionID, commandID: command.commandID)
            let lastWorking = isWorking(copy.kind)
            if let kind { copy.kind = kind }
            // Mesma regra do iPhone: carga da última só se for do mesmo tipo; senão a última conhecida no snapshot.
            let carried = isWorking(copy.kind) == lastWorking ? (copy.load ?? definedLoad(copy.plannedLoad)) : nil
            copy.plannedLoad = carried ?? lastKnownLoad(in: s, exerciseAt: index, working: isWorking(copy.kind))
            copy.load = nil
            copy.level = nil
            copy.speedKmh = nil
            copy.inclinePercent = nil
            copy.isCompleted = false
            copy.completedAt = nil
            copy.reps = nil
            copy.durationSeconds = nil
            copy.distanceMeters = nil
            s.exercises[index].sets.append(copy)
            refreshStatus(&s, exerciseAt: index)
            if s.currentExerciseID == exerciseID || s.currentExerciseID == nil { selectCurrent(&s) }
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
        case .finish(_, _, _, let notes):
            resumeIfNeeded(&s, at: at)
            s.status = .finished
            s.endedAt = at
            s.restEndsAt = nil
            s.restTotalSeconds = nil
            s.holdSetID = nil
            s.holdStartedAt = nil
            if let notes { s.notes = notes.isEmpty ? nil : notes }
        case .discard:
            s.status = .discarded
            s.endedAt = at
            s.restEndsAt = nil
            s.restTotalSeconds = nil
        }
        s.metrics = metrics(of: s)
        s.currentGroup = SessionSnapshot.groupRound(exercises: s.exercises, currentID: s.currentExerciseID)
        return s
    }

    // MARK: Início

    private static func started(_ command: SessionCommand, routineID: UUID?, digest: ProgramDigest?) -> SessionSnapshot? {
        guard let routineID, let routine = digest?.routines.first(where: { $0.id == routineID }) else { return nil }
        let sessionID = command.sessionID
        let exercises = routine.exercises.map { exercise in
            SessionSnapshot.Exercise(
                id: WatchLinkIDs.sessionExerciseID(sessionID: sessionID, routineExerciseID: exercise.id),
                exerciseID: exercise.exerciseID, name: exercise.name,
                measurementKind: exercise.measurementKind, status: .pending, groupID: exercise.groupID,
                restSeconds: exercise.restSeconds,
                sets: exercise.sets.map { set in
                    SessionSnapshot.ExerciseSet(
                        id: WatchLinkIDs.setLogID(sessionID: sessionID, prescriptionID: set.id),
                        kind: set.kind, targetText: set.targetText, repTarget: set.repTarget, effort: set.effort,
                        plannedLoad: set.load, load: set.load, reps: nil, targetHoldSeconds: set.holdSeconds,
                        durationSeconds: nil, distanceMeters: nil, restSeconds: set.restSeconds, isCompleted: false, completedAt: nil,
                        targetDurationSeconds: set.targetDurationSeconds, targetDistanceMeters: set.targetDistanceMeters)
                })
        }
        var snapshot = SessionSnapshot(
            sessionID: command.sessionID, revision: 0, status: .active, routineID: routine.id, routineName: routine.name,
            startedAt: command.issuedAt, endedAt: nil, pausedAt: nil, accumulatedPauseSeconds: 0, restEndsAt: nil,
            holdSetID: nil, holdStartedAt: nil, currentExerciseID: nil, currentSetID: nil, exercises: exercises,
            metrics: .init(completedSets: 0, totalSets: 0, exercisesDone: 0, exercisesTotal: 0, volumeKg: 0, hasEstimatedVolume: false),
            loadProposals: [], workoutType: routine.workoutType)
        selectCurrent(&snapshot)
        snapshot.metrics = metrics(of: snapshot)
        snapshot.currentGroup = SessionSnapshot.groupRound(exercises: snapshot.exercises, currentID: snapshot.currentExerciseID)
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

    /// Base de um ajuste de carga (Coroa/−/+), igual à do iPhone (`SessionStore.adjustLoad`): a registrada, senão a
    /// planejada definida (peso 0 = vazia), senão a última carga usada no mesmo exercício nesta sessão (mesmo tipo
    /// de série). Sem nada disso, 0: o relógio não conhece o histórico de sessões antigas — o iPhone pode partir
    /// da última carga do histórico, e o snapshot confirmado corrige (raro: o início já planeja pelo histórico).
    static func loadBase(setID: UUID, in s: SessionSnapshot) -> WatchLoad? {
        locate(setID, in: s).map { loadBase(at: $0, in: s) }
    }

    private static func loadBase(at location: Location, in s: SessionSnapshot) -> WatchLoad {
        let set = s.exercises[location.e].sets[location.s]
        return shownLoad(set) ?? lastKnownLoad(in: s, exerciseAt: location.e, working: isWorking(set.kind)) ?? WatchLoad(value: 0)
    }

    /// Última carga definida registrada numa série concluída do mesmo exercício (mesmo `exerciseID`) nesta sessão.
    private static func lastKnownLoad(in s: SessionSnapshot, exerciseAt index: Int, working: Bool) -> WatchLoad? {
        let target = s.exercises[index]
        let candidates = s.exercises.filter { $0.id == target.id || (target.exerciseID != nil && $0.exerciseID == target.exerciseID) }
            .flatMap(\.sets)
            .filter { $0.isCompleted && isWorking($0.kind) == working && definedLoad($0.load) != nil }
        return candidates.max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?.load
    }

    /// Carga mostrada: a registrada, senão a planejada definida (peso 0 = sem carga).
    private static func shownLoad(_ set: SessionSnapshot.ExerciseSet) -> WatchLoad? {
        set.load ?? definedLoad(set.plannedLoad)
    }

    private static func definedLoad(_ load: WatchLoad?) -> WatchLoad? {
        guard let load, load.isBodyweight || load.value != 0 else { return nil }
        return load
    }

    private static func equivalent(_ a: WatchLoad, _ b: WatchLoad) -> Bool {
        func kg(_ load: WatchLoad) -> Double { load.unit == .lb ? load.value * 0.453_592_37 : load.value }
        return a.isBodyweight == b.isBodyweight && abs(kg(a) - kg(b)) < 0.01
    }

    private static func isWorking(_ kind: WatchSetKind) -> Bool { kind != .warmup && kind != .feeder }

    /// Mesma regra do iPhone (`SessionStore.propagateLoad`, P2.8): a carga nova da série vai para as seguintes
    /// pendentes do mesmo exercício que mostravam a mesma carga planejada e não foram editadas.
    private static func propagateLoad(_ s: inout SessionSnapshot, from location: Location, previous: WatchLoad?) {
        let source = s.exercises[location.e].sets[location.s]
        guard let new = definedLoad(source.load) else { return }
        if let previous, equivalent(previous, new) { return }
        let working = isWorking(source.kind)
        for index in s.exercises[location.e].sets.indices where index > location.s {
            let other = s.exercises[location.e].sets[index]
            guard !other.isCompleted, other.load == nil, isWorking(other.kind) == working else { continue }
            let matches: Bool = switch (definedLoad(other.plannedLoad), previous) {
            case (nil, nil): true
            case let (planned?, previous?): equivalent(planned, previous)
            default: false
            }
            if matches { s.exercises[location.e].sets[index].plannedLoad = new }
        }
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
        if let end = s.restEndsAt, end > pausedAt { s.restEndsAt = end.addingTimeInterval(gap) }
        // A pausa não conta na sustentação/cronômetro de cardio (mesma regra do iPhone).
        if let started = s.holdStartedAt { s.holdStartedAt = started.addingTimeInterval(max(0, at.timeIntervalSince(max(pausedAt, started)))) }
        s.status = .active
        s.pausedAt = nil
    }

    /// Status automático depois de mudar as séries (sem mexer em pulado/parcial).
    private static func refreshStatus(_ s: inout SessionSnapshot, exerciseAt index: Int) {
        let exercise = s.exercises[index]
        guard exercise.status == .pending || exercise.status == .inProgress || exercise.status == .completed else { return }
        let done = exercise.sets.filter(\.isCompleted).count
        if !exercise.sets.isEmpty, done == exercise.sets.count {
            s.exercises[index].status = .completed
        } else {
            s.exercises[index].status = done > 0 ? .inProgress : (exercise.status == .completed ? .inProgress : exercise.status)
        }
    }

    /// Ainda há o que fazer (`SessionFlow.ExerciseState.isOpen`).
    private static func isOpen(_ e: SessionSnapshot.Exercise) -> Bool {
        (e.status == .pending || e.status == .inProgress) && (e.sets.isEmpty || e.sets.contains { !$0.isCompleted })
    }

    private static func completedCount(_ e: SessionSnapshot.Exercise) -> Int { e.sets.filter(\.isCompleted).count }

    /// Porta de `SessionFlow.currentExerciseID` (sem escolha explícita): blocos em ordem; em grupo, alterna por rodada.
    static func flowCurrentID(_ exercises: [SessionSnapshot.Exercise]) -> UUID? {
        var visited = Set<UUID>()
        for exercise in exercises {
            guard let group = exercise.groupID else {
                if isOpen(exercise) { return exercise.id }
                continue
            }
            guard visited.insert(group).inserted else { continue }
            let open = exercises.filter { $0.groupID == group && isOpen($0) }
            if let next = open.min(by: { completedCount($0) < completedCount($1) }) { return next.id }
        }
        return nil
    }

    /// Porta de `SessionFlow.isEndOfRound`: exercício solto = sempre; em grupo, quando ninguém aberto está atrás.
    static func isEndOfRound(_ s: SessionSnapshot, after index: Int) -> Bool {
        let exercise = s.exercises[index]
        guard let group = exercise.groupID else { return true }
        let done = completedCount(exercise)
        return s.exercises.enumerated()
            .filter { $0.offset != index && $0.element.groupID == group && isOpen($0.element) }
            .allSatisfy { completedCount($0.element) >= done }
    }

    /// Depois de concluir uma série.
    private static func advance(_ s: inout SessionSnapshot, after exerciseIndex: Int) {
        let exercise = s.exercises[exerciseIndex]
        s.exercises[exerciseIndex].status = exercise.sets.allSatisfy(\.isCompleted) ? .completed : .inProgress
        selectCurrent(&s)
    }

    /// Mantém o atual se for um exercício solto ainda aberto (escolha do usuário vale); senão aplica a regra do fluxo.
    private static func selectCurrent(_ s: inout SessionSnapshot) {
        if let current = s.exercises.first(where: { $0.id == s.currentExerciseID }), current.groupID == nil, isOpen(current) {
            s.currentSetID = current.sets.first { !$0.isCompleted }?.id
            return
        }
        let id = flowCurrentID(s.exercises)
        s.currentExerciseID = id
        s.currentSetID = s.exercises.first { $0.id == id }?.sets.first { !$0.isCompleted }?.id
    }

    private static func reopen(_ s: inout SessionSnapshot, exerciseAt index: Int) {
        if s.exercises[index].status == .completed { s.exercises[index].status = .inProgress }
        s.currentExerciseID = s.exercises[index].id
        s.currentSetID = s.exercises[index].sets.first { !$0.isCompleted }?.id
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
