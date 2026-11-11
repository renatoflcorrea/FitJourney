import Foundation

/// Status automático de um exercício na sessão (SPEC §4.2).
enum SessionExerciseRules {
    /// Status depois de marcar/desmarcar séries. Pulado continua pulado até ser retomado.
    static func automaticStatus(current: SessionExerciseStatus, completedSets: Int, totalSets: Int) -> SessionExerciseStatus {
        if current == .skipped { return .skipped }
        if totalSets > 0 && completedSets >= totalSets { return .completed }
        if completedSets > 0 { return .inProgress }
        // Concluído manualmente sem séries (ou parcial) mantém a decisão do usuário.
        return current == .completed || current == .partial ? current : .pending
    }

    /// Conclusão manual: todas as séries feitas → concluído; senão → concluído parcialmente.
    static func manualCompletionStatus(completedSets: Int, totalSets: Int) -> SessionExerciseStatus {
        completedSets >= totalSets ? .completed : .partial
    }
}
