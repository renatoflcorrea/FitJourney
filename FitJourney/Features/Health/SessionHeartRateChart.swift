import Charts
import SwiftData
import SwiftUI

/// Carregamento da FC de uma sessão (amostras + pausas) e análise com as zonas atuais.
@MainActor
@Observable
final class SessionHeartRateModel {
    enum Phase: Equatable { case loading, loaded, noData, unavailable }

    private(set) var phase: Phase = .loading
    private(set) var timeline: HealthSessionTimeline?
    private(set) var samples: [HeartRateSample] = []
    private(set) var pauses: [DateInterval] = []
    private(set) var analysis: SessionHeartRateAnalysis?

    func load(session: WorkoutSession, context: ModelContext, reader: any HealthDataReading, zones: HeartRateZones?) async {
        let timeline = session.healthTimeline(context: context)
        self.timeline = timeline
        phase = .loading
        let interval = timeline.interval()
        do {
            let reading = try await reader.heartRateSamples(in: interval)
            var pauses = timeline.pauses
            if pauses.isEmpty, let workoutID = session.healthKitWorkoutID {
                pauses = try await reader.workoutPauses(workoutID: workoutID).value ?? []
            }
            self.pauses = pauses
            switch reading {
            case .available(let samples):
                self.samples = HeartRateAnalysis.valid(samples)
                phase = .loaded
                reanalyze(zones: zones)
            case .noData:
                samples = []
                analysis = nil
                phase = .noData
            case .unavailable:
                samples = []
                analysis = nil
                phase = .unavailable
            }
        } catch {
            // Cancelamento (a tela saiu): mantém o estado atual.
        }
    }

    func reanalyze(zones: HeartRateZones?) {
        guard var timeline, phase == .loaded else { return }
        timeline.pauses = pauses
        analysis = SessionHeartRateAnalyzer.analyze(timeline, samples: samples, zones: zones, now: timeline.interval().end)
    }

    /// FC da amostra mais próxima de uma data (até 30 s) — posição dos marcadores de série.
    func bpm(near date: Date) -> Double? {
        guard let nearest = samples.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= 30 else { return nil }
        return nearest.bpm
    }
}

/// Gráfico de FC × tempo de uma sessão, com faixas por exercício, marcadores de série, zonas, tempo em
/// cada zona e lista numerada de exercícios (DESIGN §4.11 "Detalhe do treino"). Cada cartão é sólido.
struct SessionHeartRateChart: View {
    let session: WorkoutSession

    init(session: WorkoutSession) {
        self.session = session
    }

    @Environment(\.modelContext) private var context
    @Environment(\.healthReader) private var injectedReader
    @Environment(\.openURL) private var openURL
    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?
    @AppStorage(HealthPresentation.maxHeartRateKey) private var storedMax: Double = 0
    @State private var model = SessionHeartRateModel()
    @State private var selection: Date?
    @State private var selectedExerciseID: UUID?
    @State private var showsConnect = false
    @State private var maxText = ""
    @State private var isEditingMax = false

    private var zones: HeartRateZones? { HealthPresentation.resolveZones(storedMax: storedMax).zones }
    private var connection: HealthConnectionState { HealthConnectionState(authorization) }

    var body: some View {
        VStack(spacing: FJSpacing.cardGap) {
            content
        }
        .task(id: LoadKey(sessionID: session.id, connected: authorization?.isConnectionEnabled, access: authorization?.access)) {
            let reader: any HealthDataReading = injectedReader ?? HealthQueries.live
            await model.load(session: session, context: context, reader: reader, zones: zones)
        }
        .onChange(of: storedMax) { _, _ in model.reanalyze(zones: zones) }
        .navigationDestination(isPresented: $showsConnect) { HealthConnectView() }
    }

    private struct LoadKey: Hashable {
        var sessionID: UUID
        var connected: Bool?
        var access: HealthAuthorization.Access?
    }

    // MARK: Estados

