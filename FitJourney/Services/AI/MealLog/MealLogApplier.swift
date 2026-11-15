import Foundation
import SwiftData

/// Cópia completa de uma `FoodEntry` apagada ao substituir um registro, para o Desfazer recriá-la igual (mesmo id).
struct FoodEntrySnapshot: Codable, Sendable, Hashable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var date: Date
    var mealID: UUID?
    var mealName: String?
    var name: String
    var quantity: Double
    var unitRaw: String
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var estimationRaw: String
    var mealStatusRaw: String?
    var notes: String
    var plannedItemID: UUID?

    init(_ entry: FoodEntry) {
        id = entry.id
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        date = entry.date
        mealID = entry.mealID
        mealName = entry.mealName
        name = entry.name
        quantity = entry.quantity
        unitRaw = entry.unitRaw
        kcal = entry.kcal
        protein = entry.protein
        carbs = entry.carbs
        fat = entry.fat
        fiber = entry.fiber
        estimationRaw = entry.estimationRaw
        mealStatusRaw = entry.mealStatusRaw
        notes = entry.notes
        plannedItemID = entry.plannedItemID
    }

    func makeEntry() -> FoodEntry {
        let entry = FoodEntry(name: name, quantity: quantity, unit: .grams, date: date)
        entry.id = id
        entry.createdAt = createdAt
        entry.updatedAt = updatedAt
        entry.mealID = mealID
        entry.mealName = mealName
        entry.unitRaw = unitRaw
        entry.kcal = kcal
        entry.protein = protein
        entry.carbs = carbs
        entry.fat = fat
        entry.fiber = fiber
        entry.estimationRaw = estimationRaw
        entry.mealStatusRaw = mealStatusRaw
        entry.notes = notes
        entry.plannedItemID = plannedItemID
        return entry
    }
}

/// O que um "Registrar" gravou, para o "Desfazer" reverter exatamente: apaga as entradas criadas e recria as
/// substituídas. Codable para a UI guardar se quiser oferecer o Desfazer depois de reabrir.
struct MealLogUndo: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var day: Date
    var appliedAt: Date
    var createdEntryIDs: [UUID]
    var removedEntries: [FoodEntrySnapshot]
    /// Refeições registradas (para o aviso "4 refeições registradas").
    var mealCount: Int
    /// Itens gravados como estimados pela IA (para "inclui 7 itens estimados pela IA").
    var estimatedItemCount: Int
}

enum MealLogApplyError: Error, Sendable, Hashable {
    /// A revisão ainda tem pendências (`MealLogReview.issues`).
    case invalid([MealLogIssue])
    /// A refeição do plano vinculada não existe mais.
    case mealNotFound(UUID)
    /// A refeição ganhou registro depois da análise e a revisão não escolheu substituir: revise de novo.
    case mealChangedSinceReview(UUID)
    case futureDay
}

extension MealLogApplyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalid(issues):
            if issues.contains(where: { if case .missingQuantity = $0 { true } else { false } }) {
                String(localized: "Informe a quantidade dos itens marcados antes de registrar.")
            } else {
                String(localized: "Revise o registro antes de salvar.")
            }
        case .mealNotFound: String(localized: "A refeição do plano não existe mais. Escolha outra.")
        case .mealChangedSinceReview: String(localized: "Essa refeição foi registrada enquanto você revisava. Confira antes de substituir.")
        case .futureDay: String(localized: "Não é possível registrar refeições num dia futuro.")
        }
    }
}

