import Foundation

// Registro de refeições com IA (SPEC §7.x, O6c): regras puras — vínculo ao plano do dia, estado padrão
// (feita/ajustada/fora da dieta), revisão editável, totais com faixa e baixa confiança. Sem SwiftData/SwiftUI.

/// Refeição do dia como a IA a classifica (o nome do plano vence; isto só ajuda a casar sem plano enviado).
enum MealLogSlot: String, Codable, Sendable, Hashable, CaseIterable {
    case breakfast
    case morningSnack = "morning_snack"
    case lunch
    case afternoonSnack = "afternoon_snack"
    case dinner
    case supper
    case other

    /// Nomes usuais (pt-BR e en, já normalizados por `MealLogText.normalize`) que casam com a refeição do plano.
    var synonyms: [String] {
        switch self {
        case .breakfast: ["cafe da manha", "cafe", "desjejum", "breakfast"]
        case .morningSnack: ["lanche da manha", "colacao", "morning snack"]
        case .lunch: ["almoco", "lunch"]
        case .afternoonSnack: ["lanche da tarde", "lanche", "afternoon snack", "snack"]
        case .dinner: ["jantar", "janta", "dinner"]
        case .supper: ["ceia", "supper"]
        case .other: []
        }
    }

    /// Horário típico (minutos desde a meia-noite), usado quando não há horário nem plano.
    var typicalMinutes: Int {
        switch self {
        case .breakfast: 7 * 60 + 30
        case .morningSnack: 10 * 60
        case .lunch: 12 * 60 + 30
        case .afternoonSnack: 16 * 60
        case .dinner: 19 * 60 + 30
        case .supper: 22 * 60
        case .other: 12 * 60
        }
    }
}

/// Confiança da IA num item.
enum MealLogConfidence: String, Codable, Sendable, Hashable, CaseIterable {
    case high, medium, low
}

/// O que "Registrar" grava para uma refeição do rascunho.
enum MealLogDecision: String, Codable, Sendable, Hashable, CaseIterable {
    /// Itens e valores **do plano** (a estimativa é descartada), grau informado.
    case done
    /// O que a IA estimou (editado pelo usuário) no lugar do plano, grau IA.
    case adjusted
    /// Registro avulso, sem refeição do plano, grau IA.
    case offPlan
}

/// Faixa fechada de um valor estimado (`min ≤ max`).
struct MealLogRange: Codable, Sendable, Hashable {
    var min: Double
    var max: Double

    init(min: Double, max: Double) {
        self.min = Swift.min(min, max)
        self.max = Swift.max(min, max)
    }

    func scaled(by factor: Double) -> MealLogRange { MealLogRange(min: min * factor, max: max * factor) }
}

// MARK: - Plano do dia (entrada do matcher)

struct MealLogPlannedItem: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var quantity: Double
    var unit: FoodUnit
    var values: NutrientValues = NutrientValues()
}

/// Refeição do plano que vale para o dia, com o estado atual do registro.
struct MealLogPlannedMeal: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var minutesFromMidnight: Int
    var status: MealStatus
    var items: [MealLogPlannedItem]

    /// Já tem registro (feita, ajustada ou pulada): fica fora do rascunho por padrão ("Substituir o registro").
    var isLogged: Bool { status != .pending }
}

// MARK: - Matcher

/// Refeição do rascunho vista pelo matcher (só o que importa para o vínculo).
struct MealLogCandidate: Sendable, Hashable {
    struct Item: Sendable, Hashable {
        var name: String
        var quantity: Double?
        var unit: FoodUnit
        /// id do item do plano sugerido pela IA (só vale se pertencer à refeição vinculada).
        var plannedItemID: UUID?
    }

    var slot: MealLogSlot
    var label: String?
    var minutesFromMidnight: Int?
    /// Refeição do plano sugerida pela IA (só com "Dieta" compartilhada).
    var plannedMealID: UUID?
    /// O usuário disse "como no plano".
    var asPlanned: Bool
    var items: [Item]
}

