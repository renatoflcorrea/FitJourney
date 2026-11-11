import Foundation
import SwiftData

enum ChangeApplierError: Error, Sendable, Hashable {
    case notFound
    /// Já aplicado, descartado ou desfeito.
    case notPending(CopilotChangeState)
    /// Há um treino em andamento nesta ficha: o copiloto não altera (SPEC §7A.2).
    case sessionInProgress(routineName: String)
    /// A ficha/dieta/refeição não existe mais.
    case targetMissing
    /// As operações não valem mais no estado atual (lista legível).
    case invalid([String])
    case undoUnavailable
    case undoExpired
    /// A ficha/dieta mudou depois de aplicar: desfazer apagaria essas mudanças.
    case undoConflict
}

extension ChangeApplierError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "Alteração não encontrada.")
        case .notPending: String(localized: "Esta alteração já foi resolvida.")
        case let .sessionInProgress(name): String(localized: "Há um treino em andamento (\(name)). Finalize antes de alterar a ficha.")
        case .targetMissing: String(localized: "A ficha ou dieta não existe mais.")
        case let .invalid(issues): String(localized: "A alteração não vale mais: \(issues.prefix(2).joined(separator: "; "))")
        case .undoUnavailable: String(localized: "Não há o que desfazer.")
        case .undoExpired: String(localized: "O prazo para desfazer (24 h) passou.")
        case .undoConflict: String(localized: "A ficha ou dieta mudou depois; desfazer apagaria essas mudanças.")
        }
    }
}

/// Aplica, descarta e desfaz os cartões do copiloto (SPEC §7A.2) pelos stores (`ProgramStore`/`NutritionStore`):
/// - **Aplicar**: recalcula a fotografia atual; se mudou desde a proposta, devolve `.needsConfirmation` com o diff
///   novo (o cartão pede outro toque). Senão reaplica as operações, valida com as regras do editor e grava.
///   Ficha com treino em andamento é recusada. Carga vai para `currentLoad` salvo pedido explícito (`initial`).
/// - **Desfazer**: até 24 h e só enquanto a ficha/dieta estiver como ficou; uma alteração nova aplicada no mesmo
///   escopo invalida o desfazer das anteriores.
@MainActor
struct ChangeApplier {
    enum Outcome: Sendable, Hashable {
        case applied
        /// O estado mudou: mostre o diff novo e peça confirmação (chamar `apply` de novo aplica).
        case needsConfirmation(CopilotChangeSet)
    }

    let context: ModelContext
    let store: CopilotChangeStore
    var now: () -> Date
    var calendar: Calendar

