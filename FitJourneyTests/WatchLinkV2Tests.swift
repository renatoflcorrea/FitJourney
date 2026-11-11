import Foundation
import SwiftData
import Testing
@testable import FitJourney

// P2.6 (lacunas do motor) + W2 (protocolo v2 e transporte do iPhone).

struct WatchLinkIDsTests {
    @Test func uuid5MatchesRFCVector() throws {
        let dns = try #require(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(WatchLinkIDs.uuid5(namespace: dns, name: "python.org").uuidString == "886313E1-3B8A-5372-9B90-0C9AEE199E5D")
        #expect(WatchLinkIDs.uuid5(namespace: dns, name: "www.example.com").uuidString == "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
        // Nome maior que um bloco SHA-1 (64 bytes).
        let session = try #require(UUID(uuidString: "5E000000-0000-0000-0000-000000000001"))
        #expect(WatchLinkIDs.uuid5(namespace: session, name: String(repeating: "x", count: 100)).uuidString
                == "ACF6E5CF-6D91-51FF-91B8-8EBA8AFC6003")
    }

    /// Mesmos vetores do teste do relógio (`WatchLinkIDsWatchTests`): os dois alvos chegam aos mesmos IDs.
    @Test func sessionIDsAreDeterministicAndShared() throws {
        let session = try #require(UUID(uuidString: "5E000000-0000-0000-0000-000000000001"))
        let routineExercise = try #require(UUID(uuidString: "E0000000-0000-0000-0000-000000000100"))
        let prescription = try #require(UUID(uuidString: "E0000000-0000-0000-0000-000000000110"))
        let command = try #require(UUID(uuidString: "C0000000-0000-0000-0000-000000000001"))
        #expect(WatchLinkIDs.sessionExerciseID(sessionID: session, routineExerciseID: routineExercise).uuidString
                == "04199F87-B496-54FD-8F06-BB25EE79AF03")
        #expect(WatchLinkIDs.setLogID(sessionID: session, prescriptionID: prescription).uuidString
                == "E7F0109D-A4DC-5AFE-A8AE-3F59FB9E5022")
        #expect(WatchLinkIDs.extraSetID(sessionID: session, commandID: command).uuidString
                == "6B64A6BD-9D26-5C85-B02B-7D81847384EF")
        #expect(WatchLinkIDs.addedSetID(sessionID: session, commandID: command, index: 2).uuidString
                == "7F7D5267-A5BA-59AC-917D-8EE740358ACC")
        // Outra sessão → outros IDs.
        #expect(WatchLinkIDs.setLogID(sessionID: UUID(), prescriptionID: prescription)
                != WatchLinkIDs.setLogID(sessionID: session, prescriptionID: prescription))
    }
}

struct WatchLinkV2CodecTests {
    private let t = Date(timeIntervalSinceReferenceDate: 800_000_123.456)

    private func roundTrip(_ message: WatchLinkMessage) throws -> WatchLinkMessage {
        try WatchLinkCodec.decode(try WatchLinkCodec.encode(message))
    }

    @Test func newCommandsAndMessagesRoundTrip() throws {
        let set = UUID(), ex = UUID(), session = UUID()
        let kinds: [SessionCommand.Kind] = [
            .setExerciseNote(exerciseID: ex, text: "banco 3"), .setPain(exerciseID: ex, location: "ombro", score: 4),
            .setPain(exerciseID: ex, location: nil, score: nil), .setSessionNote(text: "bom"),
            .removeSet(setID: set), .changeSetKind(setID: set, kind: .warmup), .updateHoldTarget(setID: set, seconds: 60),
            .updateCardio(setID: set, level: 8, speedKmh: 9.5, inclinePercent: 2),
            .finish(rpe: 7, applyLoadProposalIDs: [UUID()], mood: 4, notes: "ok"),
        ]
        for kind in kinds {
            let command = SessionCommand(sessionID: session, issuedAt: t, origin: .phone, kind: kind)
            #expect(try roundTrip(.command(command)) == .command(command))
        }
        let metrics = WatchLiveMetricsPayload(sessionID: session, date: t, heartRate: 132, activeKilocalories: 88)
        #expect(try roundTrip(.liveMetrics(metrics)) == .liveMetrics(metrics))
        for state: WatchWorkoutStatus.State in [.recording, .notRecording, .saved(workoutID: UUID()), .failed] {
            let status = WatchWorkoutStatus(sessionID: session, state: state)
            #expect(try roundTrip(.workoutStatus(status)) == .workoutStatus(status))
        }
        #expect(try roundTrip(.recordingRequest(sessionID: session)) == .recordingRequest(sessionID: session))
    }

