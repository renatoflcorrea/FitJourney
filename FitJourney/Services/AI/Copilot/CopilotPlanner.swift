import Foundation
import SwiftData

/// Problemas de uma proposta (lista legível, também devolvida ao modelo para corrigir).
struct CopilotPlanError: Error, Sendable, Hashable {
    var issues: [String]
    init(_ issues: [String]) { self.issues = issues }
    init(_ issue: String) { issues = [issue] }
}

// MARK: - Argumentos das ferramentas (schemas estritos)

enum CopilotToolSchemas {
    static let loadDef = ##"{"type":"object","additionalProperties":false,"required":["kind","value","unit"],"properties":{"kind":{"type":"string","enum":["weight","bodyweight"],"description":"weight = carga absoluta; bodyweight = peso corporal com value de lastro (+) ou assistência (−)."},"value":{"type":"number","minimum":-200,"maximum":1000},"unit":{"type":"string","enum":["kg","lb"]}}}"##
    static let repsDef = ##"{"type":"object","additionalProperties":false,"required":["kind","reps","min","max"],"properties":{"kind":{"type":"string","enum":["fixed","range","amrap"]},"reps":{"type":["integer","null"],"minimum":1,"maximum":100},"min":{"type":["integer","null"],"minimum":1,"maximum":100},"max":{"type":["integer","null"],"minimum":1,"maximum":100}}}"##
    static let foodDef = ##"{"type":"object","additionalProperties":false,"required":["name","quantity","unit","kcal","protein","carbs","fat","fiber"],"properties":{"name":{"type":"string"},"quantity":{"type":"number","minimum":0,"maximum":10000},"unit":{"type":"string","enum":["grams","milliliters","unit","tablespoon","cup","slice","serving"]},"kcal":{"type":["number","null"],"minimum":0,"maximum":10000},"protein":{"type":["number","null"],"minimum":0,"maximum":1000},"carbs":{"type":["number","null"],"minimum":0,"maximum":1000},"fat":{"type":["number","null"],"minimum":0,"maximum":1000},"fiber":{"type":["number","null"],"minimum":0,"maximum":500}}}"##

    static let routine = ##"{"type":"object","additionalProperties":false,"required":["routineId","operations"],"properties":{"routineId":{"type":"string","description":"id da ficha (get_program)."},"operations":{"type":"array","minItems":1,"maxItems":20,"items":{"$ref":"#/$defs/operation"}}},"$defs":{"operation":{"type":"object","additionalProperties":false,"required":["op","exerciseId","set","load","loadTarget","reps","sets","restSeconds","exercise","position"],"properties":{"op":{"type":"string","enum":["set_load","set_reps","set_sets","set_rest","replace_exercise","add_exercise","remove_exercise","move_exercise"],"description":"set_load (load, loadTarget, set), set_reps (reps, set), set_sets (sets), set_rest (restSeconds), replace_exercise (exercise), add_exercise (exercise, sets, reps, load, restSeconds, position), remove_exercise, move_exercise (position)."},"exerciseId":{"type":["string","null"],"description":"id do exercício na ficha (get_program); null em add_exercise."},"set":{"type":["integer","null"],"minimum":1,"maximum":10,"description":"Número da série (1 = primeira); null = todas as séries válidas."},"load":{"anyOf":[{"$ref":"#/$defs/load"},{"type":"null"}]},"loadTarget":{"type":["string","null"],"enum":["current","initial",null],"description":"current (padrão) = carga atual; initial só se o usuário pedir a carga inicial."},"reps":{"anyOf":[{"$ref":"#/$defs/reps"},{"type":"null"}]},"sets":{"type":["integer","null"],"minimum":1,"maximum":10,"description":"Quantidade de séries."},"restSeconds":{"type":["integer","null"],"minimum":0,"maximum":600},"exercise":{"anyOf":[{"$ref":"#/$defs/exerciseRef"},{"type":"null"}]},"position":{"type":["integer","null"],"minimum":1,"maximum":30,"description":"Posição na ficha (1 = primeiro)."}}},"load":"## + loadDef + ##","reps":"## + repsDef + ##","exerciseRef":{"type":"object","additionalProperties":false,"required":["name","catalogKey"],"properties":{"name":{"type":"string","description":"Nome do exercício do catálogo (list_exercises)."},"catalogKey":{"type":["string","null"]}}}}}"##

