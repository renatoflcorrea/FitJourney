import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// Exemplos de rascunho válidos (também úteis como documentação do contrato).
enum DraftExamples {
    static let program = #"""
    {
      "name": "ABC Hipertrofia 4x",
      "goal": "hypertrophy",
      "goalText": "Ganhar massa com 60 min por sessão",
      "scheduleMode": "weekly",
      "durationWeeks": 8,
      "notes": null,
      "routines": [
        {
          "name": "A — Peito e tríceps",
          "symbol": "A",
          "weekdays": ["monday", "thursday"],
          "notes": null,
          "exercises": [
            {
              "name": "Supino reto com barra",
              "catalogKey": "bench-press",
              "restSeconds": 120,
              "groupLabel": null,
              "notes": "Banco reto",
              "sets": [
                {"kind": "warmup", "repTarget": {"kind": "fixed", "reps": 15, "min": null, "max": null}, "holdSeconds": null,
                 "load": {"kind": "weight", "value": 20, "unit": "kg"}, "restSeconds": 60, "tempo": null, "rir": null, "rpe": null, "cardio": null, "notes": null},
                {"kind": "working", "repTarget": {"kind": "range", "reps": null, "min": 8, "max": 12}, "holdSeconds": null,
                 "load": {"kind": "weight", "value": 40, "unit": "kg"}, "restSeconds": null, "tempo": "3-1-1-0", "rir": 2, "rpe": null, "cardio": null, "notes": null}
              ]
            },
            {
              "name": "Mergulho entre bancos",
              "catalogKey": null,
              "restSeconds": 60,
              "groupLabel": "bi1",
              "notes": null,
              "sets": [
                {"kind": "toFailure", "repTarget": {"kind": "amrap", "reps": null, "min": null, "max": null}, "holdSeconds": null,
                 "load": {"kind": "bodyweight", "value": 0, "unit": "kg"}, "restSeconds": null, "tempo": null, "rir": null, "rpe": null, "cardio": null, "notes": null}
              ]
            }
          ]
        },
        {
          "name": "B — Costas e cardio",
          "symbol": null,
          "weekdays": ["tuesday", "friday"],
          "notes": null,
          "exercises": [
            {
              "name": "Prancha",
              "catalogKey": null,
              "restSeconds": null,
              "groupLabel": null,
              "notes": null,
              "sets": [
                {"kind": "working", "repTarget": null, "holdSeconds": 45, "load": null, "restSeconds": 30, "tempo": null, "rir": null, "rpe": null, "cardio": null, "notes": null}
              ]
            },
            {
              "name": "Esteira",
              "catalogKey": null,
              "restSeconds": null,
              "groupLabel": null,
              "notes": null,
              "sets": [
                {"kind": "working", "repTarget": null, "holdSeconds": null, "load": null, "restSeconds": null, "tempo": null, "rir": null, "rpe": 6,
                 "cardio": {"durationSeconds": 1200, "distanceMeters": null, "level": null, "speedKmh": 9.5, "inclinePercent": 2, "heartRateZone": 2}, "notes": null}
              ]
            }
          ]
        }
      ]
    }
    """#

    static let nutrition = #"""
    {
      "name": "Plano 2.200 kcal",
      "goal": "Recomposição",
      "notes": null,
      "targets": {"kcal": 2200, "protein": 160, "carbs": 220, "fat": 70, "fiber": 30, "waterMilliliters": 3000},
      "days": [
        {
          "name": "Todos os dias",
          "weekdays": [],
          "meals": [
            {
              "name": "Café da manhã",
              "time": "07:30",
              "notes": null,
              "items": [
                {"name": "Ovos mexidos", "quantity": 3, "unit": "unit", "kcal": 210, "protein": 18, "carbs": 2, "fat": 15, "fiber": 0, "notes": null,
                 "substitutions": [{"name": "Iogurte grego", "quantity": 170, "unit": "grams", "kcal": 150, "protein": 15, "carbs": 6, "fat": 7, "notes": null}]},
                {"name": "Pão integral", "quantity": 2, "unit": "slice", "kcal": 140, "protein": 6, "carbs": 24, "fat": 2, "fiber": 4, "notes": null, "substitutions": []}
              ]
            }
          ]
        },
        {
          "name": "Dia de treino",
          "weekdays": ["monday", "wednesday"],
          "meals": [
            {"name": "Pré-treino", "time": "17:00", "notes": null,
             "items": [{"name": "Banana", "quantity": 1, "unit": "unit", "kcal": 90, "protein": 1, "carbs": 23, "fat": 0, "fiber": 3, "notes": null, "substitutions": []}]}
          ]
        }
      ]
    }
    """#

    /// Substitui um trecho do exemplo (para gerar inválidos a partir do válido).
    static func program(replacing old: String, with new: String) -> String {
        precondition(program.contains(old), "trecho ausente: \(old)")
        return program.replacingOccurrences(of: old, with: new)
    }

    static func nutrition(replacing old: String, with new: String) -> String {
        precondition(nutrition.contains(old), "trecho ausente: \(old)")
        return nutrition.replacingOccurrences(of: old, with: new)
    }
}

@Suite("AI · Contratos de rascunho")
struct AIDraftContractTests {
    private static func contract(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "contracts").appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("schema embutido == arquivo em contracts/", arguments: [
        ("program-draft-v1.schema.json", DraftSchemas.programDraftV1),
        ("nutrition-plan-draft-v1.schema.json", DraftSchemas.nutritionPlanDraftV1),
    ])
    func embeddedMatchesFile(pair: (String, String)) throws {
        let file = try JSONValue.parse(try Self.contract(pair.0))
        #expect(file == (try JSONValue.parse(pair.1)))
    }

    @Test("parâmetros das ferramentas propose_* == contrato sem $schema/$id")
    func toolSchemasMatchContract() throws {
        for (name, contract) in [(FitnessToolbox.Name.proposeProgram, DraftSchemas.programDraftV1),
                                 (.proposeNutritionPlan, DraftSchemas.nutritionPlanDraftV1)] {
            guard case var .object(expected) = try JSONValue.parse(contract) else { Issue.record("schema não é objeto"); continue }
            expected.removeValue(forKey: "$schema")
            expected.removeValue(forKey: "$id")
            let tool = try JSONValue.parse(FitnessToolbox.spec(name).parametersSchema)
            #expect(tool == .object(expected))
        }
    }

    @Test("todo objeto do schema é estrito: additionalProperties false e todas as chaves obrigatórias")
    func schemasAreStrict() throws {
        func walk(_ value: JSONValue, path: String) {
            switch value {
            case let .object(object):
                if object["type"] == .string("object") {
                    #expect(object["additionalProperties"] == .bool(false), "\(path)")
                    let keys = Set(object["properties"]?.objectValue?.keys.map { $0 } ?? [])
                    let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                    #expect(keys == required, "\(path)")
                }
                for (key, child) in object { walk(child, path: "\(path).\(key)") }
            case let .array(array):
                for (index, child) in array.enumerated() { walk(child, path: "\(path)[\(index)]") }
            default:
                break
            }
        }
        walk(try JSONValue.parse(DraftSchemas.programDraftV1), path: "program")
        walk(try JSONValue.parse(DraftSchemas.nutritionPlanDraftV1), path: "nutrition")
    }

    @Test("exemplo válido de programa passa no schema e decodifica")
    func validProgram() throws {
        guard case let .valid(draft) = DraftValidation.program(DraftExamples.program) else {
            Issue.record("deveria ser válido: \(DraftValidation.program(DraftExamples.program))")
            return
        }
        #expect(draft.routines.count == 2)
        #expect(draft.routines[0].exercises[0].sets[1].repTarget?.repTarget == .range(min: 8, max: 12))
        #expect(draft.routines[0].exercises[0].sets[1].effort == .rir(2))
        #expect(draft.routines[0].exercises[1].sets[0].load?.load == .bodyweight(delta: 0, unit: .kg))
        #expect(draft.routines[1].exercises[1].sets[0].cardio?.target.durationSeconds == 1200)
    }

    @Test("exemplo válido de plano alimentar passa no schema e decodifica")
    func validNutrition() throws {
        guard case let .valid(draft) = DraftValidation.nutritionPlan(DraftExamples.nutrition) else {
            Issue.record("deveria ser válido")
            return
        }
        #expect(draft.days[0].meals[0].minutesFromMidnight == 7 * 60 + 30)
        #expect(draft.targets.targets.kcal == 2200)
        #expect(draft.days[0].meals[0].items[0].substitutions.first?.substitution.name == "Iogurte grego")
    }

    @Test("programas inválidos são rejeitados", arguments: [
        DraftExamples.program(replacing: #""goal": "hypertrophy","#, with: #""goal": "bulking","#),                  // enum
        DraftExamples.program(replacing: #""durationWeeks": 8,"#, with: ""),                                            // chave obrigatória
        DraftExamples.program(replacing: #""notes": null,"#, with: #""notes": null, "extra": 1,"#),                     // propriedade extra
        DraftExamples.program(replacing: #""min": 8, "max": 12"#, with: #""min": 12, "max": 8"#),                       // semântica
        DraftExamples.program(replacing: #""weekdays": ["tuesday", "friday"]"#, with: #""weekdays": []"#),              // weekly sem dias
        DraftExamples.program(replacing: #""rir": 2"#, with: #""rir": 9"#),                                             // máximo
        DraftExamples.program(replacing: #""durationWeeks": 8"#, with: #""durationWeeks": 2.5"#),                       // integer
        DraftExamples.program(replacing: #""rir": 2, "rpe": null"#, with: #""rir": 2, "rpe": 8"#),                      // rir e rpe
        #"{"name": "x"}"#,
        "isto não é JSON",
    ])
    func invalidPrograms(json: String) {
        guard case let .invalid(issues) = DraftValidation.program(json) else {
            Issue.record("deveria ser inválido")
            return
        }
        #expect(!issues.isEmpty)
    }

    @Test("planos alimentares inválidos são rejeitados", arguments: [
        DraftExamples.nutrition(replacing: #""time": "07:30""#, with: #""time": "7h30""#),
        DraftExamples.nutrition(replacing: #""unit": "slice""#, with: #""unit": "fatia""#),
        DraftExamples.nutrition(replacing: #""weekdays": ["monday", "wednesday"]"#, with: #""weekdays": []"#),         // dois "todos os dias"
        DraftExamples.nutrition(replacing: #""kcal": 2200"#, with: #""kcal": -5"#),
        DraftExamples.nutrition(replacing: #""weekdays": ["monday", "wednesday"]"#, with: #""weekdays": ["monday", "monday"]"#),
    ])
    func invalidNutrition(json: String) {
        guard case .invalid = DraftValidation.nutritionPlan(json) else {
            Issue.record("deveria ser inválido")
            return
        }
    }

    @Test("o validador explica onde está o erro")
    func validatorPaths() throws {
        let validator = try JSONSchemaValidator(schemaJSON: DraftSchemas.programDraftV1)
        let value = try JSONValue.parse(DraftExamples.program(replacing: #""unit": "kg"}, "restSeconds": 60"#,
                                                              with: #""unit": "stone"}, "restSeconds": 60"#))
        let issues = validator.validate(value)
        #expect(issues.contains { $0.hasPrefix("$.routines[0].exercises[0].sets[0].load.unit") })
    }
}

@Suite("AI · DraftApplier")
@MainActor
struct AIDraftApplierTests {
    @Test("programa vira modelos SwiftData: origin .ai, inativo, catálogo casado, exercícios novos criados")
    func applyProgram() throws {
        let fixture = try PersistenceFixture()
        _ = try fixture.makeProgram(name: "Atual", activate: true)
        guard case let .valid(draft) = DraftValidation.program(DraftExamples.program) else { Issue.record("inválido"); return }
        let exercisesBefore = try fixture.count(Exercise.self)

        let applier = DraftApplier(context: fixture.context)
        let matches = try applier.exerciseMatches(for: draft)
        #expect(matches[0][0]?.catalogKey == "bench-press")

        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let program = try applier.makeProgram(from: draft, startDate: start)
        #expect(program.origin == .ai)
        #expect(!program.isActive)
        #expect(try fixture.programs.activeProgram()?.name == "Atual")
        #expect(program.scheduleMode == .weekly)
        #expect(program.weekProgress(on: start)?.of == 8)
        #expect(program.sortedRoutines.map(\.symbol) == ["A", "B"])
        #expect(program.sortedRoutines[0].weekdays == [.monday, .thursday])

        let bench = program.sortedRoutines[0].sortedExercises[0]
        #expect(bench.exercise?.catalogKey == "bench-press")
        #expect(bench.restSeconds == 120)
        #expect(bench.sortedSets.map(\.kind) == [.warmup, .working])
        #expect(bench.sortedSets[1].initialLoad == .kg(40))
        #expect(bench.sortedSets[1].currentLoad == nil)
        #expect(bench.sortedSets[1].tempo == "3-1-1-0")
        #expect(bench.sortedSets[1].effort == .rir(2))

        let dips = program.sortedRoutines[0].sortedExercises[1]
        #expect(dips.exercise?.isBuiltIn == false)
        #expect(dips.exercise?.measurementKind == .repsOnly)
        #expect(dips.groupID != nil)

        let routineB = program.sortedRoutines[1].sortedExercises
        #expect(routineB[0].exercise?.measurementKind == .isometric)
        #expect(routineB[0].sortedSets[0].holdSeconds == 45)
        #expect(routineB[1].exercise?.measurementKind == .timeOrDistance)
        #expect(routineB[1].sortedSets[0].cardio?.speedKmh == 9.5)

        #expect(routineB[0].exercise?.catalogKey == "plank") // casado pelo nome
        #expect(try fixture.count(Exercise.self) == exercisesBefore + 1) // só o mergulho é novo
    }

    @Test("nomes casam sem acento/maiúsculas e pelo nome em inglês do catálogo")
    func matcher() throws {
        let fixture = try PersistenceFixture()
        let catalog = try fixture.context.fetch(FetchDescriptor<Exercise>())
        #expect(ExerciseMatcher.match(name: "SUPINO reto  com barra", catalogKey: nil, in: catalog)?.catalogKey == "bench-press")
        #expect(ExerciseMatcher.match(name: "Barbell Bench Press", catalogKey: nil, in: catalog)?.catalogKey == "bench-press")
        #expect(ExerciseMatcher.match(name: "Algo inventado", catalogKey: "nao-existe", in: catalog) == nil)
    }

    @Test("plano alimentar vira modelos SwiftData: author .ai, inativo, horários e substituições")
    func applyNutrition() throws {
        let fixture = try PersistenceFixture(seed: false)
        guard case let .valid(draft) = DraftValidation.nutritionPlan(DraftExamples.nutrition) else { Issue.record("inválido"); return }
        let plan = try DraftApplier(context: fixture.context).makeNutritionPlan(from: draft)
        #expect(plan.author == .ai)
        #expect(!plan.isActive)
        #expect(plan.targets.kcal == 2200)
        #expect(plan.targets.waterMilliliters == 3000)
        #expect(plan.sortedDays.count == 2)
        #expect(plan.sortedDays[0].appliesToAllDays)
        #expect(plan.sortedDays[1].weekdays == [.monday, .wednesday])
        let breakfast = try #require(plan.sortedDays[0].sortedMeals.first)
        #expect(breakfast.minutesFromMidnight == 450)
        #expect(breakfast.sortedItems.map(\.name) == ["Ovos mexidos", "Pão integral"])
        #expect(breakfast.sortedItems[0].unit == .unit)
        #expect(breakfast.sortedItems[0].substitutions.first?.values.protein == 15)
        #expect(breakfast.plannedValues.kcal == 350)
    }
}