    @Test func v1IsIncompatibleButItsNoticeIsReadable() throws {
        #expect(WatchLinkProtocol.schemaVersion == 2)
        let v1 = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 1))
        #expect(throws: WatchLinkCodecError.unsupportedVersion(1)) { try WatchLinkCodec.decode(v1) }
        // Aviso no formato estável escrito por um lado v1: lido aqui.
        let v1Notice = Data(#"{"incompatible":{"currentVersion":1,"minimumVersion":1},"schemaVersion":1}"#.utf8)
        guard case .incompatible(let compatibility) = try WatchLinkCodec.decode(v1Notice) else {
            Issue.record("sem aviso"); return
        }
        #expect(compatibility.peerIsOutdated)
        // Nosso aviso continua no formato que o v1 lê (chaves `schemaVersion` + `incompatible`, sem `message`).
        let notice = try WatchLinkCodec.incompatibilityNotice()
        let object = try #require(try JSONSerialization.jsonObject(with: notice) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "incompatible"])
    }
}

// MARK: Motor (P2.6)

@MainActor
struct SessionEngineV2Tests {
    private func cardioRoutine(_ f: EngineFixture) throws -> Routine {
        let routine = try f.makeRoutine()
        try f.base.programs.addExercise(try f.base.exercise("treadmill"), to: routine, setCount: 1, repTarget: nil,
                                        cardio: CardioTarget(durationSeconds: 1_200), restSeconds: 0)
        return routine
    }

