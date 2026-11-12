import Foundation

// Ferramentas de escrita **propostas** do copiloto (SPEC §7A.2): validam, resolvem ids e calculam o diff a partir do
// estado atual; devolvem um `CopilotChangeSet` para o cartão. Nunca gravam — quem grava é o `ChangeApplier`.

extension FitnessToolbox {
    nonisolated static func copilotSpec(_ name: Name) -> ToolSpec {
        switch name {
        case .proposeRoutineChanges:
            ToolSpec(name: name.rawValue,
                     description: "Propõe alterações numa ficha existente (carga, repetições, séries, descanso, trocar/adicionar/remover/reordenar exercícios). Use os ids de get_program. O app mostra o antes → depois para o usuário aplicar; nada é gravado.",
                     parametersSchema: CopilotToolSchemas.routine)
        case .proposeNutritionChanges:
            ToolSpec(name: name.rawValue,
                     description: "Propõe alterações numa dieta existente (adicionar/remover/alterar item ou refeição, metas — em set_targets só os campos não nulos mudam). Use os ids de list_nutrition_plans. O app mostra o antes → depois para o usuário aplicar; nada é gravado.",
                     parametersSchema: CopilotToolSchemas.nutrition)
        case .proposeFoodLog:
            ToolSpec(name: name.rawValue,
                     description: "Propõe registrar o que o usuário comeu (horário, refeição do plano ou avulso; valores estimados). O app mostra o cartão para o usuário confirmar; nada é gravado.",
                     parametersSchema: CopilotToolSchemas.foodLog)
        default:
            spec(name)
        }
    }

    func proposeChanges(_ name: Name, _ call: ToolCall) -> ToolOutcome {
        let planner = CopilotPlanner(context: context, now: now(), calendar: calendar)
        do {
            let changeSet: CopilotChangeSet
            switch name {
            case .proposeRoutineChanges: changeSet = try planner.routineChangeSet(id: call.id, argumentsJSON: call.argumentsJSON)
            case .proposeNutritionChanges: changeSet = try planner.nutritionChangeSet(id: call.id, argumentsJSON: call.argumentsJSON)
            case .proposeFoodLog: changeSet = try planner.foodLogChangeSet(id: call.id, argumentsJSON: call.argumentsJSON)
            default: return error("internal", "unreachable")
            }
            return ToolOutcome(content: JSONValue.object([
                "status": .string("proposed"),
                "changeSetId": .string(changeSet.id),
                "scope": .string(changeSet.scope.title),
                "diff": .array(changeSet.diff.prefix(30).map { .string($0.text) }),
                "note": .string("O usuário verá um cartão com Aplicar/Ajustar/Descartar. Nada foi gravado; não diga que foi."),
            ]).jsonString(), changeSet: changeSet)
        } catch let planError as CopilotPlanError {
            return ToolOutcome(content: JSONValue.object([
                "status": .string("invalid"),
                "issues": .array(planError.issues.prefix(20).map(JSONValue.string)),
                "hint": .string("Corrija os campos e chame \(name.rawValue) de novo com o objeto completo."),
            ]).jsonString(), isError: true)
        } catch {
            return self.error("internal", "Falha ao ler os dados locais.")
        }
    }
}