    @ViewBuilder private var content: some View {
        if authorization != nil, !connection.isConnected {
            notConnectedBanner
        } else {
            switch model.phase {
            case .loading:
                FJCard { FJLoadingState("Lendo dados do Saúde…") }
            case .unavailable:
                FJBanner("Não foi possível ler o Saúde", message: "Tente de novo em instantes.", tone: .destructive,
                         systemImage: "exclamationmark.triangle.fill", actionTitle: "Tentar de novo") { reload() }
            case .noData:
                FJBanner("Sem frequência cardíaca neste treino",
                         message: "A frequência cardíaca vem do Apple Watch ou de um sensor pareado. Se você usou um, confira se o FitJourney pode ler seus dados em Ajustes › Saúde › Acesso a Dados.",
                         tone: .neutral, systemImage: "heart.slash", actionTitle: "Abrir Ajustes") { HealthSettings.open(openURL) }
            case .loaded:
                if let analysis = model.analysis, let timeline = model.timeline {
                    chartCard(analysis, timeline)
                    zoneSection(analysis)
                    exerciseList(analysis, timeline)
                }
            }
        }
    }

    private var notConnectedBanner: some View {
        FJBanner("Frequência cardíaca indisponível",
                 message: "Conecte ao Saúde para ver a frequência cardíaca de cada exercício. Seus treinos continuam sendo registrados.",
                 tone: .attention, systemImage: "heart.slash.fill", actionTitle: "Conectar ao Saúde") { showsConnect = true }
    }

    private func reload() {
        let reader: any HealthDataReading = injectedReader ?? HealthQueries.live
        Task { await model.load(session: session, context: context, reader: reader, zones: zones) }
    }

    // MARK: Gráfico

