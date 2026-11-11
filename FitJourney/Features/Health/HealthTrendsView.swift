import Charts
import SwiftData
import SwiftUI

/// Período das tendências (DESIGN §4.11): 4 sem · 8 sem · 3 m.
enum HealthTrendPeriod: String, CaseIterable, Identifiable {
    case weeks4, weeks8, months3

    var id: String { rawValue }
    var days: Int { switch self { case .weeks4: 28; case .weeks8: 56; case .months3: 90 } }
    var title: LocalizedStringKey {
        switch self {
        case .weeks4: "4 sem"
        case .weeks8: "8 sem"
        case .months3: "3 m"
        }
    }
}

@MainActor
@Observable
final class HealthTrendsModel {
    struct WorkoutPoint: Identifiable {
        var id: UUID
        var date: Date
        var bpm: Double
        var kind: FJWorkoutKind?
    }

    struct TrendData {
        var weekStarts: [Date]
        var weeklyMinutes: [[FJWorkoutKind: Double]]
        var workoutPoints: [WorkoutPoint]
        var resting: HealthReading<[HealthDailyValue]>
        var restingAverage: [HealthDailyValue]
        var restingDirection: HealthTrendDirection?
        var workoutsStatus: HealthReadingStatus
        /// Pelo menos duas semanas de dados.
        var hasTwoWeeks: Bool
    }

    enum Phase {
        case loading
        case loaded(TrendData)
        case failed
    }

    private(set) var phase: Phase = .loading
    var period: HealthTrendPeriod = .weeks4

    func load(reader: any HealthDataReading, context: ModelContext, calendar: Calendar = .current, now: Date = Date()) async {
        if case .loaded = phase {} else { phase = .loading }
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let start = calendar.date(byAdding: .day, value: -period.days, to: today) ?? today
        let range = DateInterval(start: start, end: end)
        do {
            async let workoutsRead = reader.workouts(in: range)
            async let restingRead = reader.restingHeartRate(days: range)
            let workouts = try await workoutsRead
            let resting = try await restingRead
            let sessions = HealthSessionWindow.windows(in: range, context: context, now: now)
            let entries = HealthDayAnalyzer.entries(workouts: workouts.value ?? [], sessions: sessions)
            let intervals = entries.map { (category: $0.category, interval: $0.interval) }

            var weekStarts: [Date] = []
            var cursor = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            while cursor < end {
                weekStarts.append(cursor)
                guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
                cursor = next
            }
            let weekly = HealthPresentation.weeklyMinutes(intervals, weekStarts: weekStarts, calendar: calendar)

            let points: [WorkoutPoint] = entries.compactMap { entry in
                let bpm: Double?
                switch entry {
                case .session(_, let own, let suggestions): bpm = own?.averageHeartRate ?? suggestions.first?.workout.averageHeartRate
                case .external(let record, _): bpm = record.averageHeartRate
                }
                return bpm.map { WorkoutPoint(id: entry.id, date: entry.interval.start, bpm: $0, kind: HealthPresentation.kind(entry.category)) }
            }
            let values = resting.value ?? []
            let earliest = (intervals.map(\.interval.start) + values.map(\.day)).min()
            phase = .loaded(TrendData(
                weekStarts: weekStarts, weeklyMinutes: weekly, workoutPoints: points, resting: resting,
                restingAverage: HealthPresentation.movingAverage(values), restingDirection: HealthTrend.direction(values),
                workoutsStatus: workouts.status, hasTwoWeeks: earliest.map { now.timeIntervalSince($0) >= 14 * 86_400 } ?? false))
        } catch {
            if !(error is CancellationError) { phase = .failed }
        }
    }
}

/// Aba Saúde › Tendências.
struct HealthTrendsView: View {
    @Bindable var model: HealthTrendsModel

    @Environment(\.modelContext) private var context
    @Environment(\.healthReader) private var injectedReader
    @Environment(\.openURL) private var openURL
    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?

    private var isConnected: Bool { authorization == nil || HealthConnectionState(authorization).isConnected }

