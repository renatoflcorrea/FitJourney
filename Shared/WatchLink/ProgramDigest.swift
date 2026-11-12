import Foundation

/// Resumo compacto do programa ativo para o relógio fora de sessão (SPEC §6.4): fichas, exercícios,
/// prescrição e cargas atuais. Vai por `applicationContext`; o relógio abre a lista sem o iPhone.
struct ProgramDigest: Codable, Sendable, Hashable {
    var generatedAt: Date
    var programID: UUID
    var name: String
    /// "free" | "sequential" | "weekly" (`ScheduleMode.rawValue`).
    var scheduleMode: String
    /// Ficha(s) sugerida(s) para hoje, em ordem (vazio = descanso/sem fichas).
    var suggestedRoutineIDs: [UUID]
    var routines: [Routine]
    /// Idioma efetivo do app no iPhone (`AppLanguageCode`: "pt-BR" | "en"); o relógio o aplica a si mesmo.
    /// Opcional e sem subir `schemaVersion`: ausente = o relógio mantém o idioma atual.
    var language: String? = nil

    struct Routine: Codable, Sendable, Hashable, Identifiable {
        /// `Routine.id` (vai no comando `start`).
        var id: UUID
        var name: String
        var symbol: String
        var lastCompletedAt: Date?
        var estimatedDurationSeconds: Int
        var exercises: [Exercise]
        /// Tipo do treino no Saúde (`HealthWorkoutType.rawValue`), derivado da ficha no iPhone (v2).
        var workoutType: String? = nil
        /// `Routine.colorName` (cor da ficha; vazio/ausente = padrão), para o selo no relógio (v2).
        var colorName: String? = nil
    }

    struct Exercise: Codable, Sendable, Hashable, Identifiable {
        /// `RoutineExercise.id`.
        var id: UUID
        /// Exercício do catálogo.
        var exerciseID: UUID?
        var name: String
        var measurementKind: WatchMeasurementKind
        var groupID: UUID?
        var restSeconds: Int?
        var sets: [ExerciseSet]
    }

    struct ExerciseSet: Codable, Sendable, Hashable, Identifiable {
        /// `SetPrescription.id`.
        var id: UUID
        var kind: WatchSetKind
        var targetText: String
        var repTarget: WatchRepTarget?
        var effort: WatchEffort?
        /// Carga atual (senão a inicial).
        var load: WatchLoad?
        var holdSeconds: Int?
        var restSeconds: Int?
        /// Cardio: duração/distância alvo (v2).
        var targetDurationSeconds: Int? = nil
        var targetDistanceMeters: Double? = nil
    }

    var suggestedRoutines: [Routine] {
        suggestedRoutineIDs.compactMap { id in routines.first { $0.id == id } }
    }
}
