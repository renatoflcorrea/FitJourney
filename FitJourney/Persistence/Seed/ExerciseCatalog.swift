import Foundation
import SwiftData

/// Definição de um exercício do catálogo embutido (sem mídia licenciada).
struct CatalogExercise: Sendable, Hashable {
    /// Chave estável; nunca mude depois de publicada (é a base da idempotência do seed).
    var key: String
    var name: String
    var nameEN: String
    var primary: [MuscleGroup]
    var secondary: [MuscleGroup] = []
    var equipment: Equipment
    var laterality: Laterality = .bilateral
    var kind: MeasurementKind = .repsAndLoad
    var rest: Int = 90
    /// Versão do catálogo em que o exercício entrou (só versões novas são semeadas em bases existentes).
    var addedInVersion: Int = 1
}

/// Catálogo inicial (~60 exercícios comuns). Nomes em pt-BR; `nameEN` fica para a localização en.
enum ExerciseCatalog {
    /// Suba ao adicionar exercícios (marcando-os com `addedInVersion: version`).
    static let version = 1

    static let all: [CatalogExercise] = [
        // Peito
        .init(key: "bench-press", name: "Supino reto com barra", nameEN: "Barbell Bench Press", primary: [.chest], secondary: [.triceps, .shoulders], equipment: .barbell, rest: 120),
        .init(key: "incline-bench-press", name: "Supino inclinado com barra", nameEN: "Incline Barbell Bench Press", primary: [.chest], secondary: [.shoulders, .triceps], equipment: .barbell, rest: 120),
        .init(key: "dumbbell-bench-press", name: "Supino reto com halteres", nameEN: "Dumbbell Bench Press", primary: [.chest], secondary: [.triceps, .shoulders], equipment: .dumbbell),
        .init(key: "incline-dumbbell-press", name: "Supino inclinado com halteres", nameEN: "Incline Dumbbell Press", primary: [.chest], secondary: [.shoulders, .triceps], equipment: .dumbbell),
        .init(key: "decline-bench-press", name: "Supino declinado", nameEN: "Decline Bench Press", primary: [.chest], secondary: [.triceps], equipment: .barbell),
        .init(key: "dumbbell-fly", name: "Crucifixo com halteres", nameEN: "Dumbbell Fly", primary: [.chest], equipment: .dumbbell, rest: 60),
        .init(key: "pec-deck", name: "Voador (peck deck)", nameEN: "Pec Deck", primary: [.chest], equipment: .machine, rest: 60),
        .init(key: "cable-crossover", name: "Crossover na polia", nameEN: "Cable Crossover", primary: [.chest], equipment: .cable, rest: 60),
        .init(key: "machine-chest-press", name: "Supino na máquina", nameEN: "Machine Chest Press", primary: [.chest], secondary: [.triceps], equipment: .machine),
        .init(key: "push-up", name: "Flexão de braço", nameEN: "Push-up", primary: [.chest], secondary: [.triceps, .shoulders], equipment: .bodyweight, kind: .repsOnly, rest: 60),
        .init(key: "dips", name: "Paralelas (mergulho)", nameEN: "Dips", primary: [.chest, .triceps], secondary: [.shoulders], equipment: .bodyweight, kind: .repsOnly),

        // Costas
        .init(key: "pull-up", name: "Barra fixa", nameEN: "Pull-up", primary: [.back], secondary: [.biceps], equipment: .bodyweight, kind: .repsOnly, rest: 120),
        .init(key: "chin-up", name: "Barra fixa supinada", nameEN: "Chin-up", primary: [.back, .biceps], equipment: .bodyweight, kind: .repsOnly, rest: 120),
        .init(key: "lat-pulldown", name: "Puxada frontal", nameEN: "Lat Pulldown", primary: [.back], secondary: [.biceps], equipment: .cable),
        .init(key: "close-grip-pulldown", name: "Puxada com triângulo", nameEN: "Close-grip Pulldown", primary: [.back], secondary: [.biceps], equipment: .cable),
        .init(key: "barbell-row", name: "Remada curvada com barra", nameEN: "Barbell Row", primary: [.back], secondary: [.biceps, .lowerBack], equipment: .barbell, rest: 120),
        .init(key: "dumbbell-row", name: "Remada unilateral com halter", nameEN: "One-arm Dumbbell Row", primary: [.back], secondary: [.biceps], equipment: .dumbbell, laterality: .unilateral),
        .init(key: "seated-cable-row", name: "Remada baixa", nameEN: "Seated Cable Row", primary: [.back], secondary: [.biceps], equipment: .cable),
        .init(key: "machine-row", name: "Remada na máquina", nameEN: "Machine Row", primary: [.back], secondary: [.biceps], equipment: .machine),
        .init(key: "t-bar-row", name: "Remada cavalinho", nameEN: "T-bar Row", primary: [.back], secondary: [.biceps], equipment: .barbell),
        .init(key: "straight-arm-pulldown", name: "Pulldown com braços estendidos", nameEN: "Straight-arm Pulldown", primary: [.back], equipment: .cable, rest: 60),
        .init(key: "deadlift", name: "Levantamento terra", nameEN: "Deadlift", primary: [.back, .hamstrings, .glutes], secondary: [.lowerBack, .traps, .forearms], equipment: .barbell, rest: 180),
        .init(key: "back-extension", name: "Extensão lombar (banco romano)", nameEN: "Back Extension", primary: [.lowerBack], secondary: [.glutes, .hamstrings], equipment: .bodyweight, kind: .repsOnly, rest: 60),
        .init(key: "shrug", name: "Encolhimento com halteres", nameEN: "Dumbbell Shrug", primary: [.traps], equipment: .dumbbell, rest: 60),

        // Ombros
        .init(key: "overhead-press", name: "Desenvolvimento com barra", nameEN: "Overhead Press", primary: [.shoulders], secondary: [.triceps], equipment: .barbell, rest: 120),
        .init(key: "dumbbell-shoulder-press", name: "Desenvolvimento com halteres", nameEN: "Dumbbell Shoulder Press", primary: [.shoulders], secondary: [.triceps], equipment: .dumbbell),
        .init(key: "machine-shoulder-press", name: "Desenvolvimento na máquina", nameEN: "Machine Shoulder Press", primary: [.shoulders], secondary: [.triceps], equipment: .machine),
        .init(key: "lateral-raise", name: "Elevação lateral", nameEN: "Lateral Raise", primary: [.shoulders], equipment: .dumbbell, rest: 60),
        .init(key: "cable-lateral-raise", name: "Elevação lateral na polia", nameEN: "Cable Lateral Raise", primary: [.shoulders], equipment: .cable, laterality: .unilateral, rest: 60),
        .init(key: "front-raise", name: "Elevação frontal", nameEN: "Front Raise", primary: [.shoulders], equipment: .dumbbell, rest: 60),
        .init(key: "reverse-fly", name: "Crucifixo inverso", nameEN: "Reverse Fly", primary: [.shoulders], secondary: [.back], equipment: .dumbbell, rest: 60),
        .init(key: "face-pull", name: "Face pull", nameEN: "Face Pull", primary: [.shoulders], secondary: [.traps], equipment: .cable, rest: 60),
        .init(key: "upright-row", name: "Remada alta", nameEN: "Upright Row", primary: [.shoulders, .traps], equipment: .barbell, rest: 60),

        // Braços
        .init(key: "barbell-curl", name: "Rosca direta com barra", nameEN: "Barbell Curl", primary: [.biceps], secondary: [.forearms], equipment: .barbell, rest: 60),
        .init(key: "dumbbell-curl", name: "Rosca alternada com halteres", nameEN: "Alternating Dumbbell Curl", primary: [.biceps], equipment: .dumbbell, rest: 60),
        .init(key: "hammer-curl", name: "Rosca martelo", nameEN: "Hammer Curl", primary: [.biceps, .forearms], equipment: .dumbbell, rest: 60),
        .init(key: "scott-curl", name: "Rosca Scott", nameEN: "Preacher Curl", primary: [.biceps], equipment: .machine, rest: 60),
        .init(key: "cable-curl", name: "Rosca na polia", nameEN: "Cable Curl", primary: [.biceps], equipment: .cable, rest: 60),
        .init(key: "triceps-pushdown", name: "Tríceps na polia (corda)", nameEN: "Rope Triceps Pushdown", primary: [.triceps], equipment: .cable, rest: 60),
        .init(key: "skull-crusher", name: "Tríceps testa", nameEN: "Skull Crusher", primary: [.triceps], equipment: .barbell, rest: 60),
        .init(key: "overhead-triceps-extension", name: "Tríceps francês", nameEN: "Overhead Triceps Extension", primary: [.triceps], equipment: .dumbbell, rest: 60),
        .init(key: "close-grip-bench-press", name: "Supino fechado", nameEN: "Close-grip Bench Press", primary: [.triceps], secondary: [.chest], equipment: .barbell),
        .init(key: "wrist-curl", name: "Rosca de punho", nameEN: "Wrist Curl", primary: [.forearms], equipment: .dumbbell, rest: 45),

        // Pernas
        .init(key: "back-squat", name: "Agachamento livre", nameEN: "Back Squat", primary: [.quads, .glutes], secondary: [.hamstrings, .lowerBack], equipment: .barbell, rest: 180),
        .init(key: "front-squat", name: "Agachamento frontal", nameEN: "Front Squat", primary: [.quads], secondary: [.glutes], equipment: .barbell, rest: 150),
        .init(key: "leg-press", name: "Leg press 45°", nameEN: "Leg Press", primary: [.quads, .glutes], equipment: .machine, rest: 120),
        .init(key: "hack-squat", name: "Agachamento hack", nameEN: "Hack Squat", primary: [.quads], secondary: [.glutes], equipment: .machine, rest: 120),
        .init(key: "leg-extension", name: "Cadeira extensora", nameEN: "Leg Extension", primary: [.quads], equipment: .machine, rest: 60),
        .init(key: "lying-leg-curl", name: "Mesa flexora", nameEN: "Lying Leg Curl", primary: [.hamstrings], equipment: .machine, rest: 60),
        .init(key: "seated-leg-curl", name: "Cadeira flexora", nameEN: "Seated Leg Curl", primary: [.hamstrings], equipment: .machine, rest: 60),
        .init(key: "romanian-deadlift", name: "Stiff / levantamento terra romeno", nameEN: "Romanian Deadlift", primary: [.hamstrings, .glutes], secondary: [.lowerBack], equipment: .barbell, rest: 120),
        .init(key: "bulgarian-split-squat", name: "Agachamento búlgaro", nameEN: "Bulgarian Split Squat", primary: [.quads, .glutes], equipment: .dumbbell, laterality: .unilateral),
        .init(key: "walking-lunge", name: "Avanço (passada)", nameEN: "Walking Lunge", primary: [.quads, .glutes], secondary: [.hamstrings], equipment: .dumbbell, laterality: .unilateral),
        .init(key: "hip-thrust", name: "Elevação pélvica", nameEN: "Hip Thrust", primary: [.glutes], secondary: [.hamstrings], equipment: .barbell),
        .init(key: "hip-adduction", name: "Cadeira adutora", nameEN: "Hip Adduction Machine", primary: [.adductors], equipment: .machine, rest: 60),
        .init(key: "hip-abduction", name: "Cadeira abdutora", nameEN: "Hip Abduction Machine", primary: [.abductors, .glutes], equipment: .machine, rest: 60),
        .init(key: "standing-calf-raise", name: "Panturrilha em pé", nameEN: "Standing Calf Raise", primary: [.calves], equipment: .machine, rest: 60),
        .init(key: "seated-calf-raise", name: "Panturrilha sentado", nameEN: "Seated Calf Raise", primary: [.calves], equipment: .machine, rest: 60),

        // Core
        .init(key: "plank", name: "Prancha", nameEN: "Plank", primary: [.abs], secondary: [.obliques], equipment: .bodyweight, kind: .isometric, rest: 60),
        .init(key: "side-plank", name: "Prancha lateral", nameEN: "Side Plank", primary: [.obliques], equipment: .bodyweight, laterality: .unilateral, kind: .isometric, rest: 45),
        .init(key: "crunch", name: "Abdominal supra", nameEN: "Crunch", primary: [.abs], equipment: .bodyweight, kind: .repsOnly, rest: 45),
        .init(key: "hanging-leg-raise", name: "Elevação de pernas na barra", nameEN: "Hanging Leg Raise", primary: [.abs], equipment: .bodyweight, kind: .repsOnly, rest: 60),
        .init(key: "cable-crunch", name: "Abdominal na polia", nameEN: "Cable Crunch", primary: [.abs], equipment: .cable, rest: 60),
        .init(key: "russian-twist", name: "Abdominal russo", nameEN: "Russian Twist", primary: [.obliques], equipment: .bodyweight, kind: .repsOnly, rest: 45),

        // Cardio
        .init(key: "treadmill", name: "Esteira", nameEN: "Treadmill", primary: [.cardio], equipment: .cardio, kind: .timeOrDistance, rest: 0),
        .init(key: "stationary-bike", name: "Bicicleta ergométrica", nameEN: "Stationary Bike", primary: [.cardio], equipment: .cardio, kind: .timeOrDistance, rest: 0),
        .init(key: "elliptical", name: "Elíptico", nameEN: "Elliptical", primary: [.cardio], equipment: .cardio, kind: .timeOrDistance, rest: 0),
        .init(key: "rowing-machine", name: "Remo ergômetro", nameEN: "Rowing Machine", primary: [.cardio, .fullBody], equipment: .cardio, kind: .timeOrDistance, rest: 0),
        .init(key: "stair-climber", name: "Escada (simulador)", nameEN: "Stair Climber", primary: [.cardio], equipment: .cardio, kind: .timeOrDistance, rest: 0),
        .init(key: "jump-rope", name: "Pular corda", nameEN: "Jump Rope", primary: [.cardio], equipment: .other, kind: .timeOrDistance, rest: 60),
        .init(key: "kettlebell-swing", name: "Swing com kettlebell", nameEN: "Kettlebell Swing", primary: [.glutes, .hamstrings], secondary: [.fullBody], equipment: .kettlebell, rest: 60),
    ]

