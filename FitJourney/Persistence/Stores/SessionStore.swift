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
    /// Alguma série válida concluída sem reps realizadas: o volume usa o piso do alvo (SPEC D2).
    var hasEstimatedVolume: Bool = false
    var personalRecords: [PersonalRecord]
    /// Propostas de atualização de carga atual (R-T2) — padrão: todas marcadas.
    var loadProposals: [LoadUpdateProposal]
}

/// Ciclo de vida da sessão de treino. Persiste a cada mudança; relógio só por datas.
///
/// `autosave == false` (usado pelo `SessionEngine`): as mutações não chamam `save()` — quem chama
/// grava a mutação junto com o registro do comando num único `save` (atomicidade) ou faz `rollback()`.
@MainActor
struct SessionStore {
    let context: ModelContext
    var autosave: Bool
    /// Último nível de `RestPolicy` (o motor passa o padrão de Ajustes, lido a cada comando).
    var fallbackRestSeconds = RestPreference.fallbackSeconds

    init(context: ModelContext, autosave: Bool = true) {
        self.context = context
        self.autosave = autosave
    }

    private func save() throws {
        if autosave { try context.save() }
    }

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

    // Predicados e ordenações do SwiftData aqui só usam keypaths de **um nível** (`item.exerciseID`), nunca
    // através de relação (`item.session?.statusRaw`, `\.session?.startedAt`): o SwiftData do iOS 27 resolve
    // keypaths compostos pelo texto de `String(describing: keyPath)`, que num binário sem símbolos (Release/
    // TestFlight) vira `<computed 0x…>` — e o `fetch` dá `fatalError` (crash em loop do build 1.0.0 (2)).
    // O filtro pela relação é feito em memória. `SwiftDataKeyPathGuardTests` impede a volta do padrão.