    static let nutrition = ##"{"type":"object","additionalProperties":false,"required":["planId","operations"],"properties":{"planId":{"type":"string","description":"id da dieta (list_nutrition_plans)."},"operations":{"type":"array","minItems":1,"maxItems":20,"items":{"$ref":"#/$defs/operation"}}},"$defs":{"operation":{"type":"object","additionalProperties":false,"required":["op","dayId","mealId","itemId","item","meal","targets"],"properties":{"op":{"type":"string","enum":["add_item","remove_item","update_item","add_meal","remove_meal","update_meal","set_targets"],"description":"add_item (mealId, item), remove_item (itemId), update_item (itemId, item completo), add_meal (dayId, meal), remove_meal (mealId), update_meal (mealId, meal), set_targets (targets completo)."},"dayId":{"type":["string","null"]},"mealId":{"type":["string","null"]},"itemId":{"type":["string","null"]},"item":{"anyOf":[{"$ref":"#/$defs/food"},{"type":"null"}]},"meal":{"anyOf":[{"$ref":"#/$defs/meal"},{"type":"null"}]},"targets":{"anyOf":[{"$ref":"#/$defs/targets"},{"type":"null"}]}}},"food":"## + foodDef + ##","meal":{"type":"object","additionalProperties":false,"required":["name","time"],"properties":{"name":{"type":["string","null"]},"time":{"type":["string","null"],"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","description":"HH:MM"}}},"targets":{"type":"object","additionalProperties":false,"required":["kcal","protein","carbs","fat","fiber","waterMilliliters"],"properties":{"kcal":{"type":["number","null"],"minimum":0,"maximum":20000},"protein":{"type":["number","null"],"minimum":0,"maximum":2000},"carbs":{"type":["number","null"],"minimum":0,"maximum":3000},"fat":{"type":["number","null"],"minimum":0,"maximum":1000},"fiber":{"type":["number","null"],"minimum":0,"maximum":500},"waterMilliliters":{"type":["number","null"],"minimum":0,"maximum":20000}}}}}"##

    static let foodLog = ##"{"type":"object","additionalProperties":false,"required":["entries"],"properties":{"entries":{"type":"array","minItems":1,"maxItems":10,"items":{"type":"object","additionalProperties":false,"required":["food","date","time","mealId"],"properties":{"food":{"$ref":"#/$defs/food"},"date":{"type":["string","null"],"pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$","description":"AAAA-MM-DD; null = hoje."},"time":{"type":["string","null"],"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","description":"HH:MM; null = agora."},"mealId":{"type":["string","null"],"description":"Refeição do plano ativo (list_nutrition_plans) só se o usuário disser; null = avulso."}}}}},"$defs":{"food":"## + foodDef + ##"}}"##
}

struct RoutineChangeArgs: Decodable {
    struct Operation: Decodable {
        var op: String
        var exerciseId: String?
        var set: Int?
        var load: ProgramDraft.LoadDraft?
        var loadTarget: String?
        var reps: ProgramDraft.RepTargetDraft?
        var sets: Int?
        var restSeconds: Int?
        var exercise: ExerciseRef?
        var position: Int?
    }

    struct ExerciseRef: Decodable {
        var name: String
        var catalogKey: String?
    }

    var routineId: String
    var operations: [Operation]
}

struct FoodArgs: Decodable {
    var name: String
    var quantity: Double
    var unit: FoodUnit
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?

    var item: CopilotFoodItem {
        CopilotFoodItem(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), quantity: quantity, unit: unit,
                        values: NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber))
    }
}

struct NutritionChangeArgs: Decodable {
    struct Operation: Decodable {
        var op: String
        var dayId: String?
        var mealId: String?
        var itemId: String?
        var item: FoodArgs?
        var meal: MealArgs?
        var targets: NutritionPlanDraft.TargetsDraft?
    }

    struct MealArgs: Decodable {
        var name: String?
        var time: String?
    }

    var planId: String
    var operations: [Operation]
}

struct FoodLogArgs: Decodable {
    struct Entry: Decodable {
        var food: FoodArgs
        var date: String?
        var time: String?
        var mealId: String?
    }

    var entries: [Entry]
}

// MARK: - Planejador

/// Converte argumentos das ferramentas em `CopilotChangeSet` (resolve ids, calcula o diff sobre a fotografia do
/// estado atual) e reaplica as operações na hora de gravar. Não grava nada.
@MainActor
struct CopilotPlanner {
    let context: ModelContext
    var now: Date
    var calendar: Calendar

    init(context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        self.context = context
        self.now = now
        self.calendar = calendar
    }

    private static func decode<T: Decodable>(_ json: String, schema: String, as type: T.Type) throws -> T {
        guard let extracted = StructuredDecoder.extractJSONObject(from: json.isEmpty ? "{}" : json),
              let value = try? JSONValue.parse(extracted) else { throw CopilotPlanError("$: JSON inválido") }
        let validator = try JSONSchemaValidator(schemaJSON: schema)
        let issues = validator.validate(value)
        guard issues.isEmpty else { throw CopilotPlanError(issues) }
        do {
            return try JSONDecoder().decode(T.self, from: Data(extracted.utf8))
        } catch {
            throw CopilotPlanError("$: \(error.localizedDescription)")
        }
    }

    // MARK: Ficha

