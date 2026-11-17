import Foundation

/// Proposta de atualização da carga atual de uma série prescrita (SPEC §3.4, R-T2).
struct LoadUpdateProposal: Sendable, Hashable, Identifiable {
    var prescriptionID: UUID
    var exerciseName: String
    var from: Load?
    var to: Load
    /// Exercício da sessão de origem (`SessionExercise.id`), para agrupar as propostas por exercício na tela.
    var sessionExerciseID: UUID? = nil

    var id: UUID { prescriptionID }

    /// A prescrição não tinha carga (nil ou peso 0): é o primeiro valor definido pelo usuário (P2.8). Aplicada
    /// sempre ao finalizar, mesmo sem confirmação — é assim que o app "lembra" a carga.
    var isFirstDefinition: Bool { Load.defined(from) == nil }
}

/// Decide quais `currentLoad` propor ao fim da sessão.
///
/// **Carga ajustada na sessão (17/11):** se alguma série válida concluída usou carga diferente da carga atual
/// da ficha (ou da inicial, quando ainda não há atual) e **todas as séries válidas foram concluídas**, propõe a
/// **mesma carga final** — a da última série válida concluída (`completedAt`) — para **todas** as séries válidas
/// prescritas do exercício que ainda não a têm (pirâmides viram carga única), para o próximo treino começar
/// uniforme. As sem carga na ficha entram como primeira definição.
///
/// Sem ajuste: só as primeiras definições (abaixo). Aquecimento/preparatória nunca atualizam.
/// Séries sem prescrição de origem (extras adicionadas na hora, ou cuja ficha foi apagada) são ignoradas
/// — não contam para "todas concluídas" nem para a carga final.
///
/// **Primeira definição (P2.8):** série válida cuja prescrição não tem carga (nil, ou peso 0) e que foi
/// concluída com uma carga definida gera proposta mesmo que outras séries do exercício tenham ficado pendentes
/// (`LoadUpdateProposal.isFirstDefinition`; o motor aplica essas sempre) — com a carga final do exercício.
enum CurrentLoadPolicy {
    struct SetEntry: Sendable, Hashable {
        var prescriptionID: UUID?
        var kind: SetKind
        /// Carga atual da prescrição no momento do fim (ou inicial, se não há atual).
        var currentLoad: Load?
        var usedLoad: Load?
        var isCompleted: Bool
        /// Quando foi concluída (escolhe a "última série concluída"; empate/ausente = ordem da lista).
        var completedAt: Date?

        init(prescriptionID: UUID?, kind: SetKind, currentLoad: Load?, usedLoad: Load?, isCompleted: Bool,
             completedAt: Date? = nil) {
            self.prescriptionID = prescriptionID
            self.kind = kind
            self.currentLoad = currentLoad
            self.usedLoad = usedLoad
            self.isCompleted = isCompleted
            self.completedAt = completedAt
        }
    }

    struct ExerciseEntry: Sendable, Hashable {
        var exerciseName: String
        var sets: [SetEntry]
        /// Exercício pulado ou substituído não atualiza a ficha.
        var isEligible: Bool = true
        /// `SessionExercise.id` (repassado às propostas).
        var sessionExerciseID: UUID? = nil
    }

    static func proposals(for exercises: [ExerciseEntry]) -> [LoadUpdateProposal] {
        exercises.flatMap { exercise -> [LoadUpdateProposal] in
            guard exercise.isEligible else { return [] }
            // Séries extras (sem prescrição de origem) não bloqueiam nem geram propostas.
            let working = exercise.sets.filter { $0.kind.isWorking && $0.prescriptionID != nil }
            let allCompleted = !working.isEmpty && working.allSatisfy(\.isCompleted)
            func proposal(_ set: SetEntry, to load: Load) -> LoadUpdateProposal {
                LoadUpdateProposal(prescriptionID: set.prescriptionID!, exerciseName: exercise.exerciseName,
                                   from: set.currentLoad, to: load, sessionExerciseID: exercise.sessionExerciseID)
            }

            let adjusted = working.contains { set in
                guard set.isCompleted, let current = Load.defined(set.currentLoad),
                      let used = Load.defined(set.usedLoad) else { return false }
                return !current.isEquivalent(to: used)
            }
            guard let final = finalLoad(of: working) else { return [] }
            if adjusted, allCompleted {
                var seen = Set<UUID>()
                return working.compactMap { set in
                    guard let id = set.prescriptionID, seen.insert(id).inserted else { return nil }
                    if let current = Load.defined(set.currentLoad), current.isEquivalent(to: final) { return nil }
                    return proposal(set, to: final)
                }
            }

            // Sem ajuste (ou nem todas concluídas): só as séries concluídas sem carga na ficha (primeira definição),
            // todas com a carga final (a carga pode ter mudado no meio do exercício).
            return working.compactMap { set in
                guard Load.defined(set.currentLoad) == nil, set.isCompleted,
                      Load.defined(set.usedLoad) != nil else { return nil }
                return proposal(set, to: final)
            }
        }
    }

