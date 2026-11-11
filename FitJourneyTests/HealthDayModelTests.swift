import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// Fixture do modelo do dia: contexto em memória, controller real (loja falsa) e leitor falso.
@MainActor
private struct DayFixture {
    final class Counter { var links = 0 }

    let container: ModelContainer
    let defaults = UserDefaults(suiteName: "health-day-tests-\(UUID().uuidString)")!
    let controller: HealthWorkoutController
    let counter = Counter()
    let day: Date
    let session: WorkoutSession

    var context: ModelContext { container.mainContext }

    init(status: SessionStatus = .completed) throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -3, to: Date()) ?? Date()
        day = calendar.startOfDay(for: base)
        let start = day.addingTimeInterval(12 * 3_600)
        session = WorkoutSession(routineName: "A — Peito", startedAt: start)
        session.endedAt = status == .inProgress ? nil : start.addingTimeInterval(3_600)
        session.status = status
        container.mainContext.insert(session)
        try container.mainContext.save()
        defaults.set(true, forKey: HealthAuthorization.connectionKey)
        let store = PreviewHealthStore(status: .unnecessary, sharing: .authorized)
        let authorization = HealthAuthorization(store: store, defaults: defaults)
        let counter = counter
        controller = HealthWorkoutController(store: store, authorization: authorization, context: container.mainContext,
                                             defaults: defaults, now: { counter.links += 1; return Date() })
    }

    func model() -> HealthDayModel { HealthDayModel(date: day, defaults: defaults) }

    /// Treino do Watch de força, quase no mesmo horário da sessão (confiança alta).
    func watchWorkout() -> HealthWorkoutRecord {
        HealthSampleData.record(start: day.addingTimeInterval(12 * 3_600 + 120), minutes: 58, category: .strength,
                                type: .traditionalStrength, energy: 300)
    }

    func load(_ model: HealthDayModel, reader: FakeHealthReader) async {
        await model.load(reader: reader, context: context, controller: controller, now: day.addingTimeInterval(20 * 3_600))
    }
}

@MainActor
private func data(_ model: HealthDayModel) -> HealthDayModel.DayData? {
    if case .loaded(let data) = model.phase { data } else { nil }
}

@MainActor
struct HealthDayModelTests {
    @Test func highConfidenceLinksExactlyOnce() async throws {
        let fixture = try DayFixture()
        let watch = fixture.watchWorkout()
        let reader = FakeHealthReader(workouts: .available([watch]))
        let model = fixture.model()
        await fixture.load(model, reader: reader)
        #expect(fixture.session.healthKitWorkoutID == watch.id)
        #expect(fixture.counter.links == 1)
        // Uma linha só: sessão + treino do Watch.
        #expect(data(model)?.rows.count == 1)
        #expect(data(model)?.rows.first?.origin == .appAndWatch)
        await fixture.load(model, reader: reader)
        #expect(fixture.counter.links == 1)
        #expect(fixture.session.healthKitWorkoutID == watch.id)
    }

    @Test func undoDoesNotRelinkAndMarksSessionReconciled() async throws {
        let fixture = try DayFixture()
        let watch = fixture.watchWorkout()
        let reader = FakeHealthReader(workouts: .available([watch]))
        let model = fixture.model()
        await fixture.load(model, reader: reader)
        model.unlink(sessionID: fixture.session.id, workoutID: watch.id, controller: fixture.controller)
        #expect(fixture.session.healthKitWorkoutID == nil)
        #expect(fixture.defaults.stringArray(forKey: HealthWorkoutController.reconciledKey)?.contains(fixture.session.id.uuidString) == true)
        // Nova carga (e novo modelo, como num novo launch): continua desvinculado e com duas linhas.
        for next in [model, fixture.model()] {
            await fixture.load(next, reader: reader)
            #expect(fixture.session.healthKitWorkoutID == nil)
            #expect(data(next)?.rows.count == 2)
        }
    }

    @Test func inProgressSessionIsNeverLinked() async throws {
        let fixture = try DayFixture(status: .inProgress)
        let reader = FakeHealthReader(workouts: .available([fixture.watchWorkout()]))
        let model = fixture.model()
        await fixture.load(model, reader: reader)
        #expect(fixture.session.healthKitWorkoutID == nil)
        #expect(fixture.counter.links == 0)
        // Não marca o par como tentado: vincula quando a sessão terminar.
        fixture.session.status = .completed
        fixture.session.endedAt = fixture.session.startedAt.addingTimeInterval(3_600)
        await fixture.load(model, reader: reader)
        #expect(fixture.session.healthKitWorkoutID != nil)
    }

    @Test func noDataIsNeverZeroInSeries() async throws {
        let fixture = try DayFixture()
        let model = fixture.model()
        await fixture.load(model, reader: FakeHealthReader())
        let loaded = try #require(data(model))
        #expect(loaded.summary.activeEnergyKcal == .noData)
        #expect(loaded.summary.steps == .noData)
        #expect(loaded.summary.restingHeartRate == .noData)
        #expect(loaded.energySeries.count == 7)
        #expect(loaded.energySeries.allSatisfy { $0 == nil })
        #expect(loaded.energyPrevious.isEmpty)
        #expect(loaded.restingSeries.allSatisfy { $0 == nil })
        #expect(loaded.weekTotals.reduce(0, +) == 60) // só a sessão do app
        // O dia só tem a sessão do app (dado próprio).
        #expect(loaded.rows.count == 1)
    }

    @Test func partialEnergyKeepsMissingDaysAsNil() async throws {
        let fixture = try DayFixture()
        let calendar = Calendar.current
        let twoDaysBefore = try #require(calendar.date(byAdding: .day, value: -2, to: fixture.day))
        let reader = FakeHealthReader(energyByDay: [fixture.day: 400, calendar.startOfDay(for: twoDaysBefore): 350])
        let model = fixture.model()
        await fixture.load(model, reader: reader)
        let loaded = try #require(data(model))
        #expect(loaded.energyPrevious == [350])
        #expect(loaded.energySeries.compactMap(\.self) == [350, 400])
        #expect(loaded.energySeries.filter { $0 == nil }.count == 5)
    }

    @Test func changingDayDropsPreviousData() async throws {
        let fixture = try DayFixture()
        let model = fixture.model()
        await fixture.load(model, reader: FakeHealthReader())
        #expect(data(model) != nil)
        model.shift(by: -1)
        if case .loading = model.phase {} else { Issue.record("esperava .loading ao trocar de dia") }
    }
}