    @Test func startCreatesDeterministicIDs() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let session = try f.start(routine)
        let snapshot = try f.snapshot
        for (item, exercise) in zip(routine.sortedExercises, snapshot.exercises) {
            #expect(exercise.id == WatchLinkIDs.sessionExerciseID(sessionID: session, routineExerciseID: item.id))
            for (prescription, set) in zip(item.sortedSets, exercise.sets) {
                #expect(set.id == WatchLinkIDs.setLogID(sessionID: session, prescriptionID: prescription.id))
            }
        }
        let addSet = UUID()
        #expect(f.apply(.addSet(exerciseID: snapshot.exercises[0].id, kind: nil), at: 10, session: session, id: addSet).isApplied)
        #expect(try f.sets(0).last?.id == WatchLinkIDs.extraSetID(sessionID: session, commandID: addSet))
        let addExercise = UUID()
        #expect(f.apply(.addExercise(catalogExerciseID: try f.base.exercise("plank").id, afterExerciseID: nil), at: 20,
                        session: session, id: addExercise).isApplied)
        let added = try #require(try f.snapshot.exercises.last)
        #expect(added.id == WatchLinkIDs.addedExerciseID(sessionID: session, commandID: addExercise))
        #expect(added.sets.first?.id == WatchLinkIDs.addedSetID(sessionID: session, commandID: addExercise, index: 0))
    }

    /// Relógio → iPhone sem retenção: o relógio calcula os IDs a partir do digest e manda comandos antes de qualquer
    /// snapshot; o iPhone aplica todos nos mesmos IDs.
    @Test func watchCommandsWithDigestIDsApplyBeforeAnySnapshot() throws {
        let f = try EngineFixture()
        let routine = try f.makeRoutine()
        let digest = try #require(try ProgramDigestBuilder.make(context: f.context, now: f.t0))
        let routineDigest = try #require(digest.routines.first { $0.id == routine.id })
        let session = UUID()
        let firstExercise = routineDigest.exercises[0]
        let setID = WatchLinkIDs.setLogID(sessionID: session, prescriptionID: firstExercise.sets[1].id)
        let exerciseID = WatchLinkIDs.sessionExerciseID(sessionID: session, routineExerciseID: firstExercise.id)
        let commands: [SessionCommand] = [
            f.command(.start(routineID: routine.id), at: 0, session: session),
            f.command(.adjustLoad(setID: setID, delta: 2.5), at: 5, session: session),
            f.command(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil), at: 60, session: session),
            f.command(.setExerciseNote(exerciseID: exerciseID, text: "pegada fechada"), at: 70, session: session),
        ]
        f.clock.now = f.t0.addingTimeInterval(80)
        for command in commands { #expect(f.engine.apply(command).isApplied) }
        let snapshot = try f.snapshot
        let set = try #require(snapshot.exercises[0].sets.first { $0.id == setID })
        #expect(set.isCompleted)
        #expect(set.load?.value == 32.5)
        #expect(snapshot.exercises[0].notes == "pegada fechada")
        #expect(snapshot.appliedCommandIDs == commands.map(\.commandID))
    }

    @Test func notesPainMoodAndSessionNote() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let exercise = try f.snapshot.exercises[0].id
        #expect(f.apply(.setExerciseNote(exerciseID: exercise, text: "banco 30°"), at: 10, session: session).isApplied)
        #expect(f.apply(.setPain(exerciseID: exercise, location: "  ombro  ", score: 3), at: 20, session: session).isApplied)
        #expect(f.apply(.setPain(exerciseID: exercise, location: nil, score: 11), at: 21, session: session)
                == .rejected(.invalidValue))
        #expect(f.apply(.setSessionNote(text: "dormi mal"), at: 30, session: session).isApplied)
        var snapshot = try f.snapshot
        #expect(snapshot.exercises[0].notes == "banco 30°")
        #expect(snapshot.exercises[0].painLocation == "ombro")
        #expect(snapshot.exercises[0].painScore == 3)
        #expect(snapshot.notes == "dormi mal")
        #expect(f.apply(.setPain(exerciseID: exercise, location: nil, score: nil), at: 40, session: session).isApplied)
        snapshot = try f.snapshot
        #expect(snapshot.exercises[0].painScore == nil && snapshot.exercises[0].painLocation == nil)

        #expect(f.apply(.finish(rpe: 7, applyLoadProposalIDs: [], mood: 9), at: 50, session: session) == .rejected(.invalidValue))
        let finish = UUID()
        #expect(f.apply(.finish(rpe: 7, applyLoadProposalIDs: [], mood: 4, notes: "pesado"), at: 60, session: session, id: finish).isApplied)
        #expect(f.apply(.finish(rpe: 7, applyLoadProposalIDs: [], mood: 4, notes: "pesado"), at: 60, session: session, id: finish)
                .isApplied == false)
        let stored = try #require(try f.context.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == session })
        #expect(stored.mood == 4)
        #expect(stored.notes == "pesado")
        #expect(stored.sessionRPE == 7)
    }

    @Test func removeSetChangeKindAndHoldTarget() throws {
        let f = try EngineFixture()
        let session = try f.start(try cardioRoutine(f))
        let sets = try f.sets(0)
        #expect(f.apply(.changeSetKind(setID: sets[1].id, kind: .dropSet), at: 5, session: session).isApplied)
        #expect(try f.sets(0)[1].kind == .dropSet)
        #expect(f.apply(.changeSetKind(setID: sets[1].id, kind: .unknown), at: 6, session: session) == .rejected(.invalidValue))
        let remove = UUID()
        #expect(f.apply(.removeSet(setID: sets[3].id), at: 10, session: session, id: remove).isApplied)
        #expect(try f.sets(0).count == 3)
        let revision = try f.snapshot.revision
        #expect(f.apply(.removeSet(setID: sets[3].id), at: 10, session: session, id: remove) == .duplicate(revision: revision))
        #expect(f.apply(.removeSet(setID: sets[3].id), at: 11, session: session) == .rejected(.unknownSet))

        let plank = try f.sets(3)[0].id
        #expect(f.apply(.updateHoldTarget(setID: plank, seconds: 60), at: 20, session: session).isApplied)
        #expect(try f.sets(3)[0].targetHoldSeconds == 60)
        #expect(try f.sets(3)[0].targetText == "60 s")
        #expect(f.apply(.updateHoldTarget(setID: plank, seconds: 0), at: 21, session: session) == .rejected(.invalidValue))

        let cardio = try f.sets(4)[0]
        #expect(cardio.targetDurationSeconds == 1_200)
        #expect(f.apply(.updateHoldTarget(setID: cardio.id, seconds: 900), at: 30, session: session).isApplied)
        #expect(try f.sets(4)[0].targetDurationSeconds == 900)
        #expect(try f.sets(4)[0].targetText == "15 min")
        #expect(f.apply(.updateCardio(setID: cardio.id, level: 8, speedKmh: 10.5, inclinePercent: 3), at: 40, session: session).isApplied)
        let updated = try f.sets(4)[0]
        #expect(updated.level == 8 && updated.speedKmh == 10.5 && updated.inclinePercent == 3)
        #expect(f.apply(.updateCardio(setID: cardio.id, level: nil, speedKmh: -1, inclinePercent: nil), at: 41, session: session)
                == .rejected(.invalidValue))
    }

    @Test func holdAndCardioDoNotCountPause() throws {
        let f = try EngineFixture()
        let session = try f.start(try cardioRoutine(f))
        let cardio = try f.sets(4)[0].id
        #expect(f.apply(.startHold(setID: cardio), at: 100, session: session).isApplied)
        #expect(f.apply(.pause, at: 160, session: session).isApplied)
        #expect(try f.snapshot.holdElapsed(at: f.t0.addingTimeInterval(400)) == 60) // congelado na pausa
        #expect(f.apply(.resume, at: 220, session: session).isApplied)
        #expect(try f.snapshot.holdStartedAt == f.t0.addingTimeInterval(160)) // deslocado pela pausa
        #expect(f.apply(.endHold(setID: cardio), at: 400, session: session).isApplied)
        #expect(try f.sets(4)[0].durationSeconds == 240) // 400 − 100 − 60 de pausa

        // Isométrico encerrado durante a pausa: conta só até a pausa.
        let plank = try f.sets(3)[0].id
        #expect(f.apply(.startHold(setID: plank), at: 500, session: session).isApplied)
        #expect(f.apply(.pause, at: 530, session: session).isApplied)
        #expect(f.apply(.endHold(setID: plank), at: 600, session: session).isApplied)
        #expect(try f.sets(3)[0].durationSeconds == 30)
    }

    @Test func skipRestClearsExpiredRest() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let events = f.engine.events()
        #expect(f.apply(.completeSet(setID: try f.sets(0)[1].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 100, session: session).isApplied)
        #expect(try f.snapshot.restTotalSeconds == 90)
        // Vencido há 2 min: ainda aparece no snapshot até ser dispensado.
        let result = f.apply(.skipRest, at: 310, session: session)
        #expect(result.isApplied)
        #expect(!result.events.contains(.restSkipped))
        #expect(try f.snapshot.restEndsAt == nil)
        #expect(try f.snapshot.restTotalSeconds == nil)
        _ = events
    }

    @Test func snapshotCarriesRestTotalFocusAndGroupRound() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        #expect(f.apply(.completeSet(setID: try f.sets(0)[1].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 100, session: session).isApplied)
        #expect(f.apply(.adjustRest(seconds: 15), at: 110, session: session).isApplied)
        #expect(try f.snapshot.restTotalSeconds == 105)
        #expect(f.apply(.adjustRest(seconds: -15), at: 120, session: session).isApplied)
        #expect(try f.snapshot.restTotalSeconds == 90)

        let curl = try f.snapshot.exercises[1].id
        #expect(f.apply(.focusExercise(exerciseID: curl), at: 130, session: session).isApplied)
        var snapshot = try f.snapshot
        #expect(snapshot.focusedExerciseID == curl)
        let round = try #require(snapshot.currentGroup)
        #expect(round.round == 1 && round.totalRounds == 2)
        #expect(!round.completesRound)
        #expect(round.nextExerciseID == snapshot.exercises[2].id)
        #expect(f.apply(.completeSet(setID: try f.sets(1)[0].id, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil),
                        at: 200, session: session).isApplied)
        snapshot = try f.snapshot
        #expect(snapshot.focusedExerciseID == nil) // cede à alternância do grupo (volta à regra automática)
        #expect(snapshot.currentExerciseID == snapshot.exercises[0].id) // supino ainda aberto vem antes
        let triceps = try #require(SessionSnapshot.groupRound(exercises: snapshot.exercises, currentID: snapshot.exercises[2].id))
        #expect(triceps.completesRound) // a rosca já fez a rodada 1
        #expect(triceps.round == 1)
        #expect(snapshot.restEndsAt == nil) // meio da rodada: sem descanso
    }
}

