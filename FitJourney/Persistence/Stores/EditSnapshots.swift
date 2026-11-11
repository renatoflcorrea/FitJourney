import CryptoKit
import Foundation
import SwiftData

// Fotografias em valor de uma ficha e de um plano alimentar, usadas pelo copiloto de edição (SPEC §7A.2):
// as operações propostas rodam sobre a fotografia (diff antes → depois sem tocar no banco), `write` grava o
// resultado no lugar (preservando ids) e o desfazer regrava a fotografia anterior. A impressão digital
// (`fingerprint`) detecta mudança de estado entre a proposta e o "Aplicar".

struct RoutineSnapshot: Codable, Sendable, Hashable {
    struct Item: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var exerciseID: UUID?
        var exerciseName: String
        var groupID: UUID?
        var restSeconds: Int?
        var notes: String
        var sets: [SetValue]
    }

    struct SetValue: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var kind: SetKind
        var repTarget: RepTarget?
        var holdSeconds: Int?
        var initialLoad: Load?
        var currentLoad: Load?
        var restSeconds: Int?
        var tempo: String?
        var effort: EffortTarget?
        var cardio: CardioTarget?
        var notes: String

        var effectiveLoad: Load? { currentLoad ?? initialLoad }
    }

    var routineID: UUID
    var programID: UUID?
    var routineName: String
    var exercises: [Item]

    var fingerprint: String { EditFingerprint.of(self) }
}

struct NutritionPlanSnapshot: Codable, Sendable, Hashable {
    struct Day: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var weekdays: [Weekday]
        var meals: [MealValue]
    }

    struct MealValue: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var minutesFromMidnight: Int
        var reminderEnabled: Bool
        var notes: String
        var items: [ItemValue]
    }

    struct ItemValue: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var quantity: Double
        var unit: FoodUnit
        var values: NutrientValues
        var notes: String
        var substitutions: [MealSubstitution]
    }

    var planID: UUID
    var planName: String
    var targets: NutritionTargets
    var days: [Day]

    var fingerprint: String { EditFingerprint.of(self) }
}

enum EditFingerprint {
    /// SHA-256 do JSON com chaves ordenadas.
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Ficha

extension ProgramStore {
    func snapshot(of routine: Routine) -> RoutineSnapshot {
        RoutineSnapshot(
            routineID: routine.id, programID: routine.program?.id, routineName: routine.name,
            exercises: routine.sortedExercises.map { item in
                RoutineSnapshot.Item(
                    id: item.id, exerciseID: item.exercise?.id, exerciseName: item.displayName, groupID: item.groupID,
                    restSeconds: item.restSeconds, notes: item.notes,
                    sets: item.sortedSets.map { set in
                        RoutineSnapshot.SetValue(id: set.id, kind: set.kind, repTarget: set.repTarget, holdSeconds: set.holdSeconds,
                                                 initialLoad: set.initialLoad, currentLoad: set.currentLoad,
                                                 restSeconds: set.restSeconds, tempo: set.tempo, effort: set.effort,
                                                 cardio: set.cardio, notes: set.notes)
                    })
            })
    }

