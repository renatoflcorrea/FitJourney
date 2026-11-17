import Foundation
import Testing
@testable import FitJourneyWatch

// P2.8 no relógio: propagação otimista da carga (mesma regra do iPhone), "Definir carga" sem carga planejada e
// gravação automática quando o iPhone abre o app (`startWatchApp`).

@MainActor
struct WatchLoadMemoryTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(clearingLoads: Bool = false) -> SessionSnapshot {
        var s = WatchFixtures.snapshot(completed: 0, now: t0, startedAgo: 600, revision: 5)
        // Como no snapshot do iPhone: só a carga planejada (o `start` otimista do redutor também preenche `load`).
        for e in s.exercises.indices {
            for i in s.exercises[e].sets.indices {
                s.exercises[e].sets[i].load = nil
                if clearingLoads { s.exercises[e].sets[i].plannedLoad = nil }
            }
        }
        return s
    }

    private func command(_ kind: SessionCommand.Kind, _ s: SessionSnapshot) -> SessionCommand {
        SessionCommand(sessionID: s.sessionID, issuedAt: t0, origin: .watch, kind: kind)
    }

    @Test func adjustingLoadPropagatesToAllPendingSets() throws {
        let base = snapshot() // supino 4 × 26 kg
        let sets = base.exercises[0].sets
        var s = try #require(SessionReducer.apply(command(.adjustLoad(setID: sets[0].id, delta: 2.5), base), to: base))
        #expect(s.exercises[0].sets[0].load == WatchLoad(value: 28.5))
        #expect(s.exercises[0].sets.dropFirst().allSatisfy { $0.plannedLoad == WatchLoad(value: 28.5) && $0.load == nil })
        // Outro exercício não muda.
        #expect(s.exercises[1].sets[0].plannedLoad == WatchLoad(value: 15))

        // 17/11 "mesma carga em todas": editar a 3ª leva todas as pendentes (inclusive as anteriores e a já ajustada).
        s = try #require(SessionReducer.apply(command(.updateSet(setID: sets[2].id, reps: nil, load: WatchLoad(value: 30),
                                                                 durationSeconds: nil, distanceMeters: nil), s), to: s))
        #expect(s.exercises[0].sets[0].load == WatchLoad(value: 30))
        #expect(s.exercises[0].sets[1].plannedLoad == WatchLoad(value: 30))
        #expect(s.exercises[0].sets[3].plannedLoad == WatchLoad(value: 30))
        s = try #require(SessionReducer.apply(command(.adjustLoad(setID: sets[1].id, delta: 2.5), s), to: s))
        #expect(s.exercises[0].sets[1].load == WatchLoad(value: 32.5))
        #expect(s.exercises[0].sets[0].load == WatchLoad(value: 32.5))
        #expect(s.exercises[0].sets[2].load == WatchLoad(value: 32.5))
        #expect(s.exercises[0].sets[3].plannedLoad == WatchLoad(value: 32.5))
        // Concluída não muda.
        s = try #require(SessionReducer.apply(command(.completeSet(setID: sets[0].id, reps: nil, load: nil,
                                                                   durationSeconds: nil, distanceMeters: nil), s), to: s))
        s = try #require(SessionReducer.apply(command(.adjustLoad(setID: sets[3].id, delta: 2.5), s), to: s))
        #expect(s.exercises[0].sets[0].load == WatchLoad(value: 32.5))
        #expect(s.exercises[0].sets[1].load == WatchLoad(value: 35))
    }

    @Test func enteringRepsSetsTargetOfPendingSets() throws {
        var s = snapshot()
        let sets = s.exercises[0].sets
        s = try #require(SessionReducer.apply(command(.completeSet(setID: sets[0].id, reps: nil, load: nil,
                                                                   durationSeconds: nil, distanceMeters: nil), s), to: s))
        s = try #require(SessionReducer.apply(command(.completeSet(setID: sets[1].id, reps: nil, load: nil,
                                                                   durationSeconds: nil, distanceMeters: nil), s), to: s))
        let before = s.exercises[0].sets[0].repTarget
        s = try #require(SessionReducer.apply(command(.updateSet(setID: sets[1].id, reps: 13, load: nil,
                                                                 durationSeconds: nil, distanceMeters: nil), s), to: s))
        let now = s.exercises[0].sets
        #expect(now[1].reps == nil && now[1].repTarget == .fixed(reps: 13) && now[1].targetText == "13")
        #expect(now[2].repTarget == .fixed(reps: 13) && now[3].repTarget == .fixed(reps: 13))
        #expect(now[0].repTarget == before) // concluída antes: intocada
        // Limpar não mexe nos alvos.
        s = try #require(SessionReducer.apply(command(.updateSet(setID: sets[1].id, reps: nil, load: nil,
                                                                 durationSeconds: nil, distanceMeters: nil), s), to: s))
        #expect(s.exercises[0].sets[2].repTarget == .fixed(reps: 13))
    }

    @Test func definingFirstLoadFillsFollowingSetsWithoutLoad() throws {
        let base = snapshot(clearingLoads: true)
        let sets = base.exercises[0].sets
        #expect(isLoadUnset(sets[0]))
        let s = try #require(SessionReducer.apply(command(.completeSet(setID: sets[0].id, reps: nil, load: WatchLoad(value: 10),
                                                                       durationSeconds: nil, distanceMeters: nil), base), to: base))
        #expect(s.exercises[0].sets.dropFirst().allSatisfy { $0.plannedLoad == WatchLoad(value: 10) })
        #expect(!isLoadUnset(s.exercises[0].sets[1]))
    }

    @Test func adjustWithoutPlannedLoadStartsFromLastKnownInSession() throws {
        var base = snapshot()
        // 1ª série concluída com 26 kg; a 2ª ficou com "0 kg" planejado (vazia).
        base.exercises[0].sets[0].isCompleted = true
        base.exercises[0].sets[0].completedAt = t0
        base.exercises[0].sets[0].load = WatchLoad(value: 26)
        base.exercises[0].sets[1].plannedLoad = WatchLoad(value: 0)
        let setID = base.exercises[0].sets[1].id
        #expect(SessionReducer.loadBase(setID: setID, in: base) == WatchLoad(value: 26))
        let s = try #require(SessionReducer.apply(command(.adjustLoad(setID: setID, delta: 2.5), base), to: base))
        #expect(s.exercises[0].sets[1].load == WatchLoad(value: 28.5))

        // Nada conhecido: base 0 (o relógio não tem o histórico antigo; o snapshot do iPhone confirma).
        let empty = snapshot(clearingLoads: true)
        #expect(SessionReducer.loadBase(setID: empty.exercises[0].sets[0].id, in: empty) == WatchLoad(value: 0))
    }

    @Test func extraSetCarriesOnlySameKindLoad() throws {
        let base = snapshot()
        let exercise = base.exercises[0]
        var s = try #require(SessionReducer.apply(command(.addSet(exerciseID: exercise.id, kind: nil), base), to: base))
        #expect(s.exercises[0].sets.last?.plannedLoad == WatchLoad(value: 26))
        #expect(s.exercises[0].sets.last?.load == nil)
        s = try #require(SessionReducer.apply(command(.addSet(exerciseID: exercise.id, kind: .warmup), s), to: s))
        #expect(s.exercises[0].sets.last?.plannedLoad == nil) // válida não alimenta aquecimento
    }

    @Test func recordingRequestBeforeSnapshotRecordsThatSession() {
        let clock = TestClock(t0)
        let health = FixedHealthProvider(access: .authorized)
        let (model, _) = model(health, clock: clock)
        let snap = snapshot()
        model.handlePhoneWorkoutLaunch()
        model.handle(.recordingRequest(sessionID: snap.sessionID))
        var other = snap
        other.sessionID = UUID()
        model.receive(snapshot: other) // outra sessão: não grava
        #expect(health.began == 0)
        model.receive(snapshot: snap)
        #expect(health.began == 1)
        #expect(model.recordingSessionID == snap.sessionID)
    }

    @Test func unsetLoadDetection() {
        var set = snapshot().exercises[0].sets[0]
        #expect(!isLoadUnset(set))
        set.plannedLoad = WatchLoad(value: 0)
        #expect(isLoadUnset(set))
        set.plannedLoad = WatchLoad(value: 0, isBodyweight: true)
        #expect(!isLoadUnset(set)) // peso corporal é carga
        set.plannedLoad = nil
        set.load = WatchLoad(value: 0)
        #expect(!isLoadUnset(set)) // registrada pelo usuário
    }

    // MARK: Aberto pelo iPhone (startWatchApp)

    private func model(_ health: FixedHealthProvider, clock: TestClock) -> (WatchSessionModel, MockWatchTransport) {
        let transport = MockWatchTransport(digest: WatchFixtures.digest(now: t0), snapshot: nil)
        transport.autoRespond = false
        let model = WatchSessionModel(transport: transport, haptics: RecordingHaptics(), health: health, clock: { clock.now })
        return (model, transport)
    }

    @Test func phoneLaunchRecordsTheSessionFromTheNextSnapshot() {
        let clock = TestClock(t0)
        let health = FixedHealthProvider(access: .authorized)
        let (model, transport) = model(health, clock: clock)
        let snap = snapshot()
        model.handlePhoneWorkoutLaunch()
        #expect(transport.sent.contains { if case .snapshotRequest = $0 { true } else { false } })
        #expect(health.began == 0)
        model.receive(snapshot: snap)
        #expect(health.began == 1)
        #expect(health.lastContext?.sessionID == snap.sessionID)
        #expect(model.recordingSessionID == snap.sessionID)
    }

    @Test func phoneLaunchWindowExpires() {
        let clock = TestClock(t0)
        let health = FixedHealthProvider(access: .authorized)
        let (model, _) = model(health, clock: clock)
        model.handlePhoneWorkoutLaunch()
        clock.now = t0.addingTimeInterval(model.phoneLaunchWindow + 1)
        model.receive(snapshot: snapshot())
        #expect(health.began == 0)
        #expect(model.canOfferWatchRecording) // continua oferecendo "gravar no relógio"
    }

    @Test func phoneLaunchWithoutHealthAccessDoesNotRecord() {
        let clock = TestClock(t0)
        let health = FixedHealthProvider(access: .denied)
        let (model, _) = model(health, clock: clock)
        model.handlePhoneWorkoutLaunch()
        model.receive(snapshot: snapshot())
        #expect(health.began == 0)
    }
}
