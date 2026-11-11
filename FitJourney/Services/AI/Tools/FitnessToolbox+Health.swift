import Foundation
import HealthKit

/// Se o Coach pode tentar ler o Saúde agora (aparelho e preferência "Conectar ao Saúde").
/// Permissão de leitura negada não é detectável: aparece como `no_data` nos campos.
enum HealthToolAccess: Sendable, Hashable {
    case ready
    /// Aparelho sem HealthKit.
    case deviceUnavailable
    /// "Conectar ao Saúde" desligado nos Ajustes do app.
    case disconnected

    var reason: String? {
        switch self {
        case .ready: nil
        case .deviceUnavailable: "O app Saúde não está disponível neste aparelho."
        case .disconnected: "\"Conectar ao Saúde\" está desligado nos Ajustes do FitJourney."
        }
    }

    /// Padrão: `HKHealthStore` + a preferência em `UserDefaults.standard` (a mesma que `HealthQueries` respeita).
    @MainActor static func system() -> HealthToolAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .deviceUnavailable }
        return HealthQueries.connectionEnabledInDefaults() ? .ready : .disconnected
    }

    /// Lido da `HealthAuthorization` compartilhada do app (estado atual a cada chamada).
    @MainActor static func from(_ authorization: HealthAuthorization) -> @MainActor () -> HealthToolAccess {
        { [weak authorization] in
            guard let authorization else { return system() }
            guard authorization.isAvailable else { return .deviceUnavailable }
            return authorization.isConnectionEnabled ? .ready : .disconnected
        }
    }
}

/// `get_health_summary` (SPEC §6.3/§7): agregados por dia e do período, nunca amostras individuais.
///
/// Formato (chaves ordenadas no JSON):
/// ```
/// {"from":"2026-11-05","to":"2026-11-11","days":[
///   {"date":"2026-11-10","activeKcal":420,"restingHR":58,"steps":null,"status":{"steps":"no_data"},
///    "workoutMinutes":52,"minutesByType":{"strength":52},
///    "workouts":[{"start":"18:05","min":52,"type":"strength","origin":"app+watch","avgHR":128,"name":"A"}]}],
///  "period":{"days":7,"workouts":3,"workoutMinutes":150,"minutesByType":{...},
///            "avgActiveKcal":410,"avgRestingHR":58,"avgSteps":null,"daysWithData":{...},
///            "status":{"avgSteps":"no_data"},"restingHRTrend":{"direction":"down",...}},
///  "note":"..."}
/// ```
/// Campo `null` sempre vem com o motivo em `status` (`no_data` ou `unavailable`) — nunca zero.
extension FitnessToolbox {
    static let maxHealthDays = 31
    static let defaultHealthDays = 7
    static let maxHealthWorkoutsPerDay = 10

    /// Orçamento do JSON (abaixo do teto de `CoachConversationService`, que cortaria o resultado).
    static var healthResultBudget: Int { CoachConversationService.maxToolResultCharacters - 500 }

    static let healthNote = "Contexto do app Saúde, não diagnóstico. null = sem dado (no_data: nada registrado ou leitura não permitida; unavailable: não foi possível ler) — nunca zero. Treinos vinculados aparecem uma vez (origin app+watch)."

    // MARK: Execução

