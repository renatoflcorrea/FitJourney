import Foundation
import SwiftUI

// Lógica de apresentação da importação com IA, sem SwiftUI de layout: testável e sem rede.

// MARK: - Etapas da análise

enum ImportAnalysisPresentation {
    struct Output: Equatable {
        var title: String
        var subtitle: String?
        var steps: [FJAnalysisStep]
    }

    /// A partir de quanto tempo a chamada é "lenta" (o subtítulo pede para manter o app aberto).
    static let slowAfter: Duration = .seconds(60)

    /// Título, subtítulo e etapas derivados do estado da sessão. Nada de barra por tempo: sem fração real, só o orbe.
    /// O subtítulo mostra o tempo decorrido (verdadeiro), sem prometer duração nem aviso ao terminar.
    static func make(kind: ImportSession.Kind, attachments: [AttachmentMetadata], providerName: String,
                     programImport: ProgramImport?, nutritionImport: NutritionImport?, slow: Bool,
                     elapsed: Duration? = nil) -> Output {
        let isRevision = programImport != nil || nutritionImport != nil
        let count = attachments.count
        var steps: [FJAnalysisStep] = []
        let title: String
        if isRevision {
            title = String(localized: "Aplicando suas respostas…")
            steps.append(FJAnalysisStep(id: "found", title: foundTitle(kind: kind, programImport: programImport, nutritionImport: nutritionImport),
                                        state: .done, isFinding: true))
            steps.append(FJAnalysisStep(id: "revise", title: String(localized: "Ajustando o que você respondeu"), state: .active))
        } else {
            title = count == 1 ? String(localized: "Lendo \(attachments[0].filename)…") : String(localized: "Lendo \(count) arquivos…")
            steps.append(FJAnalysisStep(id: "prepare", title: String(localized: "Arquivos preparados"), state: .done))
            steps.append(FJAnalysisStep(id: "sent", title: count == 1 ? String(localized: "1 arquivo enviado") : String(localized: "\(count) arquivos enviados"),
                                        detail: kindSummary(attachments), state: .done))
            steps.append(FJAnalysisStep(id: "read", title: kind == .program ? String(localized: "Lendo exercícios e séries") : String(localized: "Lendo refeições e quantidades"),
                                        state: .active))
            steps.append(FJAnalysisStep(id: "match", title: kind == .program ? String(localized: "Casar com a sua biblioteca") : String(localized: "Conferir calorias e quantidades"),
                                        state: .pending))
        }
        let clock = elapsed.map { $0.formatted(.time(pattern: .minuteSecond)) }
        let subtitle: String
        switch (slow, clock) {
        case let (true, clock?):
            subtitle = String(localized: "Está demorando mais que o normal (\(clock)). Mantenha o FitJourney aberto.")
        case (true, nil):
            subtitle = String(localized: "Está demorando mais que o normal. Mantenha o FitJourney aberto.")
        case let (false, clock?):
            subtitle = String(localized: "Enviados a \(providerName) · \(clock)")
        case (false, nil):
            subtitle = String(localized: "Enviados a \(providerName)")
        }
        return Output(title: title, subtitle: subtitle, steps: steps)
    }

