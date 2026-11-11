import Foundation
import SwiftData

/// Casa nomes de exercício do rascunho com o catálogo local.
enum ExerciseMatcher {
    /// Minúsculas, sem acento, espaços colapsados.
    static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .joined(separator: " ")
    }

    /// `catalogKey` exato → nome pt-BR normalizado → nome en do catálogo embutido. `nil` = exercício novo.
    static func match(name: String, catalogKey: String?, in exercises: [Exercise]) -> Exercise? {
        if let key = catalogKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
           let hit = exercises.first(where: { $0.catalogKey == key }) {
            return hit
        }
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        if let hit = exercises.first(where: { normalize($0.name) == target }) { return hit }
        if let entry = ExerciseCatalog.all.first(where: { normalize($0.nameEN) == target }) {
            return exercises.first { $0.catalogKey == entry.key }
        }
        return nil
    }
}

/// Converte rascunhos validados em modelos SwiftData. Usado pela UI **depois** de "Revisar e salvar":
/// o resultado é novo, `origin = .ai`/`author = .ai` e **inativo** até o usuário ativar.
@MainActor
struct DraftApplier {
    let context: ModelContext
    var calendar: Calendar = .current

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    /// Prévia do casamento com o catálogo, para o cartão/editor: `nil` = será criado como exercício novo.
    func exerciseMatches(for draft: ProgramDraft) throws -> [[Exercise?]] {
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        return draft.routines.map { routine in
            routine.exercises.map { ExerciseMatcher.match(name: $0.name, catalogKey: $0.catalogKey, in: catalog) }
        }
    }

    @discardableResult
    func makeProgram(from draft: ProgramDraft, startDate: Date = .now) throws -> TrainingProgram {
        var catalog = try context.fetch(FetchDescriptor<Exercise>())
        let program = TrainingProgram(name: draft.name.trimmed(max: 80), goal: draft.goal,
                                      scheduleMode: draft.scheduleMode, startDate: startDate, origin: .ai)
        program.goalText = draft.goalText ?? ""
        program.notes = draft.notes ?? ""
        program.isActive = false
        if let weeks = draft.durationWeeks, weeks > 0 {
            program.endDate = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: calendar.startOfDay(for: startDate))
        }
        context.insert(program)

        let letters = Array("ABCDEFG")
        for (r, routineDraft) in draft.routines.enumerated() {
            let symbol = routineDraft.symbol?.trimmed(max: 2) ?? (r < letters.count ? String(letters[r]) : "")
            let routine = Routine(name: routineDraft.name.trimmed(max: 80), symbol: symbol, sortIndex: r,
                                  weekdays: Set(routineDraft.weekdays))
            routine.notes = routineDraft.notes ?? ""
            context.insert(routine)
            routine.program = program

            var groups: [String: UUID] = [:]
            for (e, exerciseDraft) in routineDraft.exercises.enumerated() {
                let exercise: Exercise
                if let hit = ExerciseMatcher.match(name: exerciseDraft.name, catalogKey: exerciseDraft.catalogKey, in: catalog) {
                    exercise = hit
                } else {
                    exercise = Exercise(name: exerciseDraft.name.trimmed(max: 80),
                                        measurementKind: Self.measurementKind(for: exerciseDraft),
                                        defaultRestSeconds: exerciseDraft.restSeconds ?? 90)
                    context.insert(exercise)
                    catalog.append(exercise)
                }
                let groupID = exerciseDraft.groupLabel.flatMap { label -> UUID? in
                    let key = ExerciseMatcher.normalize(label)
                    guard !key.isEmpty else { return nil }
                    if let id = groups[key] { return id }
                    let id = UUID()
                    groups[key] = id
                    return id
                }
                let item = RoutineExercise(sortIndex: e, groupID: groupID, restSeconds: exerciseDraft.restSeconds,
                                           notes: exerciseDraft.notes ?? "")
                context.insert(item)
                item.routine = routine
                item.exercise = exercise

                for (s, setDraft) in exerciseDraft.sets.enumerated() {
                    let set = SetPrescription(sortIndex: s, kind: setDraft.kind, repTarget: setDraft.repTarget?.repTarget,
                                              initialLoad: setDraft.load?.load, restSeconds: setDraft.restSeconds)
                    set.holdSeconds = setDraft.holdSeconds
                    set.tempo = setDraft.tempo
                    set.effort = setDraft.effort
                    set.cardio = setDraft.cardio?.target
                    set.notes = setDraft.notes ?? ""
                    context.insert(set)
                    set.routineExercise = item
                }
            }
        }
        try context.save()
        return program
    }

    @discardableResult
    func makeNutritionPlan(from draft: NutritionPlanDraft, startDate: Date = .now) throws -> NutritionPlan {
        let plan = NutritionPlan(name: draft.name.trimmed(max: 80), goal: draft.goal ?? "", startDate: startDate, author: .ai)
        plan.notes = draft.notes ?? ""
        plan.targets = draft.targets.targets
        plan.isActive = false
        context.insert(plan)

        for (d, dayDraft) in draft.days.enumerated() {
            let day = NutritionDay(name: dayDraft.name.trimmed(max: 80), weekdays: Set(dayDraft.weekdays), sortIndex: d)
            context.insert(day)
            day.plan = plan
            for (m, mealDraft) in dayDraft.meals.enumerated() {
                let meal = Meal(name: mealDraft.name.trimmed(max: 80), minutesFromMidnight: mealDraft.minutesFromMidnight ?? 0,
                                sortIndex: m)
                meal.notes = mealDraft.notes ?? ""
                context.insert(meal)
                meal.day = day
                for (i, itemDraft) in mealDraft.items.enumerated() {
                    let item = MealItem(name: itemDraft.name.trimmed(max: 120), quantity: max(0, itemDraft.quantity),
                                        unit: itemDraft.unit, values: itemDraft.values, sortIndex: i)
                    item.notes = itemDraft.notes ?? ""
                    item.substitutions = itemDraft.substitutions.map(\.substitution)
                    context.insert(item)
                    item.meal = meal
                }
            }
        }
        try context.save()
        return plan
    }

    /// Tipo de medida de um exercício novo, inferido das séries do rascunho.
    static func measurementKind(for draft: ProgramDraft.ExerciseDraft) -> MeasurementKind {
        let sets = draft.sets
        if !sets.isEmpty, sets.allSatisfy({ $0.cardio != nil }) { return .timeOrDistance }
        if sets.contains(where: { $0.holdSeconds != nil }) { return .isometric }
        if !sets.isEmpty, sets.allSatisfy({ $0.load == nil || $0.load?.kind == .bodyweight }),
           sets.contains(where: { $0.load?.kind == .bodyweight }) {
            return .repsOnly
        }
        return .repsAndLoad
    }
}

private extension String {
    func trimmed(max: Int) -> String {
        String(trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
}