    /// Carga da última série concluída (por `completedAt`; empate = a posterior na lista) com carga definida.
    static func finalLoad(of sets: [SetEntry]) -> Load? {
        var best: (date: Date, load: Load)?
        for set in sets where set.isCompleted {
            guard let used = Load.defined(set.usedLoad) else { continue }
            let date = set.completedAt ?? .distantPast
            if best == nil || date >= best!.date { best = (date, used) }
        }
        return best?.load
    }
}

/// Proposta de atualização do alvo de repetições de uma série prescrita (SPEC §4.2, decisão 17/11): o número
/// digitado na sessão vira o novo alvo da ficha. Mesma confirmação da carga atual (padrão: sim).
struct RepTargetUpdateProposal: Sendable, Hashable, Identifiable {
    var prescriptionID: UUID
    var exerciseName: String
    var from: RepTarget?
    var to: RepTarget
    var sessionExerciseID: UUID? = nil

    var id: UUID { prescriptionID }
}

/// Decide os alvos de repetições a propor para a ficha ao fim da sessão (decisão 17/11).
///
/// Se o alvo de alguma série válida prescrita mudou na sessão (o usuário digitou reps — `SessionStore.updateSet`),
/// propõe o **alvo final** para **todas** as séries válidas prescritas do exercício que ainda não o têm. Alvo
/// final: o de uma série válida pendente (cada número digitado vai para todas as pendentes, então elas guardam o
/// mais recente); sem pendentes, o da série mudada editada por último (`updatedAt`). Não exige todas as séries
/// concluídas (o número é uma declaração explícita do usuário). Prescrições AMRAP ficam fora (nunca são
/// reescritas). Exercício pulado/substituído e séries extras não contam.
enum RepTargetPolicy {
    struct SetEntry: Sendable, Hashable {
        var prescriptionID: UUID?
        var kind: SetKind
        /// Alvo atual da série prescrita na ficha.
        var prescribed: RepTarget?
        /// Alvo da série na sessão.
        var session: RepTarget?
        var isCompleted: Bool
        var updatedAt: Date?

        init(prescriptionID: UUID?, kind: SetKind, prescribed: RepTarget?, session: RepTarget?,
             isCompleted: Bool, updatedAt: Date? = nil) {
            self.prescriptionID = prescriptionID
            self.kind = kind
            self.prescribed = prescribed
            self.session = session
            self.isCompleted = isCompleted
            self.updatedAt = updatedAt
        }
    }

    struct ExerciseEntry: Sendable, Hashable {
        var exerciseName: String
        var sets: [SetEntry]
        var isEligible: Bool = true
        var sessionExerciseID: UUID? = nil
    }

    static func proposals(for exercises: [ExerciseEntry]) -> [RepTargetUpdateProposal] {
        exercises.flatMap { exercise -> [RepTargetUpdateProposal] in
            guard exercise.isEligible else { return [] }
            let working = exercise.sets.filter {
                $0.kind.isWorking && $0.prescriptionID != nil && $0.prescribed != .amrap
            }
            let changed = working.filter { $0.session != $0.prescribed }
            guard !changed.isEmpty else { return [] }
            let latestChanged = changed.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            guard let final = working.first(where: { !$0.isCompleted })?.session ?? latestChanged?.session,
                  case .fixed = final else { return [] }
            var seen = Set<UUID>()
            return working.compactMap { set in
                guard let id = set.prescriptionID, seen.insert(id).inserted, set.prescribed != final else { return nil }
                return RepTargetUpdateProposal(prescriptionID: id, exerciseName: exercise.exerciseName,
                                               from: set.prescribed, to: final,
                                               sessionExerciseID: exercise.sessionExerciseID)
            }
        }
    }
}

