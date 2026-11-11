import Foundation
import SwiftData

/// Programa de exemplo oferecido no primeiro uso (D4). Diferente do `SampleData` (previews):
/// cria só o programa — sem sessões, dieta ou cargas inventadas. Cargas ficam vazias para o
/// usuário preencher na primeira sessão (a carga usada vira proposta de carga atual, R-T2).
@MainActor
enum SampleProgramFactory {
    /// Nenhum programa ainda: a UI pode oferecer o exemplo.
    static func shouldOfferStarter(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<TrainingProgram>()) == 0
    }

    /// Cria o ABC sequencial de hipertrofia com exercícios do catálogo, faixas 8–12 e descansos.
    /// - Parameter activate: ativa o programa (padrão: só se não houver outro ativo).
    @discardableResult
    static func makeStarterABC(in context: ModelContext, activate: Bool? = nil, now: Date = .now) throws -> TrainingProgram {
        try ExerciseCatalogSeeder.seedIfNeeded(in: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.catalogKey != nil }))
        let byKey = Dictionary(exercises.compactMap { e in e.catalogKey.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })

        let programs = ProgramStore(context: context)
        let shouldActivate = try activate ?? (programs.activeProgram() == nil)
        let program = try programs.createProgram(name: String(localized: "ABC — Exemplo"), goal: .hypertrophy,
                                                 scheduleMode: .sequential, startDate: now, activate: shouldActivate)
        program.goalText = String(localized: "Hipertrofia, 3 a 5 treinos por semana em rodízio A → B → C.")
        program.notes = String(localized: "Programa de exemplo: ajuste exercícios, séries e cargas à vontade.")

        struct Item {
            var key: String
            var sets: Int
            var reps: RepTarget
            var rest: Int
            var hold: Int? = nil
            var superset: Int? = nil
        }
        let plan: [(name: String, symbol: String, items: [Item])] = [
            (String(localized: "A — Peito, ombros e tríceps"), "A", [
                Item(key: "bench-press", sets: 4, reps: .range(min: 8, max: 12), rest: 120),
                Item(key: "incline-dumbbell-press", sets: 3, reps: .range(min: 8, max: 12), rest: 90),
                Item(key: "dumbbell-shoulder-press", sets: 3, reps: .range(min: 8, max: 12), rest: 90),
                Item(key: "lateral-raise", sets: 3, reps: .range(min: 12, max: 15), rest: 60),
                Item(key: "triceps-pushdown", sets: 3, reps: .range(min: 10, max: 12), rest: 60),
            ]),
            (String(localized: "B — Costas e bíceps"), "B", [
                Item(key: "lat-pulldown", sets: 4, reps: .range(min: 8, max: 12), rest: 90),
                Item(key: "seated-cable-row", sets: 3, reps: .range(min: 8, max: 12), rest: 90),
                Item(key: "dumbbell-row", sets: 3, reps: .range(min: 8, max: 12), rest: 90),
                Item(key: "face-pull", sets: 3, reps: .range(min: 12, max: 15), rest: 60),
                // Bi-set de braços: descanso só ao fim da rodada.
                Item(key: "barbell-curl", sets: 3, reps: .range(min: 8, max: 12), rest: 60, superset: 1),
                Item(key: "hammer-curl", sets: 3, reps: .range(min: 10, max: 12), rest: 60, superset: 1),
            ]),
            (String(localized: "C — Pernas e core"), "C", [
                Item(key: "back-squat", sets: 4, reps: .range(min: 8, max: 12), rest: 150),
                Item(key: "leg-press", sets: 3, reps: .range(min: 10, max: 12), rest: 120),
                Item(key: "romanian-deadlift", sets: 3, reps: .range(min: 8, max: 12), rest: 120),
                Item(key: "seated-leg-curl", sets: 3, reps: .range(min: 10, max: 12), rest: 60),
                Item(key: "standing-calf-raise", sets: 3, reps: .range(min: 12, max: 15), rest: 60),
                Item(key: "plank", sets: 3, reps: .fixed(reps: 1), rest: 60, hold: 45),
            ]),
        ]

        for entry in plan {
            let routine = try programs.addRoutine(to: program, name: entry.name, symbol: entry.symbol)
            var groups: [Int: UUID] = [:]
            for item in entry.items {
                guard let exercise = byKey[item.key] else { continue }
                let groupID = item.superset.map { key in groups[key] ?? { let id = UUID(); groups[key] = id; return id }() }
                let routineExercise = try programs.addExercise(exercise, to: routine, setCount: item.sets,
                                                               repTarget: item.reps, load: nil,
                                                               restSeconds: item.rest, groupID: groupID)
                if let hold = item.hold {
                    for set in routineExercise.sets ?? [] { set.holdSeconds = hold }
                }
            }
        }
        try context.save()
        return program
    }
}
