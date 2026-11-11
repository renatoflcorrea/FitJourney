import Foundation
import SwiftData

/// Shim fino do exemplo ABC (SPEC §11 D4). A fábrica real (`SampleProgramFactory.makeStarterABC`)
/// vive no branch do P2.1; na integração o supervisor troca o corpo de `make`/`shouldOffer` para chamá-la.
enum StarterProgram {
    /// Só oferece o exemplo quando não há nenhum programa (nem arquivado).
    @MainActor
    static func shouldOffer(in context: ModelContext) -> Bool {
        // TODO(integração): delegar a SampleProgramFactory.shouldOfferStarter(in:)
        ((try? context.fetchCount(FetchDescriptor<TrainingProgram>())) ?? 0) == 0
    }

    /// Cria e ativa o programa de exemplo.
    @MainActor
    @discardableResult
    static func make(in context: ModelContext) throws -> TrainingProgram {
        // TODO(integração): delegar a SampleProgramFactory.makeStarterABC(in: context, activate: true, now: .now)
        try ExerciseCatalogSeeder.seedIfNeeded(in: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let byKey = Dictionary(exercises.compactMap { e in e.catalogKey.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })

        let store = ProgramStore(context: context)
        let program = try store.createProgram(name: String(localized: "ABC (exemplo)"), goal: .hypertrophy,
                                              scheduleMode: .sequential, activate: true)
        let plan: [(String, String, RoutineColor, [String])] = [
            (String(localized: "A — Peito e tríceps"), "A", .orange, ["bench-press", "triceps-pushdown"]),
            (String(localized: "B — Costas e bíceps"), "B", .blue, ["lat-pulldown", "barbell-curl"]),
            (String(localized: "C — Pernas e ombros"), "C", .green, ["back-squat", "lateral-raise"]),
        ]
        for (name, symbol, color, keys) in plan {
            let routine = try store.addRoutine(to: program, name: name, symbol: symbol)
            routine.colorName = color.rawValue
            for key in keys {
                guard let exercise = byKey[key] else { continue }
                try store.addExercise(exercise, to: routine, setCount: 3, repTarget: .range(min: 8, max: 12))
            }
        }
        try context.save()
        return program
    }
}
