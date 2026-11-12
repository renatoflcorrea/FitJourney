import Foundation

/// Proposta de atualização da carga atual de uma série prescrita (SPEC §3.4, R-T2).
struct LoadUpdateProposal: Sendable, Hashable, Identifiable {
    var prescriptionID: UUID
    var exerciseName: String
    var from: Load?
    var to: Load

    var id: UUID { prescriptionID }

    /// A prescrição não tinha carga (nil ou peso 0): é o primeiro valor definido pelo usuário (P2.8). Aplicada
    /// sempre ao finalizar, mesmo sem confirmação — é assim que o app "lembra" a carga.
    var isFirstDefinition: Bool { Load.defined(from) == nil }
}

/// Decide quais `currentLoad` propor ao fim da sessão.
///
/// Padrão: para cada exercício, **se todas as séries válidas foram concluídas**, propõe
/// a carga usada em cada série válida concluída cuja carga difere da carga atual
/// (ou da inicial, quando ainda não há atual). Aquecimento/preparatória nunca atualizam.
/// Séries sem prescrição de origem (extras adicionadas na hora, ou cuja ficha foi apagada) são ignoradas
/// — não contam para "todas concluídas".
///
/// **Primeira definição (P2.8):** série válida cuja prescrição não tem carga (nil, ou peso 0) e que foi
/// concluída com uma carga definida gera proposta mesmo que outras séries do exercício tenham ficado pendentes
/// (`LoadUpdateProposal.isFirstDefinition`; o motor aplica essas sempre).
enum CurrentLoadPolicy {
    struct SetEntry: Sendable, Hashable {
        var prescriptionID: UUID?
        var kind: SetKind
        /// Carga atual da prescrição no momento do fim (ou inicial, se não há atual).
        var currentLoad: Load?
        var usedLoad: Load?
        var isCompleted: Bool

        init(prescriptionID: UUID?, kind: SetKind, currentLoad: Load?, usedLoad: Load?, isCompleted: Bool) {
            self.prescriptionID = prescriptionID
            self.kind = kind
            self.currentLoad = currentLoad
            self.usedLoad = usedLoad
            self.isCompleted = isCompleted
        }
    }

    struct ExerciseEntry: Sendable, Hashable {
        var exerciseName: String
        var sets: [SetEntry]
        /// Exercício pulado ou substituído não atualiza a ficha.
        var isEligible: Bool = true
    }

    static func proposals(for exercises: [ExerciseEntry]) -> [LoadUpdateProposal] {
        exercises.flatMap { exercise -> [LoadUpdateProposal] in
            guard exercise.isEligible else { return [] }
            // Séries extras (sem prescrição de origem) não bloqueiam nem geram propostas.
            let working = exercise.sets.filter { $0.kind.isWorking && $0.prescriptionID != nil }
            let allCompleted = !working.isEmpty && working.allSatisfy(\.isCompleted)
            return working.compactMap { set in
                guard let id = set.prescriptionID, let used = set.usedLoad else { return nil }
                if let current = Load.defined(set.currentLoad) {
                    guard allCompleted, !current.isEquivalent(to: used) else { return nil }
                } else {
                    // Sem carga na ficha: vale a primeira carga definida numa série concluída.
                    guard set.isCompleted, Load.defined(used) != nil else { return nil }
                }
                return LoadUpdateProposal(prescriptionID: id, exerciseName: exercise.exerciseName,
                                          from: set.currentLoad, to: used)
            }
        }
    }
}
