#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Demonstração para as capturas da App Store (só DEBUG; o Release nem compila este arquivo).
///
/// `-fj.seedDemo YES` (banco vazio): ~6 semanas de treinos ABC concluídos com cargas subindo, dieta com registros de
/// hoje, uma conversa do Coach com um cartão de alteração do copiloto e FC sintética no lugar do Saúde (o simulador não
/// tem HealthKit real). Nomes do programa, fichas, refeições e alimentos saem no idioma do app. Tudo passa pelos
/// stores reais; nada aqui inventa tela ou controle.
///
/// Ganchos relacionados: `-fj.startTab`, `-fj.sessionDemo mid`, `-fj.demoRoute workout|progress`, `-fj.openFirstRoutine`.
@MainActor
enum StoreDemo {
    static let seedFlag = "fj.seedDemo"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: seedFlag) }
    static var isEnglish: Bool { AppLanguageCode.current == AppLanguageCode.english }
    private static func tr(_ pt: String, _ en: String) -> String { isEnglish ? en : pt }

    // MARK: Sementes

    /// Insere tudo com o banco vazio (idempotente: com programa existente não faz nada).
    @discardableResult
    static func insertIfNeeded(into context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard (try? SampleProgramFactory.shouldOfferStarter(in: context)) == true else { return false }
        do {
            try insert(into: context, now: now, calendar: calendar)
            return true
        } catch {
            assertionFailure("StoreDemo: \(error)")
            return false
        }
    }

    private struct PlanItem {
        let key: String
        let sets: Int
        let reps: RepTarget
        let startLoad: Double?
        let step: Double
        let rest: Int?
    }

    private static func insert(into context: ModelContext, now: Date, calendar: Calendar) throws {
        try ExerciseCatalogSeeder.seedIfNeeded(in: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let byKey = Dictionary(exercises.compactMap { e in e.catalogKey.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })

        let programs = ProgramStore(context: context)
        let program = try programs.createProgram(
            name: tr("ABC Hipertrofia", "ABC Hypertrophy"), goal: .hypertrophy, scheduleMode: .sequential,
            startDate: calendar.date(byAdding: .day, value: -45, to: now) ?? now, activate: true)
        program.goalText = tr("Ganhar massa com 3–4 treinos por semana", "Build muscle with 3–4 workouts a week")
        program.endDate = calendar.date(byAdding: .weekOfYear, value: 12, to: program.startDate)

        let plan: [(name: String, symbol: String, items: [PlanItem])] = [
            (tr("A — Peito e tríceps", "A — Chest & triceps"), "A", [
                PlanItem(key: "bench-press", sets: 4, reps: .range(min: 8, max: 12), startLoad: 50, step: 2.5, rest: 120),
                PlanItem(key: "incline-dumbbell-press", sets: 3, reps: .range(min: 10, max: 12), startLoad: 18, step: 1, rest: nil),
                PlanItem(key: "pec-deck", sets: 3, reps: .fixed(reps: 12), startLoad: 40, step: 2.5, rest: 60),
                PlanItem(key: "triceps-pushdown", sets: 3, reps: .range(min: 10, max: 15), startLoad: 25, step: 2.5, rest: 60),
            ]),
            (tr("B — Costas e bíceps", "B — Back & biceps"), "B", [
                PlanItem(key: "lat-pulldown", sets: 4, reps: .range(min: 8, max: 12), startLoad: 50, step: 2.5, rest: nil),
                PlanItem(key: "seated-cable-row", sets: 3, reps: .range(min: 10, max: 12), startLoad: 45, step: 2.5, rest: nil),
                PlanItem(key: "pull-up", sets: 3, reps: .amrap, startLoad: nil, step: 0, rest: 120),
                PlanItem(key: "barbell-curl", sets: 3, reps: .range(min: 8, max: 12), startLoad: 25, step: 2.5, rest: 60),
            ]),
            (tr("C — Pernas e ombros", "C — Legs & shoulders"), "C", [
                PlanItem(key: "back-squat", sets: 4, reps: .range(min: 6, max: 10), startLoad: 70, step: 5, rest: 180),
                PlanItem(key: "leg-press", sets: 3, reps: .range(min: 10, max: 12), startLoad: 140, step: 10, rest: nil),
                PlanItem(key: "lateral-raise", sets: 3, reps: .range(min: 12, max: 15), startLoad: 8, step: 1, rest: 60),
                PlanItem(key: "plank", sets: 3, reps: .fixed(reps: 1), startLoad: nil, step: 0, rest: 60),
            ]),
        ]

        var routines: [Routine] = []
        for entry in plan {
            let routine = try programs.addRoutine(to: program, name: entry.name, symbol: entry.symbol)
            for item in entry.items {
                guard let exercise = byKey[item.key] else { continue }
                let load: Load? = item.key == "pull-up" ? .bodyweight(delta: 0, unit: .kg) : item.startLoad.map { .kg($0) }
                let re = try programs.addExercise(exercise, to: routine, setCount: item.sets, repTarget: item.reps,
                                                  load: load, restSeconds: item.rest)
                if exercise.measurementKind == .isometric {
                    for set in re.sets ?? [] { set.holdSeconds = 45 }
                }
            }
            routines.append(routine)
        }
        // Aquecimento no supino.
        if let bench = routines.first?.sortedExercises.first {
            for set in bench.sets ?? [] { set.sortIndex += 1 }
            let warmup = SetPrescription(sortIndex: 0, kind: .warmup, repTarget: .fixed(reps: 12), initialLoad: .kg(30), restSeconds: 60)
            context.insert(warmup)
            warmup.routineExercise = bench
        }

        try insertHistory(context: context, routines: routines, plan: plan.map(\.items), byKey: byKey, now: now, calendar: calendar)
        // A ficha mostra a carga de hoje (a atual) também como inicial: o editor e o Hoje contam a mesma história.
        for routine in routines {
            for item in routine.sortedExercises {
                for set in item.sets ?? [] { if let current = set.currentLoad, set.kind.isWorking { set.initialLoad = current } }
            }
        }
        try insertNutrition(context: context, program: program, now: now, calendar: calendar)
        try context.save()
        try insertCoachConversation(context: context, routine: routines[0], now: now)
    }

    // MARK: Histórico (6 semanas, 18 treinos, A → B → C, o último ontem)

    private static func insertHistory(context: ModelContext, routines: [Routine], plan: [[PlanItem]], byKey: [String: Exercise],
                                      now: Date, calendar: Calendar) throws {
        let sessions = SessionStore(context: context)
        // Dias atrás, do mais antigo ao mais recente (3 por semana).
        let offsets = [40, 38, 36, 33, 31, 29, 26, 24, 22, 19, 17, 15, 12, 10, 8, 5, 3, 1]
        for (index, offset) in offsets.enumerated() {
            let routineIndex = index % 3
            let week = index / 3
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
            let start = calendar.date(bySettingHour: 18, minute: 10 + (index * 7) % 25, second: 0, of: day) ?? day
            let session = try sessions.start(routine: routines[routineIndex], at: start)
            var t = start.addingTimeInterval(240)
            for exercise in session.sortedExercises {
                let item = plan[routineIndex].first { byKey[$0.key]?.id == exercise.exerciseID }
                var workingIndex = 0
                for log in exercise.sortedSets {
                    t = t.addingTimeInterval(Double(125 + ((index * 31 + workingIndex * 17 + log.sortIndex * 11) % 45)))
                    var load: Load?
                    var reps: Int?
                    if let item {
                        switch (log.kind.isWorking, item.startLoad) {
                        case (false, _): load = .kg(30); reps = 12
                        case (true, let value?): load = .kg(value + item.step * Double(week))
                        case (true, nil): break
                        }
                        if log.kind.isWorking {
                            switch item.reps {
                            case .range(let lo, let hi): reps = max(lo, min(hi, hi - 1 - workingIndex + (week % 2)))
                            case .fixed(let value): reps = item.key == "plank" ? nil : value
                            case .amrap: reps = max(4, 6 + week / 2 - workingIndex)
                            }
                            workingIndex += 1
                        }
                    }
                    try sessions.completeSet(log, reps: reps, load: load, at: t, startRest: false)
                }
                t = t.addingTimeInterval(50)
            }
            let rpe = min(9, 7 + (week + index % 3) / 3)
            let note = index == offsets.count - 2 ? tr("Supino rendeu bem.", "Bench felt strong.") : nil
            try sessions.finish(session, at: t.addingTimeInterval(100), sessionRPE: rpe, mood: index % 4 == 3 ? 5 : 4,
                                notes: note, applying: try sessions.loadProposals(for: session))
        }
    }

    // MARK: Dieta (horários fixos; feitas: café e lanche; a próxima: almoço. Rodar entre 10h e 13h30 para o destaque certo)

    private static func insertNutrition(context: ModelContext, program: TrainingProgram, now: Date, calendar: Calendar) throws {
        let nutrition = NutritionStore(context: context, calendar: calendar)
        let diet = NutritionPlan(name: tr("Dieta de ganho", "Lean bulk"), goal: tr("Superávit leve", "Light surplus"),
                                 startDate: program.startDate, author: .nutritionist)
        diet.targets = NutritionTargets(kcal: 2_600, protein: 160, carbs: 300, fat: 80, fiber: 30, waterMilliliters: 3_000)
        context.insert(diet)
        let day = NutritionDay(name: tr("Todos os dias", "Every day"))
        context.insert(day)
        day.plan = diet

        func slot(_ minutes: Int) -> Int { minutes }

        typealias Food = (String, Double, FoodUnit, NutrientValues)
        let meals: [(String, Int, [Food])] = [
            (tr("Café da manhã", "Breakfast"), 7 * 60, [
                (tr("Aveia com banana", "Oatmeal with banana"), 1, .serving, NutrientValues(kcal: 320, protein: 11, carbs: 58, fat: 6, fiber: 7)),
                (tr("Ovos mexidos", "Scrambled eggs"), 3, .unit, NutrientValues(kcal: 210, protein: 18, carbs: 1, fat: 15)),
                (tr("Café com leite", "Coffee with milk"), 200, .milliliters, NutrientValues(kcal: 90, protein: 6, carbs: 9, fat: 3)),
            ]),
            (tr("Lanche da manhã", "Morning snack"), 10 * 60, [
                (tr("Iogurte natural", "Plain yogurt"), 170, .grams, NutrientValues(kcal: 100, protein: 6, carbs: 8, fat: 5)),
                (tr("Castanhas", "Mixed nuts"), 30, .grams, NutrientValues(kcal: 190, protein: 5, carbs: 6, fat: 17, fiber: 2)),
            ]),
            (tr("Almoço", "Lunch"), 12 * 60 + 30, [
                (tr("Arroz", "Rice"), 150, .grams, NutrientValues(kcal: 195, protein: 4, carbs: 42, fat: 0.4)),
                (tr("Feijão", "Beans"), 100, .grams, NutrientValues(kcal: 76, protein: 5, carbs: 14, fat: 0.5, fiber: 8.5)),
                (tr("Frango grelhado", "Grilled chicken"), 150, .grams, NutrientValues(kcal: 240, protein: 45, carbs: 0, fat: 5)),
                (tr("Salada", "Salad"), 1, .serving, NutrientValues(kcal: 30, protein: 1, carbs: 5, fat: 0, fiber: 3)),
            ]),
            (tr("Pré-treino", "Pre-workout"), 16 * 60, [
                (tr("Batata-doce", "Sweet potato"), 200, .grams, NutrientValues(kcal: 170, protein: 3, carbs: 40, fat: 0, fiber: 5)),
                (tr("Whey protein", "Whey protein"), 30, .grams, NutrientValues(kcal: 120, protein: 24, carbs: 3, fat: 1.5)),
            ]),
            (tr("Jantar", "Dinner"), 20 * 60, [
                (tr("Macarrão integral", "Whole-wheat pasta"), 120, .grams, NutrientValues(kcal: 420, protein: 16, carbs: 80, fat: 3, fiber: 9)),
                (tr("Carne moída", "Ground beef"), 120, .grams, NutrientValues(kcal: 250, protein: 30, carbs: 0, fat: 14)),
            ]),
        ]
        var created: [Meal] = []
        for (index, meal) in meals.enumerated() {
            let m = Meal(name: meal.0, minutesFromMidnight: meal.1, sortIndex: index, reminderEnabled: false)
            context.insert(m)
            m.day = day
            for (itemIndex, food) in meal.2.enumerated() {
                let item = MealItem(name: food.0, quantity: food.1, unit: food.2, values: food.3, sortIndex: itemIndex)
                context.insert(item)
                item.meal = m
            }
            created.append(m)
        }
        try nutrition.activate(diet)

        // Hoje: café feito, lanche ajustado e um item fora da dieta.
        try nutrition.markMealDone(created[0], on: now)
        try nutrition.logAdjustedMeal(created[1], on: now, items: [
            (tr("Maçã", "Apple"), 1, .unit, NutrientValues(kcal: 80, protein: 0.4, carbs: 21, fat: 0.2, fiber: 3.6)),
            (tr("Castanhas", "Mixed nuts"), 30, .grams, NutrientValues(kcal: 190, protein: 5, carbs: 6, fat: 17, fiber: 2)),
        ])
        try nutrition.addWater(milliliters: 500, at: now)
        try nutrition.addWater(milliliters: 750, at: now)
        try nutrition.addWater(milliliters: 500, at: now)
    }

    // MARK: Coach (sem rede): cartão de alteração real, calculado pelo planejador do copiloto

    private static func insertCoachConversation(context: ModelContext, routine: Routine, now: Date) throws {
        guard let bench = routine.sortedExercises.first else { return }
        let working = (bench.sets ?? []).filter { $0.kind.isWorking }.sorted { $0.sortIndex < $1.sortIndex }
        let latest = (working.last?.currentLoad ?? working.last?.initialLoad)?.externalKilograms ?? 60
        let next = latest + 2.5
        let args = """
        {"routineId":"\(routine.id.uuidString)","operations":[{"op":"set_load","exerciseId":"\(bench.id.uuidString)","set":null,
        "load":{"kind":"weight","value":\(next),"unit":"kg"},"loadTarget":"current","reps":null,"sets":null,"restSeconds":null,
        "exercise":null,"position":null}]}
        """
        let changeSet = try CopilotPlanner(context: context, now: now).routineChangeSet(id: "call-demo", argumentsJSON: args)

        let chat = ChatConversation(title: tr("Carga do supino", "Bench press load"))
        context.insert(chat)
        func add(_ role: LLMRole, _ content: String) -> ChatMessage {
            let message = ChatMessage(role: role, content: content, sortIndex: chat.nextSortIndex)
            context.insert(message)
            message.conversation = chat
            return message
        }
        _ = add(.user, tr("Fechei todas as repetições do supino nas últimas sessões. Posso subir a carga?",
                          "I hit every bench press rep in my last sessions. Can I go heavier?"))
        _ = add(.assistant, tr("Pode. Você completou as quatro séries no topo da faixa de repetições, então sugiro um aumento pequeno: **+2,5 kg** em todas as séries válidas do supino. O aquecimento fica como está. Revise o cartão abaixo; nada muda sem o seu toque.",
                               "Yes. You completed all four sets at the top of the rep range, so I suggest a small bump: **+2.5 kg** on every working set of the bench press. The warm-up stays as it is. Review the card below; nothing changes until you tap."))
        let tool = add(.tool, "{\"ok\":true}")
        tool.toolCallID = "call-demo"
        tool.toolName = "propose_routine_changes"
        try context.save()
        CopilotChangeStore.shared.register(changeSet, messageID: tool.id, now: now)
    }

    // MARK: Saúde sintética

    /// Leitor do Saúde com FC alinhada às séries concluídas (sobe na série, cai no descanso), FC do dia, passos e energia.
    static func healthReader(context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> FakeHealthReader {
        var samples: [HeartRateSample] = []
        for session in (try? SessionStore(context: context).completedSessions()) ?? [] {
            samples += sessionSamples(session)
        }
        let morning = calendar.date(bySettingHour: 7, minute: 10, second: 0, of: now) ?? now
        let walk = HealthSampleData.record(start: morning, minutes: 31, averageHeartRate: 142, energy: 310)
        let today = calendar.startOfDay(for: now)
        return FakeHealthReader(
            samples: .available(samples),
            buckets: .available(dayBuckets(day: now, run: walk.interval, upTo: now, calendar: calendar)),
            workouts: .available([walk]), energy: .available(512), stepCount: .available(6_420),
            resting: .available((0..<30).map { HealthDailyValue(day: calendar.date(byAdding: .day, value: -$0, to: today) ?? today,
                                                                  value: 58 - Double($0 / 10) + Double($0 % 3)) }),
            bodyMass: .available(78.4), calendar: calendar)
    }

    /// FC do dia em baldes de 5 min: repouso suave, corrida de manhã e recuperação depois.
    private static func dayBuckets(day: Date, run: DateInterval, upTo limit: Date, calendar: Calendar) -> [HeartRateBucket] {
        let start = calendar.startOfDay(for: day)
        var result: [HeartRateBucket] = []
        for index in 78..<288 {
            let bucketStart = start.addingTimeInterval(Double(index) * 300)
            if bucketStart >= limit { break }
            let t = Double(index)
            var average = 66 + 5 * sin(t / 9) + 3 * sin(t / 4)
            var spread = (low: 5.0, high: 9.0)
            if run.contains(bucketStart) {
                let progress = bucketStart.timeIntervalSince(run.start) / run.duration
                average = 112 + 30 * min(1, progress * 3) + 6 * sin(t * 1.3)
                spread = (low: 12, high: 16)
            } else if bucketStart >= run.end {
                average += 38 * exp(-bucketStart.timeIntervalSince(run.end) / 900)
            }
            result.append(HeartRateBucket(interval: DateInterval(start: bucketStart, duration: 300), average: average,
                                          minimum: average - spread.low, maximum: average + spread.high))
        }
        return result
    }

    /// FC (90–165 bpm) de uma sessão: base sobe devagar, cada série tem um pico (maior nas pernas) e o descanso decai.
    private static func sessionSamples(_ session: WorkoutSession) -> [HeartRateSample] {
        struct Mark { var date: Date; var peak: Double }
        var marks: [Mark] = []
        var count = 0
        for exercise in session.sortedExercises {
            let lower = ["squat", "leg", "agach"].contains { exercise.name.lowercased().contains($0) }
            let base = lower ? 148.0 : 128.0 + Double(exercise.name.count % 3) * 6
            for log in exercise.sortedSets {
                guard let date = log.completedAt else { continue }
                marks.append(Mark(date: date, peak: min(165, base + Double(count) * 0.5 + (log.kind.isWorking ? 6 : -10))))
                count += 1
            }
        }
        marks.sort { $0.date < $1.date }
        guard let first = marks.first, let last = marks.last else { return [] }
        let start = session.startedAt
        let end = session.endedAt ?? last.date.addingTimeInterval(120)
        let seed = session.startedAt.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100)
        var result: [HeartRateSample] = []
        var date = start
        while date < end {
            let progress = max(0, min(1, date.timeIntervalSince(first.date) / max(1, last.date.timeIntervalSince(first.date))))
            let rest = 96 + progress * 12
            var value = date < first.date ? 88 + 12 * (1 - first.date.timeIntervalSince(date) / max(1, first.date.timeIntervalSince(start))) : rest
            if let previous = marks.last(where: { $0.date <= date }) {
                value = max(value, rest + (previous.peak - rest) * exp(-date.timeIntervalSince(previous.date) / 55))
            }
            if let next = marks.first(where: { $0.date > date }), next.date.timeIntervalSince(date) < 45 {
                let ramp = 1 - next.date.timeIntervalSince(date) / 45
                value = max(value, rest + (next.peak - rest) * ramp * 0.95)
            }
            value += sin(date.timeIntervalSinceReferenceDate / 17 + seed) * 2.5
            result.append(HeartRateSample(date: date, bpm: max(90, min(165, value)).rounded()))
            date = date.addingTimeInterval(5)
        }
        return result
    }

    // MARK: Ganchos de navegação e serviços

    /// Notificação de fim de descanso sem pedir permissão (o alerta do sistema cobriria a captura).
    @MainActor
    final class RestScheduler: RestNotificationScheduling {
        func authorization() async -> RestNotificationAuthorization { .authorized }
        func requestAuthorization() async -> Bool { true }
        func scheduleRestEnd(at date: Date, nextExerciseName: String?) {}
        func cancelRestEnd() {}
    }

    /// Destino empurrado em Treinos para a evolução de um exercício (`-fj.demoRoute progress`).
    struct ProgressRoute: Hashable { let exerciseID: UUID }

    /// `-fj.demoRoute workout|progress`: destino a empurrar na aba Treinos.
    static func route(in context: ModelContext) -> AnyHashable? {
        switch UserDefaults.standard.string(forKey: "fj.demoRoute") {
        case "workout":
            let sessions = (try? SessionStore(context: context).completedSessions()) ?? []
            return sessions.first { $0.routineName.hasPrefix("A") }.map { AnyHashable($0) }
        case "progress":
            let key = "bench-press"
            let id = (try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.catalogKey == key })))?.first?.id
            return id.map { AnyHashable(ProgressRoute(exerciseID: $0)) }
        default:
            return nil
        }
    }

    /// `-fj.sessionDemo mid`: treino iniciado há 27 min, com aquecimento + 4 séries do supino + 1 do inclinado
    /// concluídas (comandos reais com `issuedAt` no passado), descanso correndo e FC ao vivo sintética.
    static func startMidSession(_ coordinator: SessionCoordinator, routine: Routine, completing count: Int = 6) {
        let now = Date.now
        let startAt = now.addingTimeInterval(-27 * 60)
        _ = coordinator.engine.send(.start(routineID: routine.id), issuedAt: startAt)
        let step = (27 * 60 - 150 - 12) / Double(max(1, count - 1))
        for index in 0..<count {
            guard let setID = coordinator.engine.snapshot?.currentSetID else { break }
            let at = startAt.addingTimeInterval(150 + Double(index) * step)
            _ = coordinator.engine.send(.completeSet(setID: setID, reps: index == 0 ? 12 : max(8, 12 - index), load: nil,
                                                     durationSeconds: nil, distanceMeters: nil), issuedAt: at)
        }
        coordinator.heartRate = SessionHeartRate(bpm: 131, zone: nil) // a pílula de zona é cortada na barra com este nome de exercício
        coordinator.present()
    }

    /// `-fj.demoScrollY <pt>`: depois de abrir a tela, rola a maior rolagem visível (sem UI automation no simulador).
    static func scheduleScrollIfRequested() {
        let y = UserDefaults.standard.double(forKey: "fj.demoScrollY")
        guard y > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows }.flatMap { $0 }
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
            var best: UIScrollView?
            @MainActor func visit(_ view: UIView) {
                if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
                   scroll.contentSize.height > scroll.bounds.height + 1,
                   scroll.convert(scroll.bounds, to: nil).contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY)),
                   scroll.bounds.height > (best?.bounds.height ?? 0) {
                    best = scroll
                }
                view.subviews.forEach(visit)
            }
            visit(window)
            guard let scroll = best else { return }
            let maxY = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: min(maxY, y - scroll.adjustedContentInset.top)), animated: false)
        }
    }

    /// Autorização do Saúde "conectada" (sem pedir nada ao sistema) para o gráfico de FC e a aba Saúde.
    static func healthAuthorization() -> HealthAuthorization {
        HealthPreviewFixtures.connectedAuthorization(suite: "store-demo-health")
    }

    // MARK: Coach

    static let coachDefaults: UserDefaults = CoachPreviewData.defaults(consented: true)
    static let coachSecrets = CoachPreviewData.readySecrets()
}

/// Injeta o Saúde sintético na raiz (aplicado antes dos `.environment` do app, para valer por mais perto da view).
/// Sem demonstração (`reader == nil`) não muda nada.
struct StoreDemoHealthModifier: ViewModifier {
    let reader: FakeHealthReader?
    let authorization: HealthAuthorization?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let reader, let authorization {
            content.healthReader(reader).environment(authorization)
        } else {
            content
        }
    }
}
#endif
