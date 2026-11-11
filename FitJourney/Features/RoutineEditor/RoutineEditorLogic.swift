import Foundation
import SwiftData
import SwiftUI

// Lógica pura/testável do editor de ficha (SPEC §3.2–§3.4). Sem views aqui.
// EXTENSÕES A MOVER: `RoutineEditorOps` (duplicar/mover/agrupar/adicionar com padrões por tipo de medida)
// e `PrescriptionDraft.apply` poderiam virar métodos do `ProgramStore` (Persistence/Stores) na integração.

// MARK: - Formatação

enum PrescriptionFormat {
    static func unitText(_ unit: WeightUnit) -> String { unit == .kg ? "kg" : "lb" }

    /// "32,5 kg", "PC", "PC +10 kg", "PC −20 kg".
    static func loadText(_ load: Load) -> String {
        loadText(load, displayUnit: WeightUnitPreference.current)
    }

    /// Mostra na unidade preferida (conversão só na exibição; mesma unidade = valor como digitado).
    static func loadText(_ load: Load, displayUnit: WeightUnit, step: Double? = nil) -> String {
        let shown = LoadDisplay.load(load, in: displayUnit, step: step ?? LoadDisplay.step(for: displayUnit))
        switch shown {
        case .weight(let value, let unit):
            return "\(FJFormat.number(value, maxFractionDigits: 2)) \(unitText(unit))"
        case .bodyweight(let delta, let unit):
            guard delta != 0 else { return "PC" }
            let sign = delta > 0 ? "+" : "−"
            return "PC \(sign)\(FJFormat.number(abs(delta), maxFractionDigits: 2)) \(unitText(unit))"
        }
    }

    static func repText(_ target: RepTarget) -> String {
        if case .amrap = target { return "máx." }
        return target.displayText
    }

    static func restText(_ seconds: Int) -> String { "\(seconds) s" }

    static func cardioText(_ cardio: CardioTarget) -> String {
        var parts: [String] = []
        if let d = cardio.durationSeconds { parts.append("\(d / 60) min") }
        if let m = cardio.distanceMeters { parts.append("\(FJFormat.number(m / 1000, maxFractionDigits: 2)) km") }
        if let l = cardio.level { parts.append("nível \(l)") }
        if let s = cardio.speedKmh { parts.append("\(FJFormat.number(s, maxFractionDigits: 1)) km/h") }
        if let i = cardio.inclinePercent { parts.append("\(FJFormat.number(i, maxFractionDigits: 1))%") }
        if let z = cardio.heartRateZone { parts.append("Z\(z)") }
        return parts.joined(separator: " · ")
    }

    static func effortText(_ effort: EffortTarget) -> String {
        switch effort {
        case .rir(let n): "RIR \(n)"
        case .rpe(let v): "RPE \(FJFormat.number(v, maxFractionDigits: 1))"
        }
    }
}

// MARK: - Rascunho de série

/// Uma série em edição (valor). `id` é o mesmo da `SetPrescription` (nova série = novo UUID).
struct SetDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: SetKind = .working
    var repTarget: RepTarget? = .range(min: 8, max: 12)
    var holdSeconds: Int?
    var initialLoad: Load?
    var currentLoad: Load?
    var restSeconds: Int?
    var tempo: String?
    var effort: EffortTarget?
    var cardio: CardioTarget?
    var notes: String = ""

    /// Carga atual que difere da inicial (R-T2), senão `nil`.
    var divergentCurrent: Load? {
        guard let current = currentLoad else { return nil }
        if let initial = initialLoad, current.isEquivalent(to: initial) { return nil }
        return current
    }

    /// Mesma prescrição (ignora identidade e carga atual).
    func hasSameTarget(as other: SetDraft) -> Bool {
        kind == other.kind && repTarget == other.repTarget && holdSeconds == other.holdSeconds
            && initialLoad == other.initialLoad && restSeconds == other.restSeconds
            && tempo == other.tempo && effort == other.effort && cardio == other.cardio
    }

    /// Faixa inválida (mín > máx) ou valores negativos. Carga não é validada (delta pode ser negativo).
    var isValid: Bool { RepTargetValidation.isValid(repTarget) && (holdSeconds ?? 0) >= 0 && (restSeconds ?? 0) >= 0 }

    /// Copia os campos de prescrição de outra série, mantendo identidade e carga atual.
    mutating func copyTarget(from other: SetDraft) {
        kind = other.kind; repTarget = other.repTarget; holdSeconds = other.holdSeconds
        restSeconds = other.restSeconds; tempo = other.tempo; effort = other.effort; cardio = other.cardio
        setInitialLoad(other.initialLoad)
    }

    /// R-T2: editar a carga define a inicial. A atual acompanha só quando era igual à inicial anterior;
    /// atual diferente da inicial (inclusive sem inicial anterior) é divergente e é preservada.
    mutating func setInitialLoad(_ new: Load?) {
        let old = initialLoad
        initialLoad = new
        guard let current = currentLoad, let old, current.isEquivalent(to: old) else { return }
        currentLoad = new
    }

    /// "Usar a atual como inicial".
    mutating func useCurrentAsInitial() {
        guard let current = currentLoad else { return }
        initialLoad = current
    }
}

