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
        case .disconnected: "\"Conectar ao Saúde\" está desligado nos Ajustes do FitRoute."
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
/// {"from":"2026-11-05","to":"2026-11-11","note":"…","appSessionsOmitted"?:true,"adjusted"?:"…",
///  "days":[
///   {"date":"2026-11-10","activeKcal":420,"restingHR":58,"steps":null,"status":{"steps":"no_data"},
///    "workoutMinutes":52,"minutesByType":{"strength":52},
///    "workouts":[{"start":"18:05","min":52,"type":"strength","origin":"app+watch","avgHR":128,"name":"A"}]},
///   {"date":"2026-11-11","partial":true,"workouts":null,"workoutMinutes":null,"status":{"workouts":"no_data",…},…}],
///  "period":{"days":7,"workouts":3,"workoutMinutes":150,"minutesByType":{…},
///            "avgActiveKcal":410,"avgRestingHR":58,"avgSteps":null,"daysWithData":{…},
///            "status":{"avgSteps":"no_data"},"restingHRTrend":{"direction":"down",…}}}
/// ```
/// Regras:
/// - Campo `null` sempre vem com o motivo em `status` (`no_data` ou `unavailable`) — nunca zero. Isso vale
///   também para `workouts`/`workoutMinutes` do dia e do período quando não há treino nenhum.
/// - O dia corrente é `partial` e fica fora das médias e da tendência do período.
/// - Sem `Sharing.workouts`, as sessões do app são ignoradas (e os treinos do Saúde vinculados a elas ou
///   gravados pelo app também saem): só treinos de outras fontes.
/// - Pares "talvez o mesmo treino" (`maybeSameAsAppSession`) contam uma vez em `period.workouts`.
extension FitnessToolbox {
    static let maxHealthDays = 31
    static let defaultHealthDays = 7
    static let maxHealthWorkoutsPerDay = 10
    /// Dias lidos ao mesmo tempo (2 consultas cada: energia e passos) — com treinos e repouso, ≤ 6 consultas.
    nonisolated static let maxConcurrentHealthDays = 2

    /// Orçamento do JSON (abaixo do teto de `CoachConversationService`, que cortaria o resultado).
    static var healthResultBudget: Int { CoachConversationService.maxToolResultCharacters - 500 }

    static let healthNote = "Contexto do app Saúde, não diagnóstico. null = sem dado (no_data: nada registrado ou leitura não permitida; unavailable: não foi possível ler) — nunca zero. Treinos vinculados aparecem uma vez (origin app+watch); pares maybeSameAsAppSession contam 1 em period.workouts. O dia de hoje é parcial (partial) e fica fora das médias e da tendência. avgHRApprox = FC média estimada pela FC do período do treino."
    static let healthNoteWithoutAppSessions = "O usuário não compartilha treinos: sessões do FitRoute (e treinos do Saúde ligados a elas) foram omitidas; só treinos de outras fontes."

    // MARK: Execução

