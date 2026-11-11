import Foundation
import SwiftData

extension DayAdherence {
    /// "2 de 3 refeições".
    var summary: String {
        planned == 1 ? String(localized: "\(done) de 1 refeição") : String(localized: "\(done) de \(planned) refeições")
    }
}

/// Um dia do histórico.
struct HistoryDay: Identifiable, Equatable {
    var date: Date
    var totals: DayNutritionTotals
    var targetKcal: Double?
    var adherence: DayAdherence
    var id: Date { date }
}

/// Uma célula da faixa da semana.
struct WeekCell: Identifiable, Equatable {
    var date: Date
    var adherence: DayAdherence
    var isSelected: Bool
    var isToday: Bool
    var id: Date { date }
}

/// Um dia já resolvido (plano vigente, registros e refeições planejadas), carregado em lote.
struct ResolvedDay {
    var date: Date
    var plan: NutritionPlan?
    var entries: [FoodEntry]
    var planned: [PlannedMealState]
}

extension NutritionStore {
    /// `count` dias a partir de `first` com **um** fetch de planos e **um** de registros no intervalo
    /// (agrupados por dia) — em vez de dois fetches por dia.
    func resolvedDays(from first: Date, count: Int) throws -> [ResolvedDay] {
        let start = calendar.startOfDay(for: first)
        guard count > 0, let end = calendar.date(byAdding: .day, value: count, to: start) else { return [] }
        let plans = try context.fetch(FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.isActive || $0.isArchived }))
        let candidates = plans.map {
            NutritionVigency.Candidate(id: $0.id, startDate: $0.startDate, endDate: $0.endDate,
                                       isActive: $0.isActive, updatedAt: $0.updatedAt)
        }
        let entries = try context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end }, sortBy: [SortDescriptor(\.date)]))
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let id = NutritionVigency.resolve(day: day, candidates: candidates, calendar: calendar)
            let plan = plans.first { $0.id == id }
            let dayEntries = byDay[day] ?? []
            return ResolvedDay(date: day, plan: plan, entries: dayEntries,
                               planned: plannedMeals(on: day, plan: plan, entries: dayEntries))
        }
    }

    private func adherence(of day: ResolvedDay, now: Date) -> DayAdherence {
        DayAdherence.make(statuses: day.planned.map(\.status),
                          phase: NutritionDayPhase(date: day.date, now: now, calendar: calendar))
    }

    func adherence(on date: Date, now: Date = .now) throws -> DayAdherence {
        guard let day = try resolvedDays(from: date, count: 1).first else { return DayAdherence(planned: 0, done: 0) }
        return adherence(of: day, now: now)
    }

    /// Os sete dias da semana que contém `date` (início segundo o calendário), com aderência.
    func weekStrip(containing date: Date, now: Date = .now) throws -> [WeekCell] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return try resolvedDays(from: start, count: 7).map { day in
            WeekCell(date: day.date, adherence: adherence(of: day, now: now),
                     isSelected: calendar.isDate(day.date, inSameDayAs: date),
                     isToday: calendar.isDate(day.date, inSameDayAs: now))
        }
    }

    /// Dias do mais recente para o mais antigo, de `now` para trás, só os que têm algum registro (inclui refeição pulada).
    func history(days: Int = 60, now: Date = .now) throws -> [HistoryDay] {
        let today = calendar.startOfDay(for: now)
        guard days > 0, let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        return try resolvedDays(from: first, count: days).reversed().compactMap { day in
            guard !day.entries.isEmpty else { return nil }
            return HistoryDay(date: day.date, totals: NutritionTotals.totals(day.entries.map(\.totalsEntry)),
                              targetKcal: day.plan?.targets.kcal, adherence: adherence(of: day, now: now))
        }
    }
}