/// Resultado do vínculo de uma refeição do rascunho.
struct MealLogMatch: Sendable, Hashable {
    enum Basis: String, Sendable, Hashable {
        /// Sugestão da IA (plano enviado).
        case provider
        /// Nome dito pelo usuário (ou a refeição típica) casou com o nome da refeição do plano.
        case name
        /// Refeição pendente mais próxima do horário (até `MealLogMatcher.timeWindowMinutes`).
        case time
        case none
    }

    var plannedMealID: UUID?
    var decision: MealLogDecision
    var basis: Basis
    /// A refeição vinculada já tinha registro quando o rascunho foi montado.
    var alreadyLogged: Bool
    /// Por item do candidato: item do plano correspondente (pelo id sugerido ou pelo nome).
    var plannedItemIDs: [UUID?]
}

/// Vincula as refeições do rascunho às refeições do plano do dia e escolhe o estado padrão (proposta §5):
/// - sem plano no dia → fora da dieta (sem seletor);
/// - vínculo: id sugerido pela IA → nome (rótulo ou refeição típica) → refeição **pendente** a até 90 min;
///   cada refeição do plano recebe no máximo uma do rascunho;
/// - "como no plano" ou itens iguais aos do plano (mesmos alimentos, quantidade a ±25%, sem item extra) → feita;
///   vinculada com itens diferentes → ajustada; sem vínculo → fora da dieta.
enum MealLogMatcher {
    static let timeWindowMinutes = 90
    static let quantityTolerance = 0.25

    /// - Parameter referenceMinutes: "agora" em minutos, quando o dia do registro é hoje (foto sem horário).
    static func match(_ candidates: [MealLogCandidate], planned: [MealLogPlannedMeal],
                      referenceMinutes: Int? = nil) -> [MealLogMatch] {
        guard !planned.isEmpty else {
            return candidates.map {
                MealLogMatch(plannedMealID: nil, decision: .offPlan, basis: .none, alreadyLogged: false,
                             plannedItemIDs: Array(repeating: nil, count: $0.items.count))
            }
        }
        var used: Set<UUID> = []
        var links: [(UUID?, MealLogMatch.Basis)] = Array(repeating: (nil, .none), count: candidates.count)

        // 1) Sugestão da IA (id válido). 2) Nome. 3) Horário. Em passes, para um vínculo forte não ser tomado
        // por um fraco de outra refeição.
        for (index, candidate) in candidates.enumerated() {
            if let id = candidate.plannedMealID, planned.contains(where: { $0.id == id }), !used.contains(id) {
                links[index] = (id, .provider)
                used.insert(id)
            }
        }
        for (index, candidate) in candidates.enumerated() where links[index].0 == nil {
            if let meal = nameMatch(candidate, in: planned, excluding: used) {
                links[index] = (meal.id, .name)
                used.insert(meal.id)
            }
        }
        for (index, candidate) in candidates.enumerated() where links[index].0 == nil {
            let minutes = candidate.minutesFromMidnight ?? referenceMinutes
            guard let minutes else { continue }
            let nearby = planned
                .filter { !used.contains($0.id) && !$0.isLogged }
                .map { ($0, abs($0.minutesFromMidnight - minutes)) }
                .filter { $0.1 <= timeWindowMinutes }
                .min { $0.1 < $1.1 }
            if let meal = nearby?.0 {
                links[index] = (meal.id, .time)
                used.insert(meal.id)
            }
        }

        return candidates.enumerated().map { index, candidate in
            let (id, basis) = links[index]
            guard let id, let meal = planned.first(where: { $0.id == id }) else {
                return MealLogMatch(plannedMealID: nil, decision: .offPlan, basis: .none, alreadyLogged: false,
                                    plannedItemIDs: Array(repeating: nil, count: candidate.items.count))
            }
            let itemIDs = itemLinks(candidate.items, meal: meal)
            let decision: MealLogDecision = candidate.asPlanned || matchesPlan(candidate.items, meal: meal) ? .done : .adjusted
            return MealLogMatch(plannedMealID: id, decision: decision, basis: basis, alreadyLogged: meal.isLogged,
                                plannedItemIDs: itemIDs)
        }
    }