// MARK: Transporte do iPhone (W2)

@MainActor
final class FakeWatchLinkSession: WatchLinkSession {
    var isActivated = true
    var isReachable = true
    var isCounterpartInstalled = true
    var receivedContext: [String: Data] = [:]
    var onEvent: (@MainActor (WatchLinkSessionEvent) -> Void)?
    private(set) var activations = 0
    private(set) var sent: [Data] = []
    private(set) var userInfos: [Data] = []
    private(set) var contexts: [[String: Data]] = []

    func activate() { activations += 1 }
    func sendMessage(_ data: Data, reply: (@MainActor @Sendable (Data) -> Void)?, failure: @escaping @MainActor @Sendable () -> Void) {
        guard isReachable else { failure(); return }
        sent.append(data)
    }
    func transferUserInfo(_ data: Data) { userInfos.append(data) }
    func updateContext(_ context: [String: Data]) throws { contexts.append(context) }

    var sentMessages: [WatchLinkMessage] { sent.compactMap { try? WatchLinkCodec.decode($0) } }

    /// Entrega como se viesse do relógio; devolve a resposta (se o outro lado respondeu).
    @discardableResult
    func receive(_ message: WatchLinkMessage, expectsReply: Bool = true) throws -> WatchLinkMessage? {
        try receive(raw: WatchLinkCodec.encode(message), expectsReply: expectsReply)
    }

    @discardableResult
    func receive(raw data: Data, expectsReply: Bool = true) throws -> WatchLinkMessage? {
        var response: Data?
        let reply = expectsReply ? WatchLinkReply { response = $0 } : nil
        onEvent?(.message(data, reply: reply))
        guard let response, !response.isEmpty else { return nil }
        return try WatchLinkCodec.decode(response)
    }

    func setReachable(_ reachable: Bool) {
        isReachable = reachable
        onEvent?(.reachability(reachable))
    }
}

@MainActor
final class FakeWatchHealth: WatchHealthBridge {
    var hasRemoteSession = false
    var onMirroredSessionDiscarded: ((UUID) -> Void)?
    var onRemoteSessionChange: ((Bool) -> Void)?
    var mirrored: Set<UUID> = []
    var adopted: [UUID] = []
    var unmarked: [UUID] = []
    var resumed: [UUID] = []
    var reconciled = 0
    var metrics: [HealthLiveUpdate] = []
    var remoteSent: [Data] = []
    var links: [(UUID, UUID)] = []
    var linkAllowed: (UUID) -> Bool = { _ in true }
    private var continuation: AsyncStream<Data>.Continuation?

