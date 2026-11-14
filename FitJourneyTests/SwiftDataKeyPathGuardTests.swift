import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// Crash em loop do build 1.0.0 (2) (TestFlight, 14/11): o SwiftData do iOS 27 resolve keypaths compostos
/// (`\.session?.startedAt`, `item.session?.statusRaw`) pelo texto de `String(describing: keyPath)`. Num binário
/// sem símbolos (Release/Archive) esse texto vira `\SessionExercise.<computed 0x…>?.<computed 0x…>` e o `fetch`
/// dá `fatalError` dentro do SwiftData — impossível de capturar. Os testes rodam em Debug (com símbolos), então
/// não reproduzem a trava: este guarda proíbe o padrão no código-fonte. Reprodução fora do simulador: binário
/// macOS com os modelos do app e `strip` (ver relatório do incidente).
@MainActor @Suite struct SwiftDataKeyPathGuardTests {
    /// Raiz do repositório a partir deste arquivo (o simulador enxerga o sistema de arquivos do Mac).
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Ocorrências `arquivo:linha: trecho` de keypath através de relação em `#Predicate` ou `SortDescriptor`.
    static func multiHopKeyPaths(in source: String) -> [String] {
        var hits: [String] = []
        let ns = source as NSString
        func line(at offset: Int) -> Int { ns.substring(to: offset).reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

        // Corpo de cada `#Predicate { … }` / `#Predicate<T>({ … })` (chaves balanceadas) e o nome do parâmetro
        // (`item in`, `(item) in`, `(item: T) in`, `item -> Bool in`; senão `$0`).
        let start = try! NSRegularExpression(pattern: #"#Predicate(?:<[^>]*>)?\s*\(?\s*\{"#)
        for match in start.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var index = match.range.location + match.range.length
            var depth = 1
            let chars = Array(ns.substring(from: index).utf16)
            var consumed = 0
            while depth > 0, consumed < chars.count {
                if chars[consumed] == 123 { depth += 1 } else if chars[consumed] == 125 { depth -= 1 }
                consumed += 1
            }
            let body = ns.substring(with: NSRange(location: index, length: max(0, consumed - 1)))
            index = match.range.location
            var parameter = "$0"
            if let named = try! NSRegularExpression(pattern: #"^\s*\(?\s*(\w+)\s*(?::[^)]*)?\)?\s*(?:->\s*\w+\s*)?in\b"#)
                .firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                parameter = (body as NSString).substring(with: named.range(at: 1))
            }
            let hop = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: parameter) + #"\.\w+\s*[?!]?\s*\.\w+"#)
            for found in hop.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                hits.append("\(line(at: index)): \((body as NSString).substring(with: found.range))")
            }
        }
        // `SortDescriptor(\.a?.b)`, `SortDescriptor<T>(\.a?.b)`, `SortDescriptor(\Tipo.a.b)` e `sort: \Tipo.a?.b` (`@Query`).
        let sort = try! NSRegularExpression(pattern: #"(?:SortDescriptor(?:<[^>]*>)?\(|sort:)\s*\\(?:\w+)?\.\w+\s*[?!]?\s*\.\w+"#)
        for found in sort.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            hits.append("\(line(at: found.range.location)): \(ns.substring(with: found.range))")
        }
        return hits
    }

    @Test func detectorFindsTheCrashingPatterns() {
        let crashing = """
        var d = FetchDescriptor<SessionExercise>(predicate: #Predicate { item in
            item.exerciseID == eid && item.session?.statusRaw == completed
        }, sortBy: [SortDescriptor(\\.session?.startedAt, order: .reverse)])
        let q = #Predicate<SetLog> { $0.sessionExercise?.exerciseID == id }
        """
        #expect(Self.multiHopKeyPaths(in: crashing).count == 3)
        let variants = """
        let a = #Predicate<SessionExercise>({ item in item.session?.statusRaw == raw })
        let b = #Predicate<SessionExercise> { (item) in item.session?.startedAt != nil }
        let c = #Predicate<SessionExercise> { (item: SessionExercise) in item.session!.id == id }
        let d = #Predicate<SetLog> { log -> Bool in log.sessionExercise?.exerciseID == id }
        let e = SortDescriptor<SessionExercise>(\\.session?.startedAt)
        let f = SortDescriptor(\\SessionExercise.session?.startedAt, order: .reverse)
        @Query(sort: \\SessionExercise.session?.startedAt) var items: [SessionExercise]
        """
        #expect(Self.multiHopKeyPaths(in: variants).count == 7)
        let safe = """
        let a = #Predicate<SessionExercise> { item in item.exerciseID == eid && item.statusRaw != skipped }
        let b = #Predicate<WorkoutSession> { $0.statusRaw == raw }
        let c = SortDescriptor(\\WorkoutSession.startedAt, order: .reverse)
        let d = #Predicate<SessionExercise>({ (item: SessionExercise) in item.exerciseID == eid })
        let e = SortDescriptor<WorkoutSession>(\\.startedAt)
        let f = #Predicate<SetLog> { log -> Bool in log.isCompleted }
        """
        #expect(Self.multiHopKeyPaths(in: safe).isEmpty)
    }

    /// Nenhum predicado/ordenação do SwiftData no app, no relógio, no código compartilhado ou nas extensões atravessa relação.
    @Test func appSourcesHaveNoMultiHopKeyPaths() throws {
        var scanned = 0
        var offenders: [String] = []
        for folder in ["FitJourney", "FitJourneyWatch", "Shared", "FitJourneyWidgets", "FitJourneyWatchWidgets"] {
            let root = Self.repositoryRoot.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: root.path),
                  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                offenders += Self.multiHopKeyPaths(in: source).map { "\(folder)/\(url.lastPathComponent):\($0)" }
            }
        }
        #expect(scanned > 50, "fontes não encontradas em \(Self.repositoryRoot.path)")
        #expect(offenders.isEmpty, "keypath através de relação em predicado/ordenação do SwiftData (trava em Release): \(offenders)")
    }

    // MARK: Comportamento das consultas reescritas (filtro da relação em memória)

    @Test func lastPerformanceIgnoresInProgressSkippedAndFutureSessions() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let bench = try f.exercise("bench-press").id
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let older = try f.sessions.start(routine: routine, at: t0)
        try f.sessions.finish(older, at: t0.addingTimeInterval(600))
        let newer = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(86_400))
        try f.sessions.finish(newer, at: t0.addingTimeInterval(87_000))
        let skipped = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(2 * 86_400))
        try f.sessions.skipExercise(try #require(skipped.sortedExercises.first { $0.exerciseID == bench }))
        try f.sessions.finish(skipped, at: t0.addingTimeInterval(2 * 86_400 + 600))
        _ = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(3 * 86_400)) // em andamento

        #expect(try f.sessions.lastPerformance(exerciseID: bench)?.session?.id == newer.id)
        #expect(try f.sessions.lastPerformance(exerciseID: bench, before: t0.addingTimeInterval(86_400))?.session?.id == older.id)
        #expect(try f.sessions.lastPerformance(exerciseID: UUID()) == nil)
    }

    @Test func lastUsedLoadPicksMostRecentCompletedSetAcrossSessions() throws {
        let f = try PersistenceFixture()
        let (_, routine, _) = try f.makeProgram()
        let bench = try f.exercise("bench-press").id
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let first = try f.sessions.start(routine: routine, at: t0)
        let firstLog = try #require(first.sortedExercises.first { $0.exerciseID == bench }?.sortedSets.last)
        try f.sessions.completeSet(firstLog, reps: 8, load: .kg(40), at: t0.addingTimeInterval(60))
        try f.sessions.finish(first, at: t0.addingTimeInterval(600))

        let second = try f.sessions.start(routine: routine, at: t0.addingTimeInterval(86_400))
        let secondLog = try #require(second.sortedExercises.first { $0.exerciseID == bench }?.sortedSets.last)
        try f.sessions.completeSet(secondLog, reps: 8, load: .kg(42.5), at: t0.addingTimeInterval(86_460))

        #expect(try f.sessions.lastUsedLoad(exerciseID: bench) == .kg(42.5))
        #expect(try f.sessions.lastUsedLoad(exerciseID: UUID()) == nil)
        #expect(try f.sessions.lastUsedLoad(exerciseID: nil) == nil)
    }
}
