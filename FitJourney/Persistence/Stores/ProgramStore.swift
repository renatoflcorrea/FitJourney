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
    @discardableResult
    func addExercise(_ exercise: Exercise, to routine: Routine, setCount: Int = 3,
                     repTarget: RepTarget = .fixed(reps: 10), load: Load? = nil,
                     restSeconds: Int? = nil, groupID: UUID? = nil) throws -> RoutineExercise {
        let item = RoutineExercise(sortIndex: (routine.exercises ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0,
                                   groupID: groupID, restSeconds: restSeconds)
        context.insert(item)
        item.routine = routine
        item.exercise = exercise
        for index in 0..<max(0, setCount) {
            let set = SetPrescription(sortIndex: index, kind: .working, repTarget: repTarget, initialLoad: load)
            context.insert(set)
            set.routineExercise = item
        }
        routine.updatedAt = .now
        try context.save()
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