    private func chartCard(_ analysis: SessionHeartRateAnalysis, _ timeline: HealthSessionTimeline) -> some View {
        let bands = HealthPresentation.bands(timeline)
        let numbers = Dictionary(uniqueKeysWithValues: bands.map { ($0.id, $0.number) })
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                header(analysis, numbers: numbers)
                HeartRateChartBody(model: model, analysis: analysis, bands: bands, selection: $selection,
                                   highlighted: selectedExerciseID)
                    .frame(height: 240)
                    .accessibilityChartDescriptor(HeartRateChartDescriptor(samples: model.samples, start: analysis.interval.start))
                if analysis.zones == nil { Text("Sem as zonas: defina a FC máxima abaixo.").font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
            }
        }
    }

    private func header(_ analysis: SessionHeartRateAnalysis, numbers: [UUID: Int]) -> some View {
        let heading: String
        var stats = analysis.overall
        var title = String(localized: "Treino inteiro")
        if let selection {
            if let found = analysis.lookup(at: selection) {
                title = HealthPresentation.selectionTitle(number: numbers[found.exercise.exerciseID], exercise: found.exercise.name,
                                                          setNumber: found.set?.number, stats: nil)
                stats = found.set?.stats ?? found.exercise.stats
            } else {
                title = (selection.timeIntervalSince(analysis.interval.start) / 60).formatted(.number.precision(.fractionLength(0)))
                title = String(localized: "min \(title)")
            }
        } else if let id = selectedExerciseID, let exercise = analysis.exercises.first(where: { $0.exerciseID == id }) {
            title = HealthPresentation.selectionTitle(number: numbers[id], exercise: exercise.name, setNumber: nil, stats: nil)
            stats = exercise.stats
        }
        heading = title
        return VStack(alignment: .leading, spacing: FJSpacing.xs) {
            Text(verbatim: heading)
                .font(FJFont.overline)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                if let stats {
                    Text(verbatim: HealthPresentation.bpm(stats.average)).font(FJFont.numberLarge)
                    Text("média").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                    Text(verbatim: "· " + HealthPresentation.bpm(stats.maximum)).font(FJFont.numberLarge)
                    Text("máx bpm").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                } else {
                    Text(verbatim: "—").font(FJFont.numberLarge).foregroundStyle(FJColor.textSecondary)
                    Text("Sem leituras neste trecho").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: summaryText(title: heading, stats: stats)))
    }

    private func summaryText(title: String, stats: HeartRateStats?) -> String {
        guard let stats else { return title + ". " + String(localized: "Sem leituras neste trecho") }
        return title + ". " + String(localized: "Frequência cardíaca média \(HealthPresentation.bpm(stats.average)), máxima \(HealthPresentation.bpm(stats.maximum)) batimentos por minuto")
    }

    // MARK: Zonas

    @ViewBuilder private func zoneSection(_ analysis: SessionHeartRateAnalysis) -> some View {
        if let durations = analysis.timeInZones {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    FJSectionHeader("Tempo em cada zona")
                    ForEach(HeartRateZone.allCases.reversed(), id: \.self) { zone in
                        ZoneDurationRow(zone: zone, duration: durations.duration(in: zone), fraction: durations.fraction(in: zone))
                    }
                    if durations.belowZones > 0 {
                        Text("Abaixo da zona 1: \(HealthPresentation.minutes(seconds: durations.belowZones))")
                            .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    }
                    maxHeartRateFooter
                }
            }
        } else {
            maxHeartRateInvite
        }
    }

    private var maxHeartRateFooter: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            if let resolved = HealthPresentation.resolveZones(storedMax: storedMax).zones {
                HStack {
                    Text("FC máxima \(HealthPresentation.bpm(resolved.maxHeartRate)) bpm")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    Spacer()
                    Button("Alterar") { isEditingMax.toggle() }.font(FJFont.caption)
                }
                if isEditingMax { maxField }
            }
        }
    }

    private var maxHeartRateInvite: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Defina sua FC máxima", subtitle: "As zonas de frequência cardíaca usam a sua FC máxima.")
                maxField
                Text("Em Ajustes você também poderá informar a idade para estimar a FC máxima.")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    private var maxField: some View {
        HStack(spacing: FJSpacing.s) {
            TextField("FC máxima (bpm)", text: $maxText)
                .keyboardType(.numberPad)
                .padding(FJSpacing.m)
                .frame(minHeight: FJSize.minTap)
                .background(FJColor.fill, in: FJRadius.shape(FJRadius.field))
            Button("Salvar") { saveMax() }
                .buttonStyle(.fjSecondary(fillsWidth: false))
                .disabled(parsedMax == nil)
        }
    }

    private var parsedMax: Double? {
        guard let value = Double(maxText.trimmingCharacters(in: .whitespaces)),
              HeartRateZones.validMaxHeartRate.contains(value) else { return nil }
        return value
    }

    private func saveMax() {
        guard let value = parsedMax else { return }
        storedMax = value
        isEditingMax = false
        maxText = ""
    }

    // MARK: Exercícios

    private func exerciseList(_ analysis: SessionHeartRateAnalysis, _ timeline: HealthSessionTimeline) -> some View {
        FJCard(padding: FJSpacing.l) {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                FJSectionHeader("Frequência cardíaca por exercício")
                ForEach(Array(timeline.exercises.enumerated()), id: \.element.id) { offset, exercise in
                    let result = analysis.exercises.first { $0.exerciseID == exercise.id }
                    let isSelected = selectedExerciseID == exercise.id
                    Button {
                        selection = nil
                        selectedExerciseID = isSelected ? nil : (result == nil ? nil : exercise.id)
                    } label: {
                        ExerciseHeartRateRow(number: offset + 1, name: exercise.name, result: result, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .disabled(result == nil)
                }
            }
        }
    }
}

// MARK: - Corpo do gráfico

private struct HeartRateChartBody: View {
    let model: SessionHeartRateModel
    let analysis: SessionHeartRateAnalysis
    let bands: [HealthPresentation.ExerciseBand]
    @Binding var selection: Date?
    let highlighted: UUID?

    private var interval: DateInterval { analysis.interval }
    private var isScrollable: Bool { interval.duration > 90 * 60 }
    private var visibleSeconds: TimeInterval { isScrollable ? 3_600 : interval.duration }

    private var yDomain: ClosedRange<Double> {
        let values = model.samples.map(\.bpm)
        var low = (values.min() ?? 60) - 10
        var high = (values.max() ?? 180) + 10
        if let zones = analysis.zones { high = max(high, zones.range(for: .zone5).lowerBound + 10) }
        low = (low / 10).rounded(.down) * 10
        high = (high / 10).rounded(.up) * 10
        return max(30, low)...max(high, low + 40)
    }

