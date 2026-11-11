import Foundation

// Vínculo/deduplicação entre sessões do FitJourney e treinos do Saúde (SPEC §6.2) e resumo do dia
// (SPEC §6.3). Treinos sobrepostos são **vinculados**, nunca somados.

/// Treino lido do Saúde (do próprio app, do Watch ou de outros apps), já sem tipos do HealthKit.
struct HealthWorkoutRecord: Sendable, Hashable, Identifiable {
    /// `HKWorkout.uuid`.
    var id: UUID
    var start: Date
    var end: Date
    /// `HKWorkoutActivityType.rawValue` (para exibir o tipo exato).
    var activityTypeRaw: UInt
    var category: HealthWorkoutCategory
    /// Tipo do FitJourney quando o `HKWorkoutActivityType` corresponde a um (senão `nil`).
    var workoutType: HealthWorkoutType?
    var sourceName: String
    var sourceBundleID: String
    /// `HKMetadataKeyExternalUUID` (o app grava o ID da sessão).
    var externalUUID: String?
    /// Gravado por este app (bundle do app ou da extensão do relógio).
    var isFromThisApp: Bool
    /// Nome da ficha nos metadados (treinos do app).
    var routineName: String?
    var activeEnergyKcal: Double?
    var averageHeartRate: Double?

    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    var duration: TimeInterval { interval.duration }

    /// ID da sessão do FitJourney gravado no treino.
    var sessionID: UUID? { externalUUID.flatMap(UUID.init(uuidString:)) }
}

/// Sessão do FitJourney vista pelo vínculo.
struct HealthSessionWindow: Sendable, Hashable, Identifiable {
    var sessionID: UUID
    var routineName: String
    var start: Date
    /// Fim; sessão em andamento usa o instante da consulta.
    var end: Date
    var category: HealthWorkoutCategory = .strength
    /// Treino já vinculado/gravado (`WorkoutSession.healthKitWorkoutID`).
    var healthKitWorkoutID: UUID?

    var id: UUID { sessionID }
    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

enum HealthLinkConfidence: String, Sendable, Hashable, Comparable {
    /// Pode vincular direto (ou mostrar já marcado).
    case high
    /// Pedir confirmação ao usuário.
    case uncertain

    static func < (lhs: HealthLinkConfidence, rhs: HealthLinkConfidence) -> Bool {
        lhs == .uncertain && rhs == .high
    }
}

/// Como um treino do Saúde se relaciona com as sessões.
enum HealthWorkoutMatch: Sendable, Hashable {
    /// Gravado pelo app para esta sessão (`ExternalUUID`) ou já vinculado (`healthKitWorkoutID`).
    case own(sessionID: UUID)
    /// Treino de outro app/relógio sobreposto: sugestão de vínculo.
    case suggestion(sessionID: UUID, confidence: HealthLinkConfidence, overlap: Double)
    case unrelated

    var sessionID: UUID? {
        switch self {
        case .own(let id), .suggestion(let id, _, _): id
        case .unrelated: nil
        }
    }
}

enum HealthWorkoutMatcher {
    /// Sobreposição mínima (sobre o mais curto) para sugerir vínculo.
    static let minimumOverlap = 0.2
    /// A partir disto, com tipo compatível e inícios próximos, a confiança é alta.
    static let highOverlap = 0.6
    /// Diferença máxima entre inícios para confiança alta.
    static let maxStartDifference: TimeInterval = 15 * 60
    /// Duração do mais curto ÷ do mais longo mínima para confiança alta.
    static let minimumDurationRatio = 0.4

    /// Mais curto ÷ mais longo (0…1).
    static func durationRatio(_ a: DateInterval, _ b: DateInterval) -> Double {
        let longer = max(a.duration, b.duration)
        return longer > 0 ? min(a.duration, b.duration) / longer : 0
    }

    /// Interseção ÷ duração do mais curto (0…1). Intervalos de duração zero não se sobrepõem.
    static func overlap(_ a: DateInterval, _ b: DateInterval) -> Double {
        let shorter = min(a.duration, b.duration)
        guard shorter > 0, let intersection = a.intersection(with: b) else { return 0 }
        return min(1, intersection.duration / shorter)
    }