    func routine(id: UUID) throws -> Routine? {
        var descriptor = FetchDescriptor<Routine>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Grava a fotografia na ficha, no lugar: itens e séries casados por id são atualizados, os que faltam são
    /// criados com o id da fotografia e os que sobram são apagados. Um único `save()`.
    func write(_ snapshot: RoutineSnapshot, into routine: Routine, now: Date = .now) throws {
        let exerciseIDs = Set(snapshot.exercises.compactMap(\.exerciseID))
        let catalog = try context.fetch(FetchDescriptor<Exercise>()).filter { exerciseIDs.contains($0.id) }
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var existing = Dictionary((routine.exercises ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, value) in snapshot.exercises.enumerated() {
            let item: RoutineExercise
            if let found = existing.removeValue(forKey: value.id) {
                item = found
            } else {
                item = RoutineExercise()
                item.id = value.id
                context.insert(item)
                item.routine = routine
            }
            item.sortIndex = index
            item.groupID = value.groupID
            item.restSeconds = value.restSeconds
            item.notes = value.notes
            if let exerciseID = value.exerciseID, item.exercise?.id != exerciseID { item.exercise = byID[exerciseID] }
            var sets = Dictionary((item.sets ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (s, setValue) in value.sets.enumerated() {
                let set: SetPrescription
                if let found = sets.removeValue(forKey: setValue.id) {
                    set = found
                } else {
                    set = SetPrescription()
                    set.id = setValue.id
                    context.insert(set)
                    set.routineExercise = item
                }
                set.sortIndex = s
                set.kind = setValue.kind
                set.repTarget = setValue.repTarget
                set.holdSeconds = setValue.holdSeconds
                set.initialLoad = setValue.initialLoad
                set.currentLoad = setValue.currentLoad
                set.restSeconds = setValue.restSeconds
                set.tempo = setValue.tempo
                set.effort = setValue.effort
                set.cardio = setValue.cardio
                set.notes = setValue.notes
                set.updatedAt = now
            }
            for leftover in sets.values { context.delete(leftover) }
            item.updatedAt = now
        }
        for leftover in existing.values { context.delete(leftover) }
        routine.updatedAt = now
        routine.program?.updatedAt = now
        try context.save()
    }
}

// MARK: - Plano alimentar

extension NutritionStore {
    func snapshot(of plan: NutritionPlan) -> NutritionPlanSnapshot {
        NutritionPlanSnapshot(
            planID: plan.id, planName: plan.name, targets: plan.targets,
            days: plan.sortedDays.map { day in
                NutritionPlanSnapshot.Day(
                    id: day.id, name: day.name, weekdays: day.weekdays.sorted(),
                    meals: day.sortedMeals.map { meal in
                        NutritionPlanSnapshot.MealValue(
                            id: meal.id, name: meal.name, minutesFromMidnight: meal.minutesFromMidnight,
                            reminderEnabled: meal.reminderEnabled, notes: meal.notes,
                            items: meal.sortedItems.map { item in
                                NutritionPlanSnapshot.ItemValue(id: item.id, name: item.name, quantity: item.quantity, unit: item.unit,
                                                                values: item.values, notes: item.notes,
                                                                substitutions: item.substitutions)
                            })
                    })
            })
    }

    func plan(id: UUID) throws -> NutritionPlan? {
        var descriptor = FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Grava a fotografia no plano, no lugar (dias, refeições e itens casados por id). Um único `save()`.
    func write(_ snapshot: NutritionPlanSnapshot, into plan: NutritionPlan, now: Date = .now) throws {
        plan.targets = snapshot.targets
        var days = Dictionary((plan.days ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (d, dayValue) in snapshot.days.enumerated() {
            let day: NutritionDay
            if let found = days.removeValue(forKey: dayValue.id) {
                day = found
            } else {
                day = NutritionDay()
                day.id = dayValue.id
                context.insert(day)
                day.plan = plan
            }
            day.sortIndex = d
            day.name = dayValue.name
            day.weekdays = Set(dayValue.weekdays)
            var meals = Dictionary((day.meals ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (m, mealValue) in dayValue.meals.enumerated() {
                let meal: Meal
                if let found = meals.removeValue(forKey: mealValue.id) {
                    meal = found
                } else {
                    meal = Meal(name: mealValue.name, minutesFromMidnight: mealValue.minutesFromMidnight)
                    meal.id = mealValue.id
                    context.insert(meal)
                    meal.day = day
                }
                meal.sortIndex = m
                meal.name = mealValue.name
                meal.minutesFromMidnight = mealValue.minutesFromMidnight
                meal.reminderEnabled = mealValue.reminderEnabled
                meal.notes = mealValue.notes
                var items = Dictionary((meal.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (i, itemValue) in mealValue.items.enumerated() {
                    let item: MealItem
                    if let found = items.removeValue(forKey: itemValue.id) {
                        item = found
                    } else {
                        item = MealItem(name: itemValue.name, quantity: itemValue.quantity, unit: itemValue.unit)
                        item.id = itemValue.id
                        context.insert(item)
                        item.meal = meal
                    }
                    item.sortIndex = i
                    item.name = itemValue.name
                    item.quantity = itemValue.quantity
                    item.unit = itemValue.unit
                    item.values = itemValue.values
                    item.notes = itemValue.notes
                    item.substitutions = itemValue.substitutions
                    item.updatedAt = now
                }
                for leftover in items.values { context.delete(leftover) }
                meal.updatedAt = now
            }
            for leftover in meals.values { context.delete(leftover) }
            day.updatedAt = now
        }
        for leftover in days.values { context.delete(leftover) }
        plan.updatedAt = now
        try context.save()
    }

    func entry(id: UUID) throws -> FoodEntry? {
        var descriptor = FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
