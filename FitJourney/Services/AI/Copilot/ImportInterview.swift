import Foundation

// Entrevista do import (SPEC §7A.1): lacunas → perguntas estruturadas → respostas que atualizam a extração
// localmente, sem nova chamada de IA (exceto ambiguidades levantadas pela própria IA, que pedem revisão).

enum ImportGapKind: String, Codable, Sendable, Hashable {
    /// Campo obrigatório ausente (sem ele não dá para criar).
    case missingRequired
    /// A IA marcou baixa confiança (ilegível/adivinhado).
    case lowConfidence
    /// Exercício sem casamento no catálogo (vira exercício novo se o usuário não escolher).
    case unmatchedExercise
    /// Dúvida que a IA levantou (`ambiguities`).
    case ambiguity
}

/// Onde a lacuna está. Índices são da extração (estáveis enquanto ela não é revisada pela IA).
enum ImportField: Codable, Sendable, Hashable {
    case programName
    case scheduleMode
    case routineName(routine: Int)
    case routineWeekdays(routine: Int)
    case exercise(routine: Int, exercise: Int)
    case exerciseReps(routine: Int, exercise: Int)
    case exerciseLoad(routine: Int, exercise: Int)
    case planName
    case dayWeekdays(day: Int)
    case mealTime(day: Int, meal: Int)
    case itemQuantity(day: Int, meal: Int, item: Int)
    case ambiguity(index: Int)

    /// Id estável (chave das respostas).
    var key: String {
        switch self {
        case .programName: "programName"
        case .scheduleMode: "scheduleMode"
        case let .routineName(r): "routineName.\(r)"
        case let .routineWeekdays(r): "routineWeekdays.\(r)"
        case let .exercise(r, e): "exercise.\(r).\(e)"
        case let .exerciseReps(r, e): "exerciseReps.\(r).\(e)"
        case let .exerciseLoad(r, e): "exerciseLoad.\(r).\(e)"
        case .planName: "planName"
        case let .dayWeekdays(d): "dayWeekdays.\(d)"
        case let .mealTime(d, m): "mealTime.\(d).\(m)"
        case let .itemQuantity(d, m, i): "itemQuantity.\(d).\(m).\(i)"
        case let .ambiguity(i): "ambiguity.\(i)"
        }
    }
}

struct ImportGap: Codable, Sendable, Hashable, Identifiable {
    var field: ImportField
    var kind: ImportGapKind
    var isRequired: Bool
    var source: ImportSource?
    var id: String { field.key }
}

/// Pergunta estruturada para a UI. `id` = id da lacuna.
struct ImportQuestion: Codable, Sendable, Hashable, Identifiable {
    struct Option: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var label: String
        var detail: String?
    }

    enum Kind: Codable, Sendable, Hashable {
        /// Uma opção (`ImportAnswer.choice`).
        case choice([Option])
        /// Várias opções (`ImportAnswer.choices`), ex.: dias da semana.
        case multiChoice([Option])
        /// Número com unidade (`ImportAnswer.number`); `suggested` pré-preenche.
        case number(units: [String], defaultUnit: String, suggested: Double?)
        /// Exercício do catálogo (`ImportAnswer.exercise`): sugestões + "criar como novo" (`newExerciseOptionID`).
        case exercise(suggestions: [Option], allowsNew: Bool)
        /// Texto livre (`ImportAnswer.text`); `placeholder` mostra o formato (ex.: "07:30").
        case text(placeholder: String?)
    }

    static let newExerciseOptionID = "new"

    var id: String
    var gapKind: ImportGapKind
    var field: ImportField
    /// Pergunta em pt-BR, curta.
    var prompt: String
    /// Contexto: como estava escrito, onde (arquivo/página), o que a IA notou.
    var detail: String?
    var kind: Kind
    var isRequired: Bool
    var source: ImportSource?
    /// Texto para pré-preencher um campo livre (pergunta de exercício: o nome atual, para "Criar como novo").
    var suggestedText: String? = nil
}

enum ImportAnswer: Codable, Sendable, Hashable {
    case choice(String)
    case choices([String])
    case number(Double, unit: String)
    /// Id de uma sugestão (`catalogKey` ou `exercise:<uuid>`) ou `ImportQuestion.newExerciseOptionID`.
    case exercise(String)
    case text(String)
    /// Confirma o valor atual (baixa confiança → confirmado).
    case keep
}