/// Grava o rascunho revisado num **save único** (SPEC §7.x):
/// - Feita → `markMealDone` (itens e valores do plano, grau informado; a estimativa é descartada);
/// - Ajustada → `logAdjustedMeal` com os itens estimados (grau IA, `plannedItemID` quando o nome casa);
/// - Fora da dieta (ou sem plano) → entradas avulsas sem refeição, grau IA.
/// Refeição com registro anterior só é substituída se a revisão sabia disso (`alreadyLogged`), e o anterior vai para
/// o Desfazer. Favoritos/recentes não são tocados (o Desfazer volta o dia exatamente ao que era).
@MainActor
struct MealLogApplier {
    let context: ModelContext
    var calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .autoupdatingCurrent) {
        self.context = context
        self.calendar = calendar
    }

    private var store: NutritionStore { NutritionStore(context: context, calendar: calendar) }

    @discardableResult
    func apply(_ review: MealLogReview, now: Date = .now) throws -> MealLogUndo {
        let issues = review.issues
        guard issues.isEmpty else { throw MealLogApplyError.invalid(issues) }
        let day = calendar.startOfDay(for: review.day)
        guard day <= calendar.startOfDay(for: now) else { throw MealLogApplyError.futureDay }

        // 1) Valida tudo antes de mexer no contexto (nada fica pela metade).
        var targets: [UUID: Meal] = [:]
        var previous: [UUID: [FoodEntry]] = [:]
        for meal in review.includedMeals where meal.decision != .offPlan {
            guard let plannedID = meal.plannedMealID else { continue }
            let id = plannedID
            var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let target = try context.fetch(descriptor).first else { throw MealLogApplyError.mealNotFound(plannedID) }
            let existing = try store.recordedEntries(for: target, on: day)
            if !existing.isEmpty, !meal.alreadyLogged { throw MealLogApplyError.mealChangedSinceReview(plannedID) }
            targets[meal.id] = target
            previous[meal.id] = existing
        }

        // 2) Grava sem salvar e salva uma vez.
        var created: [FoodEntry] = []
        var removed: [FoodEntrySnapshot] = []
        var estimated = 0
        for meal in review.includedMeals {
            let time = entryTime(for: meal, day: day, now: now, target: targets[meal.id])
            switch (meal.decision, targets[meal.id]) {
            case let (.done, target?):
                removed += (previous[meal.id] ?? []).map(FoodEntrySnapshot.init)
                created += try store.markMealDone(target, on: day, at: time, save: false)
            case let (.adjusted, target?):
                removed += (previous[meal.id] ?? []).map(FoodEntrySnapshot.init)
                let items = meal.items.map {
                    AdjustedMealItem(name: $0.name, quantity: $0.quantity ?? 0, unit: $0.unit, values: $0.values,
                                     estimation: .ai, notes: $0.note ?? "", plannedItemID: $0.plannedItemID)
                }
                created += try store.logAdjustedMeal(target, on: day, adjusted: items, at: time, save: false)
                estimated += items.count
            default:
                for item in meal.items {
                    let entry = FoodEntry(name: item.name, quantity: item.quantity ?? 0, unit: item.unit, date: time,
                                          values: item.values, estimation: .ai)
                    entry.notes = item.note ?? ""
                    context.insert(entry)
                    created.append(entry)
                }
                estimated += meal.items.count
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return MealLogUndo(day: day, appliedAt: now, createdEntryIDs: created.map(\.id), removedEntries: removed,
                           mealCount: review.includedMeals.count, estimatedItemCount: estimated)
    }

    /// Desfaz um "Registrar": apaga as entradas criadas que ainda existem e recria as substituídas (as que ainda não
    /// existem). Um save só.
    func undo(_ undo: MealLogUndo) throws {
        let createdIDs = undo.createdEntryIDs
        if !createdIDs.isEmpty {
            for entry in try context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { createdIDs.contains($0.id) })) {
                context.delete(entry)
            }
        }
        let removedIDs = undo.removedEntries.map(\.id)
        let surviving = removedIDs.isEmpty ? Set<UUID>()
            : Set(try context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { removedIDs.contains($0.id) })).map(\.id))
        for snapshot in undo.removedEntries where !surviving.contains(snapshot.id) {
            context.insert(snapshot.makeEntry())
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Horário da entrada: o dito pela IA; senão o do plano (vinculada); senão agora (hoje) ou o típico da refeição.
    private func entryTime(for meal: MealLogReviewMeal, day: Date, now: Date, target: Meal?) -> Date {
        let minutes: Int
        if let said = meal.minutesFromMidnight {
            minutes = said
        } else if let target {
            return target.time(on: day, calendar: calendar)
        } else if calendar.isDate(now, inSameDayAs: day) {
            return now
        } else {
            minutes = meal.slot.typicalMinutes
        }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? day.addingTimeInterval(TimeInterval(minutes * 60))
    }
}