enum RepTargetValidation {
    static func isValid(_ target: RepTarget?) -> Bool {
        switch target {
        case .none, .some(.amrap): true
        case .some(.fixed(let reps)): reps >= 1
        case .some(.range(let lo, let hi)): lo >= 1 && lo <= hi
        }
    }
}

/// Edição de faixa sem estado inválido: mexer no mínimo empurra o máximo e vice-versa.
enum RepRangeEditing {
    static let minimumReps = 1

    static func setLow(_ low: Int, of target: RepTarget) -> RepTarget {
        guard case .range(_, let hi) = target else { return target }
        let lo = max(minimumReps, low)
        return .range(min: lo, max: max(hi, lo))
    }

    static func setHigh(_ high: Int, of target: RepTarget) -> RepTarget {
        guard case .range(let lo, _) = target else { return target }
        let hi = max(minimumReps, high)
        return .range(min: min(lo, hi), max: hi)
    }

    static func setFixed(_ reps: Int) -> RepTarget { .fixed(reps: max(minimumReps, reps)) }
}

enum HoldLimits {
    static let minimumSeconds = 5
    static let defaultSeconds = 30
}

// MARK: - Rascunho do exercício da ficha

enum PrescriptionMode: Hashable, Sendable { case block, perSet }

struct PrescriptionDraft: Equatable, Sendable {
    var measurement: MeasurementKind
    var sets: [SetDraft]
    /// `RoutineExercise.restSeconds` (padrão do exercício na ficha).
    var exerciseRest: Int?
    var notes: String

    @MainActor
    init(_ item: RoutineExercise) {
        measurement = item.exercise?.measurementKind ?? .repsAndLoad
        exerciseRest = item.restSeconds
        notes = item.notes
        sets = item.sortedSets.map { s in
            SetDraft(id: s.id, kind: s.kind, repTarget: s.repTarget, holdSeconds: s.holdSeconds,
                     initialLoad: s.initialLoad, currentLoad: s.currentLoad, restSeconds: s.restSeconds,
                     tempo: s.tempo, effort: s.effort, cardio: s.cardio, notes: s.notes)
        }
        normalizeForMeasurement()
    }

    /// Ajusta os alvos ao tipo de medida (sem mostrar 0): isometria e cardio não têm reps;
    /// reps sem alvo ou inválidas viram 8–12; sustentação mínima 5 s; cardio sem alvo = 20 min.
    mutating func normalizeForMeasurement() {
        for i in sets.indices {
            switch measurement {
            case .repsAndLoad, .repsOnly:
                switch sets[i].repTarget {
                case .none: sets[i].repTarget = .range(min: 8, max: 12)
                case .some(.fixed(let n)): sets[i].repTarget = RepRangeEditing.setFixed(n)
                case .some(.range(let lo, let hi)):
                    let low = max(RepRangeEditing.minimumReps, lo)
                    sets[i].repTarget = .range(min: low, max: max(low, hi))
                case .some(.amrap): break
                }
            case .isometric:
                sets[i].repTarget = nil
                sets[i].holdSeconds = max(HoldLimits.minimumSeconds, sets[i].holdSeconds ?? HoldLimits.defaultSeconds)
            case .timeOrDistance:
                sets[i].repTarget = nil
                if sets[i].cardio == nil { sets[i].cardio = CardioTarget(durationSeconds: 20 * 60) }
            }
        }
    }

