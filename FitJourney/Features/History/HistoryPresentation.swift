import Foundation

/// Regras puras do histórico e da evolução (agrupamento por mês, calendário, pontos de gráfico).
enum HistoryPresentation {
    /// Linha da lista de sessões concluídas.
    struct Row: Identifiable, Equatable {
        var id: UUID
        var startedAt: Date
        var routineName: String
        var durationSeconds: TimeInterval
        var volumeKg: Double
        var hasEstimatedVolume: Bool
        var rpe: Int?
        var isEdited: Bool
    }

    struct MonthSection: Equatable {
        var monthStart: Date
        var rows: [Row]
    }

    @MainActor
    static func row(_ session: WorkoutSession) -> Row {
        let performed = session.sortedExercises.flatMap(\.sortedSets).map(\.performed)
        let end = session.endedAt ?? session.updatedAt
        return Row(
            id: session.id,
            startedAt: session.startedAt,
            routineName: session.routineName.isEmpty ? String(localized: "Treino livre") : session.routineName,
            durationSeconds: session.clock.elapsed(at: end),
            volumeKg: WorkoutMetrics.volumeKg(performed),
            hasEstimatedVolume: WorkoutMetrics.hasEstimatedVolume(performed),
            rpe: session.sessionRPE,
            isEdited: session.sortedExercises.flatMap(\.sortedSets).contains(where: \.edited)
        )
    }

