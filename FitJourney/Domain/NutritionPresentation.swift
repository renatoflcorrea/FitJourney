import Foundation

// Regras puras de apresentação da dieta (testáveis, sem SwiftUI).

/// Onde o dia exibido está em relação a hoje.
enum NutritionDayPhase: Sendable, Hashable {
    case past, today, future

    init(date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) {
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

/// Soma planejada de uma refeição, com aviso de itens sem kcal (soma parcial = "≥").
struct PlannedKcalSummary: Sendable, Hashable {
    var kcal: Double?
    var itemsWithoutKcal: Int
    var itemCount: Int

    var isPartial: Bool { itemsWithoutKcal > 0 && kcal != nil }
}

extension Meal {
    var plannedKcalSummary: PlannedKcalSummary {
        let totals = NutritionTotals.totals(sortedItems.map { NutritionTotals.Entry(values: $0.values) })
        let known = totals.entryCount - totals.itemsWithoutKcal
        return PlannedKcalSummary(kcal: known > 0 ? totals.kcal : nil, itemsWithoutKcal: totals.itemsWithoutKcal,
                                  itemCount: totals.entryCount)
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

    /// Quando foi registrada (primeira entrada com status), para "Feita 12:40".
    var loggedAt: Date? { entries.filter { $0.mealStatus != nil }.map(\.date).min() }
    var canMarkDone: Bool { !meal.sortedItems.isEmpty }

    /// Kcal exibida: registrada se feita/ajustada, planejada nos demais; pulada não mostra kcal.
    var kcalSummary: PlannedKcalSummary? {
        if status == .skipped { return nil }
        if status == .pending { return meal.plannedKcalSummary }
        let known = entries.compactMap(\.kcal)
        return PlannedKcalSummary(kcal: known.isEmpty ? nil : known.reduce(0, +),
                                  itemsWithoutKcal: entries.count - known.count, itemCount: entries.count)
    }
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
                      calendar: Calendar = .autoupdatingCurrent) -> [TimelineItem] {
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

/// Horário a gravar ao registrar uma refeição: hoje = agora; dia passado = horário planejado (`nil`).
enum NutritionLogTime {
    static func entryTime(phase: NutritionDayPhase, now: Date, existing: Date?) -> Date? {
        if let existing { return existing }
        return phase == .today ? now : nil
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
    /// Preservados do registro anterior (grau de estimativa e observação).
    var estimation: EstimationSource = .informed
    var notes: String = ""

    /// `MealItem.id` de origem; `nil` em itens adicionados.
    var plannedItemID: UUID? { isAdded ? nil : id }

    var values: NutrientValues {
        baseQuantity > 0 ? baseValues.scaled(by: quantity / baseQuantity) : baseValues
    }

    mutating func apply(_ substitution: MealSubstitution) {
        name = substitution.name
        unit = substitution.unit
        baseQuantity = substitution.quantity
        quantity = substitution.quantity
        baseValues = substitution.values
        notes = substitution.notes.isEmpty ? notes : substitution.notes
    }

    /// Edita as kcal da quantidade atual: se já havia kcal, escala macros juntos; senão só grava kcal.
    mutating func setKcal(_ newKcal: Double?) {
        let current = values
        if let old = current.kcal, old > 0, let newKcal {
            baseValues = current.scaled(by: newKcal / old)
            baseValues.kcal = newKcal
        } else {
            baseValues = current
            baseValues.kcal = newKcal
        }
        baseQuantity = quantity
    }

    /// Itens do plano; se já há registro da refeição, parte do que foi registrado
    /// (o que não consta fica desmarcado; o que foi registrado fora do plano vira "adicionado").
    /// Entradas casam com o item pelo `plannedItemID` (mesmo trocado por substituição) e, na falta, pelo nome.
    static func drafts(for meal: Meal, entries: [FoodEntry]) -> [AdjustDraftItem] {
        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let logged = entries.filter { $0.mealStatus != .skipped && $0.mealStatus != nil }
        var used = Set<UUID>()
        var result: [AdjustDraftItem] = meal.sortedItems.map { item in
            let match = logged.first(where: { !used.contains($0.id) && $0.plannedItemID == item.id })
                ?? logged.first(where: { !used.contains($0.id) && $0.plannedItemID == nil && same($0.name, item.name) })
            if let entry = match {
                used.insert(entry.id)
                return AdjustDraftItem(id: item.id, name: entry.name, quantity: entry.quantity, unit: entry.unit,
                                       baseValues: entry.values, baseQuantity: entry.quantity, included: true,
                                       substitutions: item.substitutions.filter { !$0.name.isEmpty },
                                       estimation: entry.estimation, notes: entry.notes)
            }
            return AdjustDraftItem(id: item.id, name: item.name, quantity: item.quantity, unit: item.unit,
                                   baseValues: item.values, baseQuantity: item.quantity,
                                   included: logged.isEmpty, substitutions: item.substitutions.filter { !$0.name.isEmpty })
        }
        for entry in logged where !used.contains(entry.id) {
            result.append(AdjustDraftItem(id: entry.id, name: entry.name, quantity: entry.quantity, unit: entry.unit,
                                          baseValues: entry.values, baseQuantity: entry.quantity, included: true,
                                          substitutions: [], isAdded: true, estimation: entry.estimation, notes: entry.notes))
        }
        return result
    }

    /// `true` se os itens marcados são exatamente os do plano (nome, quantidade, unidade e valores):
    /// salvar assim é "Feita", não "Ajustada".
    static func matchesPlan(_ drafts: [AdjustDraftItem], meal: Meal) -> Bool {
        let chosen = drafts.filter(\.included)
        let planned = meal.sortedItems
        guard chosen.count == planned.count, chosen.allSatisfy({ !$0.isAdded }) else { return false }
        return planned.allSatisfy { item in
            chosen.contains { $0.id == item.id && $0.name == item.name && $0.quantity == item.quantity
                && $0.unit == item.unit && $0.values == item.values }
        }
    }

    /// Itens para gravar (marcados, com nome).
    static func adjustedItems(_ drafts: [AdjustDraftItem]) -> [AdjustedMealItem] {
        drafts.filter { $0.included && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            AdjustedMealItem(name: $0.name.trimmingCharacters(in: .whitespaces), quantity: $0.quantity, unit: $0.unit,
                             values: $0.values, estimation: $0.estimation, notes: $0.notes, plannedItemID: $0.plannedItemID)
        }
    }
}

enum NutritionFormat {
    static func quantity(_ quantity: Double, _ unit: FoodUnit) -> String {
        "\(FJFormat.number(quantity, maxFractionDigits: 1)) \(unit.symbol)"
    }

    static func kcal(_ value: Double?) -> String? {
        value.map { "\(FJFormat.number($0, maxFractionDigits: 0)) kcal" }
    }

    /// "≥ 440 kcal" quando há itens sem calorias na soma.
    static func kcal(_ summary: PlannedKcalSummary?) -> String? {
        guard let summary, let kcal = summary.kcal else { return nil }
        let text = "\(FJFormat.number(kcal, maxFractionDigits: 0)) kcal"
        return summary.isPartial ? "≥ \(text)" : text
    }

    static func clock(minutes: Int) -> String {
        let m = min(max(0, minutes), 1_439)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func clock(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func itemsWithoutKcal(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item sem calorias") : String(localized: "\(count) itens sem calorias")
    }

    /// "Hoje, 11 nov" / "Ontem, 10 nov" / "Amanhã, 12 nov" / "qua., 9 nov".
    static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
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
        let goalCups = goal.flatMap { $0 > 0 ? Int(($0 / cupMilliliters).rounded(.up)) : nil } ?? 8
        return (filled, min(24, max(goalCups, filled, 1)))
    }
}

/// Contagem de entradas estimadas (informado ≠ estimado/IA) para "inclui 2 estimados".
enum NutritionEstimates {
    static func count(in entries: [FoodEntry]) -> Int {
        entries.filter { $0.mealStatus != .skipped && $0.estimation != .informed }.count
    }
}