    init(measurement: MeasurementKind, sets: [SetDraft], exerciseRest: Int? = nil, notes: String = "") {
        self.measurement = measurement
        self.sets = sets
        self.exerciseRest = exerciseRest
        self.notes = notes
    }

    var isUniform: Bool {
        guard let first = sets.first else { return true }
        return sets.allSatisfy { $0.hasSameTarget(as: first) }
    }

    var initialMode: PrescriptionMode { isUniform ? .block : .perSet }

    /// Série modelo para os campos do modo em bloco: ler = primeira série; escrever = todas.
    var template: SetDraft {
        get { sets.first ?? PrescriptionDefaults.set(for: measurement) }
        set {
            if sets.isEmpty { sets = [newValue]; return }
            for i in sets.indices { sets[i].copyTarget(from: newValue) }
        }
    }

    /// Ajusta o número de séries (bloco): cresce clonando a última, encolhe pelo fim. Mínimo 1.
    mutating func resize(to count: Int) {
        let target = max(1, count)
        if sets.isEmpty { sets = [PrescriptionDefaults.set(for: measurement)] }
        while sets.count < target {
            var clone = sets[sets.count - 1]
            clone.id = UUID(); clone.currentLoad = nil
            sets.append(clone)
        }
        if sets.count > target { sets.removeLast(sets.count - target) }
    }

    /// Série a série → bloco: iguala todas à primeira (a UI confirma antes).
    mutating func makeUniform() {
        guard let first = sets.first else { return }
        for i in sets.indices.dropFirst() { sets[i].copyTarget(from: first) }
    }

    /// Usa a carga atual como inicial nas séries com atual divergente.
    mutating func useCurrentAsInitial() {
        for i in sets.indices { sets[i].useCurrentAsInitial() }
    }

    var hasDivergentCurrent: Bool { sets.contains { $0.divergentCurrent != nil } }

    /// Grava no modelo. Séries com alvo inválido mantêm o valor anterior (DESIGN §4.3 "Faixa inválida").
    @MainActor
    func apply(to item: RoutineExercise, context: ModelContext) throws {
        let existing = Dictionary(uniqueKeysWithValues: (item.sets ?? []).map { ($0.id, $0) })
        var keep = Set<UUID>()
        for (index, draft) in sets.enumerated() {
            let model: SetPrescription
            if let found = existing[draft.id] {
                model = found
            } else {
                model = SetPrescription(sortIndex: index)
                model.id = draft.id
                context.insert(model)
                model.routineExercise = item
            }
            keep.insert(model.id)
            model.sortIndex = index
            model.kind = draft.kind
            if RepTargetValidation.isValid(draft.repTarget) { model.repTarget = draft.repTarget }
            model.holdSeconds = draft.holdSeconds
            model.initialLoad = draft.initialLoad
            model.currentLoad = draft.currentLoad
            model.restSeconds = draft.restSeconds
            model.tempo = draft.tempo
            model.effort = draft.effort
            model.cardio = draft.cardio
            model.notes = draft.notes
            model.updatedAt = .now
        }
        for (id, model) in existing where !keep.contains(id) { context.delete(model) }
        item.restSeconds = exerciseRest
        item.notes = notes
        item.updatedAt = .now
        item.routine?.updatedAt = .now
        try context.save()
    }
}

// MARK: - Padrões por tipo de medida

enum PrescriptionDefaults {
    /// Série padrão por tipo de medida (SPEC §3.4): reps 8–12; isométrico 30 s; cardio 20 min.
    /// Peso corporal usa a unidade preferida do usuário.
    static func set(for kind: MeasurementKind, unit: WeightUnit = WeightUnitPreference.current) -> SetDraft {
        switch kind {
        case .repsAndLoad:
            SetDraft(repTarget: .range(min: 8, max: 12))
        case .repsOnly:
            SetDraft(repTarget: .range(min: 8, max: 12), initialLoad: .bodyweight(delta: 0, unit: unit))
        case .isometric:
            SetDraft(repTarget: nil, holdSeconds: HoldLimits.defaultSeconds)
        case .timeOrDistance:
            SetDraft(repTarget: nil, cardio: CardioTarget(durationSeconds: 20 * 60))
        }
    }