    func routineChangeSet(id: String, argumentsJSON: String) throws -> CopilotChangeSet {
        let args = try Self.decode(argumentsJSON, schema: CopilotToolSchemas.routine, as: RoutineChangeArgs.self)
        guard let routineID = UUID(uuidString: args.routineId),
              let routine = try ProgramStore(context: context).routine(id: routineID) else {
            throw CopilotPlanError("routineId: ficha não encontrada (use o id de get_program)")
        }
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        var issues: [String] = []
        var operations: [CopilotOperation] = []
        for (index, op) in args.operations.enumerated() {
            do {
                operations.append(try Self.routineOperation(op, catalog: catalog))
            } catch let error as CopilotPlanError {
                issues += error.issues.map { "operations[\(index)]: \($0)" }
            }
        }
        guard issues.isEmpty else { throw CopilotPlanError(issues) }
        let before = ProgramStore(context: context).snapshot(of: routine)
        let after = try Self.apply(operations, to: before)
        let diff = Self.diff(before: before, after: after)
        guard !diff.isEmpty else { throw CopilotPlanError("nada muda: os valores pedidos já são os atuais") }
        return CopilotChangeSet(id: id, scope: .routine(id: routine.id, name: routine.name), operations: operations,
                                diff: diff, baseFingerprint: before.fingerprint, createdAt: now)
    }

    private static func routineOperation(_ op: RoutineChangeArgs.Operation, catalog: [Exercise]) throws -> CopilotOperation {
        func exerciseID() throws -> UUID {
            guard let raw = op.exerciseId, let id = UUID(uuidString: raw) else {
                throw CopilotPlanError("exerciseId obrigatório (id do exercício na ficha, de get_program)")
            }
            return id
        }
        func catalogExercise() throws -> Exercise {
            guard let ref = op.exercise else { throw CopilotPlanError("exercise obrigatório") }
            guard let hit = ExerciseMatcher.match(name: ref.name, catalogKey: ref.catalogKey, in: catalog) else {
                throw CopilotPlanError("exercício \"\(ref.name)\" não está no catálogo (use list_exercises)")
            }
            return hit
        }
        let setIndex = op.set.map { $0 - 1 }
        switch op.op {
        case "set_load":
            guard let load = op.load else { throw CopilotPlanError("load obrigatório em set_load") }
            return .setLoad(exerciseID: try exerciseID(), setIndex: setIndex, load: load.load,
                            target: op.loadTarget == "initial" ? .initial : .current)
        case "set_reps":
            guard let reps = op.reps?.repTarget else { throw CopilotPlanError("reps obrigatório e coerente em set_reps") }
            return .setReps(exerciseID: try exerciseID(), setIndex: setIndex, reps: reps)
        case "set_sets":
            guard let count = op.sets else { throw CopilotPlanError("sets obrigatório em set_sets") }
            return .setSetCount(exerciseID: try exerciseID(), count: count)
        case "set_rest":
            guard let rest = op.restSeconds else { throw CopilotPlanError("restSeconds obrigatório em set_rest") }
            return .setRest(exerciseID: try exerciseID(), seconds: rest)
        case "replace_exercise":
            let target = try catalogExercise()
            return .replaceExercise(exerciseID: try exerciseID(), newExerciseID: target.id, newName: target.name)
        case "add_exercise":
            let target = try catalogExercise()
            return .addExercise(newExerciseID: target.id, name: target.name, sets: op.sets ?? 3,
                                reps: op.reps?.repTarget ?? (target.measurementKind == .timeOrDistance || target.measurementKind == .isometric
                                    ? nil : .range(min: 8, max: 12)),
                                load: op.load?.load, restSeconds: op.restSeconds, position: op.position.map { $0 - 1 })
        case "remove_exercise":
            return .removeExercise(exerciseID: try exerciseID())
        case "move_exercise":
            guard let position = op.position else { throw CopilotPlanError("position obrigatório em move_exercise") }
            return .moveExercise(exerciseID: try exerciseID(), position: position - 1)
        default:
            throw CopilotPlanError("op desconhecida: \(op.op)")
        }
    }

