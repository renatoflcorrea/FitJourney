import Foundation
import SwiftData

/// Aderência de um dia ao plano: refeições feitas (inclui "ajustada") sobre as planejadas.
struct DayAdherence: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        /// Sem refeições planejadas (sem plano, fora da vigência ou dia sem refeição).
        case noPlan
        /// Dia futuro: só o plano.
        case upcoming
        /// Nenhuma feita.
        case none
        case partial
        case complete
    }

    var planned: Int
    var done: Int
    var isFuture = false

    var ratio: Double? { planned > 0 ? Double(done) / Double(planned) : nil }

    var level: Level {
        if planned == 0 { return .noPlan }
        if isFuture { return .upcoming }
        if done == 0 { return .none }
        return done >= planned ? .complete : .partial
    }

    /// "2 de 3 refeições".
    var summary: String {
        planned == 1 ? String(localized: "\(done) de 1 refeição") : String(localized: "\(done) de \(planned) refeições")
    }

    static func make(from meals: [PlannedMealState], isFuture: Bool = false) -> DayAdherence {
        DayAdherence(planned: meals.count,
                     done: meals.filter { $0.status == .done || $0.status == .adjusted }.count,
                     isFuture: isFuture)
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

extension NutritionStore {
    func adherence(on date: Date, now: Date = .now) throws -> DayAdherence {
        let future = calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
        return DayAdherence.make(from: try plannedMeals(on: date), isFuture: future)
    }

    /// Os sete dias da semana que contém `date` (início segundo o calendário), com aderência.
    func weekStrip(containing date: Date, now: Date = .now) throws -> [WeekCell] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return try (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return WeekCell(date: day, adherence: try adherence(on: day, now: now),
                            isSelected: calendar.isDate(day, inSameDayAs: date),
                            isToday: calendar.isDate(day, inSameDayAs: now))
        }
    }

    /// Dias do mais recente para o mais antigo, de `now` para trás, só os que têm algum registro (inclui refeição pulada).
    func history(days: Int = 60, now: Date = .now) throws -> [HistoryDay] {
        let today = calendar.startOfDay(for: now)
        return try (0..<max(0, days)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let entries = try entries(on: day)
            let plan = try plan(covering: day)
            let planned = plannedMeals(on: day, plan: plan, entries: entries)
            let totals = NutritionTotals.totals(entries.map(\.totalsEntry))
            guard !entries.isEmpty else { return nil }
            return HistoryDay(date: day, totals: totals, targetKcal: plan?.targets.kcal,
                              adherence: DayAdherence.make(from: planned))
        }
    }
}
