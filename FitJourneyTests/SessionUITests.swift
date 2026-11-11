import Foundation
import Testing
@testable import FitJourney

@MainActor
struct SessionPresentationTests {
    private func set(load: Double? = 26, target: String = "8–12", reps: Int? = nil, done: Bool = false)
        -> SessionSnapshot.ExerciseSet {
        SessionSnapshot.ExerciseSet(
            id: UUID(), kind: .working, targetText: target, repTarget: .range(min: 8, max: 12), effort: nil,
            plannedLoad: load.map { WatchLoad(value: $0) }, load: nil, reps: reps, targetHoldSeconds: nil,
            durationSeconds: nil, distanceMeters: nil, restSeconds: 90, isCompleted: done, completedAt: nil)
    }

    @Test func spokenSetReadsTargetAndLoad() {
        let text = SessionPresentation.spokenSet(index: 2, of: 3, set: set())
        #expect(text.contains("Série 2 de 3"))
        #expect(text.contains("alvo 8 a 12"))
        #expect(text.contains("26 quilos"))
        #expect(!text.contains("repetições feitas"))
        #expect(SessionPresentation.spokenSet(index: 1, of: 3, set: set(reps: 9)).contains("9 repetições feitas"))
    }

    @Test func spokenTargetCoversKinds() {
        #expect(SessionPresentation.spokenTarget("45 s") == "45 segundos")
        #expect(SessionPresentation.spokenTarget("20 min") == "20 minutos")
        #expect(SessionPresentation.spokenTarget("AMRAP") == "máximo de repetições")
    }

    @Test func compactTextShowsTargetUntilRepsAreInformed() {
        #expect(SessionPresentation.compactSetText(set(), kind: .repsAndLoad) == "26 kg · alvo 8–12")
        #expect(SessionPresentation.compactSetText(set(done: true), kind: .repsAndLoad) == "26 kg · alvo 8–12")
        #expect(SessionPresentation.compactSetText(set(reps: 9, done: true), kind: .repsAndLoad) == "26 kg × 9")
    }

    @Test func bodyweightLoadText() {
        #expect(SessionPresentation.loadText(WatchLoad(value: 10, isBodyweight: true)) == "+10 kg")
        #expect(SessionPresentation.loadText(WatchLoad(value: -20, isBodyweight: true)) == "−20 kg")
        #expect(SessionPresentation.loadText(nil) == nil)
    }

    @Test func lastPerformanceText() {
        let sets = (0..<3).map { _ in PerformedSet(reps: 10, load: .kg(24)) }
        #expect(SessionPresentation.lastPerformanceText(sets) == "última vez: 3 × 10 com 24 kg")
        let noReps = (0..<3).map { _ in PerformedSet(reps: nil, load: .kg(24)) }
        #expect(SessionPresentation.lastPerformanceText(noReps) == "última vez: 3 séries com 24 kg")
        #expect(SessionPresentation.lastPerformanceText([]) == nil)
    }

    // MARK: Modo da doca

    @Test func dockFollowsSessionFlow() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let session = try f.start(routine)
        var mode = SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0)
        guard case .set(_, let title, let detail, .repsAndLoad, _) = mode else { Issue.record("esperava .set, veio \(mode)"); return }
        #expect(title.hasPrefix("Concluir série"))
        #expect(detail.contains("alvo"))

        // Concluir → descanso.
        let first = try f.snapshot.currentSetID!
        f.apply(.completeSet(setID: first, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil), at: 10, session: session)
        let rested = try f.snapshot
        mode = SessionPresentation.dockMode(snapshot: rested, now: f.t0.addingTimeInterval(11))
        guard case .rest(let endsAt, let total, let nextUp) = mode else { Issue.record("esperava .rest, veio \(mode)"); return }
        #expect(endsAt == rested.restEndsAt)
        #expect(total >= 60)
        #expect(nextUp?.contains("Série") == true)

        // "Descanso concluído" fica 10 s e depois a doca volta à série.
        let end = try #require(rested.restEndsAt)
        if case .rest = SessionPresentation.dockMode(snapshot: rested, now: end.addingTimeInterval(5)) {} else { Issue.record("deveria manter o descanso concluído") }
        if case .set = SessionPresentation.dockMode(snapshot: rested, now: end.addingTimeInterval(11)) {} else { Issue.record("deveria voltar à série") }
        if case .set = SessionPresentation.dockMode(snapshot: rested, now: end.addingTimeInterval(-30), restDismissedFor: end) {} else { Issue.record("dispensado") }

        // Pausa vence tudo.
        f.apply(.pause, at: 20, session: session)
        #expect(SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0.addingTimeInterval(21)) == .paused)
    }

    @Test func dockShowsHoldForIsometric() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        // Conclui supino, rosca e tríceps até chegar na prancha.
        var guardCount = 0
        while try f.snapshot.currentExercise?.measurementKind != .isometric, guardCount < 30 {
            let id = try #require(try f.snapshot.currentSetID)
            f.apply(.completeSet(setID: id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                    at: TimeInterval(10 + guardCount), session: session)
            f.apply(.skipRest, at: TimeInterval(10 + guardCount), session: session)
            guardCount += 1
        }
        let plank = try #require(try f.snapshot.currentSetID)
        let mode = SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0.addingTimeInterval(100))
        guard case .set(_, let title, _, .isometric, let target) = mode else { Issue.record("esperava sustentação, veio \(mode)"); return }
        #expect(title == "Iniciar sustentação")
        #expect(target == 45)

        f.apply(.startHold(setID: plank), at: 100, session: session)
        guard case .holding(let setID, _, let holdTarget, let isCardio) = SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0.addingTimeInterval(101)) else {
            Issue.record("esperava .holding"); return
        }
        #expect(setID == plank)
        #expect(holdTarget == 45)
        #expect(!isCardio)
    }

    @Test func dockEmptyAndFinish() throws {
        let f = try EngineFixture()
        _ = try f.start(nil)
        #expect(SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0) == .empty)
        #expect(SessionPresentation.accessoryDetail(try f.snapshot) == nil)
        #expect(SessionPresentation.routineTitle(try f.snapshot) == "Treino livre")
    }

    @Test func groupLabelShowsRound() throws {
        let f = try EngineFixture()
        _ = try f.start(try f.makeRoutine())
        let exercises = try f.snapshot.exercises
        let curl = try #require(exercises.first { $0.groupID != nil })
        #expect(SessionPresentation.groupLabel(for: curl, in: exercises) == "Bi-set · rodada 1 de 2")
        #expect(SessionPresentation.isFirstInGroup(curl, in: exercises))
        #expect(SessionPresentation.groupLabel(for: exercises[0], in: exercises) == nil)
    }
}