    static func setCount(for kind: MeasurementKind) -> Int { kind == .timeOrDistance ? 1 : 3 }
}

// MARK: - Resumo

enum PrescriptionSummary {
    private struct Run { var count: Int; var set: SetDraft }

    private static func runs(_ sets: [SetDraft]) -> [Run] {
        var result: [Run] = []
        for s in sets {
            if let last = result.last, last.set.hasSameTarget(as: s) {
                result[result.count - 1].count += 1
            } else {
                result.append(Run(count: 1, set: s))
            }
        }
        return result
    }

    private static func targetText(_ s: SetDraft, measurement: MeasurementKind) -> String {
        switch measurement {
        case .isometric:
            return s.holdSeconds.map { "\($0) s" } ?? "—"
        case .timeOrDistance:
            let text = s.cardio.map(PrescriptionFormat.cardioText) ?? ""
            return text.isEmpty ? "—" : text
        default:
            return s.repTarget.map(PrescriptionFormat.repText) ?? "—"
        }
    }

    /// "4 × 8–12 · 32,5 kg · 90 s". Séries diferentes viram trechos: "1 × 15 · 20 kg + 3 × 8–12 · 30 kg".
    static func line(sets: [SetDraft], measurement: MeasurementKind, effectiveRest: (SetDraft) -> Int) -> String {
        guard !sets.isEmpty else { return "" }
        let rs = runs(sets)
        let body: String
        if rs.count > 3 {
            body = String(localized: "\(sets.count) séries")
        } else {
            body = rs.map { run in
                var text: String
                if measurement == .timeOrDistance, run.count == 1 {
                    text = targetText(run.set, measurement: measurement)
                } else {
                    text = "\(run.count) × \(targetText(run.set, measurement: measurement))"
                }
                if measurement != .timeOrDistance, let load = run.set.initialLoad {
                    text += " · " + PrescriptionFormat.loadText(load)
                }
                return text
            }.joined(separator: " + ")
        }
        var result = body
        let rests = Set(sets.map(effectiveRest))
        if rests.count == 1, let r = rests.first, measurement != .timeOrDistance {
            result += " · " + PrescriptionFormat.restText(r)
        }
        return result
    }

    /// Frase para VoiceOver.
    static func spoken(sets: [SetDraft], measurement: MeasurementKind, effectiveRest: (SetDraft) -> Int) -> String {
        guard !sets.isEmpty else { return String(localized: "Sem séries definidas") }
        let parts = runs(sets).map { run -> String in
            var text = run.count == 1 ? String(localized: "1 série") : String(localized: "\(run.count) séries")
            switch measurement {
            case .isometric:
                if let h = run.set.holdSeconds { text += String(localized: " de \(h) segundos") }
            case .timeOrDistance:
                if let c = run.set.cardio {
                    let t = PrescriptionFormat.cardioText(c)
                    if !t.isEmpty { text += " de " + t }
                }
            default:
                switch run.set.repTarget {
                case .some(.fixed(let r)): text += String(localized: " de \(r) repetições")
                case .some(.range(let lo, let hi)): text += String(localized: " de \(lo) a \(hi) repetições")
                case .some(.amrap): text += String(localized: " até o máximo de repetições")
                case .none: break
                }
            }
            if run.set.kind != .working { text += ", " + run.set.kind.localizedName }
            if let load = run.set.initialLoad {
                switch load {
                case .weight(let v, let u):
                    let unit = u == .kg ? String(localized: "quilos") : String(localized: "libras")
                    text += String(localized: ", com \(FJFormat.number(v)) \(unit)")
                case .bodyweight(let d, let u):
                    let unit = u == .kg ? String(localized: "quilos") : String(localized: "libras")
                    if d == 0 { text += String(localized: ", peso corporal") }
                    else if d > 0 { text += String(localized: ", peso corporal mais \(FJFormat.number(d)) \(unit)") }
                    else { text += String(localized: ", peso corporal com \(FJFormat.number(-d)) \(unit) de assistência") }
                }
            }
            return text
        }
        var sentence = parts.joined(separator: "; ")
        let rests = Set(sets.map(effectiveRest))
        if rests.count == 1, let r = rests.first {
            sentence += String(localized: ". Descanso de \(FJFormat.spokenDuration(r))")
        }
        return sentence
    }
}

