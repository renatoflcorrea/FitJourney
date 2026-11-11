import Foundation
import SwiftData

/// Dados de exemplo para previews (e testes): programa ABC sequencial ativo, uma sessão
/// concluída ontem com logs, dieta ativa com 5 refeições e registros de hoje.
@MainActor
enum SampleData {
    static func insert(into context: ModelContext, now: Date = .now, calendar: Calendar = .current) throws {
        try ExerciseCatalogSeeder.seedIfNeeded(in: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let byKey = Dictionary(exercises.compactMap { e in e.catalogKey.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })

        let programs = ProgramStore(context: context)
        let program = try programs.createProgram(
            name: "ABC Hipertrofia", goal: .hypertrophy, scheduleMode: .sequential,
            startDate: calendar.date(byAdding: .day, value: -21, to: now) ?? now, activate: true)
        program.goalText = "Ganhar massa com 4–5 treinos por semana"
        program.endDate = calendar.date(byAdding: .weekOfYear, value: 8, to: program.startDate)

        typealias Item = (key: String, sets: Int, reps: RepTarget, load: Load?, rest: Int?)
        let plan: [(name: String, symbol: String, items: [Item])] = [
            ("A — Peito e tríceps", "A", [
                ("bench-press", 4, .range(min: 8, max: 12), .kg(30), 120),
                ("incline-dumbbell-press", 3, .range(min: 10, max: 12), .kg(14), nil),
                ("pec-deck", 3, .fixed(reps: 12), .kg(40), 60),
                ("triceps-pushdown", 3, .range(min: 10, max: 15), .kg(25), 60),
            ]),
            ("B — Costas e bíceps", "B", [
                ("lat-pulldown", 4, .range(min: 8, max: 12), .kg(45), nil),
                ("seated-cable-row", 3, .range(min: 10, max: 12), .kg(40), nil),
                ("pull-up", 3, .amrap, .bodyweight(delta: 0, unit: .kg), 120),
                ("barbell-curl", 3, .range(min: 8, max: 12), .kg(20), 60),
            ]),
            ("C — Pernas e ombros", "C", [
                ("back-squat", 4, .range(min: 6, max: 10), .kg(50), 180),
                ("leg-press", 3, .range(min: 10, max: 12), .kg(120), nil),
                ("lateral-raise", 3, .range(min: 12, max: 15), .kg(8), 60),
                ("plank", 3, .fixed(reps: 1), nil, 60),
            ]),
        ]

        var routines: [Routine] = []
        for entry in plan {
            let routine = try programs.addRoutine(to: program, name: entry.name, symbol: entry.symbol)
            for item in entry.items {
                guard let exercise = byKey[item.key] else { continue }
                let re = try programs.addExercise(exercise, to: routine, setCount: item.sets, repTarget: item.reps,
                                                  load: item.load, restSeconds: item.rest)
                if exercise.measurementKind == .isometric {
                    for set in re.sets ?? [] { set.holdSeconds = 45 }
                }
            }
            routines.append(routine)
        }
        // Aquecimento no supino.
        if let bench = routines.first?.sortedExercises.first {
            for set in bench.sets ?? [] { set.sortIndex += 1 }
            let warmup = SetPrescription(sortIndex: 0, kind: .warmup, repTarget: .fixed(reps: 15), initialLoad: .kg(20), restSeconds: 60)
            context.insert(warmup)
            warmup.routineExercise = bench
        }

        // Sessão concluída ontem (ficha A) com carga maior no supino.
        let sessions = SessionStore(context: context)
        let start = calendar.date(byAdding: .day, value: -1, to: now)!.addingTimeInterval(-3_600)
        let session = try sessions.start(routine: routines[0], at: start)
        var t = start
        for exercise in session.sortedExercises {
            for log in exercise.sortedSets {
                t = t.addingTimeInterval(150)
                let load = exercise.name == byKey["bench-press"]?.name && log.kind.isWorking ? Load.kg(32) : nil
                try sessions.completeSet(log, load: load, at: t, startRest: false)
            }
        }
        try sessions.finish(session, at: t.addingTimeInterval(120), sessionRPE: 8, mood: 4,
                            notes: "Supino rendeu bem.", applying: try sessions.loadProposals(for: session))

        // Dieta com 5 refeições.
        let nutrition = NutritionStore(context: context, calendar: calendar)
        let diet = NutritionPlan(name: "Dieta de ganho", goal: "Superávit leve", startDate: program.startDate, author: .nutritionist)
        diet.targets = NutritionTargets(kcal: 2_600, protein: 160, carbs: 300, fat: 80, fiber: 30, waterMilliliters: 3_000)
        context.insert(diet)
        let day = NutritionDay(name: "Todos os dias")
        context.insert(day)
        day.plan = diet

        typealias Food = (String, Double, FoodUnit, NutrientValues)
        let meals: [(String, Int, [Food])] = [
            ("Café da manhã", 7 * 60, [
                ("Pão integral", 2, .slice, NutrientValues(kcal: 140, protein: 6, carbs: 24, fat: 2, fiber: 4)),
                ("Ovos mexidos", 3, .unit, NutrientValues(kcal: 210, protein: 18, carbs: 1, fat: 15)),
                ("Café com leite", 200, .milliliters, NutrientValues(kcal: 90, protein: 6, carbs: 9, fat: 3)),
            ]),
            ("Lanche da manhã", 10 * 60, [
                ("Banana", 1, .unit, NutrientValues(kcal: 90, protein: 1, carbs: 23, fat: 0, fiber: 2.6)),
                ("Iogurte natural", 170, .grams, NutrientValues(kcal: 100, protein: 6, carbs: 8, fat: 5)),
            ]),
            ("Almoço", 12 * 60 + 30, [
                ("Arroz", 150, .grams, NutrientValues(kcal: 195, protein: 4, carbs: 42, fat: 0.4)),
                ("Feijão", 100, .grams, NutrientValues(kcal: 76, protein: 5, carbs: 14, fat: 0.5, fiber: 8.5)),
                ("Frango grelhado", 150, .grams, NutrientValues(kcal: 240, protein: 45, carbs: 0, fat: 5)),
                ("Salada", 1, .serving, NutrientValues(kcal: 30, protein: 1, carbs: 5, fat: 0, fiber: 3)),
            ]),
            ("Pré-treino", 16 * 60, [
                ("Batata-doce", 200, .grams, NutrientValues(kcal: 170, protein: 3, carbs: 40, fat: 0, fiber: 5)),
                ("Whey protein", 30, .grams, NutrientValues(kcal: 120, protein: 24, carbs: 3, fat: 1.5)),
            ]),
            ("Jantar", 20 * 60, [
                ("Macarrão integral", 120, .grams, NutrientValues(kcal: 420, protein: 16, carbs: 80, fat: 3, fiber: 9)),
                ("Carne moída", 120, .grams, NutrientValues(kcal: 250, protein: 30, carbs: 0, fat: 14)),
            ]),
        ]
        var created: [Meal] = []
        for (index, meal) in meals.enumerated() {
            let m = Meal(name: meal.0, minutesFromMidnight: meal.1, sortIndex: index, reminderEnabled: index == 2)
            context.insert(m)
            m.day = day
            for (itemIndex, food) in meal.2.enumerated() {
                let item = MealItem(name: food.0, quantity: food.1, unit: food.2, values: food.3, sortIndex: itemIndex)
                context.insert(item)
                item.meal = m
            }
            created.append(m)
        }
        if let rice = created[2].sortedItems.first {
            rice.substitutions = [MealSubstitution(name: "Macarrão", quantity: 120, unit: .grams,
                                                   values: NutrientValues(kcal: 190, protein: 7, carbs: 38, fat: 1))]
        }
        try nutrition.activate(diet)

        // Hoje: café feito, lanche ajustado, um item fora da dieta e água.
        try nutrition.markMealDone(created[0], on: now)
        try nutrition.logAdjustedMeal(created[1], on: now, items: [
            ("Maçã", 1, .unit, NutrientValues(kcal: 80, protein: 0.4, carbs: 21, fat: 0.2, fiber: 3.6)),
        ])
        try nutrition.logFood(name: "Chocolate", quantity: 25, unit: .grams,
                              values: NutrientValues(kcal: 135, protein: 2, carbs: 14, fat: 8),
                              estimation: .estimated, at: calendar.startOfDay(for: now).addingTimeInterval(11 * 3_600))
        try nutrition.logFood(name: "Café expresso", quantity: 1, unit: .unit,
                              at: calendar.startOfDay(for: now).addingTimeInterval(9 * 3_600))
        try nutrition.addWater(milliliters: 500, at: now)
        try nutrition.addWater(milliliters: 300, at: now)
        try context.save()
    }
}
