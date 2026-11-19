import Foundation
import Testing
@testable import FitJourney

/// Preenche com `null` as chaves obrigatórias ausentes (o `JSONEncoder` omite `nil`), como o modelo precisa escrever no
/// modo estrito. Serve para medir a saída real de cada contrato.
enum StrictJSON {
    static func encode<T: Encodable>(_ value: T, schema: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        let tree = try JSONDecoder().decode(JSONValue.self, from: data)
        let root = try JSONValue.parse(schema)
        let defs = root["$defs"]?.objectValue ?? [:]
        return fill(tree, root, defs: defs).jsonString()
    }

    static func fill(_ value: JSONValue, _ schema: JSONValue, defs: [String: JSONValue]) -> JSONValue {
        var schema = schema
        if let ref = schema["$ref"]?.stringValue, let name = ref.split(separator: "/").last, let target = defs[String(name)] {
            schema = target
        }
        if let options = schema["anyOf"]?.arrayValue {
            if case .null = value { return .null }
            let option = options.first { $0["type"]?.stringValue != "null" } ?? .null
            return fill(value, option, defs: defs)
        }
        switch value {
        case let .object(object):
            let properties = schema["properties"]?.objectValue ?? [:]
            var out = object
            for key in (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) where out[key] == nil { out[key] = .null }
            for (key, child) in out { if let sub = properties[key] { out[key] = fill(child, sub, defs: defs) } }
            return .object(out)
        case let .array(items):
            guard let itemSchema = schema["items"] else { return value }
            return .array(items.map { fill($0, itemSchema, defs: defs) })
        default:
            return value
        }
    }
}

enum TypicalImports {
    static let exerciseNames: [(String, String, String?)] = [
        ("Supino reto", "Supino reto com barra", "bench-press"), ("Supino incl. halt.", "Supino inclinado com halteres", nil),
        ("Crucifixo", "Crucifixo com halteres", nil), ("Cross over", "Crossover na polia", nil),
        ("Tríceps corda", "Tríceps na polia (corda)", "triceps-pushdown"), ("Tríceps testa", "Tríceps testa", nil),
        ("Mergulho banco", "Mergulho no banco", nil),
    ]

    /// 4 fichas × 7 exercícios × 4 séries iguais ("4x8-12, 32 kg").
    static func program(setSource: Bool) -> ProgramImport {
        let source = ImportSource(file: "ficha-treino.pdf", page: 1)
        let routines = ["Peito e tríceps", "Costas e bíceps", "Perna", "Ombro e abdômen"].enumerated().map { r, name in
            ProgramImport.RoutineImport(
                name: name, symbol: String("ABCD".map { $0 }[r]), weekdays: [[.monday], [.tuesday], [.thursday], [.friday]][r],
                notes: nil, confidence: .high, source: ImportSource(file: source.file, page: r + 1),
                exercises: exerciseNames.map { written, normalized, key in
                    let exerciseSource = ImportSource(file: source.file, page: r + 1)
                    let set = ProgramImport.SetImport(
                        kind: .working, repTarget: .init(kind: .range, reps: nil, min: 8, max: 12), holdSeconds: nil,
                        load: .init(kind: .weight, value: 32, unit: .kg), loadAsWritten: nil, restSeconds: nil, tempo: nil,
                        rir: nil, rpe: nil, cardio: nil, notes: nil, confidence: .high, source: setSource ? exerciseSource : nil)
                    return ProgramImport.ExerciseImport(asWritten: written, name: normalized, catalogKey: key, restSeconds: 60,
                                                        groupLabel: nil, notes: nil, confidence: .high, source: exerciseSource,
                                                        sets: Array(repeating: set, count: 4))
                })
        }
        return ProgramImport(name: "Hipertrofia — Ana", goal: .hypertrophy, goalText: "Hipertrofia", scheduleMode: .weekly,
                             durationWeeks: 8, notes: nil, confidence: .high, source: source, routines: routines,
                             ambiguities: [])
    }