    func remoteData() -> AsyncStream<Data> { AsyncStream { continuation = $0 } }
    func pushRemote(_ data: Data) { continuation?.yield(data) }
    func sendToRemote(_ data: Data) async throws { remoteSent.append(data) }
    func receiveRemoteMetrics(_ updates: [HealthLiveUpdate]) { metrics += updates }
    func markMirrored(_ sessionID: UUID) { mirrored.insert(sessionID) }
    func unmarkMirrored(_ sessionID: UUID) { mirrored.remove(sessionID); unmarked.append(sessionID) }
    func isMirrored(_ sessionID: UUID) -> Bool { mirrored.contains(sessionID) }
    func adoptRemoteRecording(_ sessionID: UUID) { mirrored.insert(sessionID); adopted.append(sessionID) }
    func linkWorkout(_ workoutID: UUID?, to sessionID: UUID) -> Bool {
        guard linkAllowed(sessionID), let workoutID else { return false }
        links.append((workoutID, sessionID))
        return true
    }
    func resumeIfNeeded(sessionID: UUID) async { resumed.append(sessionID) }
    func reconcilePendingWorkouts() async { reconciled += 1 }
}

@MainActor
struct PhoneWatchLinkTests {
    @MainActor
    struct Rig {
        let f: EngineFixture
        let session: FakeWatchLinkSession
        let health: FakeWatchHealth
        let link: PhoneWatchLink
        let routine: Routine

        let defaults: UserDefaults

        init(finder: WatchWorkoutFinder? = nil, defaults: UserDefaults? = nil) throws {
            session = FakeWatchLinkSession()
            health = FakeWatchHealth()
            f = try EngineFixture()
            routine = try f.makeRoutine()
            self.defaults = defaults ?? UserDefaults(suiteName: "phone-link-\(UUID().uuidString)")!
            link = PhoneWatchLink(engine: f.engine, session: session, health: health, workoutFinder: finder, defaults: self.defaults)
            link.snapshotCoalescing = .seconds(60) // os testes descarregam com `flushSnapshot()`
            link.digestDebounce = .seconds(60)
        }

        func command(_ kind: SessionCommand.Kind, at offset: TimeInterval, session id: UUID, commandID: UUID = UUID()) -> SessionCommand {
            f.clock.now = f.t0.addingTimeInterval(offset)
            return f.command(kind, at: offset, session: id, id: commandID)
        }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// Deixa o assinante de snapshots do link processar o que o motor publicou.
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func snapshots(_ messages: [WatchLinkMessage]) -> [SessionSnapshot?] {
        messages.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }
    }

    @Test func startPublishesDigestInContextAndRepliesToCommands() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        #expect(r.session.activations == 1)
        let context = try #require(r.session.contexts.last)
        guard case .programDigest(let digest) = try WatchLinkCodec.decode(try #require(context[WatchLinkSessionKey.digest])) else {
            Issue.record("sem digest"); return
        }
        #expect(digest?.routines.contains { $0.id == r.routine.id } == true)
        #expect(digest?.routines.first { $0.id == r.routine.id }?.workoutType == HealthWorkoutType.traditionalStrength.rawValue)