    /// Aplica as operações sobre a fotografia (sem banco) e valida com as regras do editor.
    static func apply(_ operations: [CopilotOperation], to snapshot: RoutineSnapshot) throws -> RoutineSnapshot {
        var result = snapshot
        func index(_ id: UUID) throws -> Int {
            guard let i = result.exercises.firstIndex(where: { $0.id == id }) else {
                throw CopilotPlanError("exercício \(id.uuidString) não está mais na ficha")
            }
            return i
        }
        func targets(_ item: RoutineSnapshot.Item, _ setIndex: Int?) throws -> [Int] {
            if let setIndex {
                guard item.sets.indices.contains(setIndex) else {
                    throw CopilotPlanError("\(item.exerciseName) não tem a série \(setIndex + 1)")
                }
                return [setIndex]
            }
            let working = item.sets.indices.filter { item.sets[$0].kind.isWorking }
            return working.isEmpty ? Array(item.sets.indices) : working
        }
        for operation in operations {
            switch operation {
            case let .setLoad(id, setIndex, load, target):
                let i = try index(id)
                for s in try targets(result.exercises[i], setIndex) {
                    switch target {
                    case .current: result.exercises[i].sets[s].currentLoad = load
                    case .initial: result.exercises[i].sets[s].initialLoad = load
                    }
                }
            case let .setReps(id, setIndex, reps):
                let i = try index(id)
                for s in try targets(result.exercises[i], setIndex) { result.exercises[i].sets[s].repTarget = reps }
            case let .setSetCount(id, count):
                let i = try index(id)
                var sets = result.exercises[i].sets
                if count < sets.count {
                    sets.removeLast(sets.count - count)
                } else if let template = sets.last(where: { $0.kind.isWorking }) ?? sets.last {
                    while sets.count < count {
                        var copy = template
                        copy.id = UUID()
                        sets.append(copy)
                    }
                }
                result.exercises[i].sets = sets
            case let .setRest(id, seconds):
                let i = try index(id)
                result.exercises[i].restSeconds = seconds
                for s in result.exercises[i].sets.indices { result.exercises[i].sets[s].restSeconds = nil }
            case let .replaceExercise(id, newID, name):
                let i = try index(id)
                result.exercises[i].exerciseID = newID
                result.exercises[i].exerciseName = name
            case let .addExercise(newID, name, count, reps, load, rest, position):
                let sets = (0 ..< max(1, count)).map { _ in
                    RoutineSnapshot.SetValue(id: UUID(), kind: .working, repTarget: reps, holdSeconds: nil, initialLoad: load,
                                             currentLoad: nil, restSeconds: nil, tempo: nil, effort: nil, cardio: nil, notes: "")
                }
                let item = RoutineSnapshot.Item(id: UUID(), exerciseID: newID, exerciseName: name, groupID: nil,
                                                restSeconds: rest, notes: "", sets: sets)
                let at = min(max(0, position ?? result.exercises.count), result.exercises.count)
                result.exercises.insert(item, at: at)
            case let .removeExercise(id):
                result.exercises.remove(at: try index(id))
            case let .moveExercise(id, position):
                let item = result.exercises.remove(at: try index(id))
                result.exercises.insert(item, at: min(max(0, position), result.exercises.count))
            default:
                throw CopilotPlanError("operação de dieta numa ficha")
            }
        }
        normalizeGroups(&result)
        let issues = validationIssues(result)
        guard issues.isEmpty else { throw CopilotPlanError(issues) }
        return result
    }

    /// Mesma regra do editor: grupo só com 2+ itens vizinhos.
    static func normalizeGroups(_ snapshot: inout RoutineSnapshot) {
        var positions: [UUID: [Int]] = [:]
        for (i, item) in snapshot.exercises.enumerated() { if let g = item.groupID { positions[g, default: []].append(i) } }
        for (group, indices) in positions {
            let contiguous = indices.count >= 2 && indices.last! - indices.first! == indices.count - 1
            if !contiguous { for i in snapshot.exercises.indices where snapshot.exercises[i].groupID == group { snapshot.exercises[i].groupID = nil } }
        }
    }

    /// Regras do editor de ficha: ao menos uma série, reps ≥ 1 com mín ≤ máx, carga absoluta ≥ 0, descanso 0–600.
    static func validationIssues(_ snapshot: RoutineSnapshot) -> [String] {
        var issues: [String] = []
        if snapshot.exercises.count > 30 { issues.append("ficha com mais de 30 exercícios") }
        for item in snapshot.exercises {
            if item.sets.isEmpty { issues.append("\(item.exerciseName): ao menos uma série") }
            if item.sets.count > 10 { issues.append("\(item.exerciseName): no máximo 10 séries") }
            if let rest = item.restSeconds, !(0 ... 600).contains(rest) { issues.append("\(item.exerciseName): descanso 0–600 s") }
            for set in item.sets {
                switch set.repTarget {
                case let .fixed(reps)?: if reps < 1 { issues.append("\(item.exerciseName): repetições ≥ 1") }
                case let .range(lo, hi)?: if lo < 1 || lo > hi { issues.append("\(item.exerciseName): faixa de repetições inválida") }
                default: break
                }
                for load in [set.initialLoad, set.currentLoad].compactMap({ $0 }) {
                    if case let .weight(value, _) = load, value < 0 { issues.append("\(item.exerciseName): carga negativa") }
                }
            }
        }
        return Array(Set(issues)).sorted()
    }

    // MARK: Dieta