    func healthSummary(from: String?, to: String?) async throws -> ToolOutcome {
        let access = healthAccess()
        if let reason = access.reason { return ok(Self.healthUnavailable(reason)) }
        guard let range = healthRange(from: from, to: to) else {
            return error("invalid_arguments", "Use from/to no formato AAAA-MM-DD (ou null) com from ≤ to e from não futuro.")
        }
        let reader = health
        let interval = DateInterval(start: range.start, end: range.end)
        let days = healthDays(range)

        async let workoutsRead = reader.workouts(in: interval)
        async let restingRead = reader.restingHeartRate(days: interval)
        async let dailyRead = Self.dailySums(days, reader: reader)
        let workouts = try await workoutsRead
        let resting = try await restingRead
        let daily = try await dailyRead
        try Task.checkCancellation()

        let allUnavailable = workouts.status == .unavailable && resting.status == .unavailable
            && daily.allSatisfy { $0.energy.status == .unavailable && $0.steps.status == .unavailable }
        if allUnavailable { return ok(Self.healthUnavailable("Não foi possível ler o app Saúde agora.")) }

        let sessions = HealthSessionWindow.windows(in: interval, context: context, now: now())
        // Entradas por dia (sem duplicar vínculos); a FC média por baldes só é lida se algum treino não a tiver.
        let entriesByDay = days.map { day in
            HealthDayAnalyzer.entries(workouts: (workouts.value ?? []).filter { $0.interval.intersects(day) },
                                      sessions: sessions.filter { $0.interval.intersects(day) })
        }
        var buckets: [HeartRateBucket] = []
        if entriesByDay.joined().contains(where: { Self.recordedHeartRate($0) == nil }) {
            buckets = try await reader.heartRateBuckets(in: interval, bucket: 300).value ?? []
        }

        var dayObjects: [[String: JSONValue]] = []
        var period = PeriodAccumulator()
        for (index, day) in days.enumerated() {
            let restingDay: HealthReading<Double> = switch resting {
            case .available(let values):
                values.last { calendar.isDate($0.day, inSameDayAs: day.start) }.map { .available($0.value) } ?? .noData
            case .noData: .noData
            case .unavailable: .unavailable
            }
            let object = dayJSON(day, entries: entriesByDay[index], workoutsStatus: workouts.status, buckets: buckets,
                                 energy: daily[index].energy, resting: restingDay, steps: daily[index].steps, period: &period)
            dayObjects.append(object)
        }
        let restingValues = resting.value ?? []
        var result: [String: JSONValue] = [
            "from": .string(Self.dayString(range.start, calendar)),
            "to": .string(Self.dayString(range.lastDay, calendar)),
            "days": .array(dayObjects.map(JSONValue.object)),
            "period": period.json(days: days.count, restingValues: restingValues, restingStatus: resting.status),
            "note": .string(Self.healthNote),
        ]
        if let adjusted = range.note { result["adjusted"] = .string(adjusted) }
        return ok(Self.fitHealthResult(result, days: dayObjects))
    }

    // MARK: Período

    struct HealthRange {
        var start: Date
        var end: Date
        var lastDay: Date
        var note: String?
    }