    static func entry(forKey key: String) -> CatalogExercise? { all.first { $0.key == key } }
}

/// Seed versionado e idempotente.
///
/// - Base nova: insere o catálogo inteiro e grava `seededCatalogVersion`.
/// - Versão do catálogo subiu: insere só os exercícios com `addedInVersion` maior que a versão
///   já semeada e cuja `catalogKey` ainda não existe.
/// - Mesma versão: não faz nada — **um exercício embutido apagado pelo usuário não volta**.
///
/// `defaults == nil` (testes/previews em memória) ignora o registro de versão e insere toda
/// chave ausente. Com CloudKit (futuro), dois aparelhos podem semear o mesmo exercício:
/// a deduplicação deve agrupar por `catalogKey` mantendo o registro mais antigo e
/// reapontando `RoutineExercise.exercise` antes de apagar os duplicados.
@MainActor
enum ExerciseCatalogSeeder {
    static let versionKey = "seededCatalogVersion"

    @discardableResult
    static func seedIfNeeded(in context: ModelContext, defaults: UserDefaults? = nil,
                             catalog: [CatalogExercise] = ExerciseCatalog.all,
                             version: Int = ExerciseCatalog.version) throws -> Int {
        let seededVersion = defaults?.integer(forKey: versionKey) ?? 0
        guard defaults == nil || seededVersion < version else { return 0 }
        let existing = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.catalogKey != nil }))
        let keys = Set(existing.compactMap(\.catalogKey))
        var inserted = 0
        for item in catalog where item.addedInVersion > seededVersion && !keys.contains(item.key) {
            context.insert(Exercise(name: item.name, primaryMuscles: item.primary, secondaryMuscles: item.secondary,
                                    equipment: item.equipment, laterality: item.laterality,
                                    measurementKind: item.kind, defaultRestSeconds: item.rest,
                                    isBuiltIn: true, catalogKey: item.key))
            inserted += 1
        }
        if inserted > 0 { try context.save() }
        defaults?.set(version, forKey: versionKey)
        return inserted
    }
}