enum ImportAnswerError: Error, Sendable, Hashable, LocalizedError {
    case unknownQuestion
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unknownQuestion: String(localized: "Essa pergunta não está mais pendente.")
        case let .invalid(reason): reason
        }
    }
}

/// Item do catálogo usado nas perguntas (valor, sem SwiftData).
struct ImportCatalogEntry: Sendable, Hashable {
    var id: UUID
    var name: String
    var catalogKey: String?
    var englishName: String?

    var optionID: String { catalogKey ?? "exercise:\(id.uuidString)" }

    static let libraryOptionPrefix = "exercise:"

    /// Id do exercício da biblioteca (sem `catalogKey`) num id de opção `exercise:<uuid>`.
    static func libraryExerciseID(fromOptionID optionID: String) -> UUID? {
        guard optionID.hasPrefix(libraryOptionPrefix) else { return nil }
        return UUID(uuidString: String(optionID.dropFirst(libraryOptionPrefix.count)))
    }
}

/// Decisão do usuário sobre um exercício importado (pergunta de exercício respondida). Guardada por chave estável
/// (`ProgramInterview.exerciseKey`, o texto como estava no arquivo) para sobreviver à revisão pela IA — que
/// reordena e pode renomear — e valer para o mesmo exercício repetido em outras fichas.
struct ImportExerciseDecision: Codable, Sendable, Hashable {
    /// Nome final (do catálogo/biblioteca ou o digitado para o exercício novo).
    var name: String
    var catalogKey: String?
    /// Exercício da biblioteca do usuário escolhido (sem `catalogKey`); `nil` com `catalogKey` nil = exercício novo.
    var exerciseID: UUID?

    var isNew: Bool { catalogKey == nil && exerciseID == nil }
}

// MARK: - Treino

enum ProgramInterview {
    /// Lacunas das fichas escolhidas, sem as já resolvidas.
    static func gaps(for extraction: ProgramImport, selected: Set<Int>, catalog: [ImportCatalogEntry],
                     resolved: Set<String>) -> [ImportGap] {
        var gaps: [ImportGap] = []
        func add(_ field: ImportField, _ kind: ImportGapKind, required: Bool, _ source: ImportSource?) {
            guard !resolved.contains(field.key) else { return }
            gaps.append(ImportGap(field: field, kind: kind, isRequired: required, source: source))
        }
        if extraction.name.nonEmpty == nil { add(.programName, .missingRequired, required: true, extraction.source) }
        if extraction.scheduleMode == nil { add(.scheduleMode, .missingRequired, required: true, extraction.source) }
        for (r, routine) in extraction.routines.enumerated() where selected.contains(r) {
            if routine.name.nonEmpty == nil { add(.routineName(routine: r), .missingRequired, required: true, routine.source) }
            if extraction.scheduleMode == .weekly, routine.weekdays.isEmpty {
                add(.routineWeekdays(routine: r), .missingRequired, required: true, routine.source)
            }
            for (e, exercise) in routine.exercises.enumerated() {
                let match = matchEntry(exercise, in: catalog)
                if match == nil {
                    add(.exercise(routine: r, exercise: e), .unmatchedExercise, required: false, exercise.source)
                } else if exercise.confidence == .low {
                    add(.exercise(routine: r, exercise: e), .lowConfidence, required: false, exercise.source)
                }
                if exercise.sets.isEmpty || exercise.sets.contains(where: \.needsReps) {
                    add(.exerciseReps(routine: r, exercise: e), .missingRequired, required: true, exercise.source)
                }
                if exercise.sets.contains(where: isLoadUncertain) {
                    add(.exerciseLoad(routine: r, exercise: e), .lowConfidence, required: false, exercise.source)
                }
            }
        }
        for (index, _) in extraction.ambiguities.enumerated() {
            add(.ambiguity(index: index), .ambiguity, required: false, nil)
        }
        return gaps
    }

    static func isLoadUncertain(_ set: ProgramImport.SetImport) -> Bool {
        (set.load == nil && set.loadAsWritten.nonEmpty != nil) || (set.load != nil && set.confidence == .low)
    }

    static func matchEntry(_ exercise: ProgramImport.ExerciseImport, in catalog: [ImportCatalogEntry]) -> ImportCatalogEntry? {
        if let key = exercise.catalogKey.nonEmpty, let hit = catalog.first(where: { $0.catalogKey == key }) { return hit }
        for candidate in [exercise.name.nonEmpty, exercise.asWritten.nonEmpty].compactMap({ $0 }) {
            let target = ExerciseMatcher.normalize(candidate)
            if let hit = catalog.first(where: { ExerciseMatcher.normalize($0.name) == target }) { return hit }
            if let hit = catalog.first(where: { $0.englishName.map(ExerciseMatcher.normalize) == target }) { return hit }
        }
        return nil
    }