// MARK: - Agrupamento

enum GroupLabel {
    /// 2 = Bi-set, 3 = Tri-set, 4+ = Circuito.
    static func name(forCount count: Int) -> String {
        switch count {
        case ...2: String(localized: "Bi-set")
        case 3: String(localized: "Tri-set")
        default: String(localized: "Circuito")
        }
    }
}

// MARK: - Apoio de UI para as operações (as mutações ficam em `ProgramStore`)

@MainActor
enum RoutineEditorOps {
    static func canMove(_ item: RoutineExercise, by offset: Int) -> Bool {
        guard let routine = item.routine else { return false }
        let items = routine.sortedExercises
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return false }
        return items.indices.contains(i + offset)
    }

    /// 2+ itens vizinhos selecionados.
    static func canGroup(selected: Set<UUID>, in routine: Routine) -> Bool {
        let idx = routine.sortedExercises.enumerated().filter { selected.contains($0.element.id) }.map(\.offset)
        guard idx.count >= 2, let first = idx.first, let last = idx.last else { return false }
        return last - first == idx.count - 1
    }

    /// Insere exercícios com prescrição padrão por tipo de medida (descanso: o do catálogo), com um único save.
    @discardableResult
    static func add(_ exercises: [Exercise], to routine: Routine, store: ProgramStore) throws -> [RoutineExercise] {
        var added: [RoutineExercise] = []
        for exercise in exercises {
            let kind = exercise.measurementKind
            let t = PrescriptionDefaults.set(for: kind)
            added.append(try store.addExercise(
                exercise, to: routine, setCount: PrescriptionDefaults.setCount(for: kind),
                repTarget: t.repTarget, load: t.initialLoad, holdSeconds: t.holdSeconds, cardio: t.cardio,
                save: false))
        }
        routine.updatedAt = .now
        try store.context.save()
        return added
    }

    /// Descanso efetivo de uma série (série → exercício na ficha → catálogo → 90 s).
    static func effectiveRest(_ set: SetDraft, exerciseRest: Int?, catalogRest: Int?) -> Int {
        set.restSeconds ?? exerciseRest ?? catalogRest ?? 90
    }

    /// Descanso do exercício (no último membro de um grupo = descanso ao fim da rodada).
    static func effectiveRest(of item: RoutineExercise) -> Int {
        item.sortedSets.last?.restSeconds ?? item.restSeconds ?? item.exercise?.defaultRestSeconds ?? 90
    }

    /// `true` se o item é membro de grupo e não o último (o descanso só vale ao fim da rodada).
    static func isInnerGroupMember(_ item: RoutineExercise) -> Bool {
        guard let gid = item.groupID, let routine = item.routine else { return false }
        return routine.sortedExercises.last(where: { $0.groupID == gid })?.id != item.id
    }
}

// MARK: - Resumo de um exercício da ficha

extension RoutineExercise {
    /// Rascunho só para leitura (resumos).
    @MainActor private var summaryDraft: PrescriptionDraft { PrescriptionDraft(self) }

    @MainActor private func rest(_ set: SetDraft) -> Int {
        RoutineEditorOps.effectiveRest(set, exerciseRest: restSeconds, catalogRest: exercise?.defaultRestSeconds)
    }

    /// "4 × 8–12 · 32,5 kg · 90 s"; vazio se não há séries.
    @MainActor var prescriptionSummary: String {
        let d = summaryDraft
        return PrescriptionSummary.line(sets: d.sets, measurement: d.measurement, effectiveRest: rest)
    }

    @MainActor var prescriptionSpoken: String {
        let d = summaryDraft
        return PrescriptionSummary.spoken(sets: d.sets, measurement: d.measurement, effectiveRest: rest)
    }

    /// Tipos de série diferentes de "válida" (para etiquetas na linha).
    var nonWorkingKinds: [SetKind] {
        var seen: [SetKind] = []
        for s in sortedSets where s.kind != .working && !seen.contains(s.kind) { seen.append(s.kind) }
        return seen
    }
}
