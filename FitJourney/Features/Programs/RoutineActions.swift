import Foundation
import SwiftData

/// Mutações de fichas feitas pela tela Treinos (duplicar, excluir, reordenar).
@MainActor
struct RoutineActions {
    let context: ModelContext

    /// Duplica a ficha (exercícios e séries) logo após a original; a carga atual vira a inicial da cópia.
    @discardableResult
    func duplicate(_ routine: Routine) throws -> Routine {
        do {
            return try duplicateUnchecked(routine)
        } catch {
            context.rollback() // sem cópia parcial
            throw error
        }
    }

    private func duplicateUnchecked(_ routine: Routine) throws -> Routine {
        guard let program = routine.program else { return routine }
        let ordered = program.sortedRoutines
        let insertAt = (ordered.firstIndex { $0 === routine } ?? ordered.count - 1) + 1
        // Cópia sem dias: evita dois treinos no mesmo dia. Mesma cópia profunda de "Copiar para outro programa".
        let copy = ProgramStore(context: context).cloneRoutine(
            routine, into: program, name: String(localized: "\(routine.name) (cópia)"),
            sortIndex: insertAt, weekdays: [])
        try renumber(program.sortedRoutines.filter { $0 !== copy }, inserting: copy, at: insertAt)
        return copy
    }

    func delete(_ routine: Routine) throws {
        let program = routine.program
        context.delete(routine)
        try context.save()
        if let program { try renumber(program.sortedRoutines) }
    }

    func move(in program: TrainingProgram, from source: IndexSet, to destination: Int) throws {
        var ordered = program.sortedRoutines
        ordered.move(fromOffsets: source, toOffset: destination)
        try renumber(ordered)
    }

    private func renumber(_ routines: [Routine], inserting extra: Routine? = nil, at index: Int? = nil) throws {
        var list = routines
        if let extra, let index { list.insert(extra, at: min(index, list.count)) }
        for (i, routine) in list.enumerated() where routine.sortIndex != i {
            routine.sortIndex = i
            routine.updatedAt = .now
        }
        try context.save()
    }
}
