import Foundation

/// Regras puras do fluxo da sessão em andamento (SPEC §4.2, §6.4): exercício atual, fim de rodada
/// em bi-set/circuito e treino esquecido aberto (D4).
enum SessionFlow {
    /// Estado mínimo de um exercício da sessão, na ordem da sessão.
    struct ExerciseState: Sendable, Hashable {
        var id: UUID
        var groupID: UUID?
        var status: SessionExerciseStatus
        var completedSets: Int
        var totalSets: Int

        init(id: UUID, groupID: UUID? = nil, status: SessionExerciseStatus = .pending,
             completedSets: Int = 0, totalSets: Int = 0) {
            self.id = id
            self.groupID = groupID
            self.status = status
            self.completedSets = completedSets
            self.totalSets = totalSets
        }

        /// Ainda há o que fazer: não concluído/parcial/pulado e com série pendente
        /// (exercício sem séries fica aberto até a conclusão manual).
        var isOpen: Bool {
            guard status == .pending || status == .inProgress else { return false }
            return totalSets == 0 || completedSets < totalSets
        }
    }

    /// Treino esquecido aberto (D4): sem atividade há mais de 4 h.
    static let staleThreshold: TimeInterval = 4 * 3_600

    /// Exercício atual.
    ///
    /// Regra: `focused` (escolha explícita do usuário) vence enquanto estiver aberto. Senão, percorre
    /// os blocos na ordem da sessão — um exercício solto é um bloco; os exercícios com o mesmo
    /// `groupID` (bi-set/tri-set/circuito) formam um bloco na posição do primeiro membro — e escolhe
    /// o primeiro bloco com algum membro aberto. Dentro do grupo alterna por rodada: o membro aberto
    /// com menos séries concluídas; empate → o primeiro na ordem (A1, B1, A2, B2…).
    /// `nil` quando não resta nada aberto.
    static func currentExerciseID(_ exercises: [ExerciseState], focused: UUID? = nil) -> UUID? {
        if let focused, exercises.contains(where: { $0.id == focused && $0.isOpen }) { return focused }
        var visitedGroups = Set<UUID>()
        for exercise in exercises {
            guard let groupID = exercise.groupID else {
                if exercise.isOpen { return exercise.id }
                continue
            }
            guard visitedGroups.insert(groupID).inserted else { continue }
            let open = exercises.filter { $0.groupID == groupID && $0.isOpen }
            // `min(by:)` devolve o primeiro mínimo: empate fica com a ordem da sessão.
            if let next = open.min(by: { $0.completedSets < $1.completedSets }) { return next.id }
        }
        return nil
    }

    /// Depois de concluir uma série de `exerciseID` (estado já atualizado), a rodada acabou?
    ///
    /// Exercício solto: sempre. Em grupo: quando nenhum outro membro aberto do grupo está atrás
    /// (todos com pelo menos tantas séries concluídas quanto este). Assim o descanso só começa
    /// no fim da rodada — inclusive quando um membro tem mais séries que os outros.
    static func isEndOfRound(after exerciseID: UUID, in exercises: [ExerciseState]) -> Bool {
        guard let exercise = exercises.first(where: { $0.id == exerciseID }),
              let groupID = exercise.groupID else { return true }
        return exercises
            .filter { $0.groupID == groupID && $0.id != exerciseID && $0.isOpen }
            .allSatisfy { $0.completedSets >= exercise.completedSets }
    }

    /// `true` quando a última atividade passou do limite (D4).
    static func isStale(lastActivity: Date, now: Date, threshold: TimeInterval = staleThreshold) -> Bool {
        now.timeIntervalSince(lastActivity) > threshold
    }
}
