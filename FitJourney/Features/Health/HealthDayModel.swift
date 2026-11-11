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
        var summary: HealthDaySummary
        var buckets: HealthReading<[HeartRateBucket]>
        var rows: [HealthPresentation.WorkoutRow]
        var styles: [UUID: RoutineStyle]
        /// Início de cada dia da semana (7).
        var weekDays: [Date]
        var weekMinutes: [[FJWorkoutKind: Double]]
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
        var isToday: Bool
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

    private(set) var phase: Phase = .loading
    var date: Date
    private let calendar: Calendar
    private var autoLinkAttempted: Set<String> = []

    init(date: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        self.date = calendar.startOfDay(for: date)
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
        let start = calendar.startOfDay(for: day)
        date = min(start, calendar.startOfDay(for: Date()))
    }

    // MARK: Carga

    func load(reader: any HealthDataReading, context: ModelContext, controller: HealthWorkoutController?,
              now: Date = Date()) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            var data = try await read(reader: reader, context: context, now: now)
            // Alta confiança: vincula sozinho (reversível); recarrega uma vez para refletir o vínculo.
            if let controller, autoLink(data.rows, controller: controller) {
                data = try await read(reader: reader, context: context, now: now)
            }
            phase = .loaded(data)
        } catch {
            if !(error is CancellationError) { phase = .failed }
        }
    }

    private func autoLink(_ rows: [HealthPresentation.WorkoutRow], controller: HealthWorkoutController) -> Bool {
        var linked = false
        for row in rows {
            guard let suggestion = row.linkedSuggestion, let sessionID = row.sessionID else { continue }
            let key = HealthPresentation.pairKey(sessionID: sessionID, workoutID: suggestion.workout.id)
            guard autoLinkAttempted.insert(key).inserted else { continue }
            if controller.linkWorkout(suggestion.workout.id, to: sessionID) { linked = true }
        }
        return linked
    }

    func link(workoutID: UUID, to sessionID: UUID, controller: HealthWorkoutController?) {
        controller?.linkWorkout(workoutID, to: sessionID)
    }

    func unlink(sessionID: UUID, workoutID: UUID, controller: HealthWorkoutController?) {
        controller?.linkWorkout(nil, to: sessionID)
        HealthDismissedLinks.add(sessionID: sessionID, workoutID: workoutID)
    }

    func dismiss(sessionID: UUID, workoutID: UUID) {
        HealthDismissedLinks.add(sessionID: sessionID, workoutID: workoutID)
    }

    private func read(reader: any HealthDataReading, context: ModelContext, now: Date) async throws -> DayData {
        let start = date
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = DateInterval(start: start, end: end)
        let week = weekInterval(containing: start)
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
        let previousStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let sessionsInWeek = HealthSessionWindow.windows(in: week, context: context, now: now)
        let sessionsInDay = sessionsInWeek.filter { $0.interval.intersection(with: day) != nil }

        async let workoutsRead = reader.workouts(in: week)
        async let bucketsRead = reader.heartRateBuckets(in: day, bucket: 300)
        async let energyRead = reader.activeEnergyKcal(in: day)
        async let stepsRead = reader.steps(in: day)
        async let restingRead = reader.restingHeartRate(days: DateInterval(start: previousStart, end: end))
        async let bodyRead = reader.latestBodyMassKg()

        let workoutsWeek = try await workoutsRead
        let buckets = try await bucketsRead
        let energy = try await energyRead
        let steps = try await stepsRead
        let resting = try await restingRead
        let bodyMass = try await bodyRead

        let workoutsDay: HealthReading<[HealthWorkoutRecord]> = workoutsWeek.map { all in
            all.filter { $0.interval.intersection(with: day) != nil }
        }.emptyAsNoData
        let restingToday: HealthReading<Double> = switch resting {
        case .available(let values): values.last { $0.day == start }.map { .available($0.value) } ?? .noData
        case .noData: .noData
        case .unavailable: .unavailable
        }
        let summary = HealthDayAnalyzer.summarize(day: day, workouts: workoutsDay, sessions: sessionsInDay, heartRate: buckets,
                                                  activeEnergyKcal: energy, restingHeartRate: restingToday, steps: steps)

        // Semana: minutos por tipo (união) e dias com treino.
        let weekEntries = HealthDayAnalyzer.entries(workouts: workoutsWeek.value ?? [], sessions: sessionsInWeek)
        let intervals = weekEntries.map { (category: $0.category, interval: $0.interval) }
        let weekMinutes = HealthPresentation.dailyMinutes(intervals, days: weekDays, calendar: calendar)
        let trainingDays = Set(weekDays.filter { dayStart in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            return intervals.contains { $0.interval.intersection(with: DateInterval(start: dayStart, end: dayEnd)) != nil }
        })

        // Energia: 7 dias anteriores (um por dia) + o dia.
        var energyPrevious: [Double?] = []
        for offset in (1...7).reversed() {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            energyPrevious.append(try await reader.activeEnergyKcal(in: DateInterval(start: dayStart, end: dayEnd)).value)
        }
        let restingByDay = Dictionary((resting.value ?? []).map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let restingPrevious: [Double?] = (1...7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: start).map { restingByDay[$0] }
        }

        var hasRecent: Bool?
        if buckets.value == nil, let from = calendar.date(byAdding: .day, value: -30, to: end) {
            hasRecent = try await reader.heartRateBuckets(in: DateInterval(start: from, end: end), bucket: 86_400).value != nil
        }

        let dismissed = HealthDismissedLinks.load()
        let rows = HealthPresentation.rows(summary, dismissedPairs: dismissed)
        return DayData(
            summary: summary, buckets: buckets, rows: rows, styles: styles(for: sessionsInDay.map(\.sessionID), context: context),
            weekDays: weekDays, weekMinutes: weekMinutes, trainingDays: trainingDays,
            energySeries: Array((energyPrevious + [energy.value]).suffix(7)), energyPrevious: energyPrevious.compactMap(\.self),
            restingSeries: Array((restingPrevious + [restingToday.value]).suffix(7)), restingPrevious: restingPrevious.compactMap(\.self),
            bodyMass: bodyMass, hasRecentHeartRate: hasRecent, isToday: calendar.isDate(now, inSameDayAs: start), now: now)
    }

    private func weekInterval(containing day: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: day)
            ?? DateInterval(start: day, end: day.addingTimeInterval(7 * 86_400))
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
