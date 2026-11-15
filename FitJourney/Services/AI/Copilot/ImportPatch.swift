import Foundation

// Revisão e reparo por remendo: a IA recebe a extração atual na forma compacta (v2) com ids posicionais estáveis
// durante a chamada ("r0", "r0e2" no treino; "d0", "d0m1" na dieta) e devolve só as operações — não o objeto
// inteiro. O app aplica sobre a mesma foto enviada (os ids se referem a ela, não às posições depois de inserir ou
// remover). Ferramenta `submit_import_patch`; o schema reaproveita os `$defs` do contrato v2.

enum ImportPatchError: Error, Sendable, Hashable {
    case invalid(String)
}

// MARK: - Ids

enum ImportPatchID {
    static func routine(_ r: Int) -> String { "r\(r)" }
    static func exercise(_ r: Int, _ e: Int) -> String { "r\(r)e\(e)" }
    static func day(_ d: Int) -> String { "d\(d)" }
    static func meal(_ d: Int, _ m: Int) -> String { "d\(d)m\(m)" }

    /// "r3" → (3, nil); "r3e2" → (3, 2). `outer`/`inner` = letras ("r"/"e" ou "d"/"m").
    static func parse(_ id: String?, outer: Character, inner: Character) -> (Int, Int?)? {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), id.first == outer else { return nil }
        let body = id.dropFirst()
        let parts = body.split(separator: inner, omittingEmptySubsequences: false)
        guard let first = parts.first, let a = Int(first) else { return nil }
        switch parts.count {
        case 1: return (a, nil)
        case 2: return Int(parts[1]).map { (a, $0) }
        default: return nil
        }
    }
}

// MARK: - Foto enviada à IA

enum ImportSnapshot {
    /// Extração atual compacta com `id` em cada ficha e exercício.
    static func program(_ value: ProgramImport) -> String {
        guard case var .object(root) = encode(value.compacted()) else { return "{}" }
        if case let .array(routines) = root["routines"] {
            root["routines"] = .array(routines.enumerated().map { r, routine in
                guard case var .object(object) = routine else { return routine }
                object["id"] = .string(ImportPatchID.routine(r))
                if case let .array(exercises) = object["exercises"] {
                    object["exercises"] = .array(exercises.enumerated().map { e, exercise in
                        guard case var .object(item) = exercise else { return exercise }
                        item["id"] = .string(ImportPatchID.exercise(r, e))
                        return .object(item)
                    })
                }
                return .object(object)
            })
        }
        return JSONValue.object(root).jsonString()
    }

    static func nutrition(_ value: NutritionImport) -> String {
        guard case var .object(root) = encode(value.compacted()) else { return "{}" }
        if case let .array(days) = root["days"] {
            root["days"] = .array(days.enumerated().map { d, day in
                guard case var .object(object) = day else { return day }
                object["id"] = .string(ImportPatchID.day(d))
                if case let .array(meals) = object["meals"] {
                    object["meals"] = .array(meals.enumerated().map { m, meal in
                        guard case var .object(item) = meal else { return meal }
                        item["id"] = .string(ImportPatchID.meal(d, m))
                        return .object(item)
                    })
                }
                return .object(object)
            })
        }
        return JSONValue.object(root).jsonString()
    }

    private static func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

// MARK: - Treino

struct ProgramImportPatch: Codable, Sendable, Hashable {
    enum Op: String, Codable, Sendable, Hashable, CaseIterable {
        case updateProgram, updateRoutine, removeRoutine, replaceExercise, insertExercise, removeExercise
    }

    struct ProgramHeader: Codable, Sendable, Hashable {
        var name: String?
        var goal: ProgramGoal?
        var goalText: String?
        var scheduleMode: ScheduleMode?
        var durationWeeks: Int?
        var notes: String?
    }

    struct RoutineHeader: Codable, Sendable, Hashable {
        var name: String?
        var symbol: String?
        var weekdays: [Weekday]
        var notes: String?
    }

    struct Operation: Codable, Sendable, Hashable {
        var op: Op
        /// Ficha ("r0") ou exercício ("r0e2"); em `insertExercise`, a ficha.
        var id: String?
        /// `insertExercise`: exercício depois do qual inserir; `nil` = no começo da ficha.
        var after: String?
        var program: ProgramHeader?
        var routine: RoutineHeader?
        var exercise: ProgramImportV2.ExerciseV2?
    }

