#if DEBUG
import Foundation

/// Dados de exemplo para previews, testes e o harness de screenshots (nunca vão para o usuário final:
/// o app só os usa com `-FJWScene` em DEBUG).
enum WatchFixtures {
    static let routineA = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let routineB = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    static let routineC = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    static let sessionID = UUID(uuidString: "5E000000-0000-0000-0000-000000000001")!

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "E0000000-0000-0000-0000-%012d", n))! }

    static func load(_ value: Double) -> WatchLoad { WatchLoad(value: value) }

    static func digest(now: Date = Date()) -> ProgramDigest {
        func prescription(_ base: Int, count: Int, target: String, reps: WatchRepTarget?, load: Double?, rest: Int?, hold: Int? = nil) -> [ProgramDigest.ExerciseSet] {
            (0..<count).map { i in
                .init(id: id(base + i), kind: .working, targetText: target, repTarget: reps, effort: .rir(2),
                      load: load.map { WatchLoad(value: $0) }, holdSeconds: hold, restSeconds: rest)
            }
        }
        let a = ProgramDigest.Routine(
            id: routineA, name: "A · Peito e tríceps", symbol: "A", lastCompletedAt: now.addingTimeInterval(-4 * 86_400),
            estimatedDurationSeconds: 55 * 60,
            exercises: [
                .init(id: id(100), exerciseID: nil, name: "Supino inclinado", measurementKind: .repsAndLoad, groupID: nil, restSeconds: 90,
                      sets: prescription(110, count: 4, target: "8–12", reps: .range(min: 8, max: 12), load: 26, rest: 90)),
                .init(id: id(200), exerciseID: nil, name: "Crucifixo", measurementKind: .repsAndLoad, groupID: nil, restSeconds: 60,
                      sets: prescription(210, count: 3, target: "12–15", reps: .range(min: 12, max: 15), load: 15, rest: 60)),
                .init(id: id(300), exerciseID: nil, name: "Tríceps corda", measurementKind: .repsAndLoad, groupID: id(999), restSeconds: 60,
                      sets: prescription(310, count: 3, target: "10–12", reps: .range(min: 10, max: 12), load: 22.5, rest: 60)),
                .init(id: id(400), exerciseID: nil, name: "Prancha", measurementKind: .isometric, groupID: id(999), restSeconds: 45,
                      sets: prescription(410, count: 3, target: "45 s", reps: nil, load: nil, rest: 45, hold: 45)),
            ])
        let b = ProgramDigest.Routine(id: routineB, name: "B · Costas e bíceps", symbol: "B", lastCompletedAt: now.addingTimeInterval(-2 * 86_400),
                                      estimatedDurationSeconds: 50 * 60, exercises: [])
        let c = ProgramDigest.Routine(id: routineC, name: "C · Pernas", symbol: "C", lastCompletedAt: nil,
                                      estimatedDurationSeconds: 60 * 60, exercises: [])
        return ProgramDigest(generatedAt: now.addingTimeInterval(-5 * 60), programID: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
                             name: "ABC · Hipertrofia", scheduleMode: "weekly", suggestedRoutineIDs: [routineA], routines: [a, b, c])
    }

    /// Sessão "iniciada" da ficha A pelo redutor, com `completed` séries concluídas em ordem.
    static func snapshot(completed: Int = 0, now: Date = Date(), startedAgo: TimeInterval = 32 * 60 + 14, revision: Int = 1) -> SessionSnapshot {
        let digest = digest(now: now)
        let start = SessionCommand(sessionID: sessionID, issuedAt: now.addingTimeInterval(-startedAgo), origin: .phone, kind: .start(routineID: routineA))
        var snapshot = SessionReducer.apply(start, to: nil, digest: digest)!
        var offset = startedAgo - 60
        for _ in 0..<completed {
            guard let setID = snapshot.currentSetID else { break }
            let command = SessionCommand(sessionID: sessionID, issuedAt: now.addingTimeInterval(-offset), origin: .phone,
                                         kind: .completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil))
            snapshot = SessionReducer.apply(command, to: snapshot, digest: digest)!
            offset -= 50
        }
        snapshot.revision = revision
        return snapshot
    }
}
#endif
