import Foundation

/// Uma série realizada, reduzida ao que as métricas precisam.
struct PerformedSet: Sendable, Hashable {
    var kind: SetKind
    /// Reps realizadas. Opcionais (SPEC D2): `nil` = "feita dentro do alvo".
    var reps: Int?
    var load: Load?
    var isCompleted: Bool
    /// Piso do alvo prescrito (faixa → mín; fixo → n; AMRAP → `nil`), usado para estimar o
    /// volume de séries concluídas sem reps (SPEC D2).
    var targetFloorReps: Int?

    init(kind: SetKind = .working, reps: Int?, load: Load?, isCompleted: Bool = true, targetFloorReps: Int? = nil) {
        self.kind = kind
        self.reps = reps
        self.load = load
        self.isCompleted = isCompleted
        self.targetFloorReps = targetFloorReps
    }

    /// Conta para volume/recordes: válida (não aquecimento/preparatória) e concluída.
    var counts: Bool { isCompleted && kind.isWorking }

    /// Reps usadas no volume: as realizadas ou, sem elas, o piso do alvo.
    var volumeReps: Int? { reps ?? targetFloorReps }

    /// Série válida concluída com carga, mas sem reps realizadas: o volume dela é estimado
    /// (pelo piso do alvo; sem piso — AMRAP — entra como 0).
    var hasEstimatedReps: Bool { counts && reps == nil && load != nil }
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
/// - Reps opcionais (SPEC D2): série concluída sem reps entra com o **piso do alvo** e o volume
///   fica marcado como estimado (`hasEstimatedVolume`). Sem reps e sem piso (AMRAP) → 0.
/// - Séries sem carga contam 0.
///
/// Regras de recorde com reps opcionais:
/// - Maior carga: qualquer série válida concluída com carga (reps não importam — carga é o que importa).
/// - Volume da sessão e 1RM estimado: só reps **realizadas** — estimativa nunca gera recorde.
enum WorkoutMetrics {
    /// Volume com estimativa pelo piso do alvo para séries sem reps.
    static func volumeKg(_ sets: [PerformedSet]) -> Double {
        sets.reduce(0) { total, set in
            guard set.counts, let reps = set.volumeReps, reps > 0, let load = set.load else { return total }
            return total + Double(reps) * load.volumeKilograms
        }
    }

    /// Volume só com reps realizadas (base dos recordes).
    static func recordedVolumeKg(_ sets: [PerformedSet]) -> Double {
        sets.reduce(0) { total, set in
            guard set.counts, let reps = set.reps, reps > 0, let load = set.load else { return total }
            return total + Double(reps) * load.volumeKilograms
        }
    }

    /// Alguma série válida concluída teve o volume estimado (sem reps realizadas).
    static func hasEstimatedVolume(_ sets: [PerformedSet]) -> Bool {
        sets.contains(where: \.hasEstimatedReps)
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
            guard let load = set.load else { continue }
            // Reps explícitas 0 = série não feita de fato; reps ausentes = feita dentro do alvo (D2).
            if let reps = set.reps, reps <= 0 { continue }
            let kg = load.volumeKilograms
            bests.heaviestLoadKg = max(bests.heaviestLoadKg, kg)
            if let reps = set.reps, let e1rm = epley1RM(loadKg: kg, reps: reps) {
                bests.bestEstimated1RMKg = max(bests.bestEstimated1RMKg, e1rm)
            }
        }
        bests.bestSessionVolumeKg = recordedVolumeKg(sets)
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