    /// "2 PDFs · 1 foto".
    static func kindSummary(_ attachments: [AttachmentMetadata]) -> String? {
        var parts: [String] = []
        let pdfs = attachments.filter { $0.kind == .pdf }.count
        let photos = attachments.filter { $0.kind == .image }.count
        let texts = attachments.filter { $0.kind == .text }.count
        if pdfs > 0 { parts.append(pdfs == 1 ? String(localized: "1 PDF") : String(localized: "\(pdfs) PDFs")) }
        if photos > 0 { parts.append(photos == 1 ? String(localized: "1 foto") : String(localized: "\(photos) fotos")) }
        if texts > 0 { parts.append(texts == 1 ? String(localized: "1 texto") : String(localized: "\(texts) textos")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func foundTitle(kind: ImportSession.Kind, programImport: ProgramImport?, nutritionImport: NutritionImport?) -> String {
        switch kind {
        case .program:
            let routines = programImport?.routines.count ?? 0
            return routines == 1 ? String(localized: "Encontrei 1 ficha") : String(localized: "Encontrei \(routines) fichas")
        case .nutrition:
            let meals = nutritionImport?.days.first?.meals.count ?? 0
            return meals == 1 ? String(localized: "Encontrei 1 refeição") : String(localized: "Encontrei \(meals) refeições")
        }
    }
}

// MARK: - Resumo da entrevista

enum ImportOverview {
    /// "Entendi um programa com 4 fichas e 27 exercícios. Faltam 5 detalhes."
    static func summary(kind: ImportSession.Kind, programImport: ProgramImport?, nutritionImport: NutritionImport?,
                        selected: Set<Int>, pending: Int) -> String {
        let base: String
        switch kind {
        case .program:
            let chosen = (programImport?.routines ?? []).enumerated().filter { selected.contains($0.offset) }.map(\.element)
            let exercises = chosen.reduce(0) { $0 + $1.exercises.count }
            base = String(localized: "Entendi um programa com \(plural(chosen.count, one: "ficha", other: "fichas")) e \(plural(exercises, one: "exercício", other: "exercícios")).")
        case .nutrition:
            let chosen = (nutritionImport?.days ?? []).enumerated().filter { selected.contains($0.offset) }.map(\.element)
            let meals = chosen.reduce(0) { $0 + $1.meals.count }
            let items = chosen.flatMap(\.meals).reduce(0) { $0 + $1.items.count }
            base = String(localized: "Entendi uma dieta com \(plural(meals, one: "refeição", other: "refeições")) e \(plural(items, one: "alimento", other: "alimentos")).")
        }
        guard pending > 0 else { return base }
        return base + " " + (pending == 1 ? String(localized: "Falta 1 detalhe.") : String(localized: "Faltam \(pending) detalhes."))
    }

    private static func plural(_ n: Int, one: String.LocalizationValue, other: String.LocalizationValue) -> String {
        "\(n) " + String(localized: n == 1 ? one : other)
    }
}

// MARK: - Perguntas

/// Qual controle a UI mostra para uma `ImportQuestion` (separado do layout para ser testável).
enum ImportQuestionControl: Equatable {
    case chips([FJQuickReply], allowsFreeText: Bool)
    case multi([FJQuickReply])
    case number(NumberSpec)
    case exercise(suggestions: [FJQuickReply], allowsNew: Bool)
    case text(placeholder: String?)

    struct NumberSpec: Equatable {
        var units: [String]
        var defaultUnit: String
        var value: Double
        var range: ClosedRange<Double>
        var step: Double
        var fractionDigits: Int
        /// Pergunta de baixa confiança: "Manter o que li" confirma o valor atual.
        var offersKeep: Bool
        /// Valores comuns em chips (60 s · 90 s · 120 s).
        var quickValues: [Double]
    }

    static func make(for question: ImportQuestion) -> ImportQuestionControl {
        switch question.kind {
        case let .choice(options):
            if case .ambiguity = question.field {
                return .chips(options.map(reply), allowsFreeText: true)
            }
            return .chips(options.map(reply), allowsFreeText: false)
        case let .multiChoice(options):
            return .multi(options.map(reply))
        case let .number(units, defaultUnit, suggested):
            return .number(numberSpec(question, units: units, defaultUnit: defaultUnit, suggested: suggested))
        case let .exercise(suggestions, allowsNew):
            return .exercise(suggestions: suggestions.map(reply), allowsNew: allowsNew)
        case let .text(placeholder):
            return .text(placeholder: placeholder)
        }
    }

    private static func reply(_ option: ImportQuestion.Option) -> FJQuickReply {
        FJQuickReply(option.label, id: option.id)
    }

    private static func numberSpec(_ question: ImportQuestion, units: [String], defaultUnit: String, suggested: Double?) -> NumberSpec {
        let keep = question.gapKind == .lowConfidence
        switch question.field {
        case .exerciseLoad:
            return NumberSpec(units: units, defaultUnit: defaultUnit, value: suggested ?? 0, range: 0...1000, step: 0.5,
                              fractionDigits: 1, offersKeep: keep, quickValues: [])
        case .exerciseReps:
            return NumberSpec(units: units, defaultUnit: defaultUnit, value: suggested ?? 10, range: 1...100, step: 1,
                              fractionDigits: 0, offersKeep: keep, quickValues: [8, 10, 12, 15])
        case .itemQuantity:
            let grams = defaultUnit == "g" || defaultUnit == "ml"
            return NumberSpec(units: units, defaultUnit: defaultUnit, value: suggested ?? (grams ? 100 : 1), range: 0...5000,
                              step: grams ? 10 : 0.5, fractionDigits: grams ? 0 : 1, offersKeep: keep, quickValues: [])
        default:
            return NumberSpec(units: units, defaultUnit: defaultUnit, value: suggested ?? 1, range: 0...999, step: 1,
                              fractionDigits: 0, offersKeep: keep, quickValues: [])
        }
    }
}

/// Pergunta respondida, recolhida numa linha com `checkmark`.
struct InterviewHistoryItem: Identifiable, Equatable {
    let id: String
    let prompt: String
    let answer: String
}

enum ImportAnswerSummary {
    /// Texto curto da resposta para a linha recolhida e para o balão do usuário.
    static func text(question: ImportQuestion, answer: ImportAnswer) -> String {
        switch answer {
        case let .choice(id):
            return options(of: question).first { $0.id == id }?.label ?? id
        case let .choices(ids):
            let list = options(of: question)
            return ids.map { id in list.first { $0.id == id }?.label ?? id }.joined(separator: ", ")
        case let .number(value, unit):
            return "\(FJFormat.number(value, maxFractionDigits: 1)) \(unit)".trimmingCharacters(in: .whitespaces)
        case let .exercise(id):
            if id == ImportQuestion.newExerciseOptionID { return String(localized: "Criar como exercício novo") }
            return options(of: question).first { $0.id == id }?.label ?? id
        case let .text(value):
            if case .exercise = question.field { return String(localized: "Exercício novo: \(value)") }
            return value
        case .keep:
            return String(localized: "Mantido como li")
        }
    }

    private static func options(of question: ImportQuestion) -> [ImportQuestion.Option] {
        switch question.kind {
        case let .choice(list), let .multiChoice(list): list
        case let .exercise(list, _): list
        default: []
        }
    }
}

// MARK: - Fichas / variações encontradas

struct ImportGroupCardModel: Identifiable, Equatable, Hashable {
    let id: Int
    var name: String
    var symbol: String
    var colorName: String
    var detail: String
    var source: ImportSource?
    var confidence: FJConfidence
    var attentionCount: Int
    var isSelected: Bool
    var items: [String]
}

enum ImportReviewPresentation {
    // MARK: Confiança

    static func confidence(_ value: ImportConfidence) -> FJConfidence {
        switch value {
        case .high: .high
        case .medium: .medium
        case .low: .low
        }
    }

    static func lowest(_ values: [FJConfidence]) -> FJConfidence { values.min() ?? .high }

    /// Confiança de um exercício: a menor entre ele e as suas séries; motivo legível quando não é alta.
    static func exerciseConfidence(_ exercise: ProgramImport.ExerciseImport, matched: Bool) -> (FJConfidence, String?) {
        var level = confidence(exercise.confidence)
        var reason: String?
        for set in exercise.sets {
            let setLevel = confidence(set.confidence)
            if ProgramInterview.isLoadUncertain(set) {
                level = min(level, .low)
                if let written = set.loadAsWritten.nonEmpty {
                    reason = String(localized: "carga ilegível: li “\(written)”")
                } else {
                    reason = String(localized: "carga com dúvida")
                }
            } else if setLevel < level {
                level = setLevel
            }
        }
        if reason == nil, !matched {
            reason = String(localized: "não está na sua biblioteca; será criado")
            level = min(level, .medium)
        }
        if reason == nil, level < .high { reason = String(localized: "a IA ficou em dúvida") }
        return (level, level == .high ? nil : reason)
    }

    // MARK: Cartões de fichas

    static func routineCards(_ extraction: ProgramImport, selected: Set<Int>, overrides: [Int: ImportUIState.RoutineOverride],
                             colorOffset: Int) -> [ImportGroupCardModel] {
        var position = 0
        return extraction.routines.enumerated().map { index, routine in
            let override = overrides[index]
            let letters = Array("ABCDEFGHIJKL")
            let isSelected = selected.contains(index)
            let slot = isSelected ? selected.filter { $0 < index }.count : position
            if isSelected { position += 1 }
            let name = override?.name.nonEmpty ?? routine.name.nonEmpty ?? String(localized: "Ficha \(String(letters[min(slot, letters.count - 1)]))")
            let symbol = override?.symbol.nonEmpty ?? routine.symbol.nonEmpty.map { String($0.prefix(2)) }
                ?? String(letters[min(slot, letters.count - 1)])
            let color = override?.colorName.nonEmpty ?? FJRoutineColor.suggested(forIndex: colorOffset + slot).rawValue
            let results = routine.exercises.map { exerciseConfidence($0, matched: true) }
            let level = lowest([confidence(routine.confidence)] + results.map(\.0))
            let attention = results.filter { $0.0 < .high }.count
            let count = routine.exercises.count
            return ImportGroupCardModel(
                id: index, name: name, symbol: symbol, colorName: color,
                detail: count == 1 ? String(localized: "1 exercício") : String(localized: "\(count) exercícios"),
                source: routine.source, confidence: level, attentionCount: attention, isSelected: isSelected,
                items: routine.exercises.map(\.displayName))
        }
    }

    static func dayCards(_ extraction: NutritionImport, selected: Set<Int>) -> [ImportGroupCardModel] {
        extraction.days.enumerated().map { index, day in
            let level = lowest([confidence(day.confidence)] + day.meals.map { confidence($0.confidence) })
            let attention = day.meals.flatMap(\.items).filter { $0.quantity == nil || $0.confidence == .low }.count
            let meals = day.meals.count
            return ImportGroupCardModel(
                id: index, name: day.name.nonEmpty ?? String(localized: "Variação \(index + 1)"), symbol: "", colorName: "green",
                detail: meals == 1 ? String(localized: "1 refeição") : String(localized: "\(meals) refeições"),
                source: day.source, confidence: level, attentionCount: attention, isSelected: selected.contains(index),
                items: day.meals.map { $0.name.nonEmpty ?? String(localized: "Refeição") })
        }
    }
}

// MARK: - Revisão final

struct ReviewExerciseRow: Identifiable, Equatable {
    let id: String
    var name: String
    var prescription: String
    var isNew: Bool
    var confidence: FJConfidence
    var reason: String?
}

struct ReviewRoutineCard: Identifiable, Equatable {
    let id: Int
    var name: String
    var symbol: String
    var colorName: String
    var source: ImportSource?
    var exercises: [ReviewExerciseRow]
    var confidence: FJConfidence
    var attentionCount: Int {
        exercises.filter { $0.confidence < .high }.count
    }
    var needsCheck: Bool { attentionCount > 0 }
}

struct ReviewItemRow: Identifiable, Equatable {
    let id: String
    var name: String
    var detail: String
    var kcal: Double?
    var isEstimated: Bool
    var needsCheck: Bool
    var substitutions: Int
}

struct ReviewMealCard: Identifiable, Equatable {
    let id: String
    var time: String
    var name: String
    var totalKcal: Double?
    var items: [ReviewItemRow]
    var estimatedCount: Int
    var attentionCount: Int { items.filter(\.needsCheck).count }
}

enum ImportReviewBuilder {
    // MARK: Treino

    /// Cartões por ficha a partir do rascunho (o que será gravado) e da extração (confiança e origem).
    static func programCards(draft: ProgramDraft, extraction: ProgramImport, selected: Set<Int>,
                             matches: [[Bool]], overrides: [Int: ImportUIState.RoutineOverride], colorOffset: Int) -> [ReviewRoutineCard] {
        let chosen = extraction.routines.enumerated().filter { selected.contains($0.offset) }
        return draft.routines.enumerated().compactMap { position, routine in
            guard position < chosen.count else { return nil }
            let (index, source) = chosen[position]
            let override = overrides[index]
            let rows = routine.exercises.enumerated().map { e, exercise -> ReviewExerciseRow in
                let matched = matches.indices.contains(position) && matches[position].indices.contains(e) ? matches[position][e] : true
                let imported = source.exercises.indices.contains(e) ? source.exercises[e] : nil
                let evaluation = imported.map { ImportReviewPresentation.exerciseConfidence($0, matched: matched) } ?? (.high, nil)
                return ReviewExerciseRow(id: "\(index).\(e)", name: exercise.name, prescription: prescription(exercise),
                                         isNew: !matched, confidence: evaluation.0, reason: evaluation.1)
            }
            let level = ImportReviewPresentation.lowest([ImportReviewPresentation.confidence(source.confidence)] + rows.map(\.confidence))
            return ReviewRoutineCard(
                id: index, name: override?.name.nonEmpty ?? routine.name,
                symbol: override?.symbol.nonEmpty ?? routine.symbol.nonEmpty ?? String(routine.name.prefix(1)).uppercased(),
                colorName: override?.colorName.nonEmpty ?? FJRoutineColor.suggested(forIndex: colorOffset + position).rawValue,
                source: source.source, exercises: rows, confidence: level)
        }
    }

    /// "4 × 8–12 · 32 kg · 90 s".
    static func prescription(_ exercise: ProgramDraft.ExerciseDraft) -> String {
        let sets = exercise.sets
        guard let first = sets.first(where: { $0.kind == .working }) ?? sets.first else { return "—" }
        var parts: [String] = []
        let count = sets.count
        if let hold = first.holdSeconds {
            parts.append("\(count) × \(hold) s")
        } else if let cardio = first.cardio {
            _ = cardio
            parts.append(String(localized: "cardio"))
        } else {
            parts.append("\(count) × \(repsText(first.repTarget))")
        }
        if let load = first.load {
            switch load.kind {
            case .weight: parts.append("\(FJFormat.number(load.value, maxFractionDigits: 1)) \(load.unit.rawValue)")
            case .bodyweight:
                parts.append(load.value == 0 ? String(localized: "PC") : String(localized: "PC \(load.value > 0 ? "+" : "−")\(FJFormat.number(abs(load.value), maxFractionDigits: 1)) \(load.unit.rawValue)"))
            }
        } else {
            parts.append("— kg")
        }
        if let rest = exercise.restSeconds ?? first.restSeconds { parts.append("\(rest) s") }
        return parts.joined(separator: " · ")
    }

    static func repsText(_ target: ProgramDraft.RepTargetDraft?) -> String {
        guard let target else { return "—" }
        switch target.kind {
        case .fixed: return target.reps.map(String.init) ?? target.min.map(String.init) ?? "—"
        case .range:
            if let min = target.min, let max = target.max { return min == max ? "\(min)" : "\(min)–\(max)" }
            return "—"
        case .amrap: return String(localized: "máx.")
        }
    }

    // MARK: Dieta

    static func mealCards(draft: NutritionPlanDraft, extraction: NutritionImport, selected: Set<Int>) -> [ReviewMealCard] {
        // A revisão mostra o primeiro dia escolhido (as variações aparecem como chips no cabeçalho).
        guard let dayIndex = selected.sorted().first, extraction.days.indices.contains(dayIndex),
              let draftDay = draft.days.first else { return [] }
        let day = extraction.days[dayIndex]
        return draftDay.meals.enumerated().map { m, meal in
            let source = day.meals.indices.contains(m) ? day.meals[m] : nil
            let rows = meal.items.enumerated().map { i, item -> ReviewItemRow in
                let imported = source.flatMap { $0.items.indices.contains(i) ? $0.items[i] : nil }
                let estimated = imported.map { $0.kcal == nil } ?? false
                let missingQuantity = imported.map { $0.quantity == nil } ?? false
                let low = imported.map { $0.confidence == .low } ?? false
                let quantity = missingQuantity ? "—" : "\(FJFormat.number(item.quantity, maxFractionDigits: 1)) \(item.unit.symbol)"
                var detail = quantity
                if let kcal = item.kcal { detail += " · \(FJFormat.number(kcal, maxFractionDigits: 0)) kcal" }
                return ReviewItemRow(id: "\(m).\(i)", name: item.name, detail: detail, kcal: item.kcal, isEstimated: estimated,
                                     needsCheck: missingQuantity || low, substitutions: item.substitutions.count)
            }
            let total = rows.compactMap(\.kcal).reduce(0, +)
            return ReviewMealCard(id: "\(m)", time: meal.time, name: meal.name, totalKcal: rows.contains { $0.kcal != nil } ? total : nil,
                                  items: rows, estimatedCount: rows.filter(\.isEstimated).count)
        }
    }
}
