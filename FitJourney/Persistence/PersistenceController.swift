import Foundation
import SwiftData

/// Schema V1. Quando surgir a V2: copie os modelos atuais para dentro de `SchemaV1`
/// (congelados), crie `SchemaV2` com os novos e adicione o `MigrationStage` no plano.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            TrainingProgram.self, Routine.self, Exercise.self, RoutineExercise.self, SetPrescription.self,
            WorkoutSession.self, SessionExercise.self, SetLog.self,
            NutritionPlan.self, NutritionDay.self, Meal.self, MealItem.self,
            FoodItem.self, FoodEntry.self, WaterLog.self,
        ]
    }
}

enum FitJourneyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Fábrica do `ModelContainer`.
enum PersistenceController {
    static var schema: Schema { Schema(versionedSchema: SchemaV1.self) }

    /// - Parameter inMemory: `true` para testes e previews.
    /// CloudKit fica desligado (`.none`) até o ciclo de sincronização; os modelos já são compatíveis.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            inMemory ? "FitJourney-\(UUID().uuidString)" : "FitJourney", // em memória: isolado por instância
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: FitJourneyMigrationPlan.self,
                                  configurations: [configuration])
    }

    /// Container do app (disco) com o catálogo de exercícios garantido.
    @MainActor
    static func makeAppContainer() -> ModelContainer {
        do {
            let container = try makeContainer()
            try ExerciseCatalogSeeder.seedIfNeeded(in: container.mainContext, defaults: .standard)
            return container
        } catch {
            // Dívida aceita: falha ao abrir o banco derruba o app. Antes do lançamento, trocar por
            // tela de erro com opção de exportar/recuperar em vez de `fatalError`.
            fatalError("Não foi possível abrir o banco do FitJourney: \(error)")
        }
    }

    /// Container em memória com catálogo + `SampleData`, para previews.
    @MainActor
    static let preview: ModelContainer = {
        do {
            let container = try makeContainer(inMemory: true)
            try SampleData.insert(into: container.mainContext)
            return container
        } catch {
            fatalError("Falha ao montar dados de preview: \(error)")
        }
    }()
}