    var operations: [Operation]
    var newAmbiguities: [ImportAmbiguity]

    /// Aplica sobre `base` (a mesma foto enviada). Lança se uma operação não fizer sentido.
    func applied(to base: ProgramImport) throws(ImportPatchError) -> ProgramImport {
        var result = base
        var removedRoutines: Set<Int> = []
        var removedExercises: Set<[Int]> = []
        var replaced: [[Int]: ProgramImport.ExerciseImport] = [:]
        var inserts: [[Int]: [ProgramImport.ExerciseImport]] = [:] // [r, e+1] (0 = começo)
        func routineIndex(_ id: String?, _ index: Int) throws(ImportPatchError) -> Int {
            guard let (r, e) = ImportPatchID.parse(id, outer: "r", inner: "e"), e == nil, base.routines.indices.contains(r) else {
                throw .invalid("operations[\(index)].id: ficha desconhecida \(id ?? "null")")
            }
            return r
        }
        func exerciseIndex(_ id: String?, _ index: Int, field: String = "id") throws(ImportPatchError) -> (Int, Int) {
            guard let (r, e) = ImportPatchID.parse(id, outer: "r", inner: "e"), let e, base.routines.indices.contains(r),
                  base.routines[r].exercises.indices.contains(e) else {
                throw .invalid("operations[\(index)].\(field): exercício desconhecido \(id ?? "null")")
            }
            return (r, e)
        }
        for (index, operation) in operations.enumerated() {
            switch operation.op {
            case .updateProgram:
                guard let header = operation.program else { throw .invalid("operations[\(index)].program: obrigatório") }
                result.name = header.name
                result.goal = header.goal
                result.goalText = header.goalText
                result.scheduleMode = header.scheduleMode
                result.durationWeeks = header.durationWeeks
                result.notes = header.notes
            case .updateRoutine:
                let r = try routineIndex(operation.id, index)
                guard let header = operation.routine else { throw .invalid("operations[\(index)].routine: obrigatório") }
                result.routines[r].name = header.name
                result.routines[r].symbol = header.symbol
                result.routines[r].weekdays = header.weekdays
                result.routines[r].notes = header.notes
            case .removeRoutine:
                removedRoutines.insert(try routineIndex(operation.id, index))
            case .replaceExercise:
                let (r, e) = try exerciseIndex(operation.id, index)
                guard let exercise = operation.exercise else { throw .invalid("operations[\(index)].exercise: obrigatório") }
                replaced[[r, e]] = exercise.expanded
            case .insertExercise:
                let r = try routineIndex(operation.id, index)
                guard let exercise = operation.exercise else { throw .invalid("operations[\(index)].exercise: obrigatório") }
                var slot = 0
                if operation.after != nil {
                    let (ar, ae) = try exerciseIndex(operation.after, index, field: "after")
                    guard ar == r else { throw .invalid("operations[\(index)].after: exercício de outra ficha") }
                    slot = ae + 1
                }
                inserts[[r, slot], default: []].append(exercise.expanded)
            case .removeExercise:
                let (r, e) = try exerciseIndex(operation.id, index)
                removedExercises.insert([r, e])
            }
        }
        var routines: [ProgramImport.RoutineImport] = []
        for (r, routine) in result.routines.enumerated() where !removedRoutines.contains(r) {
            var copy = routine
            var exercises = inserts[[r, 0]] ?? []
            for (e, exercise) in routine.exercises.enumerated() {
                if !removedExercises.contains([r, e]) { exercises.append(replaced[[r, e]] ?? exercise) }
                exercises += inserts[[r, e + 1]] ?? []
            }
            copy.exercises = exercises
            routines.append(copy)
        }
        result.routines = routines
        result.ambiguities += newAmbiguities
        return result
    }