    static func match(_ workout: HealthWorkoutRecord, sessions: [HealthSessionWindow]) -> HealthWorkoutMatch {
        if let own = sessions.first(where: { $0.healthKitWorkoutID == workout.id }) {
            return .own(sessionID: own.sessionID)
        }
        if let id = workout.sessionID, sessions.contains(where: { $0.sessionID == id }) {
            return .own(sessionID: id)
        }
        // Treino do app de uma sessão que não está na lista (apagada/outro dia): não sugere vínculo.
        if workout.isFromThisApp, workout.sessionID != nil { return .unrelated }

        var best: (session: HealthSessionWindow, overlap: Double, confidence: HealthLinkConfidence)?
        for session in sessions {
            // Sessão já vinculada a outro treino não recebe sugestão.
            if let linked = session.healthKitWorkoutID, linked != workout.id { continue }
            let value = overlap(workout.interval, session.interval)
            guard value >= minimumOverlap else { continue }
            let startsClose = abs(workout.start.timeIntervalSince(session.start)) <= maxStartDifference
            let ratio = durationRatio(workout.interval, session.interval)
            // Alta: muito sobreposto, inícios próximos, durações parecidas e mesma categoria (misto não basta).
            let confidence: HealthLinkConfidence =
                value >= highOverlap && startsClose && ratio >= minimumDurationRatio && workout.category == session.category
                ? .high : .uncertain
            if let current = best, (current.confidence, current.overlap) >= (confidence, value) { continue }
            best = (session, value, confidence)
        }
        guard let best else { return .unrelated }
        return .suggestion(sessionID: best.session.sessionID, confidence: best.confidence, overlap: best.overlap)
    }
}

// MARK: - Dia

/// Item da lista de treinos do dia. Cada sessão aparece uma vez, com o treino gravado pelo app e as
/// sugestões de **alta** confiança ligadas a ela. Treinos sem sessão — e sugestões **incertas**, até o
/// usuário confirmar — aparecem como `external` (contam nos minutos e na energia).
enum HealthDayEntry: Sendable, Hashable, Identifiable {
    case session(HealthSessionWindow, own: HealthWorkoutRecord?, suggestions: [LinkSuggestion])
    /// `suggestion`: sessão com que este treino talvez coincida (confiança incerta) — pedir confirmação.
    case external(HealthWorkoutRecord, suggestion: LinkSuggestion?)

    struct LinkSuggestion: Sendable, Hashable {
        var sessionID: UUID
        var workout: HealthWorkoutRecord
        var confidence: HealthLinkConfidence
        var overlap: Double
    }

    var id: UUID {
        switch self {
        case .session(let session, _, _): session.sessionID
        case .external(let workout, _): workout.id
        }
    }

    var interval: DateInterval {
        switch self {
        case .session(let session, _, _): session.interval
        case .external(let workout, _): workout.interval
        }
    }

    var category: HealthWorkoutCategory {
        switch self {
        case .session(let session, _, _): session.category
        case .external(let workout, _): workout.category
        }
    }

    /// Energia ativa medida: do treino gravado pelo app, senão da sugestão de confiança alta (Watch).
    var activeEnergyKcal: Double? {
        switch self {
        case .session(_, let own, let suggestions):
            own?.activeEnergyKcal ?? suggestions.first { $0.confidence == .high }?.workout.activeEnergyKcal
        case .external(let workout, _): workout.activeEnergyKcal
        }
    }
}

/// Resumo do dia (aba Saúde). Cada leitura do Saúde guarda seu estado (`HealthReading`): indisponível e
/// sem dados nunca viram zero.
struct HealthDaySummary: Sendable, Hashable {
    var day: DateInterval
    var entries: [HealthDayEntry]
    /// Estado da leitura de treinos do Saúde (as sessões do app entram sempre).
    var healthWorkouts: HealthReadingStatus
    /// Minutos por categoria pela **união** dos intervalos (sobreposição não soma).
    var minutesByCategory: [HealthWorkoutCategory: Double]
    /// Minutos de treino no dia (união de todos os intervalos). `.unavailable` quando o Saúde não pôde
    /// ser lido e não há sessão do app; `.noData` sem treino nenhum.
    var totalWorkoutMinutes: HealthReading<Double>
    var heartRate: HealthReading<HeartRateStats>
    /// FC média por item (`HealthDayEntry.id`), quando há dados no intervalo.
    var averageHeartRateByEntry: [UUID: Double]
    var activeEnergyKcal: HealthReading<Double>
    var restingHeartRate: HealthReading<Double>
    var steps: HealthReading<Double>
}

enum HealthDayAnalyzer {
    /// Monta a lista do dia sem duplicar (ver `HealthDayEntry`).
    static func entries(workouts: [HealthWorkoutRecord], sessions: [HealthSessionWindow]) -> [HealthDayEntry] {
        var own: [UUID: HealthWorkoutRecord] = [:]
        var suggestions: [UUID: [HealthDayEntry.LinkSuggestion]] = [:]
        var external: [HealthDayEntry] = []
        for workout in workouts {
            switch HealthWorkoutMatcher.match(workout, sessions: sessions) {
            case .own(let sessionID):
                if own[sessionID] == nil || workout.isFromThisApp { own[sessionID] = workout }
            case .suggestion(let sessionID, let confidence, let overlap):
                let suggestion = HealthDayEntry.LinkSuggestion(sessionID: sessionID, workout: workout,
                                                               confidence: confidence, overlap: overlap)
                if confidence == .high {
                    suggestions[sessionID, default: []].append(suggestion)
                } else {
                    external.append(.external(workout, suggestion: suggestion))
                }
            case .unrelated:
                external.append(.external(workout, suggestion: nil))
            }
        }
        var result: [HealthDayEntry] = sessions.map { session in
            let sorted = (suggestions[session.sessionID] ?? []).sorted { $0.overlap > $1.overlap }
            return .session(session, own: own[session.sessionID], suggestions: sorted)
        }
        result += external
        return result.sorted { $0.interval.start < $1.interval.start }
    }