    /// 1 dia × 6 refeições × 5 itens; um item por refeição com substituição. `macros`: valores em todos os itens.
    static func nutrition(macros: Bool) -> NutritionImport {
        let source = ImportSource(file: "dieta.pdf", page: 1)
        let foods: [(String, String, Double, FoodUnit)] = [
            ("2 ovos mexidos", "Ovo mexido", 2, .unit), ("1 fatia pão integral", "Pão integral", 1, .slice),
            ("150 g frango grelhado", "Peito de frango grelhado", 150, .grams), ("4 col. arroz", "Arroz branco", 4, .tablespoon),
            ("200 ml leite desnatado", "Leite desnatado", 200, .milliliters),
        ]
        let meals = ["Café da manhã", "Lanche da manhã", "Almoço", "Lanche da tarde", "Jantar", "Ceia"].enumerated().map { m, name in
            NutritionImport.MealImport(
                name: name, time: clockString(minutes: 7 * 60 + m * 150), notes: nil, confidence: .high, source: source,
                items: foods.enumerated().map { i, food in
                    NutritionImport.ItemImport(
                        asWritten: food.0, name: food.1, quantity: food.2, unit: food.3,
                        kcal: macros ? 140 : nil, protein: macros ? 12 : nil, carbs: macros ? 1 : nil, fat: macros ? 10 : nil,
                        fiber: nil, notes: nil, confidence: .high, source: source,
                        substitutions: i == 0 ? [.init(name: "Tofu", quantity: 100, unit: .grams, kcal: nil, protein: nil,
                                                       carbs: nil, fat: nil, notes: nil)] : [])
                })
        }
        return NutritionImport(name: "Plano da nutri", goal: "Emagrecimento", notes: nil, confidence: .high, source: source,
                               targets: .init(kcal: 2000, protein: 140, carbs: nil, fat: nil, fiber: nil, waterMilliliters: 3000,
                                              confidence: .high, source: source),
                               days: [.init(name: "Todos os dias", weekdays: [], notes: nil, confidence: .high, source: source,
                                            meals: meals)],
                               ambiguities: [])
    }
}

@MainActor
@Suite("Copiloto — importação mais rápida (contratos v2, remendo, esforço)")
struct CopilotImportSpeedTests {
    private static func contract(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "contracts").appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Tokens estimados: ~3,5 caracteres por token em JSON com texto em português (estimativa, não tokenizador).
    private static func tokens(_ characters: Int) -> Int { Int((Double(characters) / 3.5).rounded()) }

    @Test("schemas v2 embutidos == arquivos em contracts/", arguments: [
        ("program-import-v2.schema.json", ImportSchemas.programImportV2),
        ("nutrition-import-v2.schema.json", ImportSchemas.nutritionImportV2),
    ])
    func embeddedMatchesFile(pair: (String, String)) throws {
        #expect(try JSONValue.parse(try Self.contract(pair.0)) == (try JSONValue.parse(pair.1)))
    }

    // MARK: T0 — tamanho da saída