    /// Até `limit` exercícios do catálogo mais parecidos (palavras em comum), para a pergunta de exercício.
    static func suggestions(for exercise: ProgramImport.ExerciseImport, in catalog: [ImportCatalogEntry],
                            limit: Int = 3) -> [ImportCatalogEntry] {
        let words = Set(ExerciseMatcher.normalize(exercise.displayName + " " + exercise.asWritten)
            .split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !words.isEmpty else { return [] }
        let scored = catalog.compactMap { entry -> (ImportCatalogEntry, Int)? in
            let entryWords = Set(ExerciseMatcher.normalize(entry.name + " " + (entry.englishName ?? ""))
                .split(separator: " ").map(String.init))
            let score = words.intersection(entryWords).count
            return score > 0 ? (entry, score) : nil
        }
        var result: [ImportCatalogEntry] = []
        if let exact = matchEntry(exercise, in: catalog) { result.append(exact) }
        for (entry, _) in scored.sorted(by: { ($0.1, $1.0.name) > ($1.1, $0.0.name) }) where !result.contains(entry) {
            result.append(entry)
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    static func question(for gap: ImportGap, in extraction: ProgramImport, catalog: [ImportCatalogEntry]) -> ImportQuestion? {
        func make(_ prompt: String, _ detail: String?, _ kind: ImportQuestion.Kind) -> ImportQuestion {
            ImportQuestion(id: gap.id, gapKind: gap.kind, field: gap.field, prompt: prompt,
                           detail: InterviewText.detail(detail, source: gap.source), kind: kind,
                           isRequired: gap.isRequired, source: gap.source)
        }
        switch gap.field {
        case .programName:
            return make(String(localized: "Qual o nome do programa?"),
                        String(localized: "\(extraction.routines.count) fichas detectadas."),
                        .text(placeholder: String(localized: "Ex.: ABCD Hipertrofia")))
        case .scheduleMode:
            let options = [
                ImportQuestion.Option(id: ScheduleMode.weekly.rawValue, label: String(localized: "Dias fixos da semana"),
                                      detail: String(localized: "Cada ficha em dias marcados")),
                ImportQuestion.Option(id: ScheduleMode.sequential.rawValue, label: String(localized: "Rodízio A → B → C"),
                                      detail: String(localized: "A próxima ficha depois da última feita")),
                ImportQuestion.Option(id: ScheduleMode.free.rawValue, label: String(localized: "Livre"),
                                      detail: String(localized: "Escolho a ficha no dia")),
            ]
            return make(String(localized: "Como você segue as fichas?"), nil, .choice(options))
        case let .routineName(r):
            guard extraction.routines.indices.contains(r) else { return nil }
            let names = extraction.routines[r].exercises.prefix(3).map(\.displayName).joined(separator: ", ")
            return make(String(localized: "Qual o nome da ficha \(r + 1)?"),
                        names.isEmpty ? nil : String(localized: "Começa com: \(names)"),
                        .text(placeholder: String(localized: "Ex.: Peito e tríceps")))
        case let .routineWeekdays(r):
            guard extraction.routines.indices.contains(r) else { return nil }
            let name = extraction.routines[r].name.nonEmpty ?? String(localized: "ficha \(r + 1)")
            return make(String(localized: "Em que dias você faz \(name)?"), nil, .multiChoice(InterviewText.weekdayOptions))
        case let .exercise(r, e):
            guard let exercise = exercise(extraction, r, e) else { return nil }
            let options = suggestions(for: exercise, in: catalog).map {
                ImportQuestion.Option(id: $0.optionID, label: $0.name, detail: nil)
            }
            let prompt = gap.kind == .unmatchedExercise
                ? String(localized: "Qual exercício é “\(exercise.asWritten)”?")
                : String(localized: "Confere o exercício “\(exercise.asWritten)”?")
            var question = make(prompt, exercise.notes, .exercise(suggestions: options, allowsNew: true))
            question.suggestedText = exercise.displayName
            return question
        case let .exerciseReps(r, e):
            guard let exercise = exercise(extraction, r, e) else { return nil }
            return make(String(localized: "Quantas repetições em \(exercise.displayName)?"),
                        exercise.notes ?? String(localized: "Use um número (10) ou uma faixa (8-12)."),
                        .number(units: ["reps"], defaultUnit: "reps", suggested: nil))
        case let .exerciseLoad(r, e):
            guard let exercise = exercise(extraction, r, e) else { return nil }
            let uncertain = exercise.sets.first(where: isLoadUncertain)
            let written = uncertain?.loadAsWritten.nonEmpty.map { String(localized: "Escrito: \($0)") }
            let unit = uncertain?.load?.unit.rawValue ?? WeightUnit.kg.rawValue
            return make(String(localized: "Qual a carga em \(exercise.displayName)?"),
                        [written, uncertain?.notes.nonEmpty].compactMap { $0 }.joined(separator: " · ").nonEmpty,
                        .number(units: [WeightUnit.kg.rawValue, WeightUnit.lb.rawValue], defaultUnit: unit,
                                suggested: uncertain?.load?.value))
        case let .ambiguity(index):
            guard extraction.ambiguities.indices.contains(index) else { return nil }
            return InterviewText.ambiguityQuestion(extraction.ambiguities[index], gap: gap)
        default:
            return nil
        }
    }

    private static func exercise(_ extraction: ProgramImport, _ r: Int, _ e: Int) -> ProgramImport.ExerciseImport? {
        guard extraction.routines.indices.contains(r), extraction.routines[r].exercises.indices.contains(e) else { return nil }
        return extraction.routines[r].exercises[e]
    }

    /// Aplica a resposta na extração. Lança se a resposta não serve para a pergunta.
    static func apply(_ answer: ImportAnswer, to field: ImportField, in extraction: inout ProgramImport,
                      catalog: [ImportCatalogEntry]) throws {
        switch (field, answer) {
        case let (.programName, .text(text)):
            extraction.name = try InterviewText.requireText(text, max: 80)
        case let (.scheduleMode, .choice(id)):
            guard let mode = ScheduleMode(rawValue: id) else { throw ImportAnswerError.invalid(String(localized: "Escolha uma opção.")) }
            extraction.scheduleMode = mode
        case let (.routineName(r), .text(text)):
            try check(extraction.routines.indices.contains(r))
            extraction.routines[r].name = try InterviewText.requireText(text, max: 80)
        case let (.routineWeekdays(r), .choices(ids)):
            try check(extraction.routines.indices.contains(r))
            let days = ids.compactMap(Weekday.init(rawValue:))
            guard !days.isEmpty else { throw ImportAnswerError.invalid(String(localized: "Escolha ao menos um dia.")) }
            extraction.routines[r].weekdays = ProgramImport.unique(days).sorted()
        case let (.exercise(r, e), .exercise(id)):
            try check(exercise(extraction, r, e) != nil)
            if id == ImportQuestion.newExerciseOptionID {
                extraction.routines[r].exercises[e].catalogKey = nil
            } else {
                guard let entry = catalog.first(where: { $0.optionID == id }) else {
                    throw ImportAnswerError.invalid(String(localized: "Exercício não encontrado no catálogo."))
                }
                extraction.routines[r].exercises[e].name = entry.name
                extraction.routines[r].exercises[e].catalogKey = entry.catalogKey
            }
            extraction.routines[r].exercises[e].confidence = .high
        case let (.exercise(r, e), .text(text)):
            try check(exercise(extraction, r, e) != nil)
            extraction.routines[r].exercises[e].name = try InterviewText.requireText(text, max: 80)
            extraction.routines[r].exercises[e].catalogKey = nil
            extraction.routines[r].exercises[e].confidence = .high
        case let (.exercise(r, e), .keep):
            try check(exercise(extraction, r, e) != nil)
            extraction.routines[r].exercises[e].confidence = .high
        case let (.exerciseReps(r, e), .number(value, _)):
            try check(exercise(extraction, r, e) != nil)
            let reps = Int(value.rounded())
            guard (1 ... 100).contains(reps) else { throw ImportAnswerError.invalid(String(localized: "Use de 1 a 100 repetições.")) }
            setReps(.init(kind: .fixed, reps: reps, min: nil, max: nil), r, e, &extraction)
        case let (.exerciseReps(r, e), .text(text)):
            try check(exercise(extraction, r, e) != nil)
            guard let target = InterviewText.parseReps(text) else {
                throw ImportAnswerError.invalid(String(localized: "Use um número (10), uma faixa (8-12) ou “máximo”."))
            }
            setReps(target, r, e, &extraction)
        case let (.exerciseLoad(r, e), .number(value, unitRaw)):
            try check(exercise(extraction, r, e) != nil)
            guard let unit = WeightUnit(rawValue: unitRaw), (0 ... 1000).contains(value) else {
                throw ImportAnswerError.invalid(String(localized: "Informe a carga em kg ou lb."))
            }
            for s in extraction.routines[r].exercises[e].sets.indices where isLoadUncertain(extraction.routines[r].exercises[e].sets[s]) {
                extraction.routines[r].exercises[e].sets[s].load = ProgramDraft.LoadDraft(kind: .weight, value: value, unit: unit)
                extraction.routines[r].exercises[e].sets[s].loadAsWritten = nil
                extraction.routines[r].exercises[e].sets[s].confidence = .high
            }
        case let (.exerciseLoad(r, e), .keep):
            try check(exercise(extraction, r, e) != nil)
            for s in extraction.routines[r].exercises[e].sets.indices { extraction.routines[r].exercises[e].sets[s].confidence = .high }
        default:
            throw ImportAnswerError.invalid(String(localized: "Resposta não combina com a pergunta."))
        }
    }

    // MARK: Decisões estáveis (sobrevivem à revisão pela IA)

    /// Chave estável do exercício: o texto como estava no arquivo, normalizado e sem pontuação ("Máq. 3" = "maq 3"),
    /// ou o nome quando não há texto original. A IA não deve mudar `asWritten` na revisão (o prompt pede).
    static func exerciseKey(_ exercise: ProgramImport.ExerciseImport) -> String? {
        func key(_ text: String) -> String {
            ExerciseMatcher.normalize(String(text.map { $0.isLetter || $0.isNumber ? $0 : " " }))
        }
        let written = key(exercise.asWritten)
        if !written.isEmpty { return written }
        let name = key(exercise.name ?? "")
        return name.isEmpty ? nil : "name:\(name)"
    }

    /// Decisão a partir do exercício já atualizado pela resposta (`apply`).
    static func decision(for exercise: ProgramImport.ExerciseImport, answer: ImportAnswer) -> ImportExerciseDecision {
        var libraryID: UUID?
        if case let .exercise(optionID) = answer { libraryID = ImportCatalogEntry.libraryExerciseID(fromOptionID: optionID) }
        return ImportExerciseDecision(name: exercise.displayName, catalogKey: exercise.catalogKey.nonEmpty, exerciseID: libraryID)
    }

    /// Aplica as decisões a todo exercício com a mesma chave (nome, `catalogKey`, confiança alta).
    static func applyDecisions(_ decisions: [String: ImportExerciseDecision], to extraction: inout ProgramImport) {
        guard !decisions.isEmpty else { return }
        for r in extraction.routines.indices {
            for e in extraction.routines[r].exercises.indices {
                guard let key = exerciseKey(extraction.routines[r].exercises[e]), let decision = decisions[key] else { continue }
                extraction.routines[r].exercises[e].name = decision.name
                extraction.routines[r].exercises[e].catalogKey = decision.catalogKey
                extraction.routines[r].exercises[e].confidence = .high
            }
        }
    }

    /// Ids (`ImportField.key`) das perguntas de exercício já decididas: não viram lacuna de novo.
    static func decidedExerciseFields(in extraction: ProgramImport, decisions: [String: ImportExerciseDecision]) -> Set<String> {
        guard !decisions.isEmpty else { return [] }
        var keys: Set<String> = []
        for (r, routine) in extraction.routines.enumerated() {
            for (e, exercise) in routine.exercises.enumerated() {
                if let key = exerciseKey(exercise), decisions[key] != nil {
                    keys.insert(ImportField.exercise(routine: r, exercise: e).key)
                }
            }
        }
        return keys
    }

    /// Chave estável de um exercício numa ficha (para respostas de repetições/carga): ficha + exercício + ocorrência.
    static func slotKey(routine r: Int, exercise e: Int, in extraction: ProgramImport) -> String? {
        guard let current = exercise(extraction, r, e), let key = exerciseKey(current) else { return nil }
        let routineKeys = ImportStableKey.groupKeys(extraction.routines.map(\.name))
        let occurrence = extraction.routines[r].exercises[..<e].filter { exerciseKey($0) == key }.count
        return "\(routineKeys[r])|\(key)#\(occurrence)"
    }

    /// Exercícios confirmados pelo usuário (um por chave), para a mensagem de revisão.
    static func confirmedExercises(in extraction: ProgramImport, decisions: [String: ImportExerciseDecision])
        -> [CopilotPrompt.ConfirmedExercise] {
        var seen: Set<String> = []
        var result: [CopilotPrompt.ConfirmedExercise] = []
        for exercise in extraction.routines.flatMap(\.exercises) {
            guard let key = exerciseKey(exercise), let decision = decisions[key], seen.insert(key).inserted else { continue }
            result.append(.init(asWritten: exercise.asWritten, name: decision.name, catalogKey: decision.catalogKey))
        }
        return result
    }

    /// Depois da revisão: tira dúvidas que o usuário já respondeu (mesma pergunta) e as sobre o nome/catálogo de um
    /// exercício já decidido — a IA às vezes as reabre, o que levaria a outra revisão (loop).
    static func pruneAmbiguities(_ extraction: inout ProgramImport, decisions: [String: ImportExerciseDecision],
                                 answeredQuestions: Set<String>) {
        let snapshot = extraction
        extraction.ambiguities.removeAll { ambiguity in
            if answeredQuestions.contains(ImportStableKey.question(ambiguity.question)) { return true }
            guard let (r, e) = exercisePath(ambiguity.path), let current = exercise(snapshot, r, e),
                  let key = exerciseKey(current) else { return false }
            return decisions[key] != nil
        }
    }

    /// `routines[r].exercises[e]` (ou `.name`/`.catalogKey`/`.asWritten` dele) → índices; outros caminhos → nil.
    static func exercisePath(_ path: String) -> (Int, Int)? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: #/(?:\$\.)?routines\[(\d+)\]\.exercises\[(\d+)\](?:\.(?:name|catalogKey|asWritten))?/#),
              let r = Int(match.1), let e = Int(match.2) else { return nil }
        return (r, e)
    }

    private static func setReps(_ target: ProgramDraft.RepTargetDraft, _ r: Int, _ e: Int, _ extraction: inout ProgramImport) {
        if extraction.routines[r].exercises[e].sets.isEmpty {
            extraction.routines[r].exercises[e].sets = [ProgramImport.SetImport(
                kind: .working, repTarget: target, holdSeconds: nil, load: nil, loadAsWritten: nil, restSeconds: nil,
                tempo: nil, rir: nil, rpe: nil, cardio: nil, notes: nil, confidence: .high, source: nil)]
            return
        }
        for s in extraction.routines[r].exercises[e].sets.indices where extraction.routines[r].exercises[e].sets[s].needsReps {
            extraction.routines[r].exercises[e].sets[s].repTarget = target
        }
    }

    private static func check(_ condition: Bool) throws {
        if !condition { throw ImportAnswerError.unknownQuestion }
    }
}

// MARK: - Dieta

enum NutritionInterview {
    static func gaps(for extraction: NutritionImport, selected: Set<Int>, resolved: Set<String>) -> [ImportGap] {
        var gaps: [ImportGap] = []
        func add(_ field: ImportField, _ kind: ImportGapKind, required: Bool, _ source: ImportSource?) {
            guard !resolved.contains(field.key) else { return }
            gaps.append(ImportGap(field: field, kind: kind, isRequired: required, source: source))
        }
        if extraction.name.nonEmpty == nil { add(.planName, .missingRequired, required: true, extraction.source) }
        var sawAllDays = false
        for (d, day) in extraction.days.enumerated() where selected.contains(d) {
            if day.weekdays.isEmpty {
                // Só uma variação pode valer "todos os dias"; as outras precisam de dias.
                if sawAllDays { add(.dayWeekdays(day: d), .missingRequired, required: true, day.source) }
                sawAllDays = true
            }
            for (m, meal) in day.meals.enumerated() {
                if meal.minutesFromMidnight == nil { add(.mealTime(day: d, meal: m), .missingRequired, required: true, meal.source) }
                for (i, item) in meal.items.enumerated() {
                    if item.quantity == nil || item.unit == nil {
                        add(.itemQuantity(day: d, meal: m, item: i), .missingRequired, required: true, item.source)
                    } else if item.confidence == .low {
                        add(.itemQuantity(day: d, meal: m, item: i), .lowConfidence, required: false, item.source)
                    }
                }
            }
        }
        for (index, _) in extraction.ambiguities.enumerated() { add(.ambiguity(index: index), .ambiguity, required: false, nil) }
        return gaps
    }

    static func question(for gap: ImportGap, in extraction: NutritionImport) -> ImportQuestion? {
        func make(_ prompt: String, _ detail: String?, _ kind: ImportQuestion.Kind) -> ImportQuestion {
            ImportQuestion(id: gap.id, gapKind: gap.kind, field: gap.field, prompt: prompt,
                           detail: InterviewText.detail(detail, source: gap.source), kind: kind,
                           isRequired: gap.isRequired, source: gap.source)
        }
        switch gap.field {
        case .planName:
            return make(String(localized: "Qual o nome da dieta?"), nil, .text(placeholder: String(localized: "Ex.: Dieta da nutricionista")))
        case let .dayWeekdays(d):
            guard extraction.days.indices.contains(d) else { return nil }
            let name = extraction.days[d].name.nonEmpty ?? String(localized: "variação \(d + 1)")
            return make(String(localized: "Em que dias vale \(name)?"), nil, .multiChoice(InterviewText.weekdayOptions))
        case let .mealTime(d, m):
            guard let meal = meal(extraction, d, m) else { return nil }
            let name = meal.name.nonEmpty ?? String(localized: "refeição \(m + 1)")
            return make(String(localized: "Que horas é \(name)?"), meal.notes, .text(placeholder: "07:30"))
        case let .itemQuantity(d, m, i):
            guard let meal = meal(extraction, d, m), meal.items.indices.contains(i) else { return nil }
            let item = meal.items[i]
            return make(String(localized: "Quanto de \(item.name)?"),
                        [String(localized: "Escrito: \(item.asWritten)"), item.notes.nonEmpty].compactMap { $0 }.joined(separator: " · "),
                        .number(units: FoodUnit.allCases.map(\.rawValue), defaultUnit: (item.unit ?? .serving).rawValue,
                                suggested: item.quantity))
        case let .ambiguity(index):
            guard extraction.ambiguities.indices.contains(index) else { return nil }
            return InterviewText.ambiguityQuestion(extraction.ambiguities[index], gap: gap)
        default:
            return nil
        }
    }

    private static func meal(_ extraction: NutritionImport, _ d: Int, _ m: Int) -> NutritionImport.MealImport? {
        guard extraction.days.indices.contains(d), extraction.days[d].meals.indices.contains(m) else { return nil }
        return extraction.days[d].meals[m]
    }

    static func apply(_ answer: ImportAnswer, to field: ImportField, in extraction: inout NutritionImport) throws {
        switch (field, answer) {
        case let (.planName, .text(text)):
            extraction.name = try InterviewText.requireText(text, max: 80)
        case let (.dayWeekdays(d), .choices(ids)):
            guard extraction.days.indices.contains(d) else { throw ImportAnswerError.unknownQuestion }
            let days = ids.compactMap(Weekday.init(rawValue:))
            guard !days.isEmpty else { throw ImportAnswerError.invalid(String(localized: "Escolha ao menos um dia.")) }
            extraction.days[d].weekdays = ProgramImport.unique(days).sorted()
        case let (.mealTime(d, m), .text(text)):
            guard meal(extraction, d, m) != nil else { throw ImportAnswerError.unknownQuestion }
            guard let minutes = InterviewText.parseTime(text) else {
                throw ImportAnswerError.invalid(String(localized: "Use o formato HH:MM, ex.: 07:30."))
            }
            extraction.days[d].meals[m].time = clockString(minutes: minutes)
        case let (.itemQuantity(d, m, i), .number(value, unitRaw)):
            guard let current = meal(extraction, d, m), current.items.indices.contains(i) else { throw ImportAnswerError.unknownQuestion }
            guard let unit = FoodUnit(rawValue: unitRaw), value > 0, value <= 10_000 else {
                throw ImportAnswerError.invalid(String(localized: "Informe uma quantidade maior que zero."))
            }
            extraction.days[d].meals[m].items[i].quantity = value
            extraction.days[d].meals[m].items[i].unit = unit
            extraction.days[d].meals[m].items[i].confidence = .high
        case let (.itemQuantity(d, m, i), .keep):
            guard let current = meal(extraction, d, m), current.items.indices.contains(i), current.items[i].quantity != nil else {
                throw ImportAnswerError.invalid(String(localized: "Informe a quantidade."))
            }
            extraction.days[d].meals[m].items[i].confidence = .high
        default:
            throw ImportAnswerError.invalid(String(localized: "Resposta não combina com a pergunta."))
        }
    }
}

// MARK: - Chaves estáveis

/// Chaves que não dependem da posição (a revisão pela IA pode reordenar fichas, exercícios e dúvidas).
enum ImportStableKey {
    /// Chave de cada ficha/variação: nome normalizado (ou a posição, sem nome), com sufixo se repetir.
    static func groupKeys(_ names: [String?]) -> [String] {
        var seen: [String: Int] = [:]
        return names.enumerated().map { index, name in
            let base = name.nonEmpty.map(ExerciseMatcher.normalize) ?? "#\(index)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }
    }

    /// Pergunta de dúvida normalizada (para reconhecer a mesma dúvida reaberta pela IA).
    static func question(_ text: String) -> String {
        ExerciseMatcher.normalize(text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)))
    }
}

// MARK: - Textos e parsing

enum InterviewText {
    static var weekdayOptions: [ImportQuestion.Option] {
        let names: [Weekday: String] = [
            .monday: String(localized: "Segunda"), .tuesday: String(localized: "Terça"),
            .wednesday: String(localized: "Quarta"), .thursday: String(localized: "Quinta"),
            .friday: String(localized: "Sexta"), .saturday: String(localized: "Sábado"), .sunday: String(localized: "Domingo"),
        ]
        return Weekday.allCases.map { ImportQuestion.Option(id: $0.rawValue, label: names[$0] ?? $0.rawValue, detail: nil) }
    }