    /// - Parameter heartRate: baldes de FC do dia (5 min) — não as amostras individuais.
    static func summarize(day: DateInterval, workouts: HealthReading<[HealthWorkoutRecord]>, sessions: [HealthSessionWindow],
                          heartRate: HealthReading<[HeartRateBucket]>, activeEnergyKcal: HealthReading<Double>,
                          restingHeartRate: HealthReading<Double>, steps: HealthReading<Double>) -> HealthDaySummary {
        let entries = entries(workouts: workouts.value ?? [], sessions: sessions)
        var byCategory: [HealthWorkoutCategory: [DateInterval]] = [:]
        for entry in entries { byCategory[entry.category, default: []].append(entry.interval) }
        let minutes = byCategory.mapValues { DateIntervalMath.unionDuration($0, clippedTo: day) / 60 }
            .filter { $0.value > 0 }
        let total: HealthReading<Double>
        if entries.isEmpty {
            total = workouts.status == .unavailable ? .unavailable : .noData
        } else {
            total = .available(DateIntervalMath.unionDuration(entries.map(\.interval), clippedTo: day) / 60)
        }
        let buckets = heartRate.value ?? []
        var averages: [UUID: Double] = [:]
        for entry in entries {
            if let stats = HeartRateAnalysis.stats(buckets: buckets, in: entry.interval) { averages[entry.id] = stats.average }
        }
        let dayHeartRate: HealthReading<HeartRateStats> = switch heartRate {
        case .available(let buckets): HeartRateAnalysis.stats(buckets: buckets, in: day).map { .available($0) } ?? .noData
        case .noData: .noData
        case .unavailable: .unavailable
        }
        return HealthDaySummary(day: day, entries: entries, healthWorkouts: workouts.status, minutesByCategory: minutes,
                                totalWorkoutMinutes: total, heartRate: dayHeartRate, averageHeartRateByEntry: averages,
                                activeEnergyKcal: activeEnergyKcal, restingHeartRate: restingHeartRate, steps: steps)
    }
}

enum DateIntervalMath {
    /// Duração da união dos intervalos (sobreposições contam uma vez), opcionalmente recortada.
    static func unionDuration(_ intervals: [DateInterval], clippedTo clip: DateInterval? = nil) -> TimeInterval {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            guard let clip else { return interval }
            return interval.intersection(with: clip)
        }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return total
    }
}

// MARK: - Tendência

enum HealthTrendDirection: String, Sendable, Hashable {
    case up, down, stable
}

enum HealthTrend {
    /// Compara a média dos últimos `window` dias com a dos `window` anteriores (mínimo 3 valores em cada).
    /// `nil` sem dados suficientes. Variação menor que `threshold` = estável.
    static func direction(_ values: [HealthDailyValue], window: Int = 7, threshold: Double = 1) -> HealthTrendDirection? {
        let sorted = values.sorted { $0.day < $1.day }
        let recent = sorted.suffix(window)
        let previous = sorted.dropLast(recent.count).suffix(window)
        guard recent.count >= 3, previous.count >= 3 else { return nil }
        let recentMean = recent.map(\.value).reduce(0, +) / Double(recent.count)
        let previousMean = previous.map(\.value).reduce(0, +) / Double(previous.count)
        let delta = recentMean - previousMean
        if abs(delta) < threshold { return .stable }
        return delta > 0 ? .up : .down
    }
}