    @Test("T0: saída do programa típico (4 × 7 × 4) e da dieta típica (6 × 5), v1 contra v2")
    func outputSizes() throws {
        let programV1 = try StrictJSON.encode(TypicalImports.program(setSource: true), schema: ImportSchemas.programImportV1)
        let programV2 = try StrictJSON.encode(TypicalImports.program(setSource: true).compacted(),
                                              schema: ImportSchemas.programImportV2)
        let dietV1 = try StrictJSON.encode(TypicalImports.nutrition(macros: false), schema: ImportSchemas.nutritionImportV1)
        let dietV2 = try StrictJSON.encode(TypicalImports.nutrition(macros: false).compacted(),
                                           schema: ImportSchemas.nutritionImportV2)
        let macrosV1 = try StrictJSON.encode(TypicalImports.nutrition(macros: true), schema: ImportSchemas.nutritionImportV1)
        let macrosV2 = try StrictJSON.encode(TypicalImports.nutrition(macros: true).compacted(),
                                             schema: ImportSchemas.nutritionImportV2)
        // Cada saída é exatamente o que o modo estrito exige (passa no próprio schema).
        for (json, schema) in [(programV1, ImportSchemas.programImportV1), (programV2, ImportSchemas.programImportV2),
                               (dietV1, ImportSchemas.nutritionImportV1), (dietV2, ImportSchemas.nutritionImportV2),
                               (macrosV1, ImportSchemas.nutritionImportV1), (macrosV2, ImportSchemas.nutritionImportV2)] {
            #expect(try JSONSchemaValidator(schemaJSON: schema).validate(try JSONValue.parse(json)).isEmpty)
        }
        let report = """
            programa 4x7x4: v1 \(programV1.count) chars (~\(Self.tokens(programV1.count)) tokens) → v2 \(programV2.count) chars (~\(Self.tokens(programV2.count)) tokens)
            dieta 6x5 sem macros: v1 \(dietV1.count) (~\(Self.tokens(dietV1.count))) → v2 \(dietV2.count) (~\(Self.tokens(dietV2.count)))
            dieta 6x5 com macros: v1 \(macrosV1.count) (~\(Self.tokens(macrosV1.count))) → v2 \(macrosV2.count) (~\(Self.tokens(macrosV2.count)))
            schema programa: v1 \(DraftValidation.toolParameters(fromContract: ImportSchemas.programImportV1).count) → v2 \(DraftValidation.toolParameters(fromContract: ImportSchemas.programImportV2).count) chars
            """
        print(report)
        if let path = ProcessInfo.processInfo.environment["FJ_METRICS_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(programV2.count * 3 < programV1.count) // ao menos 3× menor
        #expect(dietV2.count < dietV1.count)
        #expect(macrosV2.count <= macrosV1.count)
    }

    // MARK: T1 — expansão idêntica ao v1

    @Test("programa: v2 expandido == v1 (modelo e rascunho), incluindo grupos mistos e campos raros")
    func programExpansionMatchesV1() throws {
        var program = TypicalImports.program(setSource: false)
        // Aquecimento + válidas + uma isométrica com RIR e carga escrita: grupos distintos, na ordem.
        var warmup = program.routines[0].exercises[0].sets[0]
        warmup.kind = .warmup
        warmup.repTarget = .init(kind: .fixed, reps: 15, min: nil, max: nil)
        warmup.load = nil
        warmup.loadAsWritten = "placa 3"
        warmup.confidence = .low
        warmup.notes = "carga ilegível"
        var hold = program.routines[0].exercises[0].sets[0]
        hold.repTarget = nil
        hold.holdSeconds = 30
        hold.rir = 2
        hold.tempo = "3-1-1-0"
        program.routines[0].exercises[0].sets = [warmup, warmup] + program.routines[0].exercises[0].sets + [hold]
        program.routines[1].exercises[1].sets[1].repTarget = .init(kind: .amrap, reps: nil, min: nil, max: nil)
        program.routines[2].exercises[0].sets = [] // sem séries escritas

        let compact = program.compacted()
        #expect(compact.routines[0].exercises[0].setGroups.map(\.count) == [2, 4, 1])
        #expect(compact.routines[0].exercises[1].setGroups.map(\.count) == [4])
        let v2JSON = try StrictJSON.encode(compact, schema: ImportSchemas.programImportV2)
        guard case let .valid(fromV2) = ImportValidation.program(v2JSON) else {
            Issue.record("v2 inválido: \(ImportValidation.program(v2JSON))"); return
        }
        #expect(fromV2 == program)
        let v1JSON = try StrictJSON.encode(program, schema: ImportSchemas.programImportV1)
        guard case let .valid(fromV1) = ImportValidation.program(v1JSON) else { Issue.record("v1 inválido"); return }
        #expect(fromV1 == fromV2)
        #expect(fromV1.makeDraft() == fromV2.makeDraft())
    }

    @Test("dieta: v2 expandido == v1 (modelo e rascunho)")
    func nutritionExpansionMatchesV1() throws {
        for macros in [false, true] {
            let plan = TypicalImports.nutrition(macros: macros)
            let v2JSON = try StrictJSON.encode(plan.compacted(), schema: ImportSchemas.nutritionImportV2)
            guard case let .valid(fromV2) = ImportValidation.nutrition(v2JSON) else {
                Issue.record("v2 inválido: \(ImportValidation.nutrition(v2JSON))"); return
            }
            #expect(fromV2 == plan)
            let v1JSON = try StrictJSON.encode(plan, schema: ImportSchemas.nutritionImportV1)
            guard case let .valid(fromV1) = ImportValidation.nutrition(v1JSON) else { Issue.record("v1 inválido"); return }
            #expect(fromV1 == fromV2)
            #expect(fromV1.makeDraft() == fromV2.makeDraft())
        }
    }

    @Test("v1 continua decodificável (respostas e importações pendentes antigas)")
    func v1StillDecodes() {
        guard case let .valid(program) = ImportValidation.program(ImportJSON.fourRoutines) else { Issue.record("v1"); return }
        #expect(program.routines.count == 4)
        guard case .valid = ImportValidation.nutrition(ImportJSON.nutrition()) else { Issue.record("v1 dieta"); return }
    }

    @Test("repetições em texto: fixa, faixa, amrap; fora de 1…100 é problema")
    func repsText() throws {
        #expect(ProgramImportV2.repTarget("12") == .init(kind: .fixed, reps: 12, min: nil, max: nil))
        #expect(ProgramImportV2.repTarget("8-12") == .init(kind: .range, reps: nil, min: 8, max: 12))
        #expect(ProgramImportV2.repTarget("AMRAP") == .init(kind: .amrap, reps: nil, min: nil, max: nil))
        #expect(ProgramImportV2.repTarget(nil) == nil)
        var compact = TypicalImports.program(setSource: false).compacted()
        compact.routines[0].exercises[0].setGroups[0].reps = "0"
        let json = try StrictJSON.encode(compact, schema: ImportSchemas.programImportV2)
        guard case let .invalid(issues) = ImportValidation.program(json) else { Issue.record("deveria falhar"); return }
        #expect(issues.contains { $0.contains("setGroups[0].reps") })
    }

    // MARK: T2 — remendos

    @Test("remendo do programa: troca, insere, remove, renomeia ficha e remove ficha sobre os ids enviados")
    func programPatch() throws {
        let base = TypicalImports.program(setSource: false)
        var newExercise = base.routines[0].exercises[0].compacted
        newExercise.asWritten = "Peck deck"
        newExercise.name = "Voador"
        newExercise.catalogKey = nil
        var replacement = base.routines[0].exercises[1].compacted
        replacement.setGroups = [.init(count: 3, kind: nil, reps: "10", load: nil, loadAsWritten: nil, restSeconds: nil,
                                       extra: nil, notes: nil, confidence: .high)]
        let patch = ProgramImportPatch(operations: [
            .init(op: .replaceExercise, id: "r0e1", after: nil, program: nil, routine: nil, exercise: replacement),
            .init(op: .insertExercise, id: "r0", after: "r0e1", program: nil, routine: nil, exercise: newExercise),
            .init(op: .insertExercise, id: "r0", after: nil, program: nil, routine: nil, exercise: newExercise),
            .init(op: .removeExercise, id: "r0e6", after: nil, program: nil, routine: nil, exercise: nil),
            .init(op: .updateRoutine, id: "r1", after: nil, program: nil,
                  routine: .init(name: "Costas", symbol: "B", weekdays: [.wednesday], notes: nil), exercise: nil),
            .init(op: .removeRoutine, id: "r3", after: nil, program: nil, routine: nil, exercise: nil),
            .init(op: .updateProgram, id: nil, after: nil,
                  program: .init(name: "Novo nome", goal: .strength, goalText: nil, scheduleMode: .weekly, durationWeeks: 4,
                                 notes: nil), routine: nil, exercise: nil),
        ], newAmbiguities: [ImportAmbiguity(path: "routines[0]", question: "Peck deck ou crucifixo?", options: [])])
        // O JSON da ferramenta passa no schema estrito do remendo.
        let json = try StrictJSON.encode(patch, schema: ProgramImportPatch.toolParameters)
        #expect(try JSONSchemaValidator(schemaJSON: ProgramImportPatch.toolParameters).validate(try JSONValue.parse(json)).isEmpty)
        let decoded = try JSONDecoder().decode(ProgramImportPatch.self, from: Data(json.utf8))
        let result = try decoded.applied(to: base)

        #expect(result.name == "Novo nome")
        #expect(result.goal == .strength)
        #expect(result.routines.map(\.name) == ["Peito e tríceps", "Costas", "Perna"])
        #expect(result.routines[1].weekdays == [.wednesday])
        let names = result.routines[0].exercises.map(\.asWritten)
        #expect(names == ["Peck deck", "Supino reto", "Supino incl. halt.", "Peck deck", "Crucifixo", "Cross over",
                          "Tríceps corda", "Tríceps testa"])
        #expect(result.routines[0].exercises[2].sets.count == 3)
        #expect(result.routines[0].exercises[2].sets.allSatisfy { $0.repTarget?.reps == 10 })
        #expect(result.routines[2].exercises == base.routines[2].exercises) // intocada
        #expect(result.ambiguities.count == 1)
    }

    @Test("remendo com id desconhecido ou de outra ficha é recusado")
    func programPatchRejectsUnknownIDs() {
        let base = TypicalImports.program(setSource: false)
        let bad: [ProgramImportPatch.Operation] = [
            .init(op: .removeExercise, id: "r9e0", after: nil, program: nil, routine: nil, exercise: nil),
            .init(op: .removeRoutine, id: "r0e0", after: nil, program: nil, routine: nil, exercise: nil),
            .init(op: .insertExercise, id: "r0", after: "r1e0", program: nil, routine: nil,
                  exercise: base.routines[0].exercises[0].compacted),
            .init(op: .replaceExercise, id: "r0e0", after: nil, program: nil, routine: nil, exercise: nil),
        ]
        for operation in bad {
            #expect(throws: ImportPatchError.self) {
                try ProgramImportPatch(operations: [operation], newAmbiguities: []).applied(to: base)
            }
        }
    }

    @Test("remendo da dieta: troca e remove refeição, metas e dia")
    func nutritionPatch() throws {
        let base = TypicalImports.nutrition(macros: false)
        var meal = base.days[0].meals[0].compacted
        meal.name = "Desjejum"
        meal.items = Array(meal.items.prefix(2))
        let patch = NutritionImportPatch(operations: [
            .init(op: .replaceMeal, id: "d0m0", after: nil, plan: nil, targets: nil, day: nil, meal: meal),
            .init(op: .removeMeal, id: "d0m5", after: nil, plan: nil, targets: nil, day: nil, meal: nil),
            .init(op: .insertMeal, id: "d0", after: "d0m2", plan: nil, targets: nil, day: nil, meal: meal),
            .init(op: .updateTargets, id: nil, after: nil, plan: nil,
                  targets: .init(kcal: 1800, protein: 150, carbs: nil, fat: nil, fiber: nil, waterMilliliters: nil,
                                 confidence: .high, source: nil), day: nil, meal: nil),
            .init(op: .updateDay, id: "d0", after: nil, plan: nil, targets: nil,
                  day: .init(name: "Seg a sex", weekdays: [.monday, .tuesday], notes: nil), meal: nil),
        ], newAmbiguities: [])
        let json = try StrictJSON.encode(patch, schema: NutritionImportPatch.toolParameters)
        #expect(try JSONSchemaValidator(schemaJSON: NutritionImportPatch.toolParameters).validate(try JSONValue.parse(json)).isEmpty)
        let result = try JSONDecoder().decode(NutritionImportPatch.self, from: Data(json.utf8)).applied(to: base)
        #expect(result.days[0].meals.map(\.name) == ["Desjejum", "Lanche da manhã", "Almoço", "Desjejum", "Lanche da tarde", "Jantar"])
        #expect(result.days[0].meals[0].items.count == 2)
        #expect(result.targets.kcal == 1800)
        #expect(result.days[0].name == "Seg a sex")
    }

    // MARK: Sessão: remendo, reparo, esforço, medição

    @Test("revisão pede só o remendo (ferramenta própria, foto compacta inteira, esforço baixo) e aplica")
    func reviseWithPatch() async throws {
        let fixture = try ImportFixture()
        let patch = #"""
        {"operations":[{"op":"updateRoutine","id":"r2","after":null,"program":null,"exercise":null,
          "routine":{"name":"Pernas","symbol":"C","weekdays":["thursday"],"notes":null}},
          {"op":"removeExercise","id":"r3e1","after":null,"program":null,"routine":null,"exercise":null}],
         "newAmbiguities":[]}
        """#
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines), .extraction(patch)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()

        #expect(session.programImport?.routines.map(\.name) == ["Peito e tríceps", "Ombro", "Pernas", "Costas e bíceps"])
        #expect(session.programImport?.routines[3].exercises.map(\.asWritten) == ["Puxada"])
        #expect(session.programImport?.ambiguities.isEmpty == true) // a dúvida respondida sai
        let request = try #require(gateway.requests.last)
        // Remendo primeiro; o objeto inteiro fica disponível só para acrescentar ficha/dia (o remendo não cria).
        #expect(request.tools.map(\.name) == ["submit_import_patch", "submit_extraction"])
        #expect(request.toolChoice == .required)
        #expect(request.effort == .low)
        let message = try #require(request.messages.last?.content)
        #expect(message.contains("\"id\":\"r3e1\""))
        #expect(message.contains("setGroups"))
        #expect(gateway.requests.first?.effort == .low)
        #expect(gateway.requests.first?.tools.first?.parametersSchema.contains("setGroups") == true)
        #expect(session.callMetrics.map(\.stage) == [.extract, .revise])
        #expect(session.callMetrics.last?.outputCharacters == patch.count)
    }

    @Test("revisão de programa grande manda a extração inteira (sem o corte de 60 mil caracteres)")
    func reviseLargeProgramWithoutTruncation() async throws {
        var large = TypicalImports.program(setSource: true)
        large.routines += large.routines.map { var r = $0; r.name = (r.name ?? "") + " 2"; return r }
        large.routines = Array(large.routines.prefix(8))
        large.ambiguities = [ImportAmbiguity(path: "routines[0]", question: "Descanso de 60 s?", options: ["Sim", "Não"])]
        let v1JSON = try StrictJSON.encode(large, schema: ImportSchemas.programImportV1)
        #expect(v1JSON.count > 60_000)
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(v1JSON), .extraction(#"{"operations":[],"newAmbiguities":[]}"#)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()
        let message = try #require(gateway.requests.last?.messages.last?.content)
        #expect(message.contains("\"id\":\"r7e6\"")) // o último exercício da última ficha chegou
        #expect(session.programImport?.routines.count == 8)
    }

    @Test("regra quebrada trivial é consertada no aparelho, sem segunda chamada")
    func trivialFixIsLocal() async throws {
        var set = ImportJSON.set()
        if case var .object(object) = set { object["rir"] = .number(2); object["rpe"] = .number(8); set = .object(object) }
        let json = ImportJSON.program(routines: [ImportJSON.routine("A", weekdays: ["monday", "monday"],
                                                                    exercises: [ImportJSON.exercise("Supino reto", key: "bench-press", sets: [set])])])
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(json)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(gateway.requests.count == 1)
        #expect(session.programImport?.routines[0].weekdays == [.monday])
        #expect(session.programImport?.routines[0].exercises[0].sets[0].rpe == nil)
        #expect(session.programImport?.routines[0].exercises[0].sets[0].rir == 2)
    }

    @Test("regra que precisa da IA é reparada por remendo (só as operações)")
    func repairByPatch() async throws {
        let broken = ImportJSON.program(routines: [ImportJSON.routine("A", weekdays: ["monday"], exercises: [
            ImportJSON.exercise("Supino reto", key: "bench-press"),
            ImportJSON.exercise("   "),
        ])])
        let fix = #"""
        {"operations":[{"op":"removeExercise","id":"r0e1","after":null,"program":null,"routine":null,"exercise":null}],
         "newAmbiguities":[]}
        """#
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(broken), .extraction(fix)])
        let session = fixture.session(.program, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(gateway.requests.count == 2)
        let repair = try #require(gateway.requests.last)
        #expect(repair.tools.map(\.name) == ["submit_import_patch", "submit_extraction"])
        #expect(repair.messages.last?.parts.isEmpty == true)
        #expect(repair.messages.last?.content.contains("asWritten: vazio") == true)
        #expect(session.programImport?.routines[0].exercises.count == 1)
        #expect(session.callMetrics.map(\.stage) == [.extract, .repair])
    }

    @Test("dieta: extração v2 com macros e revisão por remendo")
    func nutritionV2Session() async throws {
        let plan = TypicalImports.nutrition(macros: true)
        var withDoubt = plan
        withDoubt.ambiguities = [ImportAmbiguity(path: "days[0]", question: "Ceia é opcional?", options: ["Sim", "Não"])]
        let v2JSON = try StrictJSON.encode(withDoubt.compacted(), schema: ImportSchemas.nutritionImportV2)
        let patch = #"{"operations":[{"op":"removeMeal","id":"d0m5","after":null,"plan":null,"targets":null,"day":null,"meal":null}],"newAmbiguities":[]}"#
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(v2JSON), .extraction(patch)])
        let session = fixture.session(.nutrition, gateway: gateway)
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(session.nutritionImport?.days[0].meals[0].items[0].kcal == 140)
        try session.answer(.choice("0"), for: "ambiguity.0")
        try await session.reviseWithAI()
        #expect(session.nutritionImport?.days[0].meals.count == 5)
        #expect(session.nutritionImport?.ambiguities.isEmpty == true)
    }

    @Test("sair do app durante a análise pede tempo em segundo plano e devolve ao terminar")
    func backgroundTaskAroundCall() async throws {
        let fixture = try ImportFixture()
        let gateway = ScriptedImportGateway([.extraction(ImportJSON.fourRoutines)])
        let counter = BackgroundCounter()
        let session = ImportSession(kind: .program, context: fixture.context,
                                    resolveChat: { ResolvedChat(gateway: gateway, model: "m") }, hasConsented: { true },
                                    store: fixture.store, beginBackground: { _, _ in
                                        counter.began += 1
                                        return { counter.ended += 1 }
                                    })
        try await session.add([fixture.pdf()])
        try await session.analyze()
        #expect(counter.began == 1)
        #expect(counter.ended == 1)
        #expect(session.analysisStartedAt == nil)
    }

    // MARK: U4 — exercícios sem casamento em lote

    @Test("criar todos como novos: uma ação resolve todos os exercícios fora do catálogo (e as repetições em outras fichas)")
    func createAllUnmatchedAsNew() async throws {
        let json = ImportJSON.program(mode: "sequential", routines: [
            ImportJSON.routine("A", exercises: [ImportJSON.exercise("Abdutora máq. 3"), ImportJSON.exercise("Remada cavalinho"),
                                                ImportJSON.exercise("Supino reto", key: "bench-press")]),
            ImportJSON.routine("B", exercises: [ImportJSON.exercise("Panturrilha sentado máq."), ImportJSON.exercise("abdutora maq 3")]),
        ])
        let fixture = try ImportFixture()
        let session = fixture.session(.program, gateway: ScriptedImportGateway([.extraction(json)]))
        try await session.add([fixture.pdf()])
        try await session.analyze()
        // "Remada cavalinho" casa com o catálogo pelo nome: não é pergunta de exercício novo.
        #expect(!session.unmatchedExerciseQuestions.contains { $0.field == .exercise(routine: 0, exercise: 1) })
        #expect(!session.unmatchedExerciseQuestions.isEmpty)
        let created = try session.createAllUnmatchedAsNew()
        // "Remada cavalinho" está no catálogo (t-bar-row): não vira exercício novo (seria duplicata).
        // A abdutora da ficha B é o mesmo exercício da A ("abdutora maq 3"): decidida junto, sem criar outro.
        #expect(created.count == 2)
        #expect(created.map(\.name) == ["Abdutora máq. 3", "Panturrilha sentado máq."])
        #expect(session.unmatchedExerciseQuestions.isEmpty)
        let extraction = try #require(session.programImport)
        let abductorA = extraction.routines[0].exercises[0]
        let abductorB = extraction.routines[1].exercises[1]
        #expect(abductorB.displayName == abductorA.displayName)
        #expect(abductorB.catalogKey == abductorA.catalogKey)
        let keyA = try #require(ProgramInterview.exerciseKey(abductorA))
        let keyB = try #require(ProgramInterview.exerciseKey(abductorB))
        #expect(session.exerciseDecisions[keyA] != nil)
        #expect(session.exerciseDecisions[keyB] == session.exerciseDecisions[keyA])
        let draft = try session.programDraft()
        #expect(draft.routines[0].exercises[2].catalogKey == "bench-press")
        #expect(draft.routines[1].exercises[1].name == draft.routines[0].exercises[0].name)
    }

    // MARK: T3 — esforço nos gateways

    @Test("esforço: Anthropic output_config.effort, OpenAI reasoning_effort (só modelo de raciocínio), ChatGPT reasoning.effort")
    func effortInGateways() throws {
        let request = ChatRequest(model: "claude-opus-5-5", messages: [.user("oi")], effort: .low)
        let anthropic = AnthropicMessagesGateway(configuration: EndpointConfiguration(
            provider: .anthropic, baseURL: try #require(URL(string: "https://example.test/v1")),
            auth: .header(name: "x-api-key", value: "test-key-not-real")))
        let anthropicBody = try JSONValue.parse(String(decoding: try #require(anthropic.makeRequest(request, stream: true).httpBody), as: UTF8.self))
        #expect(anthropicBody["output_config"]?["effort"] == .string("low"))
        var coach = request
        coach.effort = nil
        let coachBody = try JSONValue.parse(String(decoding: try #require(anthropic.makeRequest(coach, stream: true).httpBody), as: UTF8.self))
        #expect(coachBody["output_config"]?["effort"] == .string(AnthropicMessagesGateway.effort)) // o Coach não muda
        #expect(anthropicBody["max_tokens"] == coachBody["max_tokens"]) // sem limite novo de saída

        let openAI = OpenAICompatibleChatGateway(configuration: EndpointConfiguration(
            provider: .openAI, baseURL: try #require(URL(string: "https://example.test/v1")), auth: .bearer("test-key-not-real")))
        var reasoning = request
        reasoning.model = "gpt-5-mini"
        let openAIBody = try JSONValue.parse(String(decoding: try #require(openAI.makeRequest(reasoning, stream: true).httpBody), as: UTF8.self))
        #expect(openAIBody["reasoning_effort"] == .string("low"))
        #expect(openAIBody["model"] == .string("gpt-5-mini")) // modelo do usuário
        var classic = request
        classic.model = "gpt-4o"
        let classicBody = try JSONValue.parse(String(decoding: try #require(openAI.makeRequest(classic, stream: true).httpBody), as: UTF8.self))
        #expect(classicBody["reasoning_effort"] == nil)

        var chatGPT = request
        chatGPT.model = "gpt-6-luna"
        let body = try ChatGPTResponsesGateway.body(for: chatGPT, options: .init(strictTools: false, reasoningSummary: true,
                                                                                 reasoningEffort: true))
        #expect(body["reasoning"]?["effort"] == .string("low"))
        #expect(body["reasoning"]?["summary"] == .string("auto"))
        let dropped = ChatGPTResponsesGateway.BodyOptions(strictTools: false, reasoningSummary: true, reasoningEffort: true)
            .dropping(citedIn: "Unsupported parameter: reasoning.effort")
        #expect(dropped?.reasoningEffort == false)
        #expect(dropped?.reasoningSummary == true)
    }

    // MARK: U1 — progresso honesto

    @Test("progresso: tempo decorrido verdadeiro, sem prometer duração nem aviso")
    func honestProgress() {
        let files = [AttachmentMetadata(id: UUID(), filename: "a.pdf", kind: .pdf, mimeType: "application/pdf", pageCount: 2, byteCount: 10)]
        let normal = ImportAnalysisPresentation.make(kind: .program, attachments: files, providerName: "a Anthropic",
                                                     programImport: nil, nutritionImport: nil, slow: false, elapsed: .seconds(42))
        #expect(normal.subtitle == "Enviados para a Anthropic · 0:42")
        let slow = ImportAnalysisPresentation.make(kind: .program, attachments: files, providerName: "Anthropic",
                                                   programImport: nil, nutritionImport: nil, slow: true, elapsed: .seconds(75))
        #expect(slow.subtitle?.contains("1:15") == true)
        #expect(slow.subtitle?.contains("aberto") == true)
        for text in [normal.subtitle, slow.subtitle].compactMap({ $0 }) {
            #expect(!text.contains("minuto"))
            #expect(!text.contains("eu aviso"))
        }
    }
}

@MainActor
final class BackgroundCounter {
    var began = 0
    var ended = 0
}