    /// Última execução concluída de um exercício ("última vez: 3×10 com 32 kg").
    func lastPerformance(exerciseID: UUID, before date: Date = .distantFuture) throws -> SessionExercise? {
        let skipped = SessionExerciseStatus.skipped.rawValue
        let eid: UUID? = exerciseID
        let candidates = try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { item in item.exerciseID == eid && item.statusRaw != skipped }
        ))
        var best: (item: SessionExercise, startedAt: Date)?
        for item in candidates {
            guard let session = item.session, session.status == .completed, session.startedAt < date else { continue }
            if best == nil || session.startedAt > best!.startedAt { best = (item, session.startedAt) }
        }
        return best?.item
    }

    /// Última carga realmente usada num exercício (P2.8): a da série concluída mais recente com carga definida
    /// (peso 0 não conta; peso corporal sim), de qualquer ficha ou treino livre — inclusive da sessão em
    /// andamento. Separado por tipo: série válida só herda de série válida e aquecimento/preparatória só de
    /// aquecimento/preparatória (a carga de aquecimento nunca vira a de trabalho). `nil` = nunca registrada.
    func lastUsedLoad(exerciseID: UUID?, working: Bool = true) throws -> Load? {
        guard let eid = exerciseID else { return nil }
        let id: UUID? = eid
        // Execuções do exercício, das mais novas para as mais antigas, em lotes: para no lote em que aparece a
        // primeira série qualificada (dentro do lote vale a de `completedAt` mais recente).
        var descriptor = FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.exerciseID == id },
                                                          sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = Self.lastUsedLoadBatchSize
        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            let best = batch.lazy
                .flatMap { $0.sets ?? [] }
                .filter { $0.isCompleted && $0.kind.isWorking == working && Load.defined($0.load) != nil }
                .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            if let best { return Load.defined(best.load) }
            guard batch.count == Self.lastUsedLoadBatchSize else { return nil }
            offset += batch.count
        }
    }

    static let lastUsedLoadBatchSize = 15

    /// Carga planejada de uma série (P2.8): a da ficha se definida (peso 0 = vazia), senão `fallback`
    /// (última carga usada no exercício). Nunca inventa zero.
    static func plannedLoad(prescribed: Load?, fallback: Load?) -> Load? {
        Load.defined(prescribed) ?? fallback
    }

    // MARK: Início

    /// Inicia a sessão copiando a prescrição da ficha (snapshot). `routine == nil` = treino livre.
    /// Cada `SetLog` nasce com `plannedLoad` = carga atual (ou inicial) da série prescrita; sem carga na ficha
    /// (nil/peso 0), a última carga usada no exercício (`lastUsedLoad`); senão `nil` ("Definir carga").
    /// IDs de `SessionExercise`/`SetLog` determinísticos (`WatchLinkIDs`, protocolo v2): o relógio calcula os mesmos.
    /// - Parameter id: ID da sessão (o comando `start` do relógio já traz o seu); padrão: novo.
    @discardableResult
    func start(routine: Routine?, at date: Date = .now, id: UUID = UUID()) throws -> WorkoutSession {
        guard try inProgressSession() == nil else { throw SessionStoreError.sessionAlreadyInProgress }
        // Consultas antes de inserir qualquer coisa (o histórico não inclui a sessão nova).
        struct HistoryKey: Hashable { var exerciseID: UUID; var working: Bool }
        var history: [HistoryKey: Load] = [:]
        var looked: Set<HistoryKey> = []
        for item in routine?.sortedExercises ?? [] {
            // Cardio não tem carga: nem consulta.
            guard let exercise = item.exercise, exercise.measurementKind != .timeOrDistance else { continue }
            for set in item.sortedSets where Load.defined(set.effectiveLoad) == nil {
                let key = HistoryKey(exerciseID: exercise.id, working: set.kind.isWorking)
                guard looked.insert(key).inserted else { continue }
                history[key] = try lastUsedLoad(exerciseID: exercise.id, working: key.working)
            }
        }
        let session = WorkoutSession(routineName: routine?.name ?? String(localized: "Treino livre"), startedAt: date)
        session.id = id
        session.lastActivityAt = date
        session.routineID = routine?.id
        session.programID = routine?.program?.id
        context.insert(session)
        session.routine = routine

        for item in routine?.sortedExercises ?? [] {
            let exercise = item.exercise
            let snapshot = SessionExercise(name: item.displayName,
                                           measurementKind: exercise?.measurementKind ?? .repsAndLoad,
                                           sortIndex: item.sortIndex)
            snapshot.id = WatchLinkIDs.sessionExerciseID(sessionID: id, routineExerciseID: item.id)
            snapshot.exerciseID = exercise?.id
            snapshot.routineExerciseID = item.id
            snapshot.laterality = exercise?.laterality ?? .bilateral
            snapshot.groupID = item.groupID
            snapshot.restSeconds = item.restSeconds ?? exercise?.defaultRestSeconds
            snapshot.notes = item.notes
            context.insert(snapshot)
            snapshot.session = session

            for prescription in item.sortedSets {
                let planned = Self.plannedLoad(prescribed: prescription.effectiveLoad,
                                               fallback: exercise.flatMap {
                                                   history[HistoryKey(exerciseID: $0.id, working: prescription.kind.isWorking)]
                                               })
                let log = SetLog(sortIndex: prescription.sortIndex, kind: prescription.kind,
                                 repTarget: prescription.repTarget, plannedLoad: planned,
                                 prescriptionID: prescription.id)
                log.id = WatchLinkIDs.setLogID(sessionID: id, prescriptionID: prescription.id)
                log.targetHoldSeconds = prescription.holdSeconds
                log.restSeconds = prescription.restSeconds ?? snapshot.restSeconds
                log.cardioTarget = prescription.cardio
                context.insert(log)
                log.sessionExercise = snapshot
            }
        }
        try save()
        return session
    }

    // MARK: Durante

    /// Conclui a série com a carga exibida (padrão: carga planejada) e inicia o descanso.
    /// Reps são opcionais (SPEC D2): sem `reps`, a série fica "feita dentro do alvo" (`reps == nil`).
    func completeSet(_ log: SetLog, reps: Int? = nil, load: Load? = nil, durationSeconds: Double? = nil,
                     distanceMeters: Double? = nil, at date: Date = .now, startRest: Bool = true) throws {
        let shown = displayedLoad(log)
        log.reps = reps ?? log.reps
        log.load = load ?? log.load ?? Load.defined(log.plannedLoad)
        propagateLoad(from: log, previous: shown, at: date)
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
                // Em bi-set/circuito, descanso só ao fim da rodada (SessionFlow.isEndOfRound).
                if SessionFlow.isEndOfRound(after: exercise.id, in: session.flowStates) {
                    clock.startRest(seconds: RestPolicy.effective(set: log.restSeconds, routineExercise: exercise.restSeconds,
                                                              exercise: nil, fallback: fallbackRestSeconds), at: date)
                } else {
                    clock.skipRest()
                }
                session.clock = clock
            }
        }
        try save()
    }

    func uncompleteSet(_ log: SetLog, at date: Date = .now) throws {
        log.isCompleted = false
        log.completedAt = nil
        markEditedIfFinished(log, at: date)
        if let exercise = log.sessionExercise { refreshStatus(exercise, at: date) }
        try save()
    }

    /// Edita valores realizados (antes ou depois de concluir). Em sessão encerrada marca "editado".
    func updateSet(_ log: SetLog, reps: Int?, load: Load?, durationSeconds: Double? = nil,
                   distanceMeters: Double? = nil, at date: Date = .now) throws {
        let shown = displayedLoad(log)
        log.reps = reps
        log.load = load
        propagateLoad(from: log, previous: shown, at: date)
        log.durationSeconds = durationSeconds
        log.distanceMeters = distanceMeters
        markEditedIfFinished(log, at: date)
        try save()
    }

    /// Soma `delta` (na unidade da carga) à carga exibida da série: a registrada, senão a planejada, senão a
    /// última carga usada no exercício (P2.8), e só então zero (peso corporal em exercícios sem carga).
    /// Carga absoluta nunca fica negativa. As séries seguintes pendentes acompanham (`propagateLoad`).
    func adjustLoad(_ log: SetLog, by delta: Double, at date: Date = .now) throws {
        let kind = log.sessionExercise?.measurementKind ?? .repsAndLoad
        let shown = displayedLoad(log)
        let base = try shown ?? lastUsedLoad(exerciseID: log.sessionExercise?.exerciseID, working: log.kind.isWorking)
            ?? (kind == .repsOnly ? .bodyweight(delta: 0, unit: .kg) : .kg(0))
        var adjusted = base.adding(delta)
        if case .weight(let value, let unit) = adjusted, value < 0 { adjusted = .weight(value: 0, unit: unit) }
        log.load = adjusted
        propagateLoad(from: log, previous: shown, at: date)
        markEditedIfFinished(log, at: date)
        try save()
    }

    /// Série extra (copia alvo/carga da última; sem carga, a última usada no exercício). Sem `prescriptionID`:
    /// não atualiza a ficha.
    /// - Parameter id: o motor passa `WatchLinkIDs.extraSetID` (determinístico); padrão: novo.
    @discardableResult
    func addSet(to exercise: SessionExercise, kind: SetKind = .working, at date: Date = .now, id: UUID = UUID()) throws -> SetLog {
        let last = exercise.sortedSets.last
        // Carga da última série só se for do mesmo tipo (aquecimento não alimenta válida, e vice-versa).
        let sameKind = last.map { $0.kind.isWorking == kind.isWorking } ?? false
        let carried = sameKind ? (Load.defined(last?.load) ?? Load.defined(last?.plannedLoad)) : nil
        let planned = try carried ?? lastUsedLoad(exerciseID: exercise.exerciseID, working: kind.isWorking)
        let log = SetLog(sortIndex: (last?.sortIndex ?? -1) + 1, kind: kind,
                         repTarget: last?.repTarget, plannedLoad: planned)
        log.id = id
        log.restSeconds = last?.restSeconds ?? exercise.restSeconds
        log.targetHoldSeconds = last?.targetHoldSeconds
        log.cardioTarget = last?.cardioTarget
        context.insert(log)
        log.sessionExercise = exercise
        refreshStatus(exercise, at: date)
        try save()
        return log
    }

    func removeSet(_ log: SetLog, at date: Date = .now) throws {
        let exercise = log.sessionExercise
        context.delete(log)
        if let exercise {
            exercise.sets?.removeAll { $0.persistentModelID == log.persistentModelID }
            refreshStatus(exercise, at: date)
        }
        try save()
    }

    func changeKind(_ log: SetLog, to kind: SetKind, at date: Date = .now) throws {
        log.kind = kind
        markEditedIfFinished(log, at: date)
        try save()
    }

    /// Alvo da sustentação (isométrico) ou duração alvo (cardio), em segundos.
    func updateHoldTarget(_ log: SetLog, seconds: Int, at date: Date = .now) throws {
        if log.sessionExercise?.measurementKind == .timeOrDistance {
            var target = log.cardioTarget ?? CardioTarget()
            target.durationSeconds = seconds
            log.cardioTarget = target
        } else {
            log.targetHoldSeconds = seconds
        }
        markEditedIfFinished(log, at: date)
        try save()
    }

    /// Cardio realizado: nível/velocidade/inclinação (substitui; `nil` limpa).
    func updateCardio(_ log: SetLog, level: Int?, speedKmh: Double?, inclinePercent: Double?, at date: Date = .now) throws {
        log.level = level
        log.speedKmh = speedKmh
        log.inclinePercent = inclinePercent
        markEditedIfFinished(log, at: date)
        try save()
    }

    func setNote(_ exercise: SessionExercise, text: String, at date: Date = .now) throws {
        exercise.notes = text
        exercise.updatedAt = date
        try save()
    }

    /// Dor/desconforto (local + 0–10), sem interpretação.
    func setPain(_ exercise: SessionExercise, location: String?, level: Int?, at date: Date = .now) throws {
        exercise.painLocation = location
        exercise.painLevel = level
        exercise.updatedAt = date
        try save()
    }

    /// Adiciona um exercício não previsto (ou o primeiro do treino livre) com `setCount` séries,
    /// no fim ou logo depois de `after`.
    /// - Parameter commandID: o motor passa o do comando `addExercise` (IDs determinísticos, `WatchLinkIDs`).
    @discardableResult
    func addExercise(_ exercise: Exercise, to session: WorkoutSession, setCount: Int = 3,
                     repTarget: RepTarget = .fixed(reps: 10), after: SessionExercise? = nil,
                     commandID: UUID? = nil) throws -> SessionExercise {
        let planned = exercise.measurementKind == .timeOrDistance ? nil : try lastUsedLoad(exerciseID: exercise.id)
        let snapshot = SessionExercise(name: exercise.name, measurementKind: exercise.measurementKind,
                                       sortIndex: (session.exercises ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0)
        if let commandID { snapshot.id = WatchLinkIDs.addedExerciseID(sessionID: session.id, commandID: commandID) }
        snapshot.exerciseID = exercise.id
        snapshot.laterality = exercise.laterality
        snapshot.restSeconds = exercise.defaultRestSeconds
        context.insert(snapshot)
        snapshot.session = session
        for index in 0..<max(0, setCount) {
            let log = SetLog(sortIndex: index, kind: .working, repTarget: repTarget, plannedLoad: planned)
            if let commandID { log.id = WatchLinkIDs.addedSetID(sessionID: session.id, commandID: commandID, index: index) }
            log.restSeconds = exercise.defaultRestSeconds
            context.insert(log)
            log.sessionExercise = snapshot
        }
        if let after {
            var ordered = session.sortedExercises.filter { $0.id != snapshot.id }
            let position = (ordered.firstIndex { $0.id == after.id }).map { $0 + 1 } ?? ordered.count
            ordered.insert(snapshot, at: position)
            renumber(ordered)
        }
        try save()
        return snapshot
    }

    /// Reordena na hora: move o exercício para a posição `index` (limitada) e renumera.
    func moveExercise(_ exercise: SessionExercise, toIndex index: Int, at date: Date = .now) throws {
        guard let session = exercise.session else { return }
        var ordered = session.sortedExercises.filter { $0.id != exercise.id }
        ordered.insert(exercise, at: min(max(0, index), ordered.count))
        renumber(ordered)
        session.updatedAt = date
        try save()
    }

    private func renumber(_ ordered: [SessionExercise]) {
        for (index, item) in ordered.enumerated() where item.sortIndex != index { item.sortIndex = index }
    }

    /// Troca o exercício na hora; a origem fica registrada e a série perde o vínculo com a ficha. As séries
    /// pendentes passam a planejar a última carga usada no novo exercício (senão ficam sem carga).
    func substitute(_ sessionExercise: SessionExercise, with exercise: Exercise, at date: Date = .now) throws {
        let hasLoad = exercise.measurementKind != .timeOrDistance
        let plannedWorking = hasLoad ? try lastUsedLoad(exerciseID: exercise.id, working: true) : nil
        let plannedWarmup = hasLoad ? try lastUsedLoad(exerciseID: exercise.id, working: false) : nil
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
            if !log.isCompleted {
                log.plannedLoad = log.kind.isWorking ? plannedWorking : plannedWarmup
                log.load = nil
            }
        }
        sessionExercise.updatedAt = date
        try save()
    }

    func skipExercise(_ exercise: SessionExercise, reason: SkipReason? = nil, text: String? = nil,
                      at date: Date = .now) throws {
        exercise.status = .skipped
        exercise.skipReason = reason
        exercise.skipReasonText = text
        exercise.updatedAt = date
        try save()
    }

    /// Retoma um exercício pulado.
    func unskipExercise(_ exercise: SessionExercise) throws {
        exercise.status = .pending
        exercise.skipReason = nil
        exercise.skipReasonText = nil
        refreshStatus(exercise, at: .now)
        try save()
    }

    /// Conclusão manual: com séries pendentes vira "concluído parcialmente".
    func completeExercise(_ exercise: SessionExercise, at date: Date = .now) throws {
        let sets = exercise.sets ?? []
        exercise.status = SessionExerciseRules.manualCompletionStatus(
            completedSets: sets.filter(\.isCompleted).count, totalSets: sets.count)
        exercise.updatedAt = date
        try save()
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
        let performed = allSets.map(\.performed)
        return SessionSummary(
            durationSeconds: session.clock.elapsed(at: date),
            volumeKg: WorkoutMetrics.volumeKg(performed),
            completedSets: allSets.filter(\.isCompleted).count,
            totalSets: allSets.count,
            skippedExercises: exercises.filter { $0.status == .skipped }.map(\.name),
            hasEstimatedVolume: WorkoutMetrics.hasEstimatedVolume(performed),
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
        try save()
    }

    /// Descarta a sessão em andamento: nada fica no histórico (o registro é apagado).
    func discard(_ session: WorkoutSession) throws {
        guard session.status == .inProgress else { throw SessionStoreError.sessionNotInProgress }
        context.delete(session)
        try save()
    }


    // MARK: Internos

    /// Carga mostrada na série: a registrada, senão a planejada definida.
    private func displayedLoad(_ log: SetLog) -> Load? {
        log.load ?? Load.defined(log.plannedLoad)
    }

    /// Propaga a carga nova de uma série às **seguintes pendentes do mesmo exercício** que ainda mostram a carga
    /// planejada que esta série mostrava (`previous`) e não foram editadas (sem `load` registrada), do mesmo
    /// grupo (válida × aquecimento/preparatória). Pirâmides (cargas planejadas diferentes) ficam intactas.
    /// Só com a sessão em andamento (corrigir uma sessão passada não mexe nas outras séries). Idempotente: mesma carga → nada muda.
    private func propagateLoad(from log: SetLog, previous: Load?, at date: Date) {
        guard let new = Load.defined(log.load), let exercise = log.sessionExercise,
              exercise.session?.status == .inProgress else { return }
        if let previous, previous.isEquivalent(to: new) { return }
        let working = log.kind.isWorking
        for other in exercise.sets ?? [] where other.sortIndex > log.sortIndex && !other.isCompleted
            && other.load == nil && other.kind.isWorking == working {
            let planned = Load.defined(other.plannedLoad)
            let matches: Bool = switch (planned, previous) {
            case (nil, nil): true
            case let (planned?, previous?): planned.isEquivalent(to: previous)
            default: false
            }
            guard matches else { continue }
            other.plannedLoad = new
            other.updatedAt = date
        }
    }

    private func mutateClock(_ session: WorkoutSession, _ change: (inout SessionClock) -> Void) throws {
        var clock = session.clock
        change(&clock)
        session.clock = clock
        session.updatedAt = .now
        try save()
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
        let current = session.id
        // Só keypath de um nível no predicado (ver nota em `lastPerformance`); sessão filtrada em memória.
        let items = try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { item in ids.contains(item.exerciseID) }
        ))
        struct Key: Hashable { var exerciseID: UUID; var sessionID: UUID }
        var bySession: [Key: [PerformedSet]] = [:]
        for item in items {
            guard let exerciseID = item.exerciseID, let owner = item.session,
                  owner.status == .completed, owner.id != current else { continue }
            let sessionID = owner.id
            bySession[Key(exerciseID: exerciseID, sessionID: sessionID), default: []].append(contentsOf: item.performedSets)
        }
        var perExercise: [UUID: [[PerformedSet]]] = [:]
        for (key, sets) in bySession { perExercise[key.exerciseID, default: []].append(sets) }
        return perExercise.mapValues { WorkoutMetrics.bests(history: $0) }
    }
}

extension WorkoutSession {
    /// Estado dos exercícios para as regras puras de `SessionFlow`, na ordem da sessão.
    var flowStates: [SessionFlow.ExerciseState] {
        sortedExercises.map { exercise in
            let sets = exercise.sets ?? []
            return SessionFlow.ExerciseState(id: exercise.id, groupID: exercise.groupID, status: exercise.status,
                                             completedSets: sets.filter(\.isCompleted).count, totalSets: sets.count)
        }
    }
}
