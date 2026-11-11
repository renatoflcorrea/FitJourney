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

    @Test func pluralsAgree() {
        #expect(SessionPresentation.seriesCount(1) == "1 série")
        #expect(SessionPresentation.seriesCount(3) == "3 séries")
        #expect(SessionPresentation.repsDone(1) == "1 repetição feita")
        #expect(SessionPresentation.setsDone(1, of: 1) == "1 de 1 série")
        #expect(SessionPresentation.groupName(memberCount: 2) == "Bi-set")
        #expect(SessionPresentation.groupName(memberCount: 3) == "Tri-set")
        #expect(SessionPresentation.groupName(memberCount: 5) == "Circuito")
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
        // `skipRest` limpa o descanso no motor: a doca volta à série sem "dispensar local".
        f.apply(.skipRest, at: 12, session: session)
        if case .set = SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0.addingTimeInterval(13)) {} else { Issue.record("skipRest deveria limpar o descanso") }

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
        guard case .holding(let setID, _, let holdTarget, let isCardio, _) = SessionPresentation.dockMode(snapshot: try f.snapshot, now: f.t0.addingTimeInterval(101)) else {
            Issue.record("esperava .holding"); return
        }
        #expect(setID == plank)
        #expect(holdTarget == 45)
        #expect(!isCardio)
    }

    @Test func restTotalComesFromTheSnapshot() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let first = try f.snapshot.currentSetID!
        f.apply(.completeSet(setID: first, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil), at: 10, session: session)
        f.apply(.adjustRest(seconds: 15), at: 12, session: session)
        let snapshot = try f.snapshot
        let end = try #require(snapshot.restEndsAt)
        let total = try #require(snapshot.restTotalSeconds)
        #expect(SessionPresentation.restTotal(snapshot, endsAt: end, now: f.t0.addingTimeInterval(13)) == total)
        // Sem o campo (snapshot antigo), cai no restante.
        var legacy = snapshot
        legacy.restTotalSeconds = nil
        let remaining = end.timeIntervalSince(f.t0.addingTimeInterval(13))
        #expect(SessionPresentation.restTotal(legacy, endsAt: end, now: f.t0.addingTimeInterval(13)) == remaining)
    }

    @Test func holdElapsedFreezesOnPause() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        var guardCount = 0
        while try f.snapshot.currentExercise?.measurementKind != .isometric, guardCount < 30 {
            let id = try #require(try f.snapshot.currentSetID)
            f.apply(.completeSet(setID: id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                    at: TimeInterval(10 + guardCount), session: session)
            f.apply(.skipRest, at: TimeInterval(10 + guardCount), session: session)
            guardCount += 1
        }
        let plank = try #require(try f.snapshot.currentSetID)
        f.apply(.startHold(setID: plank), at: 100, session: session)
        f.apply(.pause, at: 110, session: session)
        let snapshot = try f.snapshot
        #expect(snapshot.holdElapsed(at: f.t0.addingTimeInterval(500)) == 10)
    }

    @Test func kindNamesCoverSelectableKinds() {
        #expect(SessionPresentation.selectableKinds.count == 7)
        #expect(SessionPresentation.kindName(.working) == "Normal")
        #expect(SessionPresentation.kindName(.unknown) == "Normal")
        #expect(SessionPresentation.kindName(.dropSet) == "Drop set")
        #expect(Set(SessionPresentation.selectableKinds.map(SessionPresentation.kindName)).count == 7)
    }

    @Test func painAndMoodTexts() {
        #expect(SessionPresentation.painText(score: nil, location: nil) == nil)
        #expect(SessionPresentation.painText(score: 4, location: nil) == "Dor 4/10")
        #expect(SessionPresentation.painText(score: 4, location: "Ombro") == "Dor 4/10 · Ombro")
        #expect(SessionPresentation.painText(score: nil, location: "Ombro") == "Desconforto · Ombro")
        #expect(SessionPresentation.painText(score: 0, location: "") == "Dor 0/10")
        #expect(SessionPresentation.spokenPain(score: 7, location: "joelho")?.contains("7 de 10") == true)
        #expect(SessionPresentation.moodLabel(1) == "Muito baixo")
        #expect(SessionPresentation.moodLabel(5) == "Ótimo")
    }

    @Test func cardioTextsOnlyShowWhatWasInformed() {
        #expect(SessionPresentation.cardioDetailText(level: nil, speedKmh: nil, inclinePercent: nil) == nil)
        let text = SessionPresentation.cardioDetailText(level: 6, speedKmh: 9.5, inclinePercent: 2)
        #expect(text?.contains("nível 6") == true)
        #expect(text?.contains("km/h") == true)
        #expect(text?.contains("inclinação") == true)
        #expect(SessionPresentation.cardioTargetText(durationSeconds: nil, distanceMeters: nil) == nil)
        #expect(SessionPresentation.cardioTargetText(durationSeconds: 1_200, distanceMeters: 3_000) == "20:00 · 3 km")
        #expect(SessionPresentation.cardioTargetText(durationSeconds: nil, distanceMeters: 500) == "500 m")
    }

    @Test func groupRoundHintFollowsTheEngine() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        var guardCount = 0
        // Avança até o bi-set (rosca + tríceps).
        while try f.snapshot.currentGroup == nil, guardCount < 30 {
            let id = try #require(try f.snapshot.currentSetID)
            f.apply(.completeSet(setID: id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                    at: TimeInterval(10 + guardCount), session: session)
            f.apply(.skipRest, at: TimeInterval(10 + guardCount), session: session)
            guardCount += 1
        }
        let snapshot = try f.snapshot
        let round = try #require(snapshot.currentGroup)
        let hint = try #require(SessionPresentation.groupRoundHint(snapshot))
        if round.completesRound {
            #expect(hint.contains("Fim da rodada"))
        } else {
            #expect(hint.contains("sem descanso"))
        }
    }

    @Test func watchBadgeRules() {
        let id = UUID()
        let outdatedPeer = WatchLinkCompatibility(minimumVersion: 1, currentVersion: 0)
        #expect(SessionPresentation.watchBadge(canRequest: false, recordingSessionID: nil, currentSessionID: id, incompatibility: nil) == .none)
        #expect(SessionPresentation.watchBadge(canRequest: true, recordingSessionID: nil, currentSessionID: id, incompatibility: nil) == .offer)
        #expect(SessionPresentation.watchBadge(canRequest: false, recordingSessionID: id, currentSessionID: id, incompatibility: nil) == .recording)
        // Gravando outra sessão não é selo desta.
        #expect(SessionPresentation.watchBadge(canRequest: false, recordingSessionID: UUID(), currentSessionID: id, incompatibility: nil) == .none)
        #expect(SessionPresentation.watchBadge(canRequest: true, recordingSessionID: nil, currentSessionID: id,
                                               incompatibility: outdatedPeer) == .incompatible(phoneIsOutdated: false))
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
        // Descanso vencido sem painel visível vibra pelo evento.
        coordinator.handle(.restFinished(at: .now))
        #expect(coordinator.restFinishedTick == 1)
    }

    @Test func hapticsDependOnWhatIsVisible() throws {
        let (f, coordinator) = try make()
        coordinator.start(routine: try f.makeRoutine())
        #expect(coordinator.isPresented)
        // Tela aberta: o check da linha vibra sozinho; o evento não duplica.
        coordinator.handle(.setCompleted(setID: UUID(), exerciseID: UUID(), at: .now))
        #expect(coordinator.setCompletedTick == 0)
        // Painel de descanso visível vibra sozinho; sem painel (outro modo da doca), vibra pelo evento.
        coordinator.restPanelVisible = true
        coordinator.handle(.restFinished(at: .now))
        #expect(coordinator.restFinishedTick == 0)
        coordinator.restPanelVisible = false
        coordinator.handle(.restFinished(at: .now))
        #expect(coordinator.restFinishedTick == 1)
        // Minimizada: ambos vibram.
        coordinator.restPanelVisible = true
        coordinator.minimize()
        coordinator.handle(.setCompleted(setID: UUID(), exerciseID: UUID(), at: .now))
        coordinator.handle(.restFinished(at: .now))
        #expect(coordinator.setCompletedTick == 1)
        #expect(coordinator.restFinishedTick == 2)
        // Comemoração só no fim da sessão.
        #expect(coordinator.celebrationTick == 0)
    }

    @Test func staleSessionOnForegroundKeepsPresentationState() throws {
        let (f, coordinator) = try make()
        coordinator.start(routine: try f.makeRoutine())
        #expect(coordinator.isPresented)
        f.clock.now = f.t0.addingTimeInterval(5 * 3_600)
        coordinator.handleForeground()
        #expect(f.engine.staleSessionPrompt != nil)
        // O prompt não apaga o estado de apresentação; "Continuar" reabre.
        #expect(coordinator.isPresented)
        #expect(f.engine.resolveStaleSession(.keepGoing))
        #expect(f.engine.staleSessionPrompt == nil)
        coordinator.minimize()
        coordinator.present()
        #expect(coordinator.isPresented)
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

    @Test func loadEditingKeepsNativeUnit() {
        let native = LoadEditing.native(.weight(value: 66, unit: .lb))
        #expect(native.value == 66)
        #expect(native.unit == .lb)
        #expect(LoadEditing.unitText(native.unit) == "lb")
        #expect(LoadEditing.make(value: 70, unit: .lb, isBodyweight: false) == .weight(value: 70, unit: .lb))
        #expect(LoadEditing.make(value: -10, unit: .lb, isBodyweight: true) == .bodyweight(delta: -10, unit: .lb))
        #expect(LoadEditing.native(.bodyweight(delta: 12, unit: .lb)).value == 12)
        #expect(LoadEditing.native(nil).unit == .kg)
    }

    @Test func savingWithoutChangesIsNotAnEdit() {
        let old: (reps: Int?, load: Load?, duration: Double?, distance: Double?) = (10, .weight(value: 66, unit: .lb), nil, nil)
        #expect(!LoadEditing.hasChanges(old: old, new: old))
        #expect(LoadEditing.hasChanges(old: old, new: (10, .weight(value: 67, unit: .lb), nil, nil)))
        #expect(LoadEditing.hasChanges(old: old, new: (nil, old.load, nil, nil)))
    }

    @Test func historyEditInPoundsMarksEditedOnlyOnChange() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let session = try f.start(routine)
        let id = try #require(f.engine.snapshot?.currentSetID)
        f.apply(.completeSet(setID: id, reps: 8, load: WatchLoad(value: 66, unit: .lb), durationSeconds: nil, distanceMeters: nil), at: 10, session: session)
        f.apply(.finish(rpe: nil, applyLoadProposalIDs: []), at: 20, session: session)
        let finished = try #require(try f.base.sessions.completedSessions().first)
        let log = try #require(finished.sortedExercises.flatMap(\.sortedSets).first { $0.id == id })
        #expect(LoadEditing.native(log.load).unit == .lb)
        #expect(!log.edited)
        try SessionStore(context: f.context, autosave: false).updateSet(
            log, reps: 9, load: LoadEditing.make(value: 68, unit: .lb, isBodyweight: false))
        try f.context.save()
        #expect(log.edited)
        #expect(log.load == .weight(value: 68, unit: .lb))
    }

    @Test func metricsByKind() {
        #expect(ProgressCalculator.Metric.available(for: .repsAndLoad) == [.load, .volume, .oneRM])
        #expect(ProgressCalculator.Metric.available(for: .isometric) == [.time])
        #expect(ProgressCalculator.Metric.available(for: .timeOrDistance) == [.distance, .duration])
        #expect(ProgressCalculator.Metric.volume.startsAtZero)
        #expect(!ProgressCalculator.Metric.load.startsAtZero)
    }
}