/// Propagação dentro do exercício na sessão em andamento (decisão 17/11): a carga ou o alvo de reps novo de uma
/// série vale para **todas as séries pendentes do mesmo exercício e do mesmo grupo** (válidas × aquecimento/
/// preparatória), antes ou depois dela, editadas ou não. Séries concluídas nunca mudam.
enum SessionSetPropagation {
    struct SetState: Sendable, Hashable {
        var id: UUID
        var kind: SetKind
        var isCompleted: Bool
    }

    /// IDs das séries que acompanham a série `sourceID` (a própria fica de fora; ela já tem o valor novo).
    static func peers(of sourceID: UUID, in sets: [SetState]) -> [UUID] {
        guard let source = sets.first(where: { $0.id == sourceID }) else { return [] }
        let working = source.kind.isWorking
        return sets.filter { $0.id != sourceID && !$0.isCompleted && $0.kind.isWorking == working }.map(\.id)
    }
}

/// Propostas de um exercício juntas, para a tela de fim (uma linha e um toggle por exercício): a carga e o alvo de
/// reps propostos e os `prescriptionID`s que o toggle confirma. Primeiras definições de carga não entram em
/// `confirmableIDs` (o motor aplica sempre).
struct PrescriptionUpdateGroup: Sendable, Hashable, Identifiable {
    var id: String
    var exerciseName: String
    /// Carga de origem comum às propostas confirmáveis (nil se não havia ou se eram diferentes, ex.: pirâmide).
    var fromLoad: Load?
    var toLoad: Load?
    /// Alvo de origem comum (nil se diferente entre as séries).
    var fromRepTarget: RepTarget?
    var toRepTarget: RepTarget?
    /// Todas as propostas de carga do exercício são primeiras definições (salvas automaticamente).
    var isFirstDefinition: Bool
    var confirmableIDs: [UUID]

    /// Nada a confirmar: só primeiras definições (a linha é informativa).
    var isAutomatic: Bool { confirmableIDs.isEmpty }

    static func make(load: [LoadUpdateProposal], reps: [RepTargetUpdateProposal]) -> [PrescriptionUpdateGroup] {
        func key(_ exerciseID: UUID?, _ name: String) -> String { exerciseID?.uuidString ?? "name:\(name)" }
        var order: [String] = []
        var names: [String: String] = [:]
        var loads: [String: [LoadUpdateProposal]] = [:]
        var targets: [String: [RepTargetUpdateProposal]] = [:]
        for proposal in load {
            let k = key(proposal.sessionExerciseID, proposal.exerciseName)
            if loads[k] == nil && targets[k] == nil { order.append(k) }
            names[k] = proposal.exerciseName
            loads[k, default: []].append(proposal)
        }
        for proposal in reps {
            let k = key(proposal.sessionExerciseID, proposal.exerciseName)
            if loads[k] == nil && targets[k] == nil { order.append(k) }
            names[k] = proposal.exerciseName
            targets[k, default: []].append(proposal)
        }
        return order.map { k in
            let loadItems = loads[k] ?? []
            let repItems = targets[k] ?? []
            let confirmableLoads = loadItems.filter { !$0.isFirstDefinition }
            let froms = confirmableLoads.compactMap { Load.defined($0.from) }
            let commonFrom: Load? = froms.first.flatMap { first in
                froms.allSatisfy { $0.isEquivalent(to: first) } ? first : nil
            }
            let repFroms = repItems.map(\.from)
            let commonRepFrom: RepTarget? = repFroms.first.flatMap { first in
                repFroms.allSatisfy { $0 == first } ? first : nil
            }
            var seen = Set<UUID>()
            let ids = (confirmableLoads.map(\.prescriptionID) + repItems.map(\.prescriptionID))
                .filter { seen.insert($0).inserted }
            return PrescriptionUpdateGroup(
                id: k, exerciseName: names[k] ?? "",
                fromLoad: commonFrom, toLoad: (confirmableLoads.last ?? loadItems.last)?.to,
                fromRepTarget: commonRepFrom, toRepTarget: repItems.last?.to,
                isFirstDefinition: !loadItems.isEmpty && confirmableLoads.isEmpty,
                confirmableIDs: ids)
        }
    }
}