    /// Parâmetros da ferramenta: operações + novas dúvidas, com os `$defs` do contrato v2.
    static var toolParameters: String {
        ImportPatchSchema.make(contract: ImportSchemas.programImportV2, ops: Op.allCases.map(\.rawValue), extraDefs: { defs, root in
            var programProps: [String: JSONValue] = [:]
            for key in ["name", "goal", "goalText", "scheduleMode", "durationWeeks", "notes"] { programProps[key] = root[key] }
            defs["programHeader"] = ImportPatchSchema.object(programProps)
            var routineProps: [String: JSONValue] = [:]
            if case let .object(routine)? = defs["routine"], case let .object(props)? = routine["properties"] {
                for key in ["name", "symbol", "weekdays", "notes"] { routineProps[key] = props[key] }
            }
            defs["routineHeader"] = ImportPatchSchema.object(routineProps)
            return [
                "id": .object(["type": .array([.string("string"), .string("null")]),
                               "description": .string("Ficha (r0) ou exercício (r0e2) da extração enviada; em insertExercise, a ficha.")]),
                "after": .object(["type": .array([.string("string"), .string("null")]),
                                  "description": .string("insertExercise: id do exercício depois do qual inserir; null = no começo.")]),
                "program": ImportPatchSchema.refOrNull("programHeader"),
                "routine": ImportPatchSchema.refOrNull("routineHeader"),
                "exercise": ImportPatchSchema.refOrNull("exercise"),
            ]
        })
    }
}

// MARK: - Dieta

struct NutritionImportPatch: Codable, Sendable, Hashable {
    enum Op: String, Codable, Sendable, Hashable, CaseIterable {
        case updatePlan, updateTargets, updateDay, removeDay, replaceMeal, insertMeal, removeMeal
    }

    struct PlanHeader: Codable, Sendable, Hashable {
        var name: String?
        var goal: String?
        var notes: String?
    }

    struct DayHeader: Codable, Sendable, Hashable {
        var name: String?
        var weekdays: [Weekday]
        var notes: String?
    }

    struct Operation: Codable, Sendable, Hashable {
        var op: Op
        var id: String?
        var after: String?
        var plan: PlanHeader?
        var targets: NutritionImport.TargetsImport?
        var day: DayHeader?
        var meal: NutritionImportV2.MealV2?
    }

    var operations: [Operation]
    var newAmbiguities: [ImportAmbiguity]

    func applied(to base: NutritionImport) throws(ImportPatchError) -> NutritionImport {
        var result = base
        var removedDays: Set<Int> = []
        var removedMeals: Set<[Int]> = []
        var replaced: [[Int]: NutritionImport.MealImport] = [:]
        var inserts: [[Int]: [NutritionImport.MealImport]] = [:]
        func dayIndex(_ id: String?, _ index: Int) throws(ImportPatchError) -> Int {
            guard let (d, m) = ImportPatchID.parse(id, outer: "d", inner: "m"), m == nil, base.days.indices.contains(d) else {
                throw .invalid("operations[\(index)].id: dia desconhecido \(id ?? "null")")
            }
            return d
        }
        func mealIndex(_ id: String?, _ index: Int, field: String = "id") throws(ImportPatchError) -> (Int, Int) {
            guard let (d, m) = ImportPatchID.parse(id, outer: "d", inner: "m"), let m, base.days.indices.contains(d),
                  base.days[d].meals.indices.contains(m) else {
                throw .invalid("operations[\(index)].\(field): refeição desconhecida \(id ?? "null")")
            }
            return (d, m)
        }
        for (index, operation) in operations.enumerated() {
            switch operation.op {
            case .updatePlan:
                guard let header = operation.plan else { throw .invalid("operations[\(index)].plan: obrigatório") }
                result.name = header.name
                result.goal = header.goal
                result.notes = header.notes
            case .updateTargets:
                guard let targets = operation.targets else { throw .invalid("operations[\(index)].targets: obrigatório") }
                result.targets = targets
            case .updateDay:
                let d = try dayIndex(operation.id, index)
                guard let header = operation.day else { throw .invalid("operations[\(index)].day: obrigatório") }
                result.days[d].name = header.name
                result.days[d].weekdays = header.weekdays
                result.days[d].notes = header.notes
            case .removeDay:
                removedDays.insert(try dayIndex(operation.id, index))
            case .replaceMeal:
                let (d, m) = try mealIndex(operation.id, index)
                guard let meal = operation.meal else { throw .invalid("operations[\(index)].meal: obrigatório") }
                replaced[[d, m]] = meal.expanded
            case .insertMeal:
                let d = try dayIndex(operation.id, index)
                guard let meal = operation.meal else { throw .invalid("operations[\(index)].meal: obrigatório") }
                var slot = 0
                if operation.after != nil {
                    let (ad, am) = try mealIndex(operation.after, index, field: "after")
                    guard ad == d else { throw .invalid("operations[\(index)].after: refeição de outro dia") }
                    slot = am + 1
                }
                inserts[[d, slot], default: []].append(meal.expanded)
            case .removeMeal:
                let (d, m) = try mealIndex(operation.id, index)
                removedMeals.insert([d, m])
            }
        }
        var days: [NutritionImport.DayImport] = []
        for (d, day) in result.days.enumerated() where !removedDays.contains(d) {
            var copy = day
            var meals = inserts[[d, 0]] ?? []
            for (m, meal) in day.meals.enumerated() {
                if !removedMeals.contains([d, m]) { meals.append(replaced[[d, m]] ?? meal) }
                meals += inserts[[d, m + 1]] ?? []
            }
            copy.meals = meals
            days.append(copy)
        }
        result.days = days
        result.ambiguities += newAmbiguities
        return result
    }