@MainActor
struct SessionCoordinatorTests {
    private func make() throws -> (EngineFixture, SessionCoordinator) {
        let f = try EngineFixture()
        let defaults = UserDefaults(suiteName: "coordinator-tests-\(UUID().uuidString)")!
        return (f, SessionCoordinator(engine: f.engine, defaults: defaults))
    }

    @Test func startPresentsAndFinishCloses() throws {
        let (f, coordinator) = try make()
        let routine = try f.makeRoutine()
        coordinator.start(routine: routine)
        #expect(coordinator.isPresented)
        #expect(f.engine.snapshot != nil)

        coordinator.minimize()
        #expect(!coordinator.isPresented)
        coordinator.present()
        #expect(coordinator.isPresented)

        // Segundo início só reabre a sessão em andamento.
        coordinator.minimize()
        coordinator.start(routine: routine)
        #expect(coordinator.isPresented)
        #expect(try f.base.count(WorkoutSession.self) == 1)

        #expect(coordinator.send(.finish(rpe: 7, applyLoadProposalIDs: [])))
        let finished = try #require(try f.base.sessions.completedSessions().first)
        let summary = try SessionStore(context: f.context).summary(for: finished)
        coordinator.handle(.sessionFinished(sessionID: finished.id, summary: summary))
        #expect(!coordinator.isPresented)
        #expect(coordinator.celebrationTick == 1)
    }

    @Test func checkToggleCompletesAndUncompletes() throws {
        let (f, coordinator) = try make()
        coordinator.start(routine: try f.makeRoutine())
        let first = try #require(f.engine.snapshot?.currentExercise?.sets.first)
        coordinator.toggleSet(first)
        #expect(f.engine.snapshot?.metrics.completedSets == 1)
        let done = try #require(f.engine.snapshot?.currentExercise?.sets.first)
        coordinator.toggleSet(done)
        #expect(f.engine.snapshot?.metrics.completedSets == 0)
    }

    @Test func eventsDriveHaptics() throws {
        let (fixture, coordinator) = try make()
        withExtendedLifetime(fixture) {}
        let set = UUID()
        // Série concluída fora do check (doca, relógio) vibra pelo evento.
        coordinator.handle(.setCompleted(setID: set, exerciseID: UUID(), at: .now))
        #expect(coordinator.setCompletedTick == 1)
        // Descanso vencido com a tela fechada vibra; com a tela aberta, não.
        coordinator.handle(.restFinished(at: .now))
        #expect(coordinator.restFinishedTick == 1)
    }

    @Test func rejectedCommandRaisesErrorTick() throws {
        let (fixture, coordinator) = try make()
        withExtendedLifetime(fixture) {}
        #expect(!coordinator.send(.pause))
        #expect(coordinator.errorTick == 1)
        #expect(coordinator.lastRejection != nil)
    }
}

