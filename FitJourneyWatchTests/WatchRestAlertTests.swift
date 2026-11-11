import Foundation
import Testing
@testable import FitJourneyWatch

/// Alerta insistente de fim de descanso (DESIGN §9.4/§9.6): laço háptico até interação ou teto.
@MainActor
struct WatchRestAlertTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Rig {
        var model: WatchSessionModel
        var transport: MockWatchTransport
        var haptics: RecordingHaptics
        var snapshot: SessionSnapshot
        var clock: TestClock
        /// Fim do descanso aberto ao concluir a 1ª série.
        var end: Date
    }

    /// Sessão com a 1ª série concluída aqui (descanso de 90 s em curso) e o relógio no fim do descanso.
    private func resting(alertRepeat: Bool? = nil) throws -> Rig {
        let digest = WatchFixtures.digest(now: t0)
        var snapshot = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        snapshot.restAlertRepeat = alertRepeat
        let transport = MockWatchTransport(digest: digest, snapshot: snapshot)
        transport.autoRespond = false
        let haptics = RecordingHaptics()
        let clock = TestClock(t0)
        let model = WatchSessionModel(transport: transport, haptics: haptics, clock: { clock.now })
        model.loadCoalesceInterval = 0
        model.restAlertInterval = 3600 // o laço real não dispara durante o teste: os passos são chamados à mão
        model.receive(digest: digest)
        model.receive(snapshot: snapshot)
        model.completeCurrentSet()
        let end = try #require(model.display?.restEndsAt)
        clock.now = end
        return Rig(model: model, transport: transport, haptics: haptics, snapshot: snapshot, clock: clock, end: end)
    }

    private func commands(_ transport: MockWatchTransport) -> [SessionCommand.Kind] {
        transport.sent.compactMap { if case .command(let c) = $0 { c.kind } else { nil } }
    }

    private func alertEvents(_ haptics: RecordingHaptics) -> [WatchHapticEvent] {
        haptics.events.filter { $0 == .restEnded || $0 == .restAlertRetry }
    }

    @Test func loopStartsWhenRestEndsAndAlternatesPulses() throws {
        let r = try resting()
        #expect(r.model.restAlert == nil)
        r.model.restDidEnd(at: r.end)
        #expect(r.model.restAlert == WatchRestAlert(endedAt: r.end, isRinging: true))
        #expect(r.model.restFinishedAt == nil)
        #expect(alertEvents(r.haptics) == [.restEnded])
        r.clock.now = r.end.addingTimeInterval(1.8)
        r.model.restAlertTick()
        r.clock.now = r.end.addingTimeInterval(3.6)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics) == [.restEnded, .restAlertRetry, .restEnded])
        // O alerta não envia comando.
        #expect(commands(r.transport).count == 1)
    }

    @Test func anyInteractionStopsTheLoopAndKeepsTheScreen() throws {
        let r = try resting()
        r.model.restDidEnd(at: r.end)
        r.model.silenceRestAlert()
        #expect(r.model.restAlert == WatchRestAlert(endedAt: r.end, isRinging: false))
        #expect(r.haptics.cancelCount == 1)
        r.clock.now = r.end.addingTimeInterval(5)
        r.model.restAlertTick()
        r.model.silenceRestAlert() // segunda interação: nada muda
        #expect(alertEvents(r.haptics) == [.restEnded])
        #expect(r.haptics.cancelCount == 1)
        #expect(commands(r.transport).count == 1) // parar não envia comando
        #expect(r.model.display?.restEndsAt == r.end)
    }

    @Test func startSetStopsClosesAndDismissesExpiredRest() throws {
        let r = try resting()
        r.model.introExerciseID = UUID()
        r.model.restDidEnd(at: r.end)
        r.clock.now = r.end.addingTimeInterval(4)
        r.model.startSetAfterRest()
        #expect(r.model.restAlert == nil)
        #expect(r.model.introExerciseID == nil)
        #expect(r.model.display?.restEndsAt == nil)
        #expect(commands(r.transport).last == .skipRest)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics) == [.restEnded])
        // Sem descanso registrado, "Começar série" não envia nada.
        let sent = commands(r.transport).count
        r.model.startSetAfterRest()
        #expect(commands(r.transport).count == sent)
    }

    @Test func loopStopsAtTheCeilingAndLeavesTheScreen() throws {
        let r = try resting()
        r.model.restDidEnd(at: r.end)
        r.clock.now = r.end.addingTimeInterval(59)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics).count == 2)
        #expect(r.model.restAlert?.isRinging == true)
        r.clock.now = r.end.addingTimeInterval(60)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics).count == 2)
        #expect(r.model.restAlert == WatchRestAlert(endedAt: r.end, isRinging: false))
        r.clock.now = r.end.addingTimeInterval(70)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics).count == 2)
    }

    @Test func lateTimerBeyondTheCeilingWarnsOnceWithoutLoop() throws {
        let r = try resting()
        r.clock.now = r.end.addingTimeInterval(90)
        r.model.restDidEnd(at: r.end)
        #expect(r.model.restAlert == WatchRestAlert(endedAt: r.end, isRinging: false))
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics) == [.restEnded])
    }

    @Test func preferenceOffKeepsTheSingleVibration() throws {
        let r = try resting(alertRepeat: false)
        #expect(!r.model.restAlertRepeats)
        r.model.restDidEnd(at: r.end)
        #expect(r.model.restAlert == nil)
        #expect(r.model.restFinishedAt == r.end)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics) == [.restEnded])
    }

    @Test func skippedRestNeverAlerts() throws {
        let r = try resting()
        r.clock.now = r.end.addingTimeInterval(-30)
        r.model.skipRest()
        r.clock.now = r.end
        r.model.restDidEnd(at: r.end)
        #expect(r.model.restAlert == nil)
        #expect(alertEvents(r.haptics).isEmpty)
    }

    @Test func adjustedRestAlertsOnceAtTheNewEnd() throws {
        let r = try resting()
        r.clock.now = r.end.addingTimeInterval(-10)
        r.model.extendRest()
        let newEnd = r.end.addingTimeInterval(15)
        #expect(r.model.display?.restEndsAt == newEnd)
        // O temporizador antigo não vale mais.
        r.clock.now = r.end
        r.model.restDidEnd(at: r.end)
        #expect(r.model.restAlert == nil)
        r.clock.now = newEnd
        r.model.restDidEnd(at: newEnd)
        r.model.restDidEnd(at: newEnd) // disparo repetido não duplica
        #expect(r.model.restAlert == WatchRestAlert(endedAt: newEnd, isRinging: true))
        #expect(alertEvents(r.haptics) == [.restEnded])
        // Silenciado, o mesmo descanso não volta a tocar.
        r.model.silenceRestAlert()
        r.model.restDidEnd(at: newEnd)
        #expect(r.model.restAlert?.isRinging == false)
        #expect(alertEvents(r.haptics) == [.restEnded])
    }

    @Test func alertEndsWhenItsRestIsNoLongerTheSessionRest() throws {
        // Ajuste depois do fim (+15 s no iPhone): o alerta some e o novo fim avisa de novo.
        var r = try resting()
        r.model.restDidEnd(at: r.end)
        r.clock.now = r.end.addingTimeInterval(3)
        r.model.extendRest()
        #expect(r.model.restAlert == nil)
        let newEnd = try #require(r.model.display?.restEndsAt)
        #expect(newEnd > r.clock.now)
        r.clock.now = newEnd
        r.model.restDidEnd(at: newEnd)
        #expect(r.model.restAlert == WatchRestAlert(endedAt: newEnd, isRinging: true))

        // "Continuar" no iPhone (descanso dispensado): o snapshot sem descanso encerra o alerta do relógio.
        r = try resting()
        r.model.restDidEnd(at: r.end)
        var fromPhone = try #require(r.model.display)
        fromPhone.restEndsAt = nil
        fromPhone.restTotalSeconds = nil
        fromPhone.revision = 9
        fromPhone.appliedCommandIDs = r.model.pending.map(\.id)
        r.model.receive(snapshot: fromPhone)
        #expect(r.model.restAlert == nil)
        r.model.restAlertTick()
        #expect(alertEvents(r.haptics) == [.restEnded])

        // Pausa encerra o alerta.
        r = try resting()
        r.model.restDidEnd(at: r.end)
        r.model.pause()
        #expect(r.model.restAlert == nil)

        // Fim da sessão também.
        r = try resting()
        r.model.restDidEnd(at: r.end)
        r.model.finish(rpe: nil)
        #expect(r.model.restAlert == nil)
    }

    @Test func nextSetTexts() throws {
        let r = try resting()
        #expect(WatchRestAlertText.title(r.model.display) == "Supino inclinado · série 2 de 4")
        #expect(WatchRestAlertText.detail(r.model.display) == "26 kg · alvo 8–12")
        #expect(WatchRestAlertText.overtime(since: r.end, at: r.end.addingTimeInterval(12.4)) == "+0:12")
        #expect(WatchRestAlertText.overtime(since: r.end, at: r.end.addingTimeInterval(-1)) == "+0:00")
        #expect(WatchRestAlertText.announcement(r.model.display)
                == "Descanso concluído. Próxima: Supino inclinado, série 2 de 4, 26 quilos, alvo 8 a 12 repetições.")
        #expect(WatchRestAlertText.title(nil) == nil)
        #expect(WatchRestAlertText.detail(nil) == nil)
    }

    @Test func pulsePatternAlternates() {
        #expect((0..<4).map(WatchRestAlertPattern.event(forPulse:)) == [.restEnded, .restAlertRetry, .restEnded, .restAlertRetry])
        #expect(WatchRestAlertPattern.ceiling == 60)
    }

    @Test func snapshotCarriesThePreferenceOnlyWhenOff() throws {
        var snapshot = WatchFixtures.snapshot(now: t0)
        let on = try WatchLinkCodec.encode(.snapshot(snapshot))
        #expect(!String(decoding: on, as: UTF8.self).contains("restAlertRepeat"))
        guard case .snapshot(let decodedOn?) = try WatchLinkCodec.decode(on) else { Issue.record("snapshot"); return }
        #expect(decodedOn.restAlertRepeat == nil)
        snapshot.restAlertRepeat = false
        guard case .snapshot(let decodedOff?) = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.snapshot(snapshot))) else {
            Issue.record("snapshot"); return
        }
        #expect(decodedOff.restAlertRepeat == false)
    }
}