    /// Itens iguais aos do plano: cada item do plano tem um correspondente (nome, mesma unidade, ±25%) e não sobra item.
    static func matchesPlan(_ items: [MealLogCandidate.Item], meal: MealLogPlannedMeal) -> Bool {
        guard !items.isEmpty, items.count == meal.items.count else { return false }
        var remaining = meal.items
        for item in items {
            guard let quantity = item.quantity, quantity > 0,
                  let index = remaining.firstIndex(where: { planned in
                      MealLogText.namesMatch(item.name, planned.name) && planned.unit == item.unit
                          && planned.quantity > 0 && abs(quantity - planned.quantity) / planned.quantity <= quantityTolerance
                  }) else { return false }
            remaining.remove(at: index)
        }
        return remaining.isEmpty
    }

    /// Item do plano de cada item do rascunho: o id sugerido (se for da refeição) ou o primeiro nome que casa,
    /// sem repetir.
    static func itemLinks(_ items: [MealLogCandidate.Item], meal: MealLogPlannedMeal) -> [UUID?] {
        var used: Set<UUID> = []
        var result: [UUID?] = Array(repeating: nil, count: items.count)
        for (index, item) in items.enumerated() {
            if let id = item.plannedItemID, meal.items.contains(where: { $0.id == id }), !used.contains(id) {
                result[index] = id
                used.insert(id)
            }
        }
        for (index, item) in items.enumerated() where result[index] == nil {
            if let planned = meal.items.first(where: { !used.contains($0.id) && MealLogText.namesMatch(item.name, $0.name) }) {
                result[index] = planned.id
                used.insert(planned.id)
            }
        }
        return result
    }

    private static func nameMatch(_ candidate: MealLogCandidate, in planned: [MealLogPlannedMeal],
                                  excluding used: Set<UUID>) -> MealLogPlannedMeal? {
        let available = planned.filter { !used.contains($0.id) }
        if let label = candidate.label.map(MealLogText.normalize), !label.isEmpty {
            if let exact = available.first(where: { MealLogText.normalize($0.name) == label }) { return exact }
            if let close = available.first(where: { MealLogText.namesMatch($0.name, label) }) { return close }
        }
        // Refeição típica ("almoço") contra o nome do plano: o sinônimo mais longo primeiro ("lanche da tarde" antes de "lanche").
        for synonym in candidate.slot.synonyms.sorted(by: { $0.count > $1.count }) {
            let matches = available.filter { MealLogText.normalize($0.name).hasPrefix(synonym) || MealLogText.normalize($0.name) == synonym }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1, let minutes = candidate.minutesFromMidnight {
                return matches.min { abs($0.minutesFromMidnight - minutes) < abs($1.minutesFromMidnight - minutes) }
            }
            if let first = matches.first { return first }
        }
        return nil
    }
}

/// Comparação de nomes tolerante (sem acento, sem caixa, palavras inteiras).
enum MealLogText {
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Iguais depois de normalizar, ou um contém o outro como palavras inteiras ("arroz" ~ "arroz integral").
    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalize(lhs), b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return " \(long) ".contains(" \(short) ")
    }

    /// "HH:MM" → minutos desde a meia-noite.
    static func minutes(fromTime text: String?) -> Int? {
        guard let parts = text?.split(separator: ":"), parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - Revisão editável

/// Item estimado, editável na revisão. Valores ausentes ficam `nil` (ausente ≠ zero).
struct MealLogReviewItem: Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// `nil` = a IA não estimou: bloqueia "Registrar" até o usuário informar.
    var quantity: Double?
    var unit: FoodUnit
    var values: NutrientValues
    var kcalRange: MealLogRange?
    var confidence: MealLogConfidence
    var note: String?
    var plannedItemID: UUID?

    var hasQuantity: Bool { (quantity ?? 0) > 0 }

    /// Muda a quantidade recalculando kcal, macros e a faixa na proporção (só quando há quantidade anterior > 0).
    mutating func setQuantity(_ newValue: Double) {
        guard newValue > 0 else { quantity = nil; return }
        if let old = quantity, old > 0 {
            let factor = newValue / old
            values = values.scaled(by: factor)
            kcalRange = kcalRange?.scaled(by: factor)
        }
        quantity = newValue
    }
}