        let sessionID = UUID()
        let start = r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)
        guard case .commandReply(let reply) = try r.session.receive(.command(start)) else { Issue.record("sem resposta"); return }
        #expect(reply.commandID == start.commandID)
        #expect(reply.outcome == .applied)
        #expect(r.f.engine.activeSessionID == sessionID)
        // Duplicado → `duplicate` + snapshot atual na hora.
        guard case .commandReply(let again) = try r.session.receive(.command(start)) else { Issue.record("sem resposta"); return }
        #expect(again.outcome == .duplicate)
        #expect(snapshots(r.session.sentMessages).last??.sessionID == sessionID)
    }

    @Test func snapshotsAreCoalesced() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        let sessionID = UUID()
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))
        let setID = try r.f.sets(0)[1].id
        for step in 1...3 {
            try r.session.receive(.command(r.command(.adjustLoad(setID: setID, delta: 0.5), at: Double(step), session: sessionID)))
        }
        await drain()
        let before = snapshots(r.session.sentMessages).count
        r.link.flushSnapshot()
        let sent = snapshots(r.session.sentMessages)
        #expect(sent.count == before + 1)
        #expect(sent.last??.revision == 4)
        #expect(sent.last??.appliedCommandIDs.count == 4)
    }

    @Test func snapshotRequestRepliesWithSnapshotAndUnknownVersionGetsNotice() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        guard case .snapshot(let none) = try r.session.receive(.snapshotRequest) else { Issue.record("sem snapshot"); return }
        #expect(none == nil)
        let sessionID = UUID()
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))
        guard case .snapshot(let current) = try r.session.receive(.snapshotRequest) else { Issue.record("sem snapshot"); return }
        #expect(current?.sessionID == sessionID)

        let v1 = try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 1))
        guard case .incompatible(let compatibility) = try r.session.receive(raw: v1) else { Issue.record("sem aviso"); return }
        #expect(compatibility.currentVersion == WatchLinkProtocol.schemaVersion)

        try r.session.receive(.incompatible(WatchLinkCompatibility(minimumVersion: 3, currentVersion: 3)), expectsReply: false)
        #expect(r.link.watchIncompatibility?.currentVersion == 3)
    }

    @Test func offlineSnapshotGoesToApplicationContextAndOfflineCommandsApply() async throws {
        let r = try Rig()
        r.session.isReachable = false
        r.link.start()
        defer { r.link.stop() }
        let sessionID = UUID()
        // Comando que veio pela fila offline (`transferUserInfo`).
        let start = r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)
        r.session.onEvent?(.userInfo(try WatchLinkCodec.encode(.command(start))))
        #expect(r.f.engine.activeSessionID == sessionID)
        await drain()
        r.link.flushSnapshot()
        #expect(r.session.sent.isEmpty)
        let context = try #require(r.session.contexts.last)
        guard case .snapshot(let snapshot) = try WatchLinkCodec.decode(try #require(context[WatchLinkSessionKey.snapshot])) else {
            Issue.record("sem snapshot"); return
        }
        #expect(snapshot?.sessionID == sessionID)
        #expect(context[WatchLinkSessionKey.digest] != nil)
    }

    @Test func mirroredChannelIsPreferredAndAnswersRemoteCommands() async throws {
        let r = try Rig()
        r.health.hasRemoteSession = true
        r.link.start()
        defer { r.link.stop() }
        let sessionID = UUID()
        let start = r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)
        r.health.pushRemote(try WatchLinkCodec.encode(.command(start)))
        await settle { !r.health.remoteSent.isEmpty }
        let replies = r.health.remoteSent.compactMap { try? WatchLinkCodec.decode($0) }
        #expect(replies.contains(.commandReply(SessionCommandReply(commandID: start.commandID, sessionID: sessionID,
                                                                   outcome: .applied, revision: 1))))
        #expect(r.f.engine.activeSessionID == sessionID)
    }

    @Test func workoutStatusDrivesWhoRecordsAndLinksSavedWorkout() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        let sessionID = UUID()
        // O relógio avisa que grava antes do `start` chegar.
        try r.session.receive(.workoutStatus(WatchWorkoutStatus(sessionID: sessionID, state: .recording)), expectsReply: false)
        #expect(r.health.adopted == [sessionID])
        #expect(r.link.watchRecordingSessionID == sessionID)
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))

        try r.session.receive(.liveMetrics(WatchLiveMetricsPayload(sessionID: sessionID, date: r.f.t0.addingTimeInterval(30),
                                                                   heartRate: 128, activeKilocalories: 12)), expectsReply: false)
        #expect(r.health.metrics == [.heartRate(HeartRateSample(date: r.f.t0.addingTimeInterval(30), bpm: 128)),
                                     .activeEnergy(kilocalories: 12)])

        // Treino salvo no relógio antes de o `finish` chegar: vincula depois.
        var finished = false
        r.health.linkAllowed = { _ in finished }
        let workoutID = UUID()
        try r.session.receive(.workoutStatus(WatchWorkoutStatus(sessionID: sessionID, state: .saved(workoutID: workoutID))),
                              expectsReply: false)
        #expect(r.health.links.isEmpty)
        finished = true
        try r.session.receive(.command(r.command(.finish(rpe: 7, applyLoadProposalIDs: []), at: 600, session: sessionID)))
        #expect(r.health.links.map(\.0) == [workoutID])

        // Relógio não conseguiu gravar outra sessão: o iPhone volta a gravar.
        let other = UUID()
        r.health.mirrored.insert(other)
        try r.session.receive(.workoutStatus(WatchWorkoutStatus(sessionID: other, state: .notRecording)), expectsReply: false)
        await settle { r.health.resumed == [other] }
        #expect(r.health.unmarked == [other])
        #expect(r.health.resumed == [other])
    }

    @Test func discardedMirroredSessionFlushesTerminalSnapshot() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        let sessionID = UUID()
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))
        try r.session.receive(.command(r.command(.discard, at: 30, session: sessionID)))
        await settle { snapshots(r.session.sentMessages).contains { $0?.status == .discarded } }
        #expect(snapshots(r.session.sentMessages).last??.status == .discarded)
        r.health.onMirroredSessionDiscarded?(sessionID) // não quebra sem nada pendente
    }

    @Test func recordingRequestNeedsReachableWatch() async throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        #expect(!r.link.requestWatchRecording())
        let sessionID = UUID()
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))
        #expect(r.link.canRequestWatchRecording)
        #expect(r.link.requestWatchRecording())
        #expect(r.session.sentMessages.contains(.recordingRequest(sessionID: sessionID)))
    }

    @Test func digestIsRepublishedOnlyWhenContentChanges() throws {
        let r = try Rig()
        r.link.start()
        defer { r.link.stop() }
        let count = r.session.contexts.count
        r.link.refreshDigest()
        #expect(r.session.contexts.count == count) // igual (só `generatedAt` mudaria)
        r.routine.name = "A2"
        try r.f.context.save()
        r.link.refreshDigest()
        #expect(r.session.contexts.count == count + 1)
        #expect(r.session.sentMessages.contains { if case .programDigest(let d) = $0 { d?.routines.contains { $0.name == "A2" } == true } else { false } })
    }
}