    private var zoneLines: [(zone: HeartRateZone, bpm: Double)] {
        analysis.zones.map(HealthPresentation.zoneLines) ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            chart(plotWidth: geometry.size.width - 44)
        }
    }

    private func chart(plotWidth: CGFloat) -> some View {
        let domain = yDomain
        let chart = Chart {
            ForEach(Array(model.pauses.enumerated()), id: \.offset) { _, pause in
                RectangleMark(xStart: .value("Pausa", pause.start), xEnd: .value("Retomada", pause.end),
                              yStart: .value("min", domain.lowerBound), yEnd: .value("max", domain.upperBound))
                    .foregroundStyle(FJColor.fillStrong)
                    .annotation(position: .overlay, alignment: .top, spacing: 2) {
                        Image(systemName: "pause.fill").font(.caption2).foregroundStyle(FJColor.textSecondary)
                            .accessibilityLabel(Text("Pausa"))
                    }
            }
            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                RectangleMark(xStart: .value("Início", band.interval.start), xEnd: .value("Fim", band.interval.end),
                              yStart: .value("min", domain.lowerBound), yEnd: .value("max", domain.upperBound))
                    .foregroundStyle(bandFill(index: index, band: band))
                    .annotation(position: .overlay, alignment: .top, spacing: 2) {
                        if HealthPresentation.showsBandLabel(band: band.interval, total: interval, plotWidth: plotWidth,
                                                             visibleSeconds: visibleSeconds) {
                            Text(verbatim: "\(band.number)")
                                .font(FJFont.numberCaption.weight(.bold))
                                .foregroundStyle(FJColor.textPrimary)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(FJColor.fillStrong, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
            }
            ForEach(Array(HealthPresentation.segments(model.samples).enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.date) { sample in
                    LineMark(x: .value("Tempo", sample.date), y: .value("bpm", sample.bpm),
                             series: .value("Trecho", index))
                        .foregroundStyle(FJColor.health)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
            ForEach(analysis.exercises) { exercise in
                ForEach(exercise.sets) { set in
                    if let bpm = model.bpm(near: set.completedAt) {
                        PointMark(x: .value("Série", set.completedAt), y: .value("bpm", bpm))
                            .symbolSize(36)
                            .foregroundStyle(FJColor.textPrimary)
                    }
                }
            }
            if let selection {
                RuleMark(x: .value("Seleção", selection))
                    .foregroundStyle(FJColor.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: interval.start...interval.end)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: strideMinutes)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: "\(Int(date.timeIntervalSince(interval.start) / 60)) min").font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            if zoneLines.isEmpty {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
            } else {
                AxisMarks(position: .trailing, values: zoneLines.map(\.bpm)) { value in
                    if let bpm = value.as(Double.self), let line = zoneLines.first(where: { $0.bpm == bpm }) {
                        let color = HealthPresentation.designZone(line.zone).color
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(color.opacity(0.7))
                        AxisValueLabel {
                            Text(verbatim: HealthPresentation.designZone(line.zone).shortLabel)
                                .font(.caption2.weight(.semibold)).foregroundStyle(color)
                        }
                    }
                }
            }
        }
        return Group {
            if isScrollable {
                chart.chartScrollableAxes(.horizontal).chartXVisibleDomain(length: 3_600)
            } else {
                chart
            }
        }
    }

    private var strideMinutes: Int {
        let minutes = visibleSeconds / 60
        if minutes > 120 { return 30 }
        if minutes > 60 { return 15 }
        return minutes > 20 ? 10 : 5
    }

    /// Dois tons neutros alternados (fill e transparente); a faixa escolhida na lista ganha mais corpo.
    private func bandFill(index: Int, band: HealthPresentation.ExerciseBand) -> Color {
        if band.id == highlighted { return FJColor.fillStrong }
        return index.isMultiple(of: 2) ? FJColor.fill : Color.clear
    }
}

// MARK: - Linhas

private struct ZoneDurationRow: View {
    let zone: HeartRateZone
    let duration: TimeInterval
    let fraction: Double

    var body: some View {
        let design = HealthPresentation.designZone(zone)
        FJAdaptiveStack(spacing: FJSpacing.s) {
            FJHeartRateZoneBadge(design, showsName: false)
                .frame(minWidth: 56, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(FJColor.fill)
                    Capsule().fill(design.color).frame(width: max(fraction > 0 ? 4 : 0, geometry.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text(verbatim: duration > 0 ? "\(HealthPresentation.minutes(seconds: duration)) · \(Int((fraction * 100).rounded()))%" : "—")
                .font(FJFont.numberCaption)
                .foregroundStyle(FJColor.textSecondary)
                .frame(minWidth: 84, alignment: .trailing)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zona \(zone.rawValue)"))
        .accessibilityValue(duration > 0
            ? Text("\(HealthPresentation.minutes(seconds: duration)), \(Int((fraction * 100).rounded())) por cento")
            : Text("Sem tempo nesta zona"))
    }
}

private struct ExerciseHeartRateRow: View {
    let number: Int
    let name: String
    let result: ExerciseHeartRate?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Text(verbatim: "\(number)")
                .font(FJFont.numberCaption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(isSelected ? FJColor.fillStrong : FJColor.fill, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(name).font(FJFont.body).foregroundStyle(FJColor.textPrimary)
                Text(verbatim: summary).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
                if let sets = setsText {
                    Text(verbatim: sets).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, FJSpacing.xs)
        .frame(minHeight: FJSize.minTap, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var summary: String {
        guard let result else { return String(localized: "pulado") }
        guard let stats = result.stats else { return String(localized: "Sem leituras") }
        return String(localized: "média \(HealthPresentation.bpm(stats.average)) · máx \(HealthPresentation.bpm(stats.maximum)) bpm")
    }

    /// "série 1 · 128  série 2 · 135" — FC média de cada série (só as que têm leitura).
    private var setsText: String? {
        guard let result else { return nil }
        let parts = result.sets.compactMap { set in
            set.stats.map { String(localized: "série \(set.number) · \(HealthPresentation.bpm($0.average))") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}

// MARK: - Acessibilidade

/// Descritor para o VoiceOver: FC (bpm) ao longo do tempo (minutos), em até 60 pontos.
struct HeartRateChartDescriptor: AXChartDescriptorRepresentable {
    let samples: [HeartRateSample]
    let start: Date

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = HealthPresentation.downsample(samples, to: 60)
        let minutes = points.map { $0.date.timeIntervalSince(start) / 60 }
        let values = points.map(\.bpm)
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Tempo (min)"), range: 0...max(1, minutes.max() ?? 1),
                                            gridlinePositions: []) { String(format: "%.0f", $0) }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Batimentos por minuto"),
                                            range: (values.min() ?? 0)...max((values.max() ?? 1), (values.min() ?? 0) + 1),
                                            gridlinePositions: []) { String(format: "%.0f", $0) }
        let series = AXDataSeriesDescriptor(name: String(localized: "Frequência cardíaca"), isContinuous: true,
                                            dataPoints: zip(minutes, values).map { AXDataPoint(x: $0, y: $1) })
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return AXChartDescriptor(
            title: String(localized: "Frequência cardíaca durante o treino"),
            summary: values.isEmpty ? nil : String(localized: "Média \(Int(average.rounded())), máxima \(Int((values.max() ?? 0).rounded())) batimentos por minuto"),
            xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

// MARK: - Preview

#Preview("FC da sessão") {
    let container = PersistenceController.preview
    let session = try? SessionStore(context: container.mainContext).completedSessions(limit: 1).first
    return NavigationStack {
        ScrollView {
            if let session {
                SessionHeartRateChart(session: session)
                    .padding(FJSpacing.screenMargin)
                    .healthReader(HealthPreviewFixtures.reader(for: session, context: container.mainContext))
            }
        }
        .fjScreenBackground()
    }
    .modelContainer(container)
    .environment(HealthPreviewFixtures.connectedAuthorization(suite: "preview-chart"))
    .tint(FJColor.health)
}