/// Pergunta pendente da IA, presa a uma refeição/item do rascunho.
struct MealLogQuestion: Sendable, Hashable, Identifiable {
    var id = UUID()
    var mealID: UUID?
    var itemID: UUID?
    var text: String
    var options: [String]
}

/// Refeição do rascunho na revisão.
struct MealLogReviewMeal: Sendable, Hashable, Identifiable {
    var id = UUID()
    var slot: MealLogSlot
    var label: String?
    /// Horário dito (minutos desde a meia-noite); `nil` = horário do plano (vinculada) ou o típico.
    var minutesFromMidnight: Int?
    /// Refeição do plano vinculada (`nil` = fora da dieta).
    var plannedMealID: UUID?
    var decision: MealLogDecision
    /// A refeição vinculada já tinha registro quando o rascunho foi montado (registrar substitui).
    var alreadyLogged: Bool
    /// Entra no "Registrar". Refeição já registrada começa fora ("Substituir o registro" liga).
    var isIncluded: Bool
    var items: [MealLogReviewItem]

    /// Totais estimados (o que "Ajustada"/"Fora da dieta" grava).
    var estimatedTotals: NutrientValues {
        let totals = NutritionTotals.totals(items.map { NutritionTotals.Entry(values: $0.values) })
        return NutrientValues(kcal: totals.kcal, protein: totals.protein, carbs: totals.carbs, fat: totals.fat, fiber: totals.fiber)
    }
}

/// Problema que impede "Registrar".
enum MealLogIssue: Sendable, Hashable {
    /// Item sem quantidade (diz qual).
    case missingQuantity(mealID: UUID, itemID: UUID, name: String)
    /// Refeição a registrar sem nenhum item (ajustada/fora da dieta).
    case emptyMeal(mealID: UUID)
    /// "Feita" ou "Ajustada" sem refeição do plano.
    case missingLink(mealID: UUID)
    /// Duas refeições do rascunho vinculadas à mesma refeição do plano.
    case duplicateLink(plannedMealID: UUID)
    /// Nada a registrar.
    case nothingToApply
}

/// Rascunho revisável (proposta §6): o usuário edita itens, quantidade, vínculo e estado antes de "Registrar".
struct MealLogReview: Sendable, Hashable {
    /// Dia do registro (início do dia no calendário do app).
    var day: Date
    var meals: [MealLogReviewMeal]
    /// Refeições do plano do dia no momento da análise (para trocar o vínculo).
    var planned: [MealLogPlannedMeal]
    var notSeen: [String]
    var questions: [MealLogQuestion]
    /// O plano do dia foi enviado ao provedor ("Dieta" compartilhada).
    var planWasShared: Bool

    var hasPlan: Bool { !planned.isEmpty }

    var includedMeals: [MealLogReviewMeal] { meals.filter(\.isIncluded) }

    /// Fração das kcal estimadas vinda de itens de confiança baixa que dispara o aviso de atenção.
    static let lowConfidenceShare = 0.5

