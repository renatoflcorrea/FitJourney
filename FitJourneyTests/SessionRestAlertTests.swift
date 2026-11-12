import Foundation
import Testing
@testable import FitJourney

@MainActor
final class RecordingAlertVibration: FJAlertVibrating {
    private(set) var count = 0
    func vibrate() { count += 1 }
}

/// Alerta insistente de fim de descanso na sessão do iPhone (DESIGN_DIRECTION §4.5).
@MainActor
struct SessionRestAlertTests {
    struct Rig {
        let fixture: EngineFixture
        let coordinator: SessionCoordinator
        let vibration: RecordingAlertVibration
        let defaults: UserDefaults
        /// Fim do descanso aberto ao concluir a 1ª série.
        let end: Date

        var engine: SessionEngine { fixture.engine }
        var clock: TestClock { fixture.clock }
    }

    /// Sessão aberta em tela cheia, 1ª série concluída e o relógio no fim do descanso.
    private func resting(alertRepeat: Bool? = nil, hostReady: Bool = true) throws -> Rig {
        let f = try EngineFixture()
        let defaults = UserDefaults(suiteName: "rest-alert-tests-\(UUID().uuidString)")!
        if let alertRepeat { defaults.set(alertRepeat, forKey: AppPreferenceKeys.restAlertRepeat) }
        let vibration = RecordingAlertVibration()
        let clock = f.clock
        let coordinator = SessionCoordinator(engine: f.engine, defaults: defaults, vibration: vibration, now: { clock.now })
        coordinator.restAlertInterval = 3_600 // o laço real não dispara no teste: os passos são chamados à mão
        coordinator.start(routine: try f.makeRoutine())
        coordinator.restAlertHostReady = hostReady
        let setID = try #require(f.engine.snapshot?.currentSetID)
        #expect(coordinator.send(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil)))
        let end = try #require(f.engine.snapshot?.restEndsAt)
        clock.now = end
        return Rig(fixture: f, coordinator: coordinator, vibration: vibration, defaults: defaults, end: end)
    }