    var body: some View {
        VStack(spacing: FJSpacing.cardGap) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FJSpacing.s) {
                    ForEach(HealthTrendPeriod.allCases) { period in
                        FJFilterChip(period.title, isSelected: model.period == period, area: .health) { model.period = period }
                    }
                }
            }
            if !isConnected { HealthConnectCard() }
            switch model.phase {
            case .loading:
                FJCard { FJLoadingState("Lendo dados do Saúde…") }
            case .failed:
                FJBanner("Não foi possível ler o Saúde", tone: .destructive, systemImage: "exclamationmark.triangle.fill",
                         actionTitle: "Tentar de novo") { Task { await load() } }
            case .loaded(let data):
                minutesCard(data)
                workoutHeartRateCard(data)
                restingCard(data)
            }
        }
        .task(id: LoadKey(period: model.period, connected: authorization?.isConnectionEnabled, access: authorization?.access)) {
            await load()
        }
    }

    private struct LoadKey: Hashable {
        var period: HealthTrendPeriod
        var connected: Bool?
        var access: HealthAuthorization.Access?
    }

    private func load() async {
        await model.load(reader: injectedReader ?? HealthQueries.live, context: context)
    }

    private func total(_ week: [FJWorkoutKind: Double]) -> Double { week.values.reduce(0, +) }

    private func minutesCard(_ data: HealthTrendsModel.TrendData) -> some View {
        let totals = data.weeklyMinutes.map(total)
        let current = totals.last(where: { $0 > 0 })
        let previous = totals.dropLast().last(where: { $0 > 0 })
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Minutos por tipo", subtitle: "Por semana")
                if totals.contains(where: { $0 > 0 }) {
                    if let current {
                        TrendHeadline(value: HealthPresentation.minutes(current), comparison: previous.map { comparisonText(current: current, previous: $0) })
                    }
                    Chart {
                        ForEach(Array(data.weekStarts.enumerated()), id: \.offset) { index, week in
                            ForEach(FJWorkoutKind.allCases, id: \.self) { kind in
                                if let minutes = data.weeklyMinutes[index][kind] {
                                    BarMark(x: .value("Semana", week, unit: .weekOfYear), y: .value("Minutos", minutes))
                                        .foregroundStyle(by: .value("Tipo", kind.rawValue))
                                }
                            }
                        }
                    }
                    .chartForegroundStyleScale([FJWorkoutKind.strength.rawValue: FJWorkoutKind.strength.color,
                                                FJWorkoutKind.aerobic.rawValue: FJWorkoutKind.aerobic.color])
                    .chartLegend(.hidden)
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                    .frame(height: 160)
                    .accessibilityLabel(Text("Minutos de treino por semana"))
                    .accessibilityValue(Text(verbatim: zip(data.weekStarts, totals).map {
                        "\($0.formatted(.dateTime.day().month(.abbreviated))): \(HealthPresentation.minutes($1))"
                    }.joined(separator: ", ")))
                    HStack(spacing: FJSpacing.l) {
                        ForEach(FJWorkoutKind.allCases, id: \.self) { kind in
                            Label { Text(kind.title) } icon: { Image(systemName: kind.systemImage).foregroundStyle(kind.color) }
                                .font(FJFont.caption)
                        }
                    }
                    if !data.hasTwoWeeks { keepRecording }
                } else {
                    emptyNote(status: data.workoutsStatus)
                }
            }
        }
    }

    private func comparisonText(current: Double, previous: Double) -> String {
        let delta = Int((current - previous).rounded())
        guard previous > 0, abs(current - previous) / previous >= 0.02 else { return String(localized: "na média das semanas anteriores") }
        return delta > 0 ? "↑ \(delta) min " + String(localized: "acima da semana anterior")
            : "↓ \(abs(delta)) min " + String(localized: "abaixo da semana anterior")
    }

    private func workoutHeartRateCard(_ data: HealthTrendsModel.TrendData) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("FC média por treino")
                if data.workoutPoints.count >= 2 {
                    Chart(data.workoutPoints) { point in
                        PointMark(x: .value("Dia", point.date), y: .value("bpm", point.bpm))
                            .foregroundStyle(point.kind?.color ?? FJColor.textSecondary)
                            .symbolSize(50)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                    .frame(height: 150)
                    .accessibilityLabel(Text("Frequência cardíaca média de cada treino"))
                    .accessibilityValue(Text(verbatim: data.workoutPoints.map { "\($0.date.formatted(.dateTime.day().month(.abbreviated))): \(HealthPresentation.bpm($0.bpm))" }.joined(separator: ", ")))
                    HStack(spacing: FJSpacing.l) {
                        ForEach(FJWorkoutKind.allCases, id: \.self) { kind in
                            Label { Text(kind.title) } icon: { Image(systemName: kind.systemImage).foregroundStyle(kind.color) }
                                .font(FJFont.caption)
                        }
                    }
                } else if let point = data.workoutPoints.first {
                    TrendHeadline(value: "\(HealthPresentation.bpm(point.bpm)) bpm", comparison: nil)
                    keepRecording
                } else {
                    emptyNote(status: data.workoutsStatus)
                }
            }
        }
    }

    private func restingCard(_ data: HealthTrendsModel.TrendData) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("FC em repouso", subtitle: "Média móvel de 7 dias")
                switch data.resting {
                case .available(let values):
                    let latest = HealthPresentation.movingAverage(values).last
                    if let latest {
                        TrendHeadline(value: "\(HealthPresentation.bpm(latest.value)) bpm", comparison: HealthPresentation.trendText(data.restingDirection))
                    }
                    Chart {
                        ForEach(values, id: \.day) { value in
                            PointMark(x: .value("Dia", value.day, unit: .day), y: .value("bpm", value.value))
                                .foregroundStyle(FJColor.health.opacity(0.35)).symbolSize(16)
                        }
                        ForEach(data.restingAverage, id: \.day) { value in
                            LineMark(x: .value("Dia", value.day, unit: .day), y: .value("Média móvel", value.value))
                                .foregroundStyle(FJColor.health).lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                    .frame(height: 150)
                    .accessibilityLabel(Text("FC em repouso ao longo do período"))
                    .accessibilityValue(Text(verbatim: HealthPresentation.trendText(data.restingDirection)))
                    if !data.hasTwoWeeks { keepRecording }
                case .noData:
                    emptyNote(status: .noData)
                case .unavailable:
                    emptyNote(status: .unavailable)
                }
            }
        }
    }

    private var keepRecording: some View {
        Text("Continue registrando para ver a tendência").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
    }

    @ViewBuilder private func emptyNote(status: HealthReadingStatus) -> some View {
        Text(verbatim: "—").font(FJFont.numberLarge).foregroundStyle(FJColor.textSecondary)
        switch status {
        case .unavailable:
            Text(HealthReadingDisplay.unavailableNote).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
        default:
            Text("Sem dados neste período").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            if isConnected {
                Button("Revisar permissões") { HealthSettings.open(openURL) }.font(FJFont.caption)
            }
        }
    }
}

private struct TrendHeadline: View {
    let value: String
    let comparison: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            Text(verbatim: value).font(FJFont.numberLarge)
            if let comparison { Text(verbatim: comparison).font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