    func healthSummary(from: String?, to: String?) async throws -> ToolOutcome {
        let access = healthAccess()
        if let reason = access.reason { return ok(Self.healthUnavailable(reason)) }
        let calendar = self.calendar
        let now = self.now()
        guard let range = Self.healthRange(from: from, to: to, now: now, calendar: calendar) else {
            return error("invalid_arguments", "Use from/to no formato AAAA-MM-DD (ou null) com from ≤ to e from não futuro.")
        }
        let reader = health
        let interval = DateInterval(start: range.start, end: range.end)
        let days = Self.healthDays(range, calendar: calendar)
        let today = calendar.startOfDay(for: now)

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

        // As sessões entram no vínculo mesmo sem compartilhar treinos: é assim que se sabe o que omitir.
        let includeApp = sharesWorkouts
        let sessions = HealthSessionWindow.windows(in: interval, context: context, now: now)
        let itemsByDay = days.map { day in
            let entries = HealthDayAnalyzer.entries(workouts: (workouts.value ?? []).filter { $0.interval.intersects(day) },
                                                    sessions: sessions.filter { $0.interval.intersects(day) })
            return entries.compactMap { HealthWorkoutItem($0, includeApp: includeApp) }
        }
        // FC média pela FC do período só para treinos sem a média gravada.
        var buckets: HealthReading<[HeartRateBucket]> = .noData
        if itemsByDay.joined().contains(where: { $0.recordedHeartRate == nil }) {
            buckets = try await reader.heartRateBuckets(in: interval, bucket: 300)
            try Task.checkCancellation()
        }

        var dayObjects: [[String: JSONValue]] = []
        var period = PeriodAccumulator(workoutsStatus: workouts.status)
        for (index, day) in days.enumerated() {
            let restingDay: HealthReading<Double> = switch resting {
            case .available(let values):
                values.last { calendar.isDate($0.day, inSameDayAs: day.start) }.map { .available($0.value) } ?? .noData
            case .noData: .noData
            case .unavailable: .unavailable
            }
            let isPartial = day.start == today
            dayObjects.append(dayJSON(day, partial: isPartial, items: itemsByDay[index], workoutsStatus: workouts.status,
                                      buckets: buckets, energy: daily[index].energy, resting: restingDay,
                                      steps: daily[index].steps, calendar: calendar, period: &period))
        }
        let completeResting = (resting.value ?? []).filter { !calendar.isDate($0.day, inSameDayAs: today) }
        var result: [String: JSONValue] = [
            "from": .string(Self.dayString(range.start, calendar)),
            "to": .string(Self.dayString(range.lastDay, calendar)),
            "days": .array(dayObjects.map(JSONValue.object)),
            "period": period.json(days: days.count, restingValues: completeResting, restingStatus: resting.status),
            "note": .string(includeApp ? Self.healthNote : Self.healthNote + " " + Self.healthNoteWithoutAppSessions),
        ]
        if !includeApp { result["appSessionsOmitted"] = .bool(true) }
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
    static func healthRange(from: String?, to: String?, now: Date, calendar: Calendar) -> HealthRange? {
        let today = calendar.startOfDay(for: now)
        var notes: [String] = []
        var last = today
        if let to {
            guard let parsed = parseDay(to, calendar) else { return nil }
            last = parsed
        }
        if last > today {
            last = today
            notes.append("Fim ajustado para hoje.")
        }
        var first: Date
        if let from {
            guard let parsed = parseDay(from, calendar) else { return nil }
            first = parsed
        } else {
            guard let start = calendar.date(byAdding: .day, value: -(defaultHealthDays - 1), to: last) else { return nil }
            first = start
        }
        guard first <= last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        if span > maxHealthDays, let clamped = calendar.date(byAdding: .day, value: -(maxHealthDays - 1), to: last) {
            first = clamped
            notes.append("Período limitado a \(maxHealthDays) dias.")
        }
        return HealthRange(start: first, end: end, lastDay: last, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func healthDays(_ range: HealthRange, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var day = range.start
        while day < range.end, result.count < maxHealthDays,
              let next = calendar.date(byAdding: .day, value: 1, to: day) {
            result.append(DateInterval(start: day, end: next))
            day = next
        }
        return result
    }

    /// Energia e passos por dia, com no máximo `maxConcurrentHealthDays` dias em voo.
    private nonisolated static func dailySums(_ days: [DateInterval], reader: any HealthDataReading)
        async throws -> [(energy: HealthReading<Double>, steps: HealthReading<Double>)] {
        try await withThrowingTaskGroup(of: (Int, HealthReading<Double>, HealthReading<Double>).self) { group in
            var result = [(energy: HealthReading<Double>, steps: HealthReading<Double>)](
                repeating: (.noData, .noData), count: days.count)
            var next = 0
            func addNext() {
                guard next < days.count else { return }
                let index = next, day = days[index]
                next += 1
                group.addTask {
                    async let energy = reader.activeEnergyKcal(in: day)
                    async let steps = reader.steps(in: day)
                    return (index, try await energy, try await steps)
                }
            }
            for _ in 0 ..< maxConcurrentHealthDays { addNext() }
            while let (index, energy, steps) = try await group.next() {
                result[index] = (energy, steps)
                addNext()
            }
            return result
        }
    }

    // MARK: Treinos

    /// Treino do resumo já resolvido (vínculo aplicado, filtro de compartilhamento aplicado).
    struct HealthWorkoutItem {
        var interval: DateInterval
        var category: HealthWorkoutCategory
        var origin: String
        var recordedHeartRate: Double?
        var name: String?
        /// Treino externo que talvez seja uma sessão do app (confiança incerta, ainda não confirmado).
        var maybeSameAsAppSession: Bool

        /// `nil` quando o item deve sair do resumo (sessão do app ou treino ligado ao app sem `Sharing.workouts`).
        init?(_ entry: HealthDayEntry, includeApp: Bool) {
            interval = entry.interval
            category = entry.category
            switch entry {
            case .session(let window, let own, let suggestions):
                guard includeApp else { return nil }
                let linked = [own].compactMap(\.self).filter { !$0.isFromThisApp } + suggestions.map(\.workout)
                origin = linked.first.map { FitnessToolbox.isWatch($0) ? "app+watch" : "app+other" } ?? "app"
                recordedHeartRate = own?.averageHeartRate ?? suggestions.lazy.compactMap(\.workout.averageHeartRate).first
                name = window.routineName.isEmpty ? nil : String(window.routineName.prefix(60))
                maybeSameAsAppSession = false
            case .external(let record, let suggestion):
                if record.isFromThisApp {
                    guard includeApp else { return nil }
                    origin = "app"
                } else {
                    origin = FitnessToolbox.isWatch(record) ? "watch" : "other"
                }
                recordedHeartRate = record.averageHeartRate
                name = nil
                maybeSameAsAppSession = includeApp && suggestion != nil
            }
        }
    }

    // MARK: Dia

    private func dayJSON(_ day: DateInterval, partial: Bool, items: [HealthWorkoutItem], workoutsStatus: HealthReadingStatus,
                         buckets: HealthReading<[HeartRateBucket]>, energy: HealthReading<Double>,
                         resting: HealthReading<Double>, steps: HealthReading<Double>, calendar: Calendar,
                         period: inout PeriodAccumulator) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["date": .string(Self.dayString(day.start, calendar))]
        var status: [String: JSONValue] = [:]
        if partial { object["partial"] = .bool(true) }
        Self.put(energy, "activeKcal", in: &object, status: &status)
        Self.put(resting, "restingHR", in: &object, status: &status)
        Self.put(steps, "steps", in: &object, status: &status)
        if !partial { period.add(energy: energy, resting: resting, steps: steps) }

        // Treinos listados no dia em que começam; minutos recortados ao dia (união, sem somar sobreposição).
        let starting = items.filter { day.contains($0.interval.start) && $0.interval.start < day.end }
        if items.isEmpty {
            object["workouts"] = .null
            object["workoutMinutes"] = .null
            status["workouts"] = .string(Self.emptyWorkoutsStatus(workoutsStatus))
        } else {
            var byType: [String: [DateInterval]] = [:]
            for item in items { byType[Self.typeName(item.category), default: []].append(item.interval) }
            let minutes = byType.mapValues { (DateIntervalMath.unionDuration($0, clippedTo: day) / 60).rounded() }
                .filter { $0.value > 0 }
            let total = (DateIntervalMath.unionDuration(items.map(\.interval), clippedTo: day) / 60).rounded()
            object["workoutMinutes"] = .number(total)
            object["minutesByType"] = .object(minutes.mapValues(JSONValue.number))
            object["workouts"] = .array(starting.prefix(Self.maxHealthWorkoutsPerDay).map {
                itemJSON($0, buckets: buckets, calendar: calendar)
            })
            if starting.count > Self.maxHealthWorkoutsPerDay {
                object["moreWorkouts"] = .number(Double(starting.count - Self.maxHealthWorkoutsPerDay))
            }
            // Leitura do Saúde falhou: só as sessões do app estão aqui.
            if workoutsStatus == .unavailable { status["workouts"] = .string("unavailable") }
            period.addWorkouts(count: starting.filter { !$0.maybeSameAsAppSession }.count, minutes: total, byType: minutes)
        }
        if !status.isEmpty { object["status"] = .object(status) }
        return object
    }

    private func itemJSON(_ item: HealthWorkoutItem, buckets: HealthReading<[HeartRateBucket]>, calendar: Calendar) -> JSONValue {
        var object: [String: JSONValue] = [
            "start": .string(Self.timeString(item.interval.start, calendar)),
            "min": .number((item.interval.duration / 60).rounded()),
            "type": .string(Self.typeName(item.category)),
            "origin": .string(item.origin),
        ]
        if let recorded = item.recordedHeartRate {
            object["avgHR"] = .number(recorded.rounded())
        } else if let estimated = buckets.value.flatMap({ HeartRateAnalysis.stats(buckets: $0, in: item.interval) }) {
            object["avgHR"] = .number(estimated.average.rounded())
            object["avgHRApprox"] = .bool(true)
        } else {
            object["avgHR"] = .null
            object["avgHRStatus"] = .string(buckets.status == .unavailable ? "unavailable" : "no_data")
        }
        if sharesWorkouts, let name = item.name { object["name"] = .string(name) }
        if item.maybeSameAsAppSession { object["maybeSameAsAppSession"] = .bool(true) }
        return .object(object)
    }

    /// Sem treino nenhum: `unavailable` se o Saúde não pôde ser lido, senão `no_data` (nunca zero treinos).
    nonisolated static func emptyWorkoutsStatus(_ readingStatus: HealthReadingStatus) -> String {
        readingStatus == .unavailable ? "unavailable" : "no_data"
    }

    static func typeName(_ category: HealthWorkoutCategory) -> String {
        switch category {
        case .strength: "strength"
        case .aerobic: "aerobic"
        case .mixed, .mobility, .other: "other"
        }
    }

    nonisolated static func isWatch(_ record: HealthWorkoutRecord) -> Bool {
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
        let workoutsStatus: HealthReadingStatus
        var energy: [Double] = []
        var resting: [Double] = []
        var steps: [Double] = []
        var energyStatuses: Set<HealthReadingStatus> = []
        var stepsStatuses: Set<HealthReadingStatus> = []
        var restingStatuses: Set<HealthReadingStatus> = []
        var workouts = 0
        var workoutMinutes: Double?
        var minutesByType: [String: Double] = [:]

        init(workoutsStatus: HealthReadingStatus) { self.workoutsStatus = workoutsStatus }

        /// Só dias completos (o dia corrente fica de fora).
        mutating func add(energy: HealthReading<Double>, resting: HealthReading<Double>, steps: HealthReading<Double>) {
            if let value = energy.value { self.energy.append(value) }
            if let value = resting.value { self.resting.append(value) }
            if let value = steps.value { self.steps.append(value) }
            energyStatuses.insert(energy.status)
            restingStatuses.insert(resting.status)
            stepsStatuses.insert(steps.status)
        }

        mutating func addWorkouts(count: Int, minutes: Double, byType: [String: Double]) {
            workouts += count
            workoutMinutes = (workoutMinutes ?? 0) + minutes
            for (key, value) in byType { minutesByType[key, default: 0] += value }
        }

        func json(days: Int, restingValues: [HealthDailyValue], restingStatus: HealthReadingStatus) -> JSONValue {
            var object: [String: JSONValue] = ["days": .number(Double(days))]
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
                object["workouts"] = .number(Double(workouts))
                object["workoutMinutes"] = .number(workoutMinutes)
                object["minutesByType"] = .object(minutesByType.mapValues(JSONValue.number))
                if workoutsStatus == .unavailable { status["workouts"] = .string("unavailable") } // só sessões do app
            } else {
                // Nenhum treino no período: mesmo critério do dia (nunca "0 treinos").
                let reason = FitnessToolbox.emptyWorkoutsStatus(workoutsStatus)
                object["workouts"] = .null
                object["workoutMinutes"] = .null
                status["workouts"] = .string(reason)
                status["workoutMinutes"] = .string(reason)
            }
            object["restingHRTrend"] = Self.trend(restingValues, status: restingStatus)
            if !status.isEmpty { object["status"] = .object(status) }
            return .object(object)
        }

        /// Primeira × segunda metade dos dias completos (≥ 3 dias com valor em cada; variação < 1 bpm = estável).
        static func trend(_ values: [HealthDailyValue], status: HealthReadingStatus) -> JSONValue {
            guard status != .unavailable else { return .object(["direction": .null, "status": .string("unavailable")]) }
            let sorted = values.sorted { $0.day < $1.day }
            let window = sorted.count / 2
            guard window >= 3, let direction = HealthTrend.direction(sorted, window: window) else {
                return .object(["direction": .null, "status": .string("no_data"),
                                "reason": .string("Precisa de ≥ 6 dias completos com FC em repouso no período.")])
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

    /// Cabe em `healthResultBudget`: primeiro a lista de treinos de cada dia vira `workoutCount` (ficam os
    /// minutos), depois saem os dias (ficam os agregados).
    static func fitHealthResult(_ result: [String: JSONValue], days: [[String: JSONValue]]) -> JSONValue {
        var result = result
        guard JSONValue.object(result).jsonString().count > healthResultBudget else { return .object(result) }
        let compactDays = days.map { day -> JSONValue in
            var day = day
            if let listed = day["workouts"]?.arrayValue {
                var more = 0
                if case .number(let value)? = day["moreWorkouts"] { more = Int(value) }
                day["workoutCount"] = .number(Double(listed.count + more))
                day["workouts"] = nil
                day["moreWorkouts"] = nil
            }
            return .object(day)
        }
        result["days"] = .array(compactDays)
        result["truncated"] = .string("Lista de treinos por dia trocada por workoutCount para caber no limite; peça um período menor para detalhes.")
        guard JSONValue.object(result).jsonString().count > healthResultBudget else { return .object(result) }
        result["days"] = nil
        result["truncated"] = .string("Detalhe por dia omitido para caber no limite; só os agregados do período. Peça um período menor.")
        return .object(result)
    }
}