    /// Seções por mês, mais recente primeiro (linhas também mais recentes primeiro).
    static func sections(_ rows: [Row], calendar: Calendar = .current) -> [MonthSection] {
        let grouped = Dictionary(grouping: rows) { calendar.dateInterval(of: .month, for: $0.startedAt)?.start ?? $0.startedAt }
        return grouped.keys.sorted(by: >).map { key in
            MonthSection(monthStart: key, rows: grouped[key, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }

    /// Dias (início do dia) com treino.
    static func trainedDays(_ rows: [Row], calendar: Calendar = .current) -> Set<Date> {
        Set(rows.map { calendar.startOfDay(for: $0.startedAt) })
    }

    /// Semanas do mês (cada uma com 7 posições; `nil` = fora do mês), respeitando o primeiro dia da semana.
    static func calendarWeeks(month: Date, calendar: Calendar = AppCalendar.current) -> [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount { cells.append(calendar.date(byAdding: .day, value: offset, to: first)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// "52 min · 8.420 kg" (volume estimado com "~").
    static func summaryLine(_ row: Row) -> String {
        let minutes = max(1, Int((row.durationSeconds / 60).rounded()))
        var parts = [String(localized: "\(minutes) min")]
        if row.volumeKg > 0 {
            parts.append((row.hasEstimatedVolume ? "~" : "") + LoadDisplay.kgText(row.volumeKg, maxFractionDigits: 0))
        }
        return parts.joined(separator: " · ")
    }
}

/// Cálculos da evolução por exercício.
enum ProgressCalculator {
    struct SetSample: Equatable {
        var performed: PerformedSet
        var durationSeconds: Double?
        var distanceMeters: Double?
    }

    /// Uma execução do exercício numa sessão concluída.
    struct Sample: Equatable, Identifiable {
        var id: UUID
        var date: Date
        var sets: [SetSample]
    }

    enum Metric: String, CaseIterable, Identifiable {
        case load, volume, oneRM, time, distance, duration
        var id: String { rawValue }

        var title: String {
            switch self {
            case .load: String(localized: "Carga")
            case .volume: String(localized: "Volume")
            case .oneRM: String(localized: "1RM est.")
            case .time: String(localized: "Tempo")
            case .distance: String(localized: "Distância")
            case .duration: String(localized: "Duração")
            }
        }

        var unit: String {
            switch self {
            case .load, .volume, .oneRM: "kg"
            case .time: "s"
            case .distance: "km"
            case .duration: "min"
            }
        }

        /// Gráfico começa em zero só para volume (design §4.8).
        var startsAtZero: Bool { self == .volume }

        static func available(for kind: MeasurementKind) -> [Metric] {
            switch kind {
            case .repsAndLoad, .repsOnly: [.load, .volume, .oneRM]
            case .isometric: [.time]
            case .timeOrDistance: [.distance, .duration]
            }
        }
    }

    struct Point: Equatable, Identifiable {
        var id: UUID
        var date: Date
        var value: Double
        /// Superou todos os anteriores (recorde).
        var isRecord: Bool
    }

    enum Period: String, CaseIterable, Identifiable {
        case month, quarter, half, year, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: "1M"
            case .quarter: "3M"
            case .half: "6M"
            case .year: String(localized: "1A")
            case .all: String(localized: "Tudo")
            }
        }

        func startDate(now: Date, calendar: Calendar = .current) -> Date? {
            let months: Int
            switch self {
            case .month: months = 1
            case .quarter: months = 3
            case .half: months = 6
            case .year: months = 12
            case .all: return nil
            }
            return calendar.date(byAdding: .month, value: -months, to: now)
        }
    }

    static func value(of sample: Sample, metric: Metric) -> Double? {
        let performed = sample.sets.map(\.performed)
        let bests = WorkoutMetrics.bests(of: performed)
        let result: Double
        switch metric {
        case .load: result = bests.heaviestLoadKg
        case .volume: result = WorkoutMetrics.recordedVolumeKg(performed)
        case .oneRM: result = bests.bestEstimated1RMKg
        case .time:
            result = sample.sets.filter { $0.performed.counts }.compactMap(\.durationSeconds).max() ?? 0
        case .distance:
            result = sample.sets.filter { $0.performed.isCompleted }.compactMap(\.distanceMeters).reduce(0, +) / 1_000
        case .duration:
            result = sample.sets.filter { $0.performed.isCompleted }.compactMap(\.durationSeconds).reduce(0, +) / 60
        }
        return result > 0 ? result : nil
    }

    /// Pontos em ordem cronológica; amostras sem valor são omitidas. `isRecord` marca novos máximos.
    static func points(_ samples: [Sample], metric: Metric) -> [Point] {
        var best = 0.0
        var result: [Point] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            guard let value = value(of: sample, metric: metric) else { continue }
            let isRecord = value > best && !result.isEmpty
            best = max(best, value)
            result.append(Point(id: sample.id, date: sample.date, value: value, isRecord: isRecord))
        }
        return result
    }

    static func filter(_ points: [Point], period: Period, now: Date = .now, calendar: Calendar = .current) -> [Point] {
        guard let start = period.startDate(now: now, calendar: calendar) else { return points }
        return points.filter { $0.date >= start }
    }

    /// Melhor série: maior carga (empate: mais reps). `reps` só quando informadas.
    static func bestSet(_ samples: [Sample]) -> (loadKg: Double, reps: Int?)? {
        var best: (loadKg: Double, reps: Int?)?
        for set in samples.flatMap(\.sets).map(\.performed) where set.counts {
            guard let load = set.load else { continue }
            let kg = load.volumeKilograms
            guard kg > 0 else { continue }
            if let current = best {
                if kg > current.loadKg || (kg == current.loadKg && (set.reps ?? 0) > (current.reps ?? 0)) { best = (kg, set.reps) }
            } else {
                best = (kg, set.reps)
            }
        }
        return best
    }

    /// "32,5 × 10, 10, 9, 8" (reps informadas em todas), senão "32,5 kg · 4 séries".
    static func sessionLine(_ sample: Sample, kind: MeasurementKind) -> String {
        let done = sample.sets.filter { $0.performed.isCompleted }
        switch kind {
        case .isometric:
            let times = done.compactMap(\.durationSeconds).map { "\(Int($0.rounded())) s" }
            return times.isEmpty ? SessionPresentation.seriesCount(done.count) : times.joined(separator: ", ")
        case .timeOrDistance:
            let minutes = done.compactMap(\.durationSeconds).reduce(0, +) / 60
            let km = done.compactMap(\.distanceMeters).reduce(0, +) / 1_000
            var parts: [String] = []
            if minutes > 0 { parts.append("\(FJFormat.number(minutes, maxFractionDigits: 0)) min") }
            if km > 0 { parts.append("\(FJFormat.number(km, maxFractionDigits: 2)) km") }
            return parts.isEmpty ? SessionPresentation.seriesCount(done.count) : parts.joined(separator: " · ")
        case .repsAndLoad, .repsOnly:
            let valid = done.map(\.performed).filter(\.counts)
            guard let top = valid.compactMap(\.load).max(by: { $0.externalKilograms < $1.externalKilograms }) else {
                return SessionPresentation.seriesCount(valid.count)
            }
            let load = LoadDisplay.kgNumber(top.externalKilograms)
            let reps = valid.compactMap(\.reps)
            if !valid.isEmpty, reps.count == valid.count {
                return "\(load) × " + reps.map(String.init).joined(separator: ", ")
            }
            return "\(load) \(LoadDisplay.symbol()) · " + SessionPresentation.seriesCount(valid.count)
        }
    }
}


/// Edição de carga na unidade nativa da série (nunca converte para kg).
enum LoadEditing {
    /// Valor e unidade exibidos no campo.
    static func native(_ load: Load?) -> (value: Double, unit: WeightUnit) {
        switch load {
        case .weight(let value, let unit)?: (value, unit)
        case .bodyweight(let delta, let unit)?: (delta, unit)
        case nil: (0, .kg)
        }
    }

    static func unitText(_ unit: WeightUnit) -> String { unit == .kg ? "kg" : "lb" }

    static func make(value: Double, unit: WeightUnit, isBodyweight: Bool) -> Load {
        isBodyweight ? .bodyweight(delta: value, unit: unit) : .weight(value: value, unit: unit)
    }

    /// `true` se salvar mudaria algo (salvar sem alteração não marca "editado").
    static func hasChanges(old: (reps: Int?, load: Load?, duration: Double?, distance: Double?),
                           new: (reps: Int?, load: Load?, duration: Double?, distance: Double?)) -> Bool {
        old.reps != new.reps || old.load != new.load || old.duration != new.duration || old.distance != new.distance
    }
}