    func nutritionChangeSet(id: String, argumentsJSON: String) throws -> CopilotChangeSet {
        let args = try Self.decode(argumentsJSON, schema: CopilotToolSchemas.nutrition, as: NutritionChangeArgs.self)
        guard let planID = UUID(uuidString: args.planId), let plan = try NutritionStore(context: context, calendar: calendar).plan(id: planID) else {
            throw CopilotPlanError("planId: dieta não encontrada (use o id de list_nutrition_plans)")
        }
        let before = NutritionStore(context: context, calendar: calendar).snapshot(of: plan)
        var issues: [String] = []
        var operations: [CopilotOperation] = []
        for (index, op) in args.operations.enumerated() {
            do {
                operations.append(try Self.nutritionOperation(op, in: before))
            } catch let error as CopilotPlanError {
                issues += error.issues.map { "operations[\(index)]: \($0)" }
            }
        }
        guard issues.isEmpty else { throw CopilotPlanError(issues) }
        let after = try Self.apply(operations, to: before)
        let diff = Self.diff(before: before, after: after)
        guard !diff.isEmpty else { throw CopilotPlanError("nada muda: os valores pedidos já são os atuais") }
        return CopilotChangeSet(id: id, scope: .nutritionPlan(id: plan.id, name: plan.name), operations: operations,
                                diff: diff, baseFingerprint: before.fingerprint, createdAt: now)
    }

    private static func nutritionOperation(_ op: NutritionChangeArgs.Operation, in plan: NutritionPlanSnapshot) throws -> CopilotOperation {
        func uuid(_ raw: String?, _ field: String) throws -> UUID {
            guard let raw, let id = UUID(uuidString: raw) else { throw CopilotPlanError("\(field) obrigatório (de list_nutrition_plans)") }
            return id
        }
        func food() throws -> CopilotFoodItem {
            guard let item = op.item?.item, !item.name.isEmpty, item.quantity > 0 else {
                throw CopilotPlanError("item obrigatório com nome e quantidade > 0")
            }
            return item
        }
        switch op.op {
        case "add_item": return .addItem(mealID: try uuid(op.mealId, "mealId"), item: try food())
        case "remove_item": return .removeItem(itemID: try uuid(op.itemId, "itemId"))
        case "update_item": return .updateItem(itemID: try uuid(op.itemId, "itemId"), item: try food())
        case "add_meal":
            guard let name = op.meal?.name.nonEmpty, let minutes = op.meal?.time.flatMap(NutritionPlanDraft.MealDraft.minutes(from:)) else {
                throw CopilotPlanError("meal com name e time (HH:MM) obrigatório em add_meal")
            }
            let dayID = try op.dayId.map { try uuid($0, "dayId") } ?? (plan.days.first(where: { $0.weekdays.isEmpty }) ?? plan.days.first)?.id
            guard let dayID else { throw CopilotPlanError("dieta sem dias") }
            return .addMeal(dayID: dayID, name: String(name.prefix(80)), minutesFromMidnight: minutes)
        case "remove_meal": return .removeMeal(mealID: try uuid(op.mealId, "mealId"))
        case "update_meal":
            let minutes = op.meal?.time.flatMap(NutritionPlanDraft.MealDraft.minutes(from:))
            let name = op.meal?.name.nonEmpty
            guard name != nil || minutes != nil else { throw CopilotPlanError("meal.name ou meal.time obrigatório em update_meal") }
            return .updateMeal(mealID: try uuid(op.mealId, "mealId"), name: name.map { String($0.prefix(80)) }, minutesFromMidnight: minutes)
        case "set_targets":
            guard let targets = op.targets else { throw CopilotPlanError("targets obrigatório em set_targets") }
            return .setTargets(targets.targets)
        default:
            throw CopilotPlanError("op desconhecida: \(op.op)")
        }
    }

