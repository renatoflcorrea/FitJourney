import Foundation

/// Aderência de um dia ao plano (SPEC §5): refeições feitas (feita ou ajustada) sobre as planejadas.
///
/// Regras (puras, testadas):
/// - Sem refeição planejada → `.noPlan`.
/// - Dia futuro → `.upcoming` (só o plano, sem avaliação).
/// - Tudo feito → `.complete`, em qualquer fase (hoje inclusive: não sobra nada pendente).
/// - Dia **100% pulado** → `.allSkipped`: decisão consciente de não comer o plano, diferente de "nada feito".
/// - Nenhuma feita e nenhuma pulada, dia passado → `.none` ("sem registro", neutro, não é falha moral).
/// - Hoje, nada feito ainda mas refeições por vir → `.upcoming` (o dia está aberto; nunca `.none`).
/// - Alguma feita e ainda falta alguma (pendente, pulada ou, no passado, sem registro) → `.partial`.
struct DayAdherence: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case noPlan, upcoming, none, allSkipped, partial, complete
    }

    var planned: Int
    var done: Int
    var skipped: Int = 0
    var phase: NutritionDayPhase = .past

    var ratio: Double? { planned > 0 ? Double(done) / Double(planned) : nil }

    var level: Level {
        if planned == 0 { return .noPlan }
        if phase == .future { return .upcoming }
        if done >= planned { return .complete }
        if done == 0 {
            if skipped >= planned { return .allSkipped }
            return phase == .today ? .upcoming : .none
        }
        return .partial
    }

    static func make(statuses: [MealStatus], phase: NutritionDayPhase) -> DayAdherence {
        DayAdherence(planned: statuses.count,
                     done: statuses.filter { $0 == .done || $0 == .adjusted }.count,
                     skipped: statuses.filter { $0 == .skipped }.count,
                     phase: phase)
    }
}
