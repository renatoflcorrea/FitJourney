import Foundation

/// Qual plano vale em um dia (SPEC §5.1: vigência início/fim; histórico de dietas).
enum NutritionVigency {
    struct Candidate: Sendable, Hashable {
        var id: UUID
        var startDate: Date
        var endDate: Date?
        var isActive: Bool
        /// Fim efetivo de plano arquivado sem `endDate` (dados antigos): quando saiu de cena.
        var updatedAt: Date
    }

    /// Plano cuja vigência cobre `day`: entre os que cobrem, o de início mais recente; empate → o ativo.
    static func resolve(day: Date, candidates: [Candidate], calendar: Calendar = .autoupdatingCurrent) -> UUID? {
        let target = calendar.startOfDay(for: day)
        let covering = candidates.filter { candidate in
            guard calendar.startOfDay(for: candidate.startDate) <= target else { return false }
            let end = candidate.isActive ? candidate.endDate : (candidate.endDate ?? candidate.updatedAt)
            guard let end else { return true }
            return target <= calendar.startOfDay(for: end)
        }
        return covering.max { a, b in
            let (sa, sb) = (calendar.startOfDay(for: a.startDate), calendar.startOfDay(for: b.startDate))
            if sa != sb { return sa < sb }
            return !a.isActive && b.isActive
        }?.id
    }

    /// `endDate` do plano que sai ao trocar de dieta: ontem (nunca antes do início).
    static func outgoingEndDate(start: Date, current: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let ended = max(calendar.startOfDay(for: start), yesterday)
        guard let current, calendar.startOfDay(for: current) <= ended else { return ended }
        return calendar.startOfDay(for: current)
    }
}

/// Regras de status ao editar uma entrada (SPEC §5.2).
enum NutritionEntryRules {
    /// Editar uma entrada de refeição "feita" a torna "ajustada"; mover entre refeições também.
    /// Registro avulso vinculado (sem status) continua sem status: registro parcial, a refeição segue pendente.
    /// Desvincular zera o status.
    static func statusAfterEdit(current: MealStatus?, oldMealID: UUID?, newMealID: UUID?) -> MealStatus? {
        guard newMealID != nil else { return nil }
        guard let current else { return nil }
        if current == .skipped { return .skipped }
        if oldMealID == newMealID { return current == .done ? .adjusted : current }
        return .adjusted
    }
}