    static func detail(_ text: String?, source: ImportSource?) -> String? {
        let place = source.map { source in
            source.page.map { String(localized: "\(source.file), p. \($0)") } ?? source.file
        }
        return [text.nonEmpty, place].compactMap { $0 }.joined(separator: " — ").nonEmpty
    }

    static func ambiguityQuestion(_ ambiguity: ImportAmbiguity, gap: ImportGap) -> ImportQuestion {
        let options = ambiguity.options.compactMap(\.nonEmpty).enumerated().map {
            ImportQuestion.Option(id: "\($0.offset)", label: $0.element, detail: nil)
        }
        return ImportQuestion(id: gap.id, gapKind: .ambiguity, field: gap.field,
                              prompt: ambiguity.question.nonEmpty ?? String(localized: "Pode esclarecer este ponto?"),
                              detail: nil, kind: options.isEmpty ? .text(placeholder: nil) : .choice(options),
                              isRequired: false, source: nil)
    }

    static func requireText(_ text: String, max: Int) throws -> String {
        guard let value = text.nonEmpty else { throw ImportAnswerError.invalid(String(localized: "Escreva um nome.")) }
        return String(value.prefix(max))
    }

    /// "10" → fixo; "8-12"/"8 a 12"/"8–12" → faixa; "máximo"/"amrap"/"falha" → AMRAP.
    static func parseReps(_ text: String) -> ProgramDraft.RepTargetDraft? {
        let lower = ExerciseMatcher.normalize(text)
        if ["amrap", "maximo", "max", "falha", "ate a falha"].contains(lower) {
            return ProgramDraft.RepTargetDraft(kind: .amrap, reps: nil, min: nil, max: nil)
        }
        let numbers = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        switch numbers.count {
        case 1 where (1 ... 100).contains(numbers[0]):
            return ProgramDraft.RepTargetDraft(kind: .fixed, reps: numbers[0], min: nil, max: nil)
        case 2 where (1 ... 100).contains(numbers[0]) && (1 ... 100).contains(numbers[1]):
            let lo = min(numbers[0], numbers[1]), hi = max(numbers[0], numbers[1])
            return lo == hi ? ProgramDraft.RepTargetDraft(kind: .fixed, reps: lo, min: nil, max: nil)
                : ProgramDraft.RepTargetDraft(kind: .range, reps: nil, min: lo, max: hi)
        default:
            return nil
        }
    }

    /// "7:30", "07:30", "7h30", "7h" → minutos desde a meia-noite.
    static func parseTime(_ text: String) -> Int? {
        let parts = text.lowercased().split(whereSeparator: { $0 == ":" || $0 == "h" || $0 == " " }).compactMap { Int($0) }
        guard let hour = parts.first, (0 ..< 24).contains(hour) else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        guard (0 ..< 60).contains(minute), parts.count <= 2 else { return nil }
        return hour * 60 + minute
    }
}