    static var toolParameters: String {
        ImportPatchSchema.make(contract: ImportSchemas.nutritionImportV2, ops: Op.allCases.map(\.rawValue), extraDefs: { defs, root in
            var planProps: [String: JSONValue] = [:]
            for key in ["name", "goal", "notes"] { planProps[key] = root[key] }
            defs["planHeader"] = ImportPatchSchema.object(planProps)
            var dayProps: [String: JSONValue] = [:]
            if case let .object(day)? = defs["day"], case let .object(props)? = day["properties"] {
                for key in ["name", "weekdays", "notes"] { dayProps[key] = props[key] }
            }
            defs["dayHeader"] = ImportPatchSchema.object(dayProps)
            return [
                "id": .object(["type": .array([.string("string"), .string("null")]),
                               "description": .string("Dia (d0) ou refeição (d0m1) da extração enviada; em insertMeal, o dia.")]),
                "after": .object(["type": .array([.string("string"), .string("null")]),
                                  "description": .string("insertMeal: id da refeição depois da qual inserir; null = no começo.")]),
                "plan": ImportPatchSchema.refOrNull("planHeader"),
                "targets": ImportPatchSchema.refOrNull("targets"),
                "day": ImportPatchSchema.refOrNull("dayHeader"),
                "meal": ImportPatchSchema.refOrNull("meal"),
            ]
        })
    }
}

// MARK: - Schema da ferramenta

enum ImportPatchSchema {
    static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "additionalProperties": .bool(false),
                 "required": .array(properties.keys.sorted().map(JSONValue.string)), "properties": .object(properties)])
    }

    static func refOrNull(_ name: String) -> JSONValue {
        .object(["anyOf": .array([.object(["$ref": .string("#/$defs/\(name)")]), .object(["type": .string("null")])])])
    }

    /// `{operations: [operation], newAmbiguities: [ambiguity]}` com os `$defs` do contrato v2 (estrito: tudo
    /// obrigatório, `null` explícito).
    static func make(contract: String, ops: [String],
                     extraDefs: (inout [String: JSONValue], [String: JSONValue]) -> [String: JSONValue]) -> String {
        guard case let .object(schema)? = try? JSONValue.parse(contract),
              case var .object(defs)? = schema["$defs"], case let .object(rootProps)? = schema["properties"] else { return "{}" }
        var operationProps = extraDefs(&defs, rootProps)
        operationProps["op"] = .object(["type": .string("string"), "enum": .array(ops.map(JSONValue.string))])
        defs["operation"] = object(operationProps)
        let root: [String: JSONValue] = [
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("operations"), .string("newAmbiguities")]),
            "properties": .object([
                "operations": .object(["type": .string("array"), "maxItems": .number(200),
                                       "items": .object(["$ref": .string("#/$defs/operation")])]),
                "newAmbiguities": .object(["type": .string("array"), "maxItems": .number(20),
                                           "items": .object(["$ref": .string("#/$defs/ambiguity")]),
                                           "description": .string("Só dúvidas novas que ainda precisam do usuário; vazio na maioria das vezes.")]),
            ]),
            "$defs": .object(defs),
        ]
        return JSONValue.object(root).jsonString()
    }
}
