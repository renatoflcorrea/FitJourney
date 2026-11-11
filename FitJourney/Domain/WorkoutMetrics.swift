import Foundation

/// Uma série realizada, reduzida ao que as métricas precisam.
struct PerformedSet: Sendable, Hashable {
    var kind: SetKind
    var reps: Int?
    var load: Load?
    var isCompleted: Bool

    init(kind: SetKind = .working, reps: Int?, load: Load?, isCompleted: Bool = true) {
        self.kind = kind
        self.reps = reps
        self.load = load
        self.isCompleted = isCompleted
    }

    /// Conta para volume/recordes: válida (não aquecimento/preparatória) e concluída.
    var counts: Bool { isCompleted && kind.isWorking }
}

/// Melhores marcas de um exercício (todas em kg).
struct ExerciseBests: Sendable, Hashable {
    var heaviestLoadKg: Double = 0
    /// Maior volume do exercício numa única sessão.
    var bestSessionVolumeKg: Double = 0
    var bestEstimated1RMKg: Double = 0

    var isEmpty: Bool { heaviestLoadKg == 0 && bestSessionVolumeKg == 0 && bestEstimated1RMKg == 0 }
}

enum PersonalRecordKind: String, Codable, Sendable, Hashable, CaseIterable {
    case heaviestLoad, bestVolume, estimated1RM
}

struct PersonalRecord: Sendable, Hashable {
    var exerciseID: UUID
    var kind: PersonalRecordKind
    var valueKg: Double
    var previousKg: Double
}

/// Métricas de treino (SPEC §4.3). Todas as cargas em kg.
///
/// Regras de volume:
/// - Σ reps × carga apenas de séries **válidas e concluídas** (aquecimento e preparatória excluídos).
/// - Carga absoluta conta inteira. **Peso corporal conta só o lastro positivo** (o app não tem a
///   massa corporal no momento da série; assistência conta 0). Barra fixa sem lastro → volume 0.
/// - Séries sem reps ou sem carga contam 0.
enum WorkoutMetrics {
    static func volumeKg(_ sets: [PerformedSet]) -> Double {
        sets.reduce(0) { total, set in
            guard set.counts, let reps = set.reps, reps > 0, let load = set.load else { return total }
            return total + Double(reps) * load.volumeKilograms
        }
    }

    /// 1RM estimado por Epley: `carga × (1 + reps / 30)`; 1 repetição → a própria carga.
    /// `nil` para reps < 1 ou carga ≤ 0.
    static func epley1RM(loadKg: Double, reps: Int) -> Double? {
        guard reps >= 1, loadKg > 0 else { return nil }
        return reps == 1 ? loadKg : loadKg * (1 + Double(reps) / 30)
    }

    /// Melhores marcas de uma sessão para um exercício.
    static func bests(of sets: [PerformedSet]) -> ExerciseBests {
        var bests = ExerciseBests()
        for set in sets where set.counts {
            guard let reps = set.reps, reps > 0, let load = set.load else { continue }
            let kg = load.volumeKilograms
            bests.heaviestLoadKg = max(bests.heaviestLoadKg, kg)
            if let e1rm = epley1RM(loadKg: kg, reps: reps) {
                bests.bestEstimated1RMKg = max(bests.bestEstimated1RMKg, e1rm)
            }
        }
        bests.bestSessionVolumeKg = volumeKg(sets)
        return bests
    }

    /// Melhores marcas históricas: cada elemento é a lista de séries de uma sessão.
    static func bests(history sessions: [[PerformedSet]]) -> ExerciseBests {
        sessions.reduce(into: ExerciseBests()) { acc, sets in
            let b = bests(of: sets)
            acc.heaviestLoadKg = max(acc.heaviestLoadKg, b.heaviestLoadKg)
            acc.bestSessionVolumeKg = max(acc.bestSessionVolumeKg, b.bestSessionVolumeKg)
            acc.bestEstimated1RMKg = max(acc.bestEstimated1RMKg, b.bestEstimated1RMKg)
        }
    }

    /// Recordes pessoais desta sessão vs. histórico anterior.
    ///
    /// Só há recorde quando existe histórico do exercício (a primeira vez não é "recorde")
    /// e o valor supera estritamente o anterior.
    static func personalRecords(session: [UUID: [PerformedSet]],
                                history: [UUID: ExerciseBests]) -> [PersonalRecord] {
        var records: [PersonalRecord] = []
        for exerciseID in session.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let previous = history[exerciseID], !previous.isEmpty else { continue }
            let current = bests(of: session[exerciseID] ?? [])
            let pairs: [(PersonalRecordKind, Double, Double)] = [
                (.heaviestLoad, current.heaviestLoadKg, previous.heaviestLoadKg),
                (.bestVolume, current.bestSessionVolumeKg, previous.bestSessionVolumeKg),
                (.estimated1RM, current.bestEstimated1RMKg, previous.bestEstimated1RMKg),
            ]
            for (kind, value, old) in pairs where value > old + 0.001 {
                records.append(PersonalRecord(exerciseID: exerciseID, kind: kind, valueKg: value, previousKg: old))
            }
        }
        return records
    }
}
