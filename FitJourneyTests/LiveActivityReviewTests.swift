import Foundation
import Testing
@testable import FitJourney

// Correções da revisão do P6.4 (A1–A2, M1–M6, B1).

@MainActor
final class LiveTestFlag { var value = false }

@MainActor
struct LiveActivityReviewTests {
    let s = LiveSnapshots()
    let source = FakeSessionSource()
    let client = FakeLiveActivityClient()
    let notifications = FakeRestScheduler()
    let gate: LiveActivityRestNotificationGate
    let defaults = UserDefaults(suiteName: "live-review-\(UUID().uuidString)")!
    let clock: TestClock
    let appActive: LiveTestFlag
    let controller: LiveActivityController

    init() {
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_500))
        self.clock = clock
        let flag = LiveTestFlag()
        appActive = flag
        gate = LiveActivityRestNotificationGate(wrapping: notifications, now: { clock.now })
        controller = LiveActivityController(engine: source, client: client, gate: gate, defaults: defaults,
                                            now: { clock.now }, unit: { .kg }, isAppActive: { flag.value },
                                            restDoneHold: .seconds(60))
    }

    private func feed(_ snapshot: SessionSnapshot) async {
        source.snapshot = snapshot
        controller.handle(snapshot)
        await controller.waitUntilIdle()
    }

    // MARK: A1 — atividade encerrada pelo sistema

    @Test func systemDismissalClearsCurrentAndIsNotRerequested() async {
        let end = clock.now.addingTimeInterval(60)
        await feed(s.make(completed: 3, restEndsAt: end, restTotal: 90))
        #expect(gate.isLiveActivityActive)
        client.systemDismiss("act-1")
        #expect(controller.current == nil)
        #expect(!gate.isLiveActivityActive)

        // Mesma sessão: não pede outra; fim de descanso não suprime a notificação (não houve alerta).
        await feed(s.make(revision: 4, completed: 3, restEndsAt: end, restTotal: 90))
        #expect(client.requests.count == 1)
        controller.handle(.restFinished(at: clock.now))
        await controller.waitUntilIdle()
        #expect(notifications.cancelCount == 0)
    }

    @Test func alertOnVanishedActivityDoesNotSuppressNotification() async {
        let end = clock.now.addingTimeInterval(60)
        await feed(s.make(completed: 3, restEndsAt: end, restTotal: 90))
        gate.scheduleRestEnd(at: end, nextExerciseName: nil)
        client.existing = []   // sumiu sem aviso: o update devolve false
        clock.now = end
        controller.handle(.restFinished(at: end))
        await controller.waitUntilIdle()
        #expect(client.updates.isEmpty)
        #expect(notifications.cancelCount == 0)
    }

    @Test func foregroundReconcileDetectsVanishedActivity() async {
        await feed(s.make())
        client.existing = []
        controller.handleForeground()
        await controller.waitUntilIdle()
        #expect(client.requests.count == 1)
        #expect(controller.current == nil)
        #expect(!gate.isLiveActivityActive)
    }

    // MARK: A2 — gate reagenda

    @Test func gateReschedulesWhenActivityStateChanges() {
        let end = clock.now.addingTimeInterval(60)
        // Sessão restaurada antes da reconciliação: agendado sem folga…
        gate.scheduleRestEnd(at: end, nextExerciseName: "Supino")
        #expect(notifications.scheduled == [end])
        // …a atividade liga: reagenda com a folga; desliga: volta ao horário real.
        gate.isLiveActivityActive = true
        #expect(notifications.scheduled.last == end.addingTimeInterval(LiveActivityRestNotificationGate.defaultGrace))
        #expect(notifications.names.last == "Supino")
        gate.isLiveActivityActive = false
        #expect(notifications.scheduled.last == end)
        // Cancelado: não reagenda.
        gate.cancelRestEnd()
        gate.isLiveActivityActive = true
        #expect(notifications.scheduled.count == 3)
    }

    @Test func expiredRestIsNotRescheduled() {
        gate.scheduleRestEnd(at: clock.now.addingTimeInterval(5), nextExerciseName: nil)
        clock.now = clock.now.addingTimeInterval(10)
        gate.isLiveActivityActive = true
        #expect(notifications.scheduled.count == 1)
    }

    @Test func restoreWithRestInProgressDelaysNotification() async {
        let end = clock.now.addingTimeInterval(60)
        gate.scheduleRestEnd(at: end, nextExerciseName: nil)
        await feed(s.make(completed: 3, restEndsAt: end, restTotal: 90))
        #expect(notifications.scheduled.last == end.addingTimeInterval(LiveActivityRestNotificationGate.defaultGrace))
    }

    @Test func suppressIgnoresANewerRest() {
        let first = clock.now.addingTimeInterval(10), second = clock.now.addingTimeInterval(100)
        gate.scheduleRestEnd(at: second, nextExerciseName: nil)
        gate.suppressRestEnd(endingAt: first)
        #expect(notifications.cancelCount == 0)
        gate.suppressRestEnd(endingAt: second)
        #expect(notifications.cancelCount == 1)
    }

    // MARK: M3 — alerta só recente e fora do primeiro plano

    @Test func restFinishedAlertsOnlyWhenRecentAndInBackground() async {
        let end = clock.now.addingTimeInterval(60)
        await feed(s.make(completed: 3, restEndsAt: end, restTotal: 90))
        appActive.value = true
        clock.now = end
        controller.handle(.restFinished(at: end))
        await controller.waitUntilIdle()
        #expect(client.updates.last?.state.phase == .restDone)
        #expect(client.updates.last?.alert == nil)

        // Em segundo plano, mas o evento é velho: atualiza sem alerta.
        appActive.value = false
        let second = end.addingTimeInterval(120)
        await feed(s.make(revision: 5, completed: 3, restEndsAt: second, restTotal: 90))
        #expect(client.updates.last?.state.phase == .resting)
        clock.now = second.addingTimeInterval(5)
        controller.handle(.restFinished(at: second))
        await controller.waitUntilIdle()
        #expect(client.updates.last?.state.phase == .restDone)
        #expect(client.updates.last?.alert == nil)
        #expect(notifications.cancelCount == 0)
    }

    // MARK: M1/M2 — cardio e sustentação sem alvo contam progressivo

    @Test func cardioAndUntargetedHoldCountUp() throws {
        var snapshot = s.make(holdOnPlank: s.t0.addingTimeInterval(800))
        snapshot.exercises[1].sets[0].targetHoldSeconds = nil
        let hold = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(810), unit: .kg))
        #expect(hold.phase == .hold)
        #expect(!hold.holdCountsDown)
        #expect(hold.holdInterval?.upperBound == s.t0.addingTimeInterval(800 + 24 * 3_600))

        snapshot.exercises[1].measurementKind = .timeOrDistance
        snapshot.exercises[1].sets[0].targetDurationSeconds = 1_200
        let cardio = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(810), unit: .kg))
        #expect(cardio.phase == .cardio)
        #expect(!cardio.holdCountsDown)
        #expect(cardio.holdTargetSeconds == 1_200)
        #expect(cardio.holdInterval?.upperBound == s.t0.addingTimeInterval(800 + 24 * 3_600))

        let targeted = try #require(LiveActivityStateMapper.state(for: s.make(holdOnPlank: s.t0), now: s.t0, unit: .kg))
        #expect(targeted.holdCountsDown)
    }

    // MARK: M6 — estado estável sem `restTotalSeconds`

    @Test func restStateIsStableWithoutTotal() throws {
        let snapshot = s.make(restEndsAt: s.t0.addingTimeInterval(900), restTotal: nil)
        let a = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(800), unit: .kg))
        let b = try #require(LiveActivityStateMapper.state(for: snapshot, now: s.t0.addingTimeInterval(850), unit: .kg))
        #expect(a == b)
        // Sem o total no snapshot, o descanso prescrito do exercício (120 s).
        #expect(a.restTotalSeconds == 120)
        #expect(a.restCountdownInterval?.upperBound == s.t0.addingTimeInterval(900))
    }

    // MARK: B1 — toques repetidos

    @Test func repeatedTapsAreDebounced() async {
        source.snapshot = s.make(restEndsAt: clock.now.addingTimeInterval(60), restTotal: 90)
        await controller.perform(.adjustRest(seconds: 15), sessionID: s.sessionID)
        clock.now = clock.now.addingTimeInterval(0.1)
        await controller.perform(.adjustRest(seconds: 15), sessionID: s.sessionID)
        clock.now = clock.now.addingTimeInterval(0.5)
        await controller.perform(.adjustRest(seconds: 15), sessionID: s.sessionID)
        #expect(source.sent == [.adjustRest(seconds: 15), .adjustRest(seconds: 15)])
    }

    // MARK: M4 — intent acorda os serviços sem UI

    @Test func intentWakesBackgroundServicesFirst() async {
        let woke = LiveTestFlag()
        controller.onWake = { woke.value = true }
        source.snapshot = s.make()
        await controller.perform(.skipRest, sessionID: s.sessionID)
        #expect(woke.value)
    }

    @Test func backgroundServicesRunOnce() {
        var runs = 0
        let services = AppBackgroundServices { runs += 1 }
        services.start()
        services.start()
        #expect(runs == 1)
    }

    // MARK: Preferência mudada com o app aberto

    @Test func preferenceChangeEndsAndRestarts() async {
        source.snapshot = s.make()
        controller.start()
        controller.handle(s.make())
        await controller.waitUntilIdle()
        #expect(client.requests.count == 1)
        defaults.set(false, forKey: AppPreferenceKeys.liveActivity)
        controller.preferenceMayHaveChanged()
        await controller.waitUntilIdle()
        #expect(controller.current == nil)
        #expect(controller.ending.isEmpty)
        defaults.set(true, forKey: AppPreferenceKeys.liveActivity)
        controller.preferenceMayHaveChanged()
        await controller.waitUntilIdle()
        #expect(client.requests.count == 2)
    }
}
