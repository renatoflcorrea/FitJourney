import Foundation

/// Regra única do descanso efetivo: série → exercício na ficha → catálogo/exercício → padrão de Ajustes.
/// `nil` em qualquer nível = "não definido, usar o próximo"; `0` explícito é um descanso zero e vale.
enum RestPolicy {
    static func effective(set: Int?, routineExercise: Int?, exercise: Int?, fallback: Int) -> Int {
        set ?? routineExercise ?? exercise ?? fallback
    }
}