@MainActor
struct PhoneWatchLinkReviewTests {
    private func drain() async { for _ in 0..<50 { await Task.yield() } }

    @Test func contextWaitsForActivationAndIsRepublishedOnActivated() async throws {
        let r = try PhoneWatchLinkTests.Rig()
        r.session.isActivated = false
        r.session.isReachable = false
        r.link.start()
        defer { r.link.stop() }
        #expect(r.session.contexts.isEmpty)
        let sessionID = UUID()
        r.session.onEvent?(.userInfo(try WatchLinkCodec.encode(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))))
        await drain()
        r.link.flushSnapshot()
        #expect(r.session.contexts.isEmpty)
        // Ativação assíncrona: o contexto sai com digest + último snapshot.
        r.session.isActivated = true
        r.session.onEvent?(.activated)
        let context = try #require(r.session.contexts.last)
        #expect(context[WatchLinkSessionKey.digest] != nil)
        #expect(WatchLinkSessionKey.decodeStamp(context[WatchLinkSessionKey.stamp]) != nil)
        guard case .snapshot(let snapshot) = try WatchLinkCodec.decode(try #require(context[WatchLinkSessionKey.snapshot])) else {
            Issue.record("sem snapshot"); return
        }
        #expect(snapshot?.sessionID == sessionID)
        // Toda nova ativação republica.
        r.session.onEvent?(.activated)
        #expect(r.session.contexts.count == 2)
    }

    @Test func oldUserInfoGetsNoNoticeAndValidMessageClearsIncompatibility() throws {
        let r = try PhoneWatchLinkTests.Rig()
        r.link.start()
        defer { r.link.stop() }
        let sentBefore = r.session.sent.count
        r.session.onEvent?(.userInfo(try WatchLinkCodec.encode(WatchLinkEnvelope(message: .snapshotRequest, schemaVersion: 1))))
        #expect(r.session.sent.count == sentBefore)
        try r.session.receive(.incompatible(WatchLinkCompatibility(minimumVersion: 3, currentVersion: 3)), expectsReply: false)
        #expect(r.link.watchIncompatibility != nil)
        try r.session.receive(.snapshotRequest)
        #expect(r.link.watchIncompatibility == nil)
    }

    @Test func mirrorChangesRefreshReachability() throws {
        let r = try PhoneWatchLinkTests.Rig()
        r.session.isReachable = false
        r.link.start()
        defer { r.link.stop() }
        #expect(!r.link.isWatchReachable)
        r.health.hasRemoteSession = true
        r.health.onRemoteSessionChange?(true)
        #expect(r.link.isWatchReachable)
        r.health.hasRemoteSession = false
        r.health.onRemoteSessionChange?(false)
        #expect(!r.link.isWatchReachable)
    }

    @Test func pendingLinksSurviveRelaunch() throws {
        let defaults = UserDefaults(suiteName: "phone-link-\(UUID().uuidString)")!
        let r = try PhoneWatchLinkTests.Rig(defaults: defaults)
        r.link.start()
        let sessionID = UUID(), workoutID = UUID()
        r.health.linkAllowed = { _ in false }
        try r.session.receive(.workoutStatus(WatchWorkoutStatus(sessionID: sessionID, state: .saved(workoutID: workoutID))), expectsReply: false)
        r.link.stop()
        #expect(r.link.pendingLinks[sessionID] == workoutID)

        let relaunched = PhoneWatchLink(engine: r.f.engine, session: FakeWatchLinkSession(), health: r.health, defaults: defaults)
        r.health.linkAllowed = { _ in true }
        relaunched.handleForeground()
        #expect(r.health.links.map(\.0) == [workoutID])
        #expect(relaunched.pendingLinks.isEmpty)
    }

    private func finishedMirroredSession(_ r: PhoneWatchLinkTests.Rig) async throws -> UUID {
        r.link.start()
        await drain() // a reconciliação do `start()` roda antes de existir sessão
        let sessionID = UUID()
        try r.session.receive(.command(r.command(.start(routineID: r.routine.id), at: 0, session: sessionID)))
        try r.session.receive(.command(r.command(.finish(rpe: 7, applyLoadProposalIDs: []), at: 600, session: sessionID)))
        r.health.mirrored.insert(sessionID)
        return sessionID
    }

    @Test func unlinkedMirroredSessionIsFoundInHealthAfterDeadline() async throws {
        let workoutID = UUID()
        let asked = AskedBox()
        let r = try PhoneWatchLinkTests.Rig(finder: { sessionID, _ in asked.ids.append(sessionID); return workoutID })
        let sessionID = try await finishedMirroredSession(r)
        defer { r.link.stop() }
        r.f.clock.now = r.f.t0.addingTimeInterval(600 + 300)
        await r.link.reconcileMirroredSessions()
        #expect(asked.ids.isEmpty) // ainda no prazo
        r.f.clock.now = r.f.t0.addingTimeInterval(600 + 601)
        await r.link.reconcileMirroredSessions()
        #expect(asked.ids == [sessionID])
        #expect(r.health.links.map(\.0) == [workoutID])
        #expect(r.health.reconciled == 0)
    }

    @Test func unlinkedMirroredSessionNotInHealthIsReleased() async throws {
        let r = try PhoneWatchLinkTests.Rig(finder: { _, _ in nil })
        let sessionID = try await finishedMirroredSession(r)
        defer { r.link.stop() }
        r.f.clock.now = r.f.t0.addingTimeInterval(600 + 601)
        await r.link.reconcileMirroredSessions()
        #expect(r.health.unmarked == [sessionID])
        #expect(r.health.reconciled == 1)
    }
}