    /// Itens incluídos com kcal estimada; "Feita" conta os valores do plano (não a estimativa).
    var totals: NutrientValues {
        var entries: [NutritionTotals.Entry] = []
        for meal in includedMeals {
            if meal.decision == .done, let planned = planned.first(where: { $0.id == meal.plannedMealID }) {
                entries += planned.items.map { NutritionTotals.Entry(values: $0.values) }
            } else {
                entries += meal.items.map { NutritionTotals.Entry(values: $0.values) }
            }
        }
        let t = NutritionTotals.totals(entries)
        return NutrientValues(kcal: t.kcal, protein: t.protein, carbs: t.carbs, fat: t.fat, fiber: t.fiber)
    }

    /// Faixa total de kcal das refeições estimadas incluídas (item sem faixa entra com o próprio valor).
    var kcalRange: MealLogRange? {
        let items = includedMeals.filter { $0.decision != .done }.flatMap(\.items)
        guard items.contains(where: { $0.kcalRange != nil }) else { return nil }
        var low = 0.0, high = 0.0
        for item in items {
            if let range = item.kcalRange { low += range.min; high += range.max } else if let kcal = item.values.kcal {
                low += kcal; high += kcal
            }
        }
        return MealLogRange(min: low, max: high)
    }

    /// Itens que serão gravados como estimados pela IA.
    var estimatedItemCount: Int { includedMeals.filter { $0.decision != .done }.reduce(0) { $0 + $1.items.count } }

    /// Mais da metade das kcal estimadas vem de itens de confiança baixa (aviso no topo; não bloqueia).
    var isLowConfidence: Bool {
        let items = meals.flatMap(\.items)
        let total = items.compactMap(\.values.kcal).reduce(0, +)
        guard total > 0 else { return !items.isEmpty && items.allSatisfy { $0.confidence == .low } }
        let low = items.filter { $0.confidence == .low }.compactMap(\.values.kcal).reduce(0, +)
        return low / total > Self.lowConfidenceShare
    }

    var issues: [MealLogIssue] {
        let included = includedMeals
        guard !included.isEmpty else { return [.nothingToApply] }
        var result: [MealLogIssue] = []
        var seen: Set<UUID> = []
        for meal in included {
            if meal.decision != .offPlan {
                guard let id = meal.plannedMealID else { result.append(.missingLink(mealID: meal.id)); continue }
                if !seen.insert(id).inserted { result.append(.duplicateLink(plannedMealID: id)) }
            }
            // "Feita" grava o plano: os itens estimados não precisam estar completos.
            guard meal.decision != .done else { continue }
            if meal.items.isEmpty { result.append(.emptyMeal(mealID: meal.id)) }
            for item in meal.items where !item.hasQuantity {
                result.append(.missingQuantity(mealID: meal.id, itemID: item.id, name: item.name))
            }
        }
        return result
    }

    var canApply: Bool { issues.isEmpty }

    /// Troca o vínculo de uma refeição (ou tira, com `nil`): recalcula o estado padrão, "já registrada" e os itens do plano.
    mutating func relink(mealID: UUID, to plannedMealID: UUID?) {
        guard let index = meals.firstIndex(where: { $0.id == mealID }) else { return }
        var meal = meals[index]
        guard let plannedMealID, let target = planned.first(where: { $0.id == plannedMealID }) else {
            meal.plannedMealID = nil
            meal.decision = .offPlan
            meal.alreadyLogged = false
            meal.isIncluded = true
            meal.items = meal.items.map { var item = $0; item.plannedItemID = nil; return item }
            meals[index] = meal
            return
        }
        let candidates = meal.items.map { MealLogCandidate.Item(name: $0.name, quantity: $0.quantity, unit: $0.unit) }
        let links = MealLogMatcher.itemLinks(candidates, meal: target)
        for i in meal.items.indices { meal.items[i].plannedItemID = links[i] }
        meal.plannedMealID = plannedMealID
        meal.decision = MealLogMatcher.matchesPlan(candidates, meal: target) ? .done : .adjusted
        meal.alreadyLogged = target.isLogged
        meal.isIncluded = !target.isLogged
        meals[index] = meal
    }
}