    static func apply(_ operations: [CopilotOperation], to snapshot: NutritionPlanSnapshot) throws -> NutritionPlanSnapshot {
        var result = snapshot
        func mealPath(_ id: UUID) throws -> (Int, Int) {
            for (d, day) in result.days.enumerated() {
                if let m = day.meals.firstIndex(where: { $0.id == id }) { return (d, m) }
            }
            throw CopilotPlanError("refeição \(id.uuidString) não está mais na dieta")
        }
        func itemPath(_ id: UUID) throws -> (Int, Int, Int) {
            for (d, day) in result.days.enumerated() {
                for (m, meal) in day.meals.enumerated() {
                    if let i = meal.items.firstIndex(where: { $0.id == id }) { return (d, m, i) }
                }
            }
            throw CopilotPlanError("item \(id.uuidString) não está mais na dieta")
        }
        func value(_ item: CopilotFoodItem, id: UUID, keeping old: NutritionPlanSnapshot.ItemValue?) -> NutritionPlanSnapshot.ItemValue {
            NutritionPlanSnapshot.ItemValue(id: id, name: item.name, quantity: item.quantity, unit: item.unit, values: item.values,
                                            notes: old?.notes ?? "", substitutions: old?.substitutions ?? [])
        }
        for operation in operations {
            switch operation {
            case let .addItem(mealID, item):
                let (d, m) = try mealPath(mealID)
                result.days[d].meals[m].items.append(value(item, id: UUID(), keeping: nil))
            case let .removeItem(itemID):
                let (d, m, i) = try itemPath(itemID)
                result.days[d].meals[m].items.remove(at: i)
            case let .updateItem(itemID, item):
                let (d, m, i) = try itemPath(itemID)
                result.days[d].meals[m].items[i] = value(item, id: itemID, keeping: result.days[d].meals[m].items[i])
            case let .addMeal(dayID, name, minutes):
                guard let d = result.days.firstIndex(where: { $0.id == dayID }) else {
                    throw CopilotPlanError("dia \(dayID.uuidString) não está na dieta")
                }
                result.days[d].meals.append(NutritionPlanSnapshot.MealValue(id: UUID(), name: name, minutesFromMidnight: minutes,
                                                                             reminderEnabled: false, notes: "", items: []))
                result.days[d].meals.sort { $0.minutesFromMidnight < $1.minutesFromMidnight }
            case let .removeMeal(mealID):
                let (d, m) = try mealPath(mealID)
                result.days[d].meals.remove(at: m)
            case let .updateMeal(mealID, name, minutes):
                let (d, m) = try mealPath(mealID)
                if let name { result.days[d].meals[m].name = name }
                if let minutes { result.days[d].meals[m].minutesFromMidnight = minutes }
                result.days[d].meals.sort { $0.minutesFromMidnight < $1.minutesFromMidnight }
            case let .setTargets(targets):
                result.targets = targets
            default:
                throw CopilotPlanError("operação de ficha numa dieta")
            }
        }
        var issues: [String] = []
        for day in result.days {
            for meal in day.meals {
                if meal.name.nonEmpty == nil { issues.append("refeição sem nome") }
                if !(0 ..< 24 * 60).contains(meal.minutesFromMidnight) { issues.append("\(meal.name): horário inválido") }
                for item in meal.items where item.quantity <= 0 || item.name.nonEmpty == nil {
                    issues.append("\(meal.name): item sem nome ou quantidade")
                }
            }
        }
        guard issues.isEmpty else { throw CopilotPlanError(Array(Set(issues)).sorted()) }
        return result
    }

    // MARK: Registro alimentar

