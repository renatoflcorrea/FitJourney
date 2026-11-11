import Foundation
import SwiftData

/// Modelo do dia da aba Saúde: lê tudo com o `HealthDataReading` e guarda cada leitura com seu estado
/// (sem dado ≠ zero). As sessões do app entram sempre (dados locais), com ou sem Saúde.
@MainActor
@Observable
final class HealthDayModel {
    struct RoutineStyle: Equatable {
        var symbol: String
        var colorName: String
        var isInProgress: Bool
    }

    struct DayData {
        /// Início do dia a que os dados pertencem (a tela só os mostra se for o dia escolhido).
        var day: Date
        var summary: HealthDaySummary
        var buckets: HealthReading<[HeartRateBucket]>
        var rows: [HealthPresentation.WorkoutRow]
        var styles: [UUID: RoutineStyle]
        /// Início de cada dia da semana (7).
        var weekDays: [Date]
        /// Minutos por tipo em cada dia da semana (união dentro do tipo).
        var weekMinutes: [[HealthMinutesKind: Double]]
        /// Minutos por dia pela união geral (sobreposição entre tipos não soma duas vezes).
        var weekTotals: [Double]
        var weekWorkoutsStatus: HealthReadingStatus
        var trainingDays: Set<Date>
        /// Energia dos 7 dias que terminam no dia (último = o dia); `nil` = sem amostra.
        var energySeries: [Double?]
        /// Energia dos 7 dias anteriores (só os com amostra).
        var energyPrevious: [Double]
        var restingSeries: [Double?]
        var restingPrevious: [Double]
        var bodyMass: HealthReading<Double>
        /// Havia alguma FC nos últimos 30 dias? `nil` = não verificado.
        var hasRecentHeartRate: Bool?
        var now: Date

        var energyFromWorkouts: Double? {
            let values = rows.compactMap(\.energyKcal)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
    }

    enum Phase {
        case loading
        case loaded(DayData)
        case failed
    }

    /// Tudo o que foi lido, antes de montar o resumo (permite remontar após um vínculo sem reler).
    private struct Raw {
        var day: DateInterval
        var week: DateInterval
        var weekDays: [Date]
        var workoutsWeek: HealthReading<[HealthWorkoutRecord]>
        var sessionsInWeek: [HealthSessionWindow]
        var buckets: HealthReading<[HeartRateBucket]>
        var energy: HealthReading<Double>
        var steps: HealthReading<Double>
        var restingToday: HealthReading<Double>
        var restingByDay: [Date: Double]
        var energyPrevious: [Double?]
        var bodyMass: HealthReading<Double>
        var hasRecent: Bool?
        var styles: [UUID: RoutineStyle]
        var now: Date
    }

    private(set) var phase: Phase = .loading
    private(set) var date: Date
    private let fixedCalendar: Calendar?
    /// Calendário do app (semana começa como em Ajustes) salvo se um fixo foi injetado (testes).
    var calendar: Calendar { fixedCalendar ?? AppCalendar.current }
    private let defaults: UserDefaults
    private var autoLinkAttempted: Set<String> = []

    init(date: Date = Date(), calendar: Calendar? = nil, defaults: UserDefaults = .standard) {
        self.fixedCalendar = calendar
        self.defaults = defaults
        self.date = (calendar ?? AppCalendar.current).startOfDay(for: date)
    }

    var isToday: Bool { calendar.isDateInToday(date) }