    init(context: ModelContext, store: CopilotChangeStore = .shared, now: @escaping () -> Date = { .now },
         calendar: Calendar = .current) {
        self.context = context
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    @discardableResult
    func apply(_ id: String) throws -> Outcome {
        guard var record = store.record(for: id) else { throw ChangeApplierError.notFound }
        guard record.state == .proposed || record.state == .needsConfirmation else { throw ChangeApplierError.notPending(record.state) }
        let changeSet = record.changeSet
        let planner = CopilotPlanner(context: context, now: now(), calendar: calendar)
        do {
            switch changeSet.scope {
            case let .routine(routineID, _):
                let programs = ProgramStore(context: context)
                guard let routine = try programs.routine(id: routineID) else { throw ChangeApplierError.targetMissing }
                try ensureNoSession(on: routine)
                let before = programs.snapshot(of: routine)
                if before.fingerprint != changeSet.baseFingerprint {
                    return try requestConfirmation(&record, planner: planner)
                }
                let after = try CopilotPlanner.apply(changeSet.operations, to: before)
                try programs.write(after, into: routine, now: now())
                record.undo = .routine(before: before, afterFingerprint: programs.snapshot(of: routine).fingerprint)
            case let .nutritionPlan(planID, _):
                let nutrition = NutritionStore(context: context, calendar: calendar)
                guard let plan = try nutrition.plan(id: planID) else { throw ChangeApplierError.targetMissing }
                let before = nutrition.snapshot(of: plan)
                if before.fingerprint != changeSet.baseFingerprint {
                    return try requestConfirmation(&record, planner: planner)
                }
                let after = try CopilotPlanner.apply(changeSet.operations, to: before)
                try nutrition.write(after, into: plan, now: now())
                record.undo = .nutritionPlan(before: before, afterFingerprint: nutrition.snapshot(of: plan).fingerprint)
            case .foodLog:
                record.undo = .foodLog(entryIDs: try logFood(changeSet.operations))
            }
        } catch let error as CopilotPlanError {
            throw ChangeApplierError.invalid(error.issues)
        }
        invalidateUndo(sameScopeAs: changeSet)
        record.state = .applied
        record.appliedAt = now()
        record.updatedAt = now()
        store.update(record)
        return .applied
    }

    func discard(_ id: String) throws {
        guard var record = store.record(for: id) else { throw ChangeApplierError.notFound }
        guard record.state == .proposed || record.state == .needsConfirmation else { throw ChangeApplierError.notPending(record.state) }
        record.state = .discarded
        record.updatedAt = now()
        store.update(record)
    }

    /// Pode desfazer agora (aplicado há ≤ 24 h, com desfazer guardado e sem mudança posterior no escopo).
    func canUndo(_ id: String) -> Bool {
        (try? undoCheck(id)) != nil
    }

    func undo(_ id: String) throws {
        var record = try undoCheck(id)
        switch record.undo {
        case let .routine(before, _)?:
            let programs = ProgramStore(context: context)
            guard let routine = try programs.routine(id: before.routineID) else { throw ChangeApplierError.targetMissing }
            try ensureNoSession(on: routine)
            try programs.write(before, into: routine, now: now())
        case let .nutritionPlan(before, _)?:
            let nutrition = NutritionStore(context: context, calendar: calendar)
            guard let plan = try nutrition.plan(id: before.planID) else { throw ChangeApplierError.targetMissing }
            try nutrition.write(before, into: plan, now: now())
        case let .foodLog(entryIDs)?:
            let nutrition = NutritionStore(context: context, calendar: calendar)
            for entryID in entryIDs {
                if let entry = try nutrition.entry(id: entryID) { context.delete(entry) }
            }
            try context.save()
        case nil:
            throw ChangeApplierError.undoUnavailable
        }
        record.state = .undone
        record.undo = nil
        record.updatedAt = now()
        store.update(record)
    }

    // MARK: - Privado

    private func undoCheck(_ id: String) throws -> CopilotChangeStore.Record {
        guard let record = store.record(for: id) else { throw ChangeApplierError.notFound }
        guard record.state == .applied, let undo = record.undo, let appliedAt = record.appliedAt else {
            throw ChangeApplierError.undoUnavailable
        }
        guard now().timeIntervalSince(appliedAt) <= CopilotChangeStore.undoWindow else { throw ChangeApplierError.undoExpired }
        switch undo {
        case let .routine(before, afterFingerprint):
            let programs = ProgramStore(context: context)
            guard let routine = try programs.routine(id: before.routineID) else { throw ChangeApplierError.targetMissing }
            guard programs.snapshot(of: routine).fingerprint == afterFingerprint else { throw ChangeApplierError.undoConflict }
        case let .nutritionPlan(before, afterFingerprint):
            let nutrition = NutritionStore(context: context, calendar: calendar)
            guard let plan = try nutrition.plan(id: before.planID) else { throw ChangeApplierError.targetMissing }
            guard nutrition.snapshot(of: plan).fingerprint == afterFingerprint else { throw ChangeApplierError.undoConflict }
        case .foodLog:
            break
        }
        return record
    }

    private func requestConfirmation(_ record: inout CopilotChangeStore.Record, planner: CopilotPlanner) throws -> Outcome {
        let updated = try planner.recompute(record.changeSet)
        record.changeSet = updated
        record.state = .needsConfirmation
        record.updatedAt = now()
        store.update(record)
        return .needsConfirmation(updated)
    }

    private func ensureNoSession(on routine: Routine) throws {
        if let session = try SessionStore(context: context).inProgressSession(), session.routineID == routine.id {
            throw ChangeApplierError.sessionInProgress(routineName: session.routineName)
        }
    }

    private func logFood(_ operations: [CopilotOperation]) throws -> [UUID] {
        let nutrition = NutritionStore(context: context, calendar: calendar)
        let meals = Dictionary(((try nutrition.activePlan())?.sortedDays.flatMap(\.sortedMeals) ?? []).map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        // Confere tudo antes de gravar o primeiro registro (nada pela metade).
        let entries: [(CopilotFoodItem, Date, Meal?)] = try operations.map { operation in
            guard case let .logFood(item, date, mealID) = operation else { throw CopilotPlanError("operação inválida no registro") }
            guard let mealID else { return (item, date, nil) }
            guard let meal = meals[mealID] else { throw ChangeApplierError.targetMissing }
            return (item, date, meal)
        }
        return try entries.map { item, date, meal in
            try nutrition.logFood(name: item.name, quantity: item.quantity, unit: item.unit, values: item.values,
                                  estimation: .ai, at: date, meal: meal).id
        }
    }

    /// Uma alteração nova no mesmo escopo invalida o desfazer das anteriores (desfazer apagaria a nova).
    private func invalidateUndo(sameScopeAs changeSet: CopilotChangeSet) {
        for record in store.records.values where record.changeSet.id != changeSet.id && record.state == .applied
            && record.undo != nil && Self.sameScope(record.changeSet.scope, changeSet.scope) {
            var copy = record
            copy.undo = nil
            store.update(copy)
        }
    }

    private static func sameScope(_ a: CopilotScope, _ b: CopilotScope) -> Bool {
        switch (a, b) {
        case let (.routine(x, _), .routine(y, _)): x == y
        case let (.nutritionPlan(x, _), .nutritionPlan(y, _)): x == y
        default: false
        }
    }
}