    func foodLogChangeSet(id: String, argumentsJSON: String) throws -> CopilotChangeSet {
        let args = try Self.decode(argumentsJSON, schema: CopilotToolSchemas.foodLog, as: FoodLogArgs.self)
        let store = NutritionStore(context: context, calendar: calendar)
        let activeMeals = Dictionary(((try store.activePlan())?.sortedDays.flatMap(\.sortedMeals) ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        var operations: [CopilotOperation] = []
        var diff: [CopilotDiffLine] = []
        var issues: [String] = []
        for (index, entry) in args.entries.enumerated() {
            let item = entry.food.item
            guard !item.name.isEmpty, item.quantity > 0 else {
                issues.append("entries[\(index)]: nome e quantidade > 0")
                continue
            }
            var mealID: UUID?
            if let raw = entry.mealId {
                guard let id = UUID(uuidString: raw), activeMeals[id] != nil else {
                    issues.append("entries[\(index)].mealId: refeição não está no plano ativo")
                    continue
                }
                mealID = id
            }
            guard let date = resolveDate(day: entry.date, time: entry.time) else {
                issues.append("entries[\(index)]: data/hora inválida")
                continue
            }
            if date > now.addingTimeInterval(3600) { issues.append("entries[\(index)]: horário no futuro"); continue }
            operations.append(.logFood(item: item, date: date, mealID: mealID))
            let meal = mealID.flatMap { activeMeals[$0]?.name } ?? String(localized: "fora do plano")
            diff.append(CopilotDiffLine(context: String(localized: "Registro \(Self.dayLabel(date, now: now, calendar: calendar)) \(Self.clock(date, calendar)) · \(meal)"),
                                        before: nil, after: Self.foodText(item)))
        }
        guard issues.isEmpty else { throw CopilotPlanError(issues) }
        guard let first = operations.first, case let .logFood(_, date, _) = first else { throw CopilotPlanError("nada a registrar") }
        return CopilotChangeSet(id: id, scope: .foodLog(day: calendar.startOfDay(for: date)), operations: operations, diff: diff,
                                baseFingerprint: "", createdAt: now)
    }

    private func resolveDate(day: String?, time: String?) -> Date? {
        let base: Date
        if let day {
            guard let parsed = FitnessToolbox.parseDay(day, calendar) else { return nil }
            base = parsed
        } else {
            base = calendar.startOfDay(for: now)
        }
        if let time {
            guard let minutes = NutritionPlanDraft.MealDraft.minutes(from: time) else { return nil }
            return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base)
        }
        if calendar.isDate(base, inSameDayAs: now) { return now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: base)
    }

    // MARK: Recalcular (conflito)

    /// Reaplica as operações sobre o estado atual: diff e impressão digital novos (para reconfirmar).
    func recompute(_ changeSet: CopilotChangeSet) throws -> CopilotChangeSet {
        var updated = changeSet
        switch changeSet.scope {
        case let .routine(id, _):
            guard let routine = try ProgramStore(context: context).routine(id: id) else { throw CopilotPlanError("a ficha não existe mais") }
            let before = ProgramStore(context: context).snapshot(of: routine)
            let after = try Self.apply(changeSet.operations, to: before)
            updated.diff = Self.diff(before: before, after: after)
            updated.baseFingerprint = before.fingerprint
            updated.scope = .routine(id: id, name: routine.name)
        case let .nutritionPlan(id, _):
            let store = NutritionStore(context: context, calendar: calendar)
            guard let plan = try store.plan(id: id) else { throw CopilotPlanError("a dieta não existe mais") }
            let before = store.snapshot(of: plan)
            let after = try Self.apply(changeSet.operations, to: before)
            updated.diff = Self.diff(before: before, after: after)
            updated.baseFingerprint = before.fingerprint
            updated.scope = .nutritionPlan(id: id, name: plan.name)
        case .foodLog:
            break
        }
        return updated
    }
}

// MARK: - Diff legível

extension CopilotPlanner {
    static func diff(before: RoutineSnapshot, after: RoutineSnapshot) -> [CopilotDiffLine] {
        var lines: [CopilotDiffLine] = []
        let beforeByID = Dictionary(before.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterIDs = Set(after.exercises.map(\.id))
        for item in before.exercises where !afterIDs.contains(item.id) {
            lines.append(CopilotDiffLine(context: item.exerciseName, before: setsSummary(item), after: nil))
        }
        for item in after.exercises {
            guard let old = beforeByID[item.id] else {
                lines.append(CopilotDiffLine(context: item.exerciseName, before: nil, after: setsSummary(item)))
                continue
            }
            if old.exerciseID != item.exerciseID {
                lines.append(CopilotDiffLine(context: String(localized: "Exercício"), before: old.exerciseName, after: item.exerciseName))
            }
            let name = item.exerciseName
            if old.restSeconds != item.restSeconds {
                lines.append(CopilotDiffLine(context: String(localized: "\(name) · descanso"), before: restText(old.restSeconds),
                                             after: restText(item.restSeconds)))
            }
            if old.sets.count != item.sets.count {
                lines.append(CopilotDiffLine(context: String(localized: "\(name) · séries"), before: "\(old.sets.count)",
                                             after: "\(item.sets.count)"))
            }
            let common = min(old.sets.count, item.sets.count)
            lines += attributeLines(name: name, label: String(localized: "repetições"), common: common,
                                    old: old.sets.map { $0.repTarget.map(repText) ?? "—" },
                                    new: item.sets.map { $0.repTarget.map(repText) ?? "—" })
            lines += attributeLines(name: name, label: String(localized: "carga atual"), common: common,
                                    old: old.sets.map { loadText($0.currentLoad) }, new: item.sets.map { loadText($0.currentLoad) },
                                    fallbackOld: old.sets.map { loadText($0.effectiveLoad) })
            lines += attributeLines(name: name, label: String(localized: "carga inicial"), common: common,
                                    old: old.sets.map { loadText($0.initialLoad) }, new: item.sets.map { loadText($0.initialLoad) })
            lines += attributeLines(name: name, label: String(localized: "descanso"), common: common,
                                    old: old.sets.map { restText($0.restSeconds) }, new: item.sets.map { restText($0.restSeconds) })
        }
        let commonBefore = before.exercises.map(\.id).filter { afterIDs.contains($0) }
        let commonAfter = after.exercises.map(\.id).filter { beforeByID[$0] != nil }
        if commonBefore != commonAfter {
            lines.append(CopilotDiffLine(context: String(localized: "Ordem"),
                                         before: commonBefore.compactMap { beforeByID[$0]?.exerciseName }.joined(separator: ", "),
                                         after: commonAfter.compactMap { id in after.exercises.first { $0.id == id }?.exerciseName }
                                             .joined(separator: ", ")))
        }
        return lines
    }

    /// Uma linha por atributo quando a mudança é igual em todas as séries alteradas; senão uma por série.
    /// `fallbackOld`: o que mostrar como "antes" quando o valor antigo é vazio (carga atual ausente → efetiva).
    private static func attributeLines(name: String, label: String, common: Int, old: [String], new: [String],
                                       fallbackOld: [String]? = nil) -> [CopilotDiffLine] {
        let changed = (0 ..< common).filter { old[$0] != new[$0] }
        guard !changed.isEmpty else { return [] }
        func before(_ i: Int) -> String {
            if old[i] == "—", let fallbackOld, fallbackOld[i] != "—" { return fallbackOld[i] }
            return old[i]
        }
        let pairs = Set(changed.map { "\(before($0))|\(new[$0])" })
        if pairs.count == 1, let first = changed.first {
            let which = changed.count == common ? String(localized: "todas as séries")
                : changed.count == 1 ? String(localized: "série \(first + 1)")
                : String(localized: "séries \(changed.map { String($0 + 1) }.joined(separator: ", "))")
            return [CopilotDiffLine(context: "\(name) · \(label) (\(which))", before: before(first), after: new[first])]
        }
        return changed.map { CopilotDiffLine(context: String(localized: "\(name) · série \($0 + 1) · \(label)"), before: before($0), after: new[$0]) }
    }

    static func setsSummary(_ item: RoutineSnapshot.Item) -> String {
        let reps = item.sets.first?.repTarget.map(repText) ?? ""
        let load = loadText(item.sets.first?.effectiveLoad)
        return [String(localized: "\(item.sets.count) séries"), reps.isEmpty ? nil : "× \(reps)", load == "—" ? nil : load]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func repText(_ target: RepTarget) -> String { target.displayText }

    static func loadText(_ load: Load?) -> String {
        guard let load else { return "—" }
        func number(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        }
        switch load {
        case let .weight(value, unit): return "\(number(value)) \(unit.rawValue)"
        case let .bodyweight(delta, unit):
            return delta == 0 ? String(localized: "peso corporal")
                : String(localized: "peso corporal \(delta > 0 ? "+" : "−")\(number(abs(delta))) \(unit.rawValue)")
        }
    }

    static func restText(_ seconds: Int?) -> String { seconds.map { "\($0) s" } ?? String(localized: "padrão") }

    static func diff(before: NutritionPlanSnapshot, after: NutritionPlanSnapshot) -> [CopilotDiffLine] {
        var lines: [CopilotDiffLine] = []
        if before.targets != after.targets {
            lines.append(CopilotDiffLine(context: String(localized: "Metas"), before: targetsText(before.targets), after: targetsText(after.targets)))
        }
        let oldMeals = Dictionary(before.days.flatMap(\.meals).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newMeals = Dictionary(after.days.flatMap(\.meals).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for meal in before.days.flatMap(\.meals) where newMeals[meal.id] == nil {
            lines.append(CopilotDiffLine(context: String(localized: "Refeição"), before: "\(meal.name) \(clockString(minutes: meal.minutesFromMidnight))", after: nil))
        }
        for meal in after.days.flatMap(\.meals) {
            guard let old = oldMeals[meal.id] else {
                lines.append(CopilotDiffLine(context: String(localized: "Refeição"), before: nil,
                                             after: "\(meal.name) \(clockString(minutes: meal.minutesFromMidnight))"))
                for item in meal.items { lines.append(CopilotDiffLine(context: meal.name, before: nil, after: foodText(item))) }
                continue
            }
            if old.name != meal.name || old.minutesFromMidnight != meal.minutesFromMidnight {
                lines.append(CopilotDiffLine(context: String(localized: "Refeição"),
                                             before: "\(old.name) \(clockString(minutes: old.minutesFromMidnight))",
                                             after: "\(meal.name) \(clockString(minutes: meal.minutesFromMidnight))"))
            }
            let oldItems = Dictionary(old.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newIDs = Set(meal.items.map(\.id))
            for item in old.items where !newIDs.contains(item.id) {
                lines.append(CopilotDiffLine(context: meal.name, before: foodText(item), after: nil))
            }
            for item in meal.items {
                if let previous = oldItems[item.id] {
                    if previous.name != item.name || previous.quantity != item.quantity || previous.unit != item.unit
                        || previous.values != item.values {
                        lines.append(CopilotDiffLine(context: meal.name, before: foodText(previous), after: foodText(item)))
                    }
                } else {
                    lines.append(CopilotDiffLine(context: meal.name, before: nil, after: foodText(item)))
                }
            }
        }
        return lines
    }

    static func foodText(_ item: NutritionPlanSnapshot.ItemValue) -> String {
        foodText(CopilotFoodItem(name: item.name, quantity: item.quantity, unit: item.unit, values: item.values))
    }

    static func foodText(_ item: CopilotFoodItem) -> String {
        let quantity = item.quantity.rounded() == item.quantity ? String(Int(item.quantity)) : String(format: "%.1f", item.quantity)
        let kcal = item.values.kcal.map { " · \(Int($0.rounded())) kcal" } ?? ""
        return "\(quantity) \(item.unit.symbol) \(item.name)\(kcal)"
    }

    static func targetsText(_ t: NutritionTargets) -> String {
        let parts: [String?] = [
            t.kcal.map { "\(Int($0)) kcal" }, t.protein.map { "P \(Int($0)) g" }, t.carbs.map { "C \(Int($0)) g" },
            t.fat.map { "G \(Int($0)) g" }, t.fiber.map { "fibra \(Int($0)) g" }, t.waterMilliliters.map { "água \(Int($0)) ml" },
        ]
        let text = parts.compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? String(localized: "sem metas") : text
    }

    static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "hoje") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "ontem")
        }
        let c = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
    }
}