    var title: String {
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        if isToday { return String(localized: "Hoje, \(day)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Ontem, \(day)") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    func shift(by days: Int) {
        guard let next = calendar.date(byAdding: .day, value: days, to: date) else { return }
        jump(to: next)
    }

    func jump(to day: Date) {
        let start = min(calendar.startOfDay(for: day), calendar.startOfDay(for: Date()))
        guard start != date else { return }
        date = start
        // O dia anterior não fica sob o título novo.
        phase = .loading
    }

    // MARK: Carga

    func load(reader: any HealthDataReading, context: ModelContext, controller: HealthWorkoutController?,
              now: Date = Date()) async {
        if case .loaded(let data) = phase, data.day != date { phase = .loading }
        do {
            var raw = try await gather(reader: reader, context: context, now: now)
            var data = assemble(raw)
            // Alta confiança: vincula sozinho (reversível); remonta o resumo com o vínculo, sem reler o Saúde.
            if let controller {
                let linked = autoLink(data, controller: controller)
                if !linked.isEmpty {
                    raw.sessionsInWeek = raw.sessionsInWeek.map { window in
                        var window = window
                        if let workoutID = linked[window.sessionID] { window.healthKitWorkoutID = workoutID }
                        return window
                    }
                    data = assemble(raw)
                }
            }
            phase = .loaded(data)
        } catch {
            if !(error is CancellationError) { phase = .failed }
        }
    }

    /// Vincula as sugestões de alta confiança ainda não tentadas. Sessão em andamento nunca é vinculada; o
    /// par só conta como tentado quando o vínculo foi gravado. Devolve sessão → treino vinculado.
    private func autoLink(_ data: DayData, controller: HealthWorkoutController) -> [UUID: UUID] {
        var linked: [UUID: UUID] = [:]
        for row in data.rows {
            guard let suggestion = row.linkedSuggestion, let sessionID = row.sessionID,
                  data.styles[sessionID]?.isInProgress != true else { continue }
            let key = HealthPresentation.pairKey(sessionID: sessionID, workoutID: suggestion.workout.id)
            guard !autoLinkAttempted.contains(key) else { continue }
            if controller.linkWorkout(suggestion.workout.id, to: sessionID) {
                autoLinkAttempted.insert(key)
                linked[sessionID] = suggestion.workout.id
            }
        }
        return linked
    }

    /// Vínculo manual (incerta → "Vincular"). `true` se gravou.
    @discardableResult
    func link(workoutID: UUID, to sessionID: UUID, controller: HealthWorkoutController?) -> Bool {
        controller?.linkWorkout(workoutID, to: sessionID) ?? false
    }

    /// "Desfazer": zera o vínculo sem duplicar no próximo launch e lembra que não é o mesmo treino.
    func unlink(sessionID: UUID, workoutID: UUID, controller: HealthWorkoutController?) {
        controller?.unlinkWorkout(from: sessionID)
        HealthDismissedLinks.add(sessionID: sessionID, workoutID: workoutID, defaults: defaults)
    }

    func dismiss(sessionID: UUID, workoutID: UUID) {
        HealthDismissedLinks.add(sessionID: sessionID, workoutID: workoutID, defaults: defaults)
    }

    // MARK: Leitura

    private func gather(reader: any HealthDataReading, context: ModelContext, now: Date) async throws -> Raw {
        let start = date
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = DateInterval(start: start, end: end)
        let week = calendar.dateInterval(of: .weekOfYear, for: start) ?? DateInterval(start: start, end: end.addingTimeInterval(6 * 86_400))
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
        let previousStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let sessionsInWeek = HealthSessionWindow.windows(in: week, context: context, now: now)

        async let workoutsRead = reader.workouts(in: week)
        async let bucketsRead = reader.heartRateBuckets(in: day, bucket: 300)
        async let energyRead = reader.activeEnergyKcal(in: day)
        async let stepsRead = reader.steps(in: day)
        async let restingRead = reader.restingHeartRate(days: DateInterval(start: previousStart, end: end))
        async let bodyRead = reader.latestBodyMassKg()
        async let previousEnergy = energyOfPreviousDays(reader: reader, before: start)

        let workoutsWeek = try await workoutsRead
        let buckets = try await bucketsRead
        let resting = try await restingRead
        let restingToday: HealthReading<Double> = switch resting {
        case .available(let values): values.last { $0.day == start }.map { .available($0.value) } ?? .noData
        case .noData: .noData
        case .unavailable: .unavailable
        }
        var hasRecent: Bool?
        if buckets.value == nil, let from = calendar.date(byAdding: .day, value: -30, to: end) {
            hasRecent = try await reader.heartRateBuckets(in: DateInterval(start: from, end: end), bucket: 86_400).value != nil
        }
        let weekSessionIDs = sessionsInWeek.map(\.sessionID)
        return Raw(
            day: day, week: week, weekDays: weekDays, workoutsWeek: workoutsWeek, sessionsInWeek: sessionsInWeek,
            buckets: buckets, energy: try await energyRead, steps: try await stepsRead, restingToday: restingToday,
            restingByDay: Dictionary((resting.value ?? []).map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last }),
            energyPrevious: try await previousEnergy, bodyMass: try await bodyRead, hasRecent: hasRecent,
            styles: styles(for: weekSessionIDs, context: context), now: now)
    }

    /// Energia ativa dos 7 dias anteriores, em paralelo (do mais antigo ao mais recente; `nil` = sem amostra).
    private func energyOfPreviousDays(reader: any HealthDataReading, before start: Date) async throws -> [Double?] {
        let intervals: [(Int, DateInterval)] = (1...7).reversed().enumerated().compactMap { index, offset in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return (index, DateInterval(start: dayStart, end: dayEnd))
        }
        return try await withThrowingTaskGroup(of: (Int, Double?).self) { group in
            for (index, interval) in intervals {
                group.addTask { (index, try await reader.activeEnergyKcal(in: interval).value) }
            }
            var result = [Double?](repeating: nil, count: intervals.count)
            for try await (index, value) in group { result[index] = value }
            return result
        }
    }

    private func assemble(_ raw: Raw) -> DayData {
        let day = raw.day
        let sessionsInDay = raw.sessionsInWeek.filter { $0.interval.intersection(with: day) != nil }
        let workoutsDay: HealthReading<[HealthWorkoutRecord]> = raw.workoutsWeek.map { all in
            all.filter { $0.interval.intersection(with: day) != nil }
        }.emptyAsNoData
        let summary = HealthDayAnalyzer.summarize(day: day, workouts: workoutsDay, sessions: sessionsInDay, heartRate: raw.buckets,
                                                  activeEnergyKcal: raw.energy, restingHeartRate: raw.restingToday, steps: raw.steps)

        let weekEntries = HealthDayAnalyzer.entries(workouts: raw.workoutsWeek.value ?? [], sessions: raw.sessionsInWeek)
        let intervals = weekEntries.map { (category: $0.category, interval: $0.interval) }
        let weekTotals = HealthPresentation.dailyTotals(intervals, days: raw.weekDays, calendar: calendar)
        let trainingDays = Set(zip(raw.weekDays, weekTotals).filter { $0.1 > 0 }.map(\.0))

        let previousDays = (1...7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: day.start) }
        let restingPrevious: [Double?] = previousDays.map { raw.restingByDay[$0] }
        let rows = HealthPresentation.rows(summary, dismissedPairs: HealthDismissedLinks.load(defaults))
        return DayData(
            day: day.start, summary: summary, buckets: raw.buckets, rows: rows, styles: raw.styles, weekDays: raw.weekDays,
            weekMinutes: HealthPresentation.dailyMinutes(intervals, days: raw.weekDays, calendar: calendar), weekTotals: weekTotals,
            weekWorkoutsStatus: raw.workoutsWeek.status, trainingDays: trainingDays,
            energySeries: Array((raw.energyPrevious + [raw.energy.value]).suffix(7)), energyPrevious: raw.energyPrevious.compactMap(\.self),
            restingSeries: Array((restingPrevious + [raw.restingToday.value]).suffix(7)), restingPrevious: restingPrevious.compactMap(\.self),
            bodyMass: raw.bodyMass, hasRecentHeartRate: raw.hasRecent, now: raw.now)
    }

    private func styles(for ids: [UUID], context: ModelContext) -> [UUID: RoutineStyle] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { wanted.contains($0.id) })
        var result: [UUID: RoutineStyle] = [:]
        for session in (try? context.fetch(descriptor)) ?? [] {
            result[session.id] = RoutineStyle(symbol: session.routine?.symbol ?? "", colorName: session.routine?.colorName ?? "",
                                              isInProgress: session.status == .inProgress)
        }
        return result
    }
}

extension HealthReading where Value: Collection {
    /// Lista vazia vira `.noData` (nunca "zero treinos" por falta de leitura).
    var emptyAsNoData: HealthReading<Value> {
        if case .available(let value) = self, value.isEmpty { return .noData }
        return self
    }
}