    /// `to` ausente = hoje; `from` ausente = 6 dias antes de `to`; futuro cortado em hoje; ≤ 31 dias terminando em `to`.
    func healthRange(from: String?, to: String?) -> HealthRange? {
        let today = calendar.startOfDay(for: now())
        var notes: [String] = []
        var last = today
        if let to {
            guard let parsed = Self.parseDay(to, calendar) else { return nil }
            last = parsed
        }
        if last > today {
            last = today
            notes.append("Fim ajustado para hoje.")
        }
        var first: Date
        if let from {
            guard let parsed = Self.parseDay(from, calendar) else { return nil }
            first = parsed
        } else {
            guard let start = calendar.date(byAdding: .day, value: -(Self.defaultHealthDays - 1), to: last) else { return nil }
            first = start
        }
        guard first <= last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        if span > Self.maxHealthDays, let clamped = calendar.date(byAdding: .day, value: -(Self.maxHealthDays - 1), to: last) {
            first = clamped
            notes.append("Período limitado a \(Self.maxHealthDays) dias.")
        }
        return HealthRange(start: first, end: end, lastDay: last, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private func healthDays(_ range: HealthRange) -> [DateInterval] {
        var result: [DateInterval] = []
        var day = range.start
        while day < range.end, result.count < Self.maxHealthDays,
              let next = calendar.date(byAdding: .day, value: 1, to: day) {
            result.append(DateInterval(start: day, end: next))
            day = next
        }
        return result
    }

    private nonisolated static func dailySums(_ days: [DateInterval], reader: any HealthDataReading)
        async throws -> [(energy: HealthReading<Double>, steps: HealthReading<Double>)] {
        try await withThrowingTaskGroup(of: (Int, HealthReading<Double>, HealthReading<Double>).self) { group in
            for (index, day) in days.enumerated() {
                group.addTask {
                    async let energy = reader.activeEnergyKcal(in: day)
                    async let steps = reader.steps(in: day)
                    return (index, try await energy, try await steps)
                }
            }
            var result = [(energy: HealthReading<Double>, steps: HealthReading<Double>)](
                repeating: (.noData, .noData), count: days.count)
            for try await (index, energy, steps) in group { result[index] = (energy, steps) }
            return result
        }
    }

    // MARK: Dia

    private func dayJSON(_ day: DateInterval, entries: [HealthDayEntry], workoutsStatus: HealthReadingStatus,
                         buckets: [HeartRateBucket], energy: HealthReading<Double>, resting: HealthReading<Double>,
                         steps: HealthReading<Double>, period: inout PeriodAccumulator) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["date": .string(Self.dayString(day.start, calendar))]
        var status: [String: JSONValue] = [:]
        Self.put(energy, "activeKcal", in: &object, status: &status)
        Self.put(resting, "restingHR", in: &object, status: &status)
        Self.put(steps, "steps", in: &object, status: &status)
        period.add(energy: energy, resting: resting, steps: steps)

        // Treinos listados no dia em que começam; minutos recortados ao dia (união, sem somar sobreposição).
        let starting = entries.filter { day.contains($0.interval.start) && $0.interval.start < day.end }
        var byType: [String: [DateInterval]] = [:]
        for entry in entries { byType[Self.typeName(entry.category), default: []].append(entry.interval) }
        let minutes = byType.mapValues { (DateIntervalMath.unionDuration($0, clippedTo: day) / 60).rounded() }.filter { $0.value > 0 }
        let total = (DateIntervalMath.unionDuration(entries.map(\.interval), clippedTo: day) / 60).rounded()
        if entries.isEmpty {
            object["workoutMinutes"] = .null
            status["workouts"] = .string(workoutsStatus == .unavailable ? "unavailable" : "no_data")
        } else {
            object["workoutMinutes"] = .number(total)
            object["minutesByType"] = .object(minutes.mapValues(JSONValue.number))
            if workoutsStatus == .unavailable { status["workouts"] = .string("unavailable") } // só sessões do app
        }
        object["workouts"] = .array(starting.prefix(Self.maxHealthWorkoutsPerDay).map { entryJSON($0, buckets: buckets) })
        if starting.count > Self.maxHealthWorkoutsPerDay {
            object["moreWorkouts"] = .number(Double(starting.count - Self.maxHealthWorkoutsPerDay))
        }
        if !status.isEmpty { object["status"] = .object(status) }
        period.addWorkouts(count: starting.count, minutes: entries.isEmpty ? nil : total, byType: minutes)
        return object
    }

    private func entryJSON(_ entry: HealthDayEntry, buckets: [HeartRateBucket]) -> JSONValue {
        var object: [String: JSONValue] = [
            "start": .string(Self.timeString(entry.interval.start, calendar)),
            "min": .number((entry.interval.duration / 60).rounded()),
            "type": .string(Self.typeName(entry.category)),
        ]
        let heartRate = Self.recordedHeartRate(entry) ?? HeartRateAnalysis.stats(buckets: buckets, in: entry.interval)?.average
        object["avgHR"] = heartRate.map { .number($0.rounded()) } ?? .null
        switch entry {
        case .session(let window, let own, let suggestions):
            let linked = [own].compactMap(\.self).filter { !$0.isFromThisApp } + suggestions.map(\.workout)
            object["origin"] = .string(linked.first.map { Self.isWatch($0) ? "app+watch" : "app+other" } ?? "app")
            if sharesWorkouts, !window.routineName.isEmpty { object["name"] = .string(String(window.routineName.prefix(60))) }
        case .external(let record, let suggestion):
            object["origin"] = .string(record.isFromThisApp ? "app" : (Self.isWatch(record) ? "watch" : "other"))
            // Sobreposição incerta com uma sessão do app: pode ser o mesmo treino (o usuário ainda não confirmou).
            if suggestion != nil { object["maybeSameAsAppSession"] = .bool(true) }
        }
        return .object(object)
    }

    /// FC média gravada no próprio treino do Saúde (do app, do Watch vinculado ou externo).
    private static func recordedHeartRate(_ entry: HealthDayEntry) -> Double? {
        switch entry {
        case .session(_, let own, let suggestions):
            own?.averageHeartRate ?? suggestions.lazy.compactMap(\.workout.averageHeartRate).first
        case .external(let record, _):
            record.averageHeartRate
        }
    }

    static func typeName(_ category: HealthWorkoutCategory) -> String {
        switch category {
        case .strength: "strength"
        case .aerobic: "aerobic"
        case .mixed, .mobility, .other: "other"
        }
    }

    static func isWatch(_ record: HealthWorkoutRecord) -> Bool {
        record.sourceBundleID.hasPrefix("com.apple.health") || record.sourceName.localizedCaseInsensitiveContains("watch")
    }

    static func statusName(_ status: HealthReadingStatus) -> String {
        switch status {
        case .available: "available"
        case .noData: "no_data"
        case .unavailable: "unavailable"
        }
    }

    /// Valor arredondado ou `null` + motivo em `status`.
    private static func put(_ reading: HealthReading<Double>, _ key: String,
                            in object: inout [String: JSONValue], status: inout [String: JSONValue]) {
        if let value = reading.value {
            object[key] = .number(value.rounded())
        } else {
            object[key] = .null
            status[key] = .string(statusName(reading.status))
        }
    }

    static func healthUnavailable(_ reason: String) -> JSONValue {
        .object(["status": .string("unavailable"), "reason": .string(reason),
                 "note": .string("Sem dados do Saúde: não trate como zero.")])
    }

    // MARK: Agregados

    struct PeriodAccumulator {
        var energy: [Double] = []
        var resting: [Double] = []
        var steps: [Double] = []
        var energyStatuses: Set<HealthReadingStatus> = []
        var stepsStatuses: Set<HealthReadingStatus> = []
        var restingStatuses: Set<HealthReadingStatus> = []
        var workouts = 0
        var workoutMinutes: Double?
        var minutesByType: [String: Double] = [:]

        mutating func add(energy: HealthReading<Double>, resting: HealthReading<Double>, steps: HealthReading<Double>) {
            if let value = energy.value { self.energy.append(value) }
            if let value = resting.value { self.resting.append(value) }
            if let value = steps.value { self.steps.append(value) }
            energyStatuses.insert(energy.status)
            restingStatuses.insert(resting.status)
            stepsStatuses.insert(steps.status)
        }

        mutating func addWorkouts(count: Int, minutes: Double?, byType: [String: Double]) {
            workouts += count
            if let minutes { workoutMinutes = (workoutMinutes ?? 0) + minutes }
            for (key, value) in byType { minutesByType[key, default: 0] += value }
        }

        func json(days: Int, restingValues: [HealthDailyValue], restingStatus: HealthReadingStatus) -> JSONValue {
            var object: [String: JSONValue] = ["days": .number(Double(days)), "workouts": .number(Double(workouts))]
            var status: [String: JSONValue] = [:]
            func average(_ values: [Double], _ statuses: Set<HealthReadingStatus>, _ key: String) {
                if values.isEmpty {
                    object[key] = .null
                    status[key] = .string(statuses == [.unavailable] ? "unavailable" : "no_data")
                } else {
                    object[key] = .number((values.reduce(0, +) / Double(values.count)).rounded())
                }
            }
            average(energy, energyStatuses, "avgActiveKcal")
            average(resting, restingStatuses, "avgRestingHR")
            average(steps, stepsStatuses, "avgSteps")
            object["daysWithData"] = .object(["activeKcal": .number(Double(energy.count)),
                                              "restingHR": .number(Double(resting.count)),
                                              "steps": .number(Double(steps.count))])
            if let workoutMinutes {
                object["workoutMinutes"] = .number(workoutMinutes)
                object["minutesByType"] = .object(minutesByType.mapValues(JSONValue.number))
            } else {
                object["workoutMinutes"] = .null
                status["workoutMinutes"] = .string("no_data")
            }
            object["restingHRTrend"] = Self.trend(restingValues, status: restingStatus)
            if !status.isEmpty { object["status"] = .object(status) }
            return .object(object)
        }

        /// Primeira × segunda metade do período (≥ 3 dias com valor em cada; variação < 1 bpm = estável).
        static func trend(_ values: [HealthDailyValue], status: HealthReadingStatus) -> JSONValue {
            guard status != .unavailable else { return .object(["direction": .null, "status": .string("unavailable")]) }
            let sorted = values.sorted { $0.day < $1.day }
            let window = sorted.count / 2
            guard window >= 3, let direction = HealthTrend.direction(sorted, window: window) else {
                return .object(["direction": .null, "status": .string("no_data"),
                                "reason": .string("Precisa de ≥ 6 dias com FC em repouso no período.")])
            }
            let recent = sorted.suffix(window).map(\.value)
            let previous = sorted.dropLast(window).suffix(window).map(\.value)
            return .object([
                "direction": .string(direction.rawValue),
                "firstHalfAvg": .number((previous.reduce(0, +) / Double(previous.count)).rounded()),
                "secondHalfAvg": .number((recent.reduce(0, +) / Double(recent.count)).rounded()),
            ])
        }
    }

    // MARK: Tamanho

    /// Cabe em `healthResultBudget`: primeiro tira a lista de treinos de cada dia (fica a contagem e os minutos),
    /// depois os dias (ficam os agregados).
    static func fitHealthResult(_ result: [String: JSONValue], days: [[String: JSONValue]]) -> JSONValue {
        var result = result
        guard JSONValue.object(result).jsonString().count > healthResultBudget else { return .object(result) }
        let compactDays = days.map { day -> JSONValue in
            var day = day
            var more = 0
            if case .number(let value)? = day["moreWorkouts"] { more = Int(value) }
            let count = (day["workouts"]?.arrayValue?.count ?? 0) + more
            day["workouts"] = .number(Double(count))
            day["moreWorkouts"] = nil
            return .object(day)
        }
        result["days"] = .array(compactDays)
        result["truncated"] = .string("Lista de treinos por dia omitida (só a contagem) para caber no limite; peça um período menor para detalhes.")
        guard JSONValue.object(result).jsonString().count > healthResultBudget else { return .object(result) }
        result["days"] = nil
        result["truncated"] = .string("Detalhe por dia omitido para caber no limite; só os agregados do período. Peça um período menor.")
        return .object(result)
    }
}
