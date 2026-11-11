import Foundation

// Regras puras de apresentação da dieta (testáveis, sem SwiftUI).

/// Onde o dia exibido está em relação a hoje.
enum NutritionDayPhase: Sendable, Hashable {
    case past, today, future

    init(date: Date, now: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        self = day < today ? .past : (day > today ? .future : .today)
    }
}

/// Como uma refeição aparece na linha do tempo (forma + texto, SPEC §5.2 / DESIGN §4.9).
enum MealDisplay: Sendable, Hashable {
    case pending, next, overdue, noRecord, planned, done, adjusted, skipped

    /// `noRecord` = pendente em dia passado (neutro, nunca "pulada" — D4).
    static func resolve(status: MealStatus, phase: NutritionDayPhase, isNext: Bool, isOverdue: Bool) -> MealDisplay {
        switch status {
        case .done: .done
        case .adjusted: .adjusted
        case .skipped: .skipped
        case .pending:
            switch phase {
            case .past: .noRecord
            case .future: .planned
            case .today: isNext ? .next : (isOverdue ? .overdue : .pending)
            }
        }
    }
}

/// Linha de refeição do plano, já resolvida para exibir.
struct MealRowModel: Identifiable {
    let meal: Meal
    let status: MealStatus
    let scheduledAt: Date
    /// Entradas reais vinculadas (sem marcadores de pulo).
    let entries: [FoodEntry]
    let display: MealDisplay
    var id: UUID { meal.id }

    /// Quando foi registrada (primeira entrada), para "Feita 12:40".
    var loggedAt: Date? { entries.map(\.date).min() }
    var canMarkDone: Bool { !meal.sortedItems.isEmpty }
}

enum TimelineItem: Identifiable {
    case meal(MealRowModel)
    /// Registro avulso (ou de refeição que não existe mais no dia).
    case extra(FoodEntry)

    var id: UUID {
        switch self {
        case .meal(let row): row.id
        case .extra(let entry): entry.id
        }
    }

    var time: Date {
        switch self {
        case .meal(let row): row.scheduledAt
        case .extra(let entry): entry.date
        }
    }
}

enum NutritionTimeline {
    /// Atraso a partir do qual uma refeição pendente de hoje ganha o relógio (DESIGN §4.9).
    static let overdueAfter: TimeInterval = 3_600

    static func build(planned: [PlannedMealState], entries: [FoodEntry], date: Date, now: Date,
                      calendar: Calendar = .current) -> [TimelineItem] {
        let phase = NutritionDayPhase(date: date, now: now, calendar: calendar)
        let plannedIDs = Set(planned.map(\.meal.id))
        let nextID: UUID? = phase == .today
            ? planned.first(where: { $0.status == .pending && now < $0.scheduledAt.addingTimeInterval(overdueAfter) })?.meal.id
            : nil

        var items: [TimelineItem] = planned.map { state in
            let linked = entries.filter { $0.mealID == state.meal.id && $0.mealStatus != .skipped }
            let overdue = phase == .today && state.status == .pending
                && now >= state.scheduledAt.addingTimeInterval(overdueAfter)
            let display = MealDisplay.resolve(status: state.status, phase: phase,
                                              isNext: state.meal.id == nextID, isOverdue: overdue)
            return .meal(MealRowModel(meal: state.meal, status: state.status, scheduledAt: state.scheduledAt,
                                      entries: linked, display: display))
        }
        for entry in entries where entry.mealStatus != .skipped {
            if let id = entry.mealID, plannedIDs.contains(id) { continue }
            items.append(.extra(entry))
        }
        // Estável: hora, depois ordem original (refeições antes de avulsos no mesmo minuto).
        return items.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }
}

/// Rascunho do "Ajustar": itens da refeição com quantidade, troca e remoção.
struct AdjustDraftItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var quantity: Double
    var unit: FoodUnit
    /// Valores correspondentes a `baseQuantity` (escalam com a quantidade).
    var baseValues: NutrientValues
    var baseQuantity: Double
    var included: Bool
    var substitutions: [MealSubstitution]
    var isAdded: Bool = false

    var values: NutrientValues {
        baseQuantity > 0 ? baseValues.scaled(by: quantity / baseQuantity) : baseValues
    }

    mutating func apply(_ substitution: MealSubstitution) {
        name = substitution.name
        unit = substitution.unit
        baseQuantity = substitution.quantity
        quantity = substitution.quantity
        baseValues = substitution.values
    }

    /// Itens do plano; se já há registro da refeição, parte do que foi registrado
    /// (o que não consta fica desmarcado; o que foi registrado fora do plano vira "adicionado").
    static func drafts(for meal: Meal, entries: [FoodEntry]) -> [AdjustDraftItem] {
        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let logged = entries.filter { $0.mealStatus != .skipped }
        var used = Set<UUID>()
        var result: [AdjustDraftItem] = meal.sortedItems.map { item in
            if let entry = logged.first(where: { !used.contains($0.id) && same($0.name, item.name) }) {
                used.insert(entry.id)
                return AdjustDraftItem(id: item.id, name: item.name, quantity: entry.quantity, unit: entry.unit,
                                       baseValues: entry.values, baseQuantity: entry.quantity, included: true,
                                       substitutions: item.substitutions)
            }
            return AdjustDraftItem(id: item.id, name: item.name, quantity: item.quantity, unit: item.unit,
                                   baseValues: item.values, baseQuantity: item.quantity,
                                   included: logged.isEmpty, substitutions: item.substitutions)
        }
        for entry in logged where !used.contains(entry.id) {
            result.append(AdjustDraftItem(id: entry.id, name: entry.name, quantity: entry.quantity, unit: entry.unit,
                                          baseValues: entry.values, baseQuantity: entry.quantity, included: true,
                                          substitutions: [], isAdded: true))
        }
        return result
    }
}

enum NutritionFormat {
    static func quantity(_ quantity: Double, _ unit: FoodUnit) -> String {
        "\(FJFormat.number(quantity, maxFractionDigits: 1)) \(unit.symbol)"
    }

    static func kcal(_ value: Double?) -> String? {
        value.map { "\(FJFormat.number($0, maxFractionDigits: 0)) kcal" }
    }

    static func clock(minutes: Int) -> String {
        let m = min(max(0, minutes), 1_439)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func itemsWithoutKcal(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item sem calorias") : String(localized: "\(count) itens sem calorias")
    }

    /// "Hoje, 11 nov" / "Ontem, 10 nov" / "Amanhã, 12 nov" / "qua., 9 nov".
    static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let short = date.formatted(.dateTime.day().month(.abbreviated))
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                             to: calendar.startOfDay(for: date)).day ?? 0
        switch offset {
        case 0: return String(localized: "Hoje, \(short)")
        case -1: return String(localized: "Ontem, \(short)")
        case 1: return String(localized: "Amanhã, \(short)")
        default: return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }
}

/// Quantos copos desenhar e quantos estão cheios.
enum WaterCups {
    static let cupMilliliters: Double = 250

    static func layout(total: Double, goal: Double?) -> (filled: Int, capacity: Int) {
        let filled = Int((total / cupMilliliters).rounded(.down))
        let goalCups = goal.map { Int(($0 / cupMilliliters).rounded(.up)) } ?? 8
        return (filled, min(24, max(goalCups, filled, 1)))
    }
}
