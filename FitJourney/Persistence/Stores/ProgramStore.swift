import Foundation
import SwiftData

/// Operações de programas/fichas que mantêm invariantes (ex.: um único programa ativo).
/// Fino de propósito: as telas leem com `@Query` e chamam o store para mutações com regra.
///
/// Dívida aceita: com CloudKit (futuro) dois aparelhos podem ativar programas diferentes offline;
/// será preciso autocura do invariante "um ativo" ao receber mudanças remotas (ex.: o mais recente vence).
@MainActor
struct ProgramStore {
    let context: ModelContext

    init(context: ModelContext) { self.context = context }

    // MARK: Leitura

    func activeProgram() throws -> TrainingProgram? {
        var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.isActive })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Programas fora do ativo (histórico), mais recentes primeiro.
    func pastPrograms() throws -> [TrainingProgram] {
        try context.fetch(FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { !$0.isActive },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))
    }

    /// Sugestão da aba Hoje para o programa (SPEC §3.1).
    func todaySuggestion(for program: TrainingProgram, on date: Date = .now,
                         calendar: Calendar = .current) throws -> ScheduleSuggestion {
        let last = try lastCompletionByRoutine(programID: program.id)
        let infos = program.sortedRoutines.map {
            ScheduleResolver.RoutineInfo(id: $0.id, sortIndex: $0.sortIndex, weekdays: $0.weekdays,
                                         lastCompletedAt: last[$0.id])
        }
        return ScheduleResolver.suggestion(mode: program.scheduleMode, routines: infos,
                                           lastCompletedRoutineID: try lastCompletedSession(programID: program.id)?.routineID,
                                           today: date, calendar: calendar)
    }

    /// Sessão concluída mais recente do programa (âncora do modo sequencial).
    func lastCompletedSession(programID: UUID) throws -> WorkoutSession? {
        let completed = SessionStatus.completed.rawValue
        let pid: UUID? = programID
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.programID == pid && $0.statusRaw == completed },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Data da última sessão concluída de cada ficha do programa.
    func lastCompletionByRoutine(programID: UUID) throws -> [UUID: Date] {
        let completed = SessionStatus.completed.rawValue
        let pid: UUID? = programID
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.programID == pid && $0.statusRaw == completed }
        ))
        var result: [UUID: Date] = [:]
        for session in sessions {
            guard let rid = session.routineID else { continue }
            let date = session.endedAt ?? session.startedAt
            if result[rid].map({ date > $0 }) ?? true { result[rid] = date }
        }
        return result
    }

    // MARK: Mutações

    @discardableResult
    func createProgram(name: String, goal: ProgramGoal = .hypertrophy, scheduleMode: ScheduleMode = .sequential,
                       startDate: Date = .now, origin: ProgramOrigin = .manual, activate: Bool = false) throws -> TrainingProgram {
        let program = TrainingProgram(name: name, goal: goal, scheduleMode: scheduleMode, startDate: startDate, origin: origin)
        context.insert(program)
        if activate { try self.activate(program) } else { try context.save() }
        return program
    }

    /// Ativa o programa e desativa qualquer outro (exatamente um ativo). Desarquiva se preciso.
    func activate(_ program: TrainingProgram) throws {
        let now = Date.now
        for other in try context.fetch(FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.isActive }))
        where other.persistentModelID != program.persistentModelID {
            other.isActive = false
            other.updatedAt = now
        }
        program.isActive = true
        program.isArchived = false
        program.updatedAt = now
        try context.save()
    }

    func deactivate(_ program: TrainingProgram) throws {
        program.isActive = false
        program.updatedAt = .now
        try context.save()
    }

    func archive(_ program: TrainingProgram) throws {
        program.isActive = false
        program.isArchived = true
        program.updatedAt = .now
        try context.save()
    }

    /// Apaga o programa e, em cascata, fichas → exercícios da ficha → séries prescritas.
    /// Sessões ficam no histórico (com `routine = nil`); exercícios do catálogo ficam.
    func delete(_ program: TrainingProgram) throws {
        context.delete(program)
        try context.save()
    }

    @discardableResult
    func addRoutine(to program: TrainingProgram, name: String, symbol: String = "",
                    weekdays: Set<Weekday> = []) throws -> Routine {
        let routine = Routine(name: name, symbol: symbol,
                              sortIndex: (program.routines ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0,
                              weekdays: weekdays)
        context.insert(routine)
        routine.program = program
        program.updatedAt = .now
        try context.save()
        return routine
    }

    /// Adiciona um exercício à ficha com `setCount` séries iguais.
    /// `repTarget` nil = sem alvo de reps (isométrico/cardio); `holdSeconds`/`cardio` valem para todas as séries.
    /// `save: false` permite inserir vários e salvar uma única vez (`context.save()` pelo chamador).
    @discardableResult
    func addExercise(_ exercise: Exercise, to routine: Routine, setCount: Int = 3,
                     repTarget: RepTarget? = .fixed(reps: 10), load: Load? = nil,
                     holdSeconds: Int? = nil, cardio: CardioTarget? = nil,
                     restSeconds: Int? = nil, groupID: UUID? = nil, save: Bool = true) throws -> RoutineExercise {
        let item = RoutineExercise(sortIndex: (routine.exercises ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0,
                                   groupID: groupID, restSeconds: restSeconds)
        context.insert(item)
        item.routine = routine
        item.exercise = exercise
        for index in 0..<max(0, setCount) {
            let set = SetPrescription(sortIndex: index, kind: .working, repTarget: repTarget, initialLoad: load)
            set.holdSeconds = holdSeconds
            set.cardio = cardio
            context.insert(set)
            set.routineExercise = item
        }
        routine.updatedAt = .now
        if save { try context.save() }
        return item
    }

    /// Duplica um programa inteiro (fichas, exercícios, séries) como `origin = .duplicated`, inativo.
    /// A carga atual vira a carga inicial da cópia.
    @discardableResult
    func duplicate(_ program: TrainingProgram, name: String? = nil) throws -> TrainingProgram {
        let copy = TrainingProgram(name: name ?? String(localized: "\(program.name) (cópia)"),
                                   goal: program.goal, scheduleMode: program.scheduleMode,
                                   startDate: .now, origin: .duplicated)
        copy.goalText = program.goalText
        copy.notes = program.notes
        context.insert(copy)
        for routine in program.sortedRoutines {
            let r = Routine(name: routine.name, symbol: routine.symbol, sortIndex: routine.sortIndex, weekdays: routine.weekdays)
            r.colorName = routine.colorName
            r.notes = routine.notes
            context.insert(r)
            r.program = copy
            for item in routine.sortedExercises {
                let i = RoutineExercise(sortIndex: item.sortIndex, groupID: item.groupID,
                                        restSeconds: item.restSeconds, notes: item.notes)
                context.insert(i)
                i.routine = r
                i.exercise = item.exercise
                for set in item.sortedSets {
                    let s = SetPrescription(sortIndex: set.sortIndex, kind: set.kind, repTarget: set.repTarget,
                                            initialLoad: set.effectiveLoad, restSeconds: set.restSeconds)
                    s.holdSeconds = set.holdSeconds
                    s.tempo = set.tempo
                    s.effort = set.effort
                    s.cardio = set.cardio
                    s.notes = set.notes
                    context.insert(s)
                    s.routineExercise = i
                }
            }
        }
        // `groupID` é compartilhado entre exercícios da mesma ficha; a cópia mantém o agrupamento.
        try context.save()
        return copy
    }
}


// MARK: - Edição de ficha (editor de ficha, SPEC §3.2)
//
// Cada operação faz um único `save()` e propaga o erro. Regras de agrupamento: itens do mesmo `groupID`
// ficam vizinhos; um grupo com menos de 2 itens ou quebrado desfaz-se; item solto entre dois membros
// do mesmo grupo entra nele.

extension ProgramStore {
    static func reindex(_ items: [RoutineExercise]) {
        for (i, e) in items.enumerated() where e.sortIndex != i { e.sortIndex = i }
    }

    /// `items` na ordem final. `placed` = itens movidos/inseridos agora: entram no grupo de que ficam
    /// entre dois membros, ou saem do próprio se ficaram longe dele. Depois, grupos não contíguos
    /// ou com menos de 2 itens se desfazem.
    static func normalizeGroups(_ items: [RoutineExercise], placed: [UUID] = []) {
        for id in placed {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            let before = i > 0 ? items[i - 1].groupID : nil
            let after = i + 1 < items.count ? items[i + 1].groupID : nil
            if let before, before == after {
                items[i].groupID = before
            } else if let own = items[i].groupID, before != own, after != own {
                items[i].groupID = nil
            }
        }
        var positions: [UUID: [Int]] = [:]
        for (i, e) in items.enumerated() { if let g = e.groupID { positions[g, default: []].append(i) } }
        for (gid, idx) in positions {
            let contiguous = idx.count >= 2 && idx.last! - idx.first! == idx.count - 1
            if !contiguous { for e in items where e.groupID == gid { e.groupID = nil } }
        }
    }

    private func finish(_ routine: Routine) throws {
        routine.updatedAt = .now
        try context.save()
    }

    func moveExercises(in routine: Routine, from source: IndexSet, to destination: Int) throws {
        var items = routine.sortedExercises
        let movedIDs = source.map { items[$0].id }
        items.move(fromOffsets: source, toOffset: destination)
        Self.reindex(items)
        Self.normalizeGroups(items, placed: movedIDs)
        try finish(routine)
    }

    /// Sobe/desce uma posição (alternativa acessível ao arrastar).
    func moveExercise(_ item: RoutineExercise, by offset: Int) throws {
        guard let routine = item.routine else { return }
        let items = routine.sortedExercises
        guard let i = items.firstIndex(where: { $0.id == item.id }), items.indices.contains(i + offset) else { return }
        try moveExercises(in: routine, from: IndexSet(integer: i), to: offset > 0 ? i + offset + 1 : i + offset)
    }

    func deleteExercise(_ item: RoutineExercise) throws {
        guard let routine = item.routine else {
            context.delete(item)
            try context.save()
            return
        }
        let remaining = routine.sortedExercises.filter { $0.id != item.id }
        context.delete(item)
        Self.reindex(remaining)
        Self.normalizeGroups(remaining)
        try finish(routine)
    }

    /// Cópia da prescrição. Regra única (duplicar e copiar): a carga **atual** vira a **inicial** da cópia
    /// (como em `duplicate(_:name:)`), e a cópia não tem carga atual.
    @discardableResult
    private func cloneExercise(_ item: RoutineExercise, into routine: Routine, sortIndex: Int,
                               groupID: UUID?) -> RoutineExercise {
        let copy = RoutineExercise(sortIndex: sortIndex, groupID: groupID, restSeconds: item.restSeconds, notes: item.notes)
        context.insert(copy)
        copy.routine = routine
        copy.exercise = item.exercise
        for set in item.sortedSets {
            let s = SetPrescription(sortIndex: set.sortIndex, kind: set.kind, repTarget: set.repTarget,
                                    initialLoad: set.effectiveLoad, restSeconds: set.restSeconds)
            s.holdSeconds = set.holdSeconds
            s.tempo = set.tempo
            s.effort = set.effort
            s.cardio = set.cardio
            s.notes = set.notes
            context.insert(s)
            s.routineExercise = copy
        }
        return copy
    }

    /// Duplica logo abaixo do original; a cópia herda o grupo (o grupo cresce).
    @discardableResult
    func duplicateExercise(_ item: RoutineExercise) throws -> RoutineExercise? {
        guard let routine = item.routine else { return nil }
        let items = routine.sortedExercises
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        for later in items[(i + 1)...] { later.sortIndex += 1 }
        let copy = cloneExercise(item, into: routine, sortIndex: i + 1, groupID: item.groupID)
        var ordered = items
        ordered.insert(copy, at: i + 1)
        Self.normalizeGroups(ordered)
        try finish(routine)
        return copy
    }

    /// Move ou copia para o fim de outra ficha (fora de grupo).
    func transferExercise(_ item: RoutineExercise, to target: Routine, copy: Bool) throws {
        let end = (target.exercises ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0
        if copy {
            cloneExercise(item, into: target, sortIndex: end, groupID: nil)
        } else {
            let source = item.routine
            let remaining = source?.sortedExercises.filter { $0.id != item.id } ?? []
            item.groupID = nil
            item.routine = target
            item.sortIndex = end
            Self.reindex(remaining)
            Self.normalizeGroups(remaining)
            source?.updatedAt = .now
        }
        try finish(target)
    }

    /// Agrupa itens vizinhos selecionados (2+); não faz nada se não forem contíguos.
    func groupExercises(_ ids: Set<UUID>, in routine: Routine) throws {
        let items = routine.sortedExercises
        let idx = items.enumerated().filter { ids.contains($0.element.id) }.map(\.offset)
        guard idx.count >= 2, let first = idx.first, let last = idx.last, last - first == idx.count - 1 else { return }
        let gid = UUID()
        for i in idx { items[i].groupID = gid }
        Self.normalizeGroups(items)
        try finish(routine)
    }

    func ungroup(_ groupID: UUID, in routine: Routine) throws {
        for e in routine.sortedExercises where e.groupID == groupID { e.groupID = nil }
        try finish(routine)
    }

    /// Descanso ao fim da rodada: grava no **último** membro do grupo (`restSeconds` do exercício) e
    /// limpa o descanso por série dele, que sobrescreveria o valor.
    func setGroupRest(_ seconds: Int, groupID: UUID, in routine: Routine) throws {
        guard let last = routine.sortedExercises.last(where: { $0.groupID == groupID }) else { return }
        last.restSeconds = max(0, seconds)
        for s in last.sets ?? [] { s.restSeconds = nil }
        last.updatedAt = .now
        try finish(routine)
    }
}