@MainActor
struct HistoryPresentationTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func row(_ d: Date) -> HistoryPresentation.Row {
        .init(id: UUID(), startedAt: d, routineName: "A", durationSeconds: 3_000, volumeKg: 1_000,
              hasEstimatedVolume: false, rpe: nil, isEdited: false)
    }

    @Test func sectionsGroupByMonthNewestFirst() {
        let rows = [row(date(2026, 9, 3)), row(date(2026, 10, 20)), row(date(2026, 10, 2)), row(date(2025, 12, 31))]
        let sections = HistoryPresentation.sections(rows, calendar: calendar)
        #expect(sections.count == 3)
        #expect(sections[0].monthStart == date(2026, 10, 1, 0))
        #expect(sections[0].rows.map(\.startedAt) == [date(2026, 10, 20), date(2026, 10, 2)])
        #expect(sections[2].monthStart == date(2025, 12, 1, 0))
    }

    @Test func calendarWeeksPadToSevenAndRespectFirstWeekday() {
        // Novembro/2026 começa num domingo; semana começando na segunda → 6 vazios antes do dia 1.
        let weeks = HistoryPresentation.calendarWeeks(month: date(2026, 11, 15), calendar: calendar)
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(weeks[0].prefix(6).allSatisfy { $0 == nil })
        #expect(weeks[0][6] != nil)
        #expect(weeks.flatMap { $0 }.compactMap { $0 }.count == 30)
    }

    @Test func trainedDaysDeduplicate() {
        let rows = [row(date(2026, 11, 2, 7)), row(date(2026, 11, 2, 19)), row(date(2026, 11, 4))]
        #expect(HistoryPresentation.trainedDays(rows, calendar: calendar).count == 2)
    }

    @Test func summaryLineMarksEstimatedVolume() {
        var r = row(date(2026, 11, 2))
        #expect(HistoryPresentation.summaryLine(r).hasPrefix("50 min"))
        r.hasEstimatedVolume = true
        #expect(HistoryPresentation.summaryLine(r).contains("~"))
    }

    // MARK: Evolução

    private func sample(_ day: Int, load: Double, reps: [Int?]) -> ProgressCalculator.Sample {
        .init(id: UUID(), date: date(2026, 10, day),
              sets: reps.map { .init(performed: PerformedSet(reps: $0, load: .kg(load)), durationSeconds: nil, distanceMeters: nil) })
    }

    @Test func pointsMarkRecordsAfterTheFirstSession() {
        let samples = [sample(1, load: 30, reps: [10, 10]), sample(8, load: 32.5, reps: [10, 8]),
                       sample(15, load: 30, reps: [10, 10]), sample(22, load: 35, reps: [8])]
        let load = ProgressCalculator.points(samples, metric: .load)
        #expect(load.map(\.value) == [30, 32.5, 30, 35])
        #expect(load.map(\.isRecord) == [false, true, false, true])
        let volume = ProgressCalculator.points(samples, metric: .volume)
        #expect(volume.first?.value == 600)
        let oneRM = ProgressCalculator.points(samples, metric: .oneRM)
        #expect(oneRM.count == 4)
    }

    @Test func oneRMIgnoresSessionsWithoutRepsButLoadDoesNot() {
        let samples = [sample(1, load: 30, reps: [nil, nil])]
        #expect(ProgressCalculator.points(samples, metric: .load).count == 1)
        #expect(ProgressCalculator.points(samples, metric: .oneRM).isEmpty)
    }

    @Test func periodFilterAndBestSet() {
        let samples = [sample(1, load: 30, reps: [10]), sample(22, load: 35, reps: [8, 6])]
        let points = ProgressCalculator.points(samples, metric: .load)
        let now = date(2026, 10, 25)
        #expect(ProgressCalculator.filter(points, period: .month, now: now, calendar: calendar).count == 2)
        #expect(ProgressCalculator.filter(points, period: .month, now: date(2026, 12, 1), calendar: calendar).isEmpty)
        #expect(ProgressCalculator.filter(points, period: .all, now: date(2030, 1, 1), calendar: calendar).count == 2)
        let best = ProgressCalculator.bestSet(samples)
        #expect(best?.loadKg == 35)
        #expect(best?.reps == 8)
    }

    @Test func sessionLineShowsRepsOnlyWhenInformed() {
        let withReps = sample(1, load: 32.5, reps: [10, 10, 9, 8])
        #expect(ProgressCalculator.sessionLine(withReps, kind: .repsAndLoad) == "\(FJFormat.number(32.5)) × 10, 10, 9, 8")
        let without = sample(1, load: 32.5, reps: [nil, nil, nil, nil])
        #expect(ProgressCalculator.sessionLine(without, kind: .repsAndLoad).hasSuffix("4 séries"))
    }

    @Test func metricsByKind() {
        #expect(ProgressCalculator.Metric.available(for: .repsAndLoad) == [.load, .volume, .oneRM])
        #expect(ProgressCalculator.Metric.available(for: .isometric) == [.time])
        #expect(ProgressCalculator.Metric.available(for: .timeOrDistance) == [.distance, .duration])
        #expect(ProgressCalculator.Metric.volume.startsAtZero)
        #expect(!ProgressCalculator.Metric.load.startsAtZero)
    }
}