@MainActor
final class AskedBox {
    var ids: [UUID] = []
}

@MainActor
struct SessionEngineReviewOrderTests {
    @Test func olderNotePainAndRemoveAreIgnored() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let exercise = try f.snapshot.exercises[0].id
        #expect(f.apply(.setExerciseNote(exerciseID: exercise, text: "nova"), at: 100, session: session).isApplied)
        #expect(f.apply(.setExerciseNote(exerciseID: exercise, text: "velha"), at: 50, session: session, phoneAt: 120).isApplied)
        #expect(try f.snapshot.exercises[0].notes == "nova")
        #expect(f.apply(.setPain(exerciseID: exercise, location: "joelho", score: 2), at: 100, session: session).isApplied)
        #expect(f.apply(.setPain(exerciseID: exercise, location: nil, score: nil), at: 60, session: session, phoneAt: 130).isApplied)
        #expect(try f.snapshot.exercises[0].painScore == 2)
        #expect(f.apply(.setSessionNote(text: "nova"), at: 100, session: session).isApplied)
        #expect(f.apply(.setSessionNote(text: "velha"), at: 70, session: session, phoneAt: 140).isApplied)
        #expect(try f.snapshot.notes == "nova")
        let set = try f.sets(0)[1].id
        #expect(f.apply(.updateSet(setID: set, reps: 10, load: nil, durationSeconds: nil, distanceMeters: nil), at: 150, session: session).isApplied)
        #expect(f.apply(.removeSet(setID: set), at: 80, session: session, phoneAt: 160).isApplied)
        #expect(try f.sets(0).contains { $0.id == set })
    }

    @Test func holdStartedDuringPauseCountsFromResume() throws {
        let f = try EngineFixture()
        let session = try f.start(try f.makeRoutine())
        let plank = try f.sets(3)[0].id
        #expect(f.apply(.pause, at: 100, session: session).isApplied)
        // Chegou atrasado: emitido antes da pausa (fila offline) — registra sem retomar.
        #expect(f.apply(.startHold(setID: plank), at: 90, session: session, phoneAt: 150).isApplied)
        #expect(f.apply(.resume, at: 200, session: session).isApplied)
        #expect(try f.snapshot.holdStartedAt == f.t0.addingTimeInterval(190)) // 10 s antes da pausa contam
        #expect(f.apply(.endHold(setID: plank), at: 230, session: session).isApplied)
        #expect(try f.sets(3)[0].durationSeconds == 40)
    }
}

@MainActor
struct HealthAdoptRemoteRecordingTests {
    @Test func watchRecordingDiscardsLocalLiveRecorder() async throws {
        let f = try HealthFixture()
        let id = try await f.start()
        let local = try #require(f.store.live.first)
        #expect(f.controller.state == .recording(sessionID: id, live: true))
        f.controller.adoptRemoteRecording(id)
        #expect(local.discarded)
        #expect(f.controller.isMirrored(id))
        #expect(f.controller.state == .mirrorDisconnected(sessionID: id))
        await f.apply(.finish(rpe: 6, applyLoadProposalIDs: []), at: 300, session: id)
        #expect(f.controller.state == .awaitingRemoteWorkout(sessionID: id))
        #expect(f.store.basic.isEmpty)
    }

    @Test func markedBeforeStartNeverRecordsLocally() async throws {
        let f = try HealthFixture()
        let routine = try f.engine.makeRoutine()
        let id = UUID()
        f.controller.adoptRemoteRecording(id)
        let result = await f.apply(.start(routineID: routine.id), at: 0, session: id)
        #expect(result.isApplied)
        #expect(f.store.live.isEmpty)
        #expect(f.controller.state == .mirrorDisconnected(sessionID: id))
    }
}