    @Test func alertStartsWhenRestEndsAndKeepsVibrating() throws {
        let r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.activeRestAlert == SessionRestAlert(endedAt: r.end, isRinging: true))
        #expect(r.vibration.count == 1)
        #expect(r.coordinator.restFinishedTick == 0) // a vibração única não soma
        r.clock.now = r.end.addingTimeInterval(1.5)
        r.coordinator.restAlertTick()
        r.clock.now = r.end.addingTimeInterval(3)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 3)
        // Evento repetido do mesmo descanso não reinicia nem vibra a mais.
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.vibration.count == 3)
        #expect(r.coordinator.restFinishedTick == 0)
    }

    @Test func anyTouchStopsAndClosesWithoutCommand() throws {
        let r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        let revision = r.engine.snapshot?.revision
        r.coordinator.dismissRestAlert()
        #expect(r.coordinator.restAlert == nil)
        #expect(r.engine.snapshot?.revision == revision)
        #expect(r.engine.snapshot?.restEndsAt == r.end)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 1)
        // Dispensado, o mesmo descanso não volta a alertar.
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restAlert == nil)
        #expect(r.vibration.count == 1)
        #expect(r.coordinator.restFinishedTick == 0)
    }

    @Test func startSetClosesAndDismissesTheRest() throws {
        let r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        r.clock.now = r.end.addingTimeInterval(4)
        r.coordinator.startSetAfterRest()
        #expect(r.coordinator.restAlert == nil)
        #expect(r.engine.snapshot?.restEndsAt == nil)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 1)
        // Sem alerta, não envia nada.
        let revision = r.engine.snapshot?.revision
        r.coordinator.startSetAfterRest()
        #expect(r.engine.snapshot?.revision == revision)
    }

    @Test func vibrationStopsAtTheCeilingAndTheCardStays() throws {
        let r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        r.clock.now = r.end.addingTimeInterval(59)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 2)
        r.clock.now = r.end.addingTimeInterval(SessionCoordinator.restAlertCeiling)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 2)
        #expect(r.coordinator.activeRestAlert == SessionRestAlert(endedAt: r.end, isRinging: false))
        r.clock.now = r.end.addingTimeInterval(80)
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 2)
        r.coordinator.dismissRestAlert()
        #expect(r.coordinator.restAlert == nil)
    }

    @Test func preferenceOffKeepsTheSingleVibration() throws {
        let r = try resting(alertRepeat: false)
        #expect(!RestPreference.alertRepeatEnabled(r.defaults))
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restAlert == nil)
        #expect(r.vibration.count == 0)
        #expect(r.coordinator.restFinishedTick == 1)
        // Com o painel de descanso à vista ele mesmo vibra uma vez (como antes).
        r.coordinator.restPanelVisible = true
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restFinishedTick == 1)
    }

    @Test func restPanelStaysQuietOnlyWhenTheAlertTakesOver() throws {
        // Alerta a caminho: o painel de descanso não vibra nem anuncia (um aviso só).
        var r = try resting()
        #expect(r.coordinator.restAlertTakesOver)
        r.coordinator.restPanelVisible = true
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.vibration.count == 1)
        #expect(r.coordinator.restFinishedTick == 0)
        // Preferência desligada, folha por cima ou tela minimizada: o painel avisa como antes.
        r = try resting(alertRepeat: false)
        #expect(!r.coordinator.restAlertTakesOver)
        r = try resting(hostReady: false)
        #expect(!r.coordinator.restAlertTakesOver)
        r = try resting()
        r.coordinator.minimize()
        #expect(!r.coordinator.restAlertTakesOver)
    }

    @Test func loopEndsWhenTheCoordinatorIsReleased() async throws {
        let f = try EngineFixture()
        let vibration = RecordingAlertVibration()
        let clock = f.clock
        var coordinator: SessionCoordinator? = SessionCoordinator(
            engine: f.engine, defaults: UserDefaults(suiteName: "rest-alert-release-\(UUID().uuidString)")!,
            vibration: vibration, now: { clock.now })
        coordinator?.restAlertInterval = 0.02
        coordinator?.start(routine: try f.makeRoutine())
        coordinator?.restAlertHostReady = true
        let setID = try #require(f.engine.snapshot?.currentSetID)
        coordinator?.send(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil))
        let end = try #require(f.engine.snapshot?.restEndsAt)
        clock.now = end
        coordinator?.handle(.restFinished(at: end))
        weak let released = coordinator
        coordinator = nil
        #expect(released == nil) // o laço não segura o coordenador
        let count = vibration.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(vibration.count == count)
    }

    @Test func preferenceDefaultsOn() {
        let defaults = UserDefaults(suiteName: "rest-alert-pref-\(UUID().uuidString)")!
        #expect(RestPreference.alertRepeatEnabled(defaults))
        defaults.set(false, forKey: AppPreferenceKeys.restAlertRepeat)
        #expect(!RestPreference.alertRepeatEnabled(defaults))
    }

    @Test func withoutTheSessionScreenInViewTheOldVibrationApplies() throws {
        // Folha por cima / app fora do primeiro plano.
        var r = try resting(hostReady: false)
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restAlert == nil)
        #expect(r.coordinator.restFinishedTick == 1)
        #expect(r.vibration.count == 0)

        // Sessão minimizada.
        r = try resting()
        r.coordinator.minimize()
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restAlert == nil)
        #expect(r.coordinator.restFinishedTick == 1)

        // A tela sai de vista com o alerta tocando: a vibração para, o cartão fica.
        r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        r.coordinator.restAlertHostReady = false
        #expect(r.coordinator.restAlert == SessionRestAlert(endedAt: r.end, isRinging: false))
        r.coordinator.restAlertTick()
        #expect(r.vibration.count == 1)
    }

    @Test func skippedOrAdjustedRestDoesNotAlertTwice() throws {
        // Pulado antes do fim: o evento atrasado do descanso antigo não abre alerta.
        var r = try resting()
        r.clock.now = r.end.addingTimeInterval(-20)
        #expect(r.coordinator.send(.skipRest))
        r.clock.now = r.end
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.restAlert == nil)
        #expect(r.vibration.count == 0)

        // +15 s com o alerta aberto: o alerta some; o novo fim alerta uma vez.
        r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        r.clock.now = r.end.addingTimeInterval(2)
        #expect(r.coordinator.send(.adjustRest(seconds: 15)))
        #expect(r.coordinator.activeRestAlert == nil)
        r.coordinator.reconcileRestAlert()
        #expect(r.coordinator.restAlert == nil)
        let newEnd = try #require(r.engine.snapshot?.restEndsAt)
        #expect(newEnd > r.clock.now)
        r.coordinator.handle(.restFinished(at: r.end)) // evento do fim antigo
        #expect(r.coordinator.restAlert == nil)
        r.clock.now = newEnd
        r.coordinator.handle(.restFinished(at: newEnd))
        #expect(r.coordinator.activeRestAlert == SessionRestAlert(endedAt: newEnd, isRinging: true))
        #expect(r.vibration.count == 2)
    }

    @Test func dismissingOnTheWatchEndsThePhoneAlert() throws {
        let r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        // "Começar série" no relógio chega como `skipRest`.
        let sessionID = try #require(r.engine.snapshot?.sessionID)
        let result = r.engine.apply(SessionCommand(sessionID: sessionID, issuedAt: r.clock.now, origin: .watch, kind: .skipRest))
        #expect(result.isApplied)
        #expect(r.coordinator.activeRestAlert == nil)
        r.coordinator.restAlertTick()
        #expect(r.coordinator.restAlert == nil)
        #expect(r.vibration.count == 1)
    }

    @Test func pauseAndFinishEndTheAlert() throws {
        var r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.send(.pause))
        #expect(r.coordinator.activeRestAlert == nil)

        r = try resting()
        r.coordinator.handle(.restFinished(at: r.end))
        #expect(r.coordinator.send(.finish(rpe: nil, applyLoadProposalIDs: [])))
        r.coordinator.reconcileRestAlert()
        #expect(r.coordinator.restAlert == nil)
    }

    @Test func snapshotCarriesThePreferenceToTheWatchOnlyWhenOff() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        f.engine.send(.start(routineID: routine.id))
        #expect(try f.snapshot.restAlertRepeat == nil)

        let other = try EngineFixture()
        let prefs = UserDefaults(suiteName: "rest-alert-engine-\(UUID().uuidString)")!
        prefs.set(false, forKey: AppPreferenceKeys.restAlertRepeat)
        let clock = other.clock
        let engine = SessionEngine(context: other.context, tombstoneDefaults: other.defaults, autoRestTimer: false,
                                   now: { clock.now }, preferences: prefs)
        engine.send(.start(routineID: try other.makeRoutine().id))
        #expect(engine.snapshot?.restAlertRepeat == false)
        // Religada: vale no snapshot seguinte.
        prefs.set(true, forKey: AppPreferenceKeys.restAlertRepeat)
        engine.send(.pause)
        #expect(engine.snapshot?.restAlertRepeat == nil)
    }

    @Test func cardTexts() throws {
        let r = try resting()
        let snapshot = try #require(r.engine.snapshot)
        let nextUp = try #require(SessionPresentation.restAlertNextUp(snapshot))
        #expect(nextUp.hasPrefix("Série 2 de 4"))
        #expect(nextUp.contains("alvo 8–12"))
        #expect(!nextUp.contains(snapshot.currentExercise?.name ?? "?"))
        #expect(FJRestAlertCard.overtime(since: r.end, at: r.end.addingTimeInterval(12.6)) == "+0:12")
        #expect(FJRestAlertCard.overtime(since: r.end, at: r.end.addingTimeInterval(-3)) == "+0:00")
        #expect(FJRestAlertCard.announcement(exerciseName: "Supino", nextUp: "Série 2 de 4 · 30 kg · alvo 8–12")
                == "Descanso concluído. Próxima: Supino, Série 2 de 4 · 30 kg · alvo 8–12.")
        #expect(FJRestAlertCard.announcement(exerciseName: nil, nextUp: nil) == "Descanso concluído")
    }
}
