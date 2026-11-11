import Charts
import SwiftData
import SwiftUI

/// Evolução de um exercício (SPEC §4.4, DESIGN_DIRECTION §4.8): carga, volume e 1RM estimado
/// (ou tempo / distância / duração conforme o tipo), melhor série e histórico por sessão. Empurrável.
struct ExerciseProgressView: View {
    let exerciseID: UUID

    @Query private var executions: [SessionExercise]
    @Query private var catalog: [Exercise]

    @State private var metric: ProgressCalculator.Metric?
    @State private var period: ProgressCalculator.Period = .all
    @State private var selectedDate: Date?

    init(exerciseID: UUID) {
        self.exerciseID = exerciseID
        let optionalID: UUID? = exerciseID
        let completed = SessionStatus.completed.rawValue
        let skipped = SessionExerciseStatus.skipped.rawValue
        _executions = Query(
            filter: #Predicate<SessionExercise> {
                $0.exerciseID == optionalID && $0.statusRaw != skipped && $0.session?.statusRaw == completed
            },
            sort: \SessionExercise.createdAt
        )
        _catalog = Query(filter: #Predicate<Exercise> { $0.id == exerciseID })
    }

    private var kind: MeasurementKind { executions.last?.measurementKind ?? catalog.first?.measurementKind ?? .repsAndLoad }
    private var name: String { catalog.first?.name ?? executions.last?.name ?? String(localized: "Exercício") }
    private var availableMetrics: [ProgressCalculator.Metric] { ProgressCalculator.Metric.available(for: kind) }
    private var activeMetric: ProgressCalculator.Metric { metric.flatMap { availableMetrics.contains($0) ? $0 : nil } ?? availableMetrics[0] }

    private func makeSamples() -> [ProgressCalculator.Sample] {
        executions.compactMap { execution in
            guard let session = execution.session else { return nil }
            return ProgressCalculator.Sample(
                id: execution.id, date: session.startedAt,
                sets: execution.sortedSets.map {
                    ProgressCalculator.SetSample(performed: $0.performed, durationSeconds: $0.durationSeconds,
                                                 distanceMeters: $0.distanceMeters)
                })
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        let samples = makeSamples()
        return Group {
            if samples.isEmpty {
                FJEmptyState("Sem registros ainda", systemImage: "chart.line.uptrend.xyaxis",
                             message: "Conclua um treino com este exercício para ver a evolução.")
            } else {
                content(samples)
            }
        }
        .fjScreenBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ samples: [ProgressCalculator.Sample]) -> some View {
        let all = ProgressCalculator.points(samples, metric: activeMetric)
        let points = ProgressCalculator.filter(all, period: period)
        return ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.cardGap) {
                if availableMetrics.count > 1 {
                    Picker("Métrica", selection: Binding(get: { activeMetric }, set: { metric = $0; selectedDate = nil })) {
                        ForEach(availableMetrics) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                periodChips
                chartCard(points, samples: samples)
                bestCards(samples)
                sessionList(samples)
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.vertical, FJSpacing.s)
        }
    }

    private var periodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: FJSpacing.s) {
                HStack(spacing: FJSpacing.s) {
                    ForEach(ProgressCalculator.Period.allCases) { item in
                        FJFilterChip(LocalizedStringKey(item.title), isSelected: period == item) {
                            period = item
                            selectedDate = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: Gráfico

    private func chartCard(_ points: [ProgressCalculator.Point], samples: [ProgressCalculator.Sample]) -> some View {
        let selected = selectedDate.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        let unit = activeMetric.unit
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    if let selected {
                        Text(selected.date.formatted(date: .abbreviated, time: .omitted))
                            .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        Text("\(FJFormat.number(selected.value, maxFractionDigits: 1)) \(unit)").font(FJFont.numberLarge)
                    } else if let last = points.last {
                        Text("Mais recente").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        Text("\(FJFormat.number(last.value, maxFractionDigits: 1)) \(unit)").font(FJFont.numberLarge)
                    } else {
                        Text("Sem dados neste período").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)

                if points.count == 1 {
                    Text("Registre mais treinos para ver a evolução.")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
                if !points.isEmpty {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("Data", point.date), y: .value(activeMetric.title, point.value))
                                .foregroundStyle(FJColor.training)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Data", point.date), y: .value(activeMetric.title, point.value))
                                .foregroundStyle(point.isRecord ? FJColor.record : FJColor.training)
                                .symbolSize(point.isRecord ? 120 : 50)
                                .annotation(position: .top) {
                                    if point.isRecord {
                                        Image(systemName: "trophy.fill").font(.caption2).foregroundStyle(FJColor.record)
                                    }
                                }
                        }
                        if let selected {
                            RuleMark(x: .value("Data", selected.date))
                                .foregroundStyle(FJColor.textTertiary)
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartYScale(domain: yDomain(points))
                    .frame(height: 220)
                    .accessibilityLabel(Text("Gráfico de \(activeMetric.title) de \(name)"))
                    .accessibilityValue(Text(chartSummary(points)))
                }
            }
        }
    }

    private func yDomain(_ points: [ProgressCalculator.Point]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if activeMetric.startsAtZero { return 0...max(high * 1.1, 1) }
        let pad = max((high - low) * 0.2, high * 0.05, 0.5)
        return max(0, low - pad)...(high + pad)
    }

    private func chartSummary(_ points: [ProgressCalculator.Point]) -> String {
        guard let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return "" }
        return String(localized: "\(SessionPresentation.sessionsCount(points.count)), de \(FJFormat.number(low, maxFractionDigits: 1)) a \(FJFormat.number(high, maxFractionDigits: 1)) \(activeMetric.unit)")
    }

    // MARK: Melhor série e última vez

    @ViewBuilder
    private func bestCards(_ samples: [ProgressCalculator.Sample]) -> some View {
        if kind == .repsAndLoad || kind == .repsOnly {
            FJCard {
                FJMetricGrid {
                    FJMetricCell("Melhor série", value: bestSetText(samples), systemImage: "trophy.fill", tint: FJColor.record)
                    FJMetricCell("Última vez", value: lastTimeText(samples), systemImage: "clock")
                }
            }
        }
    }

    private func bestSetText(_ samples: [ProgressCalculator.Sample]) -> String? {
        guard let best = ProgressCalculator.bestSet(samples) else { return nil }
        let load = "\(FJFormat.number(best.loadKg)) kg"
        return best.reps.map { "\(load) × \($0)" } ?? load
    }

    private func lastTimeText(_ samples: [ProgressCalculator.Sample]) -> String? {
        guard let last = samples.last else { return nil }
        let relative = last.date.formatted(.relative(presentation: .named))
        if let kg = ProgressCalculator.value(of: last, metric: .load) { return "\(FJFormat.number(kg)) kg · \(relative)" }
        return relative
    }

    // MARK: Sessões

    private func sessionList(_ samples: [ProgressCalculator.Sample]) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            FJSectionHeader("Sessões")
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    ForEach(samples.reversed()) { sample in
                        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                            Text(sample.date.formatted(date: .abbreviated, time: .omitted))
                                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                            Text(ProgressCalculator.sessionLine(sample, kind: kind)).font(FJFont.numberBody)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

#Preview("Evolução") {
    let container = PersistenceController.preview
    let id = (try? container.mainContext.fetch(FetchDescriptor<SessionExercise>()).compactMap(\.exerciseID).first) ?? UUID()
    return NavigationStack { ExerciseProgressView(exerciseID: id) }
        .modelContainer(container)
        .tint(FJColor.training)
}
