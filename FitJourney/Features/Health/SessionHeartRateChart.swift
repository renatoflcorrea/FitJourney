import Charts
import SwiftData
import SwiftUI

/// Carregamento da FC de uma sessão (amostras + pausas) e análise com as zonas atuais. Tudo o que o
/// gráfico desenha (segmentos, marcadores, eixo Y, faixas) é pré-calculado aqui, uma vez por análise.
@MainActor
@Observable
final class SessionHeartRateModel {
    enum Phase: Equatable { case loading, loaded, noData, unavailable }

    struct SetMarker: Identifiable, Equatable {
        var id: UUID
        var date: Date
        var bpm: Double
    }

    /// Limite de pontos desenhados (a análise usa todas as amostras).
    static let drawLimit = 2_000

    private(set) var phase: Phase = .loading
    private(set) var timeline: HealthSessionTimeline?
    private(set) var samples: [HeartRateSample] = []
    private(set) var pauses: [DateInterval] = []
    private(set) var analysis: SessionHeartRateAnalysis?
    private(set) var bands: [HealthPresentation.ExerciseBand] = []
    private(set) var segments: [[HeartRateSample]] = []
    private(set) var setMarkers: [SetMarker] = []
    private(set) var yDomain: ClosedRange<Double> = 40...200

    func load(session: WorkoutSession, context: ModelContext, reader: any HealthDataReading, zones: HeartRateZones?) async {
        let timeline = session.healthTimeline(context: context)
        self.timeline = timeline
        bands = HealthPresentation.bands(timeline)
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
                segments = HealthPresentation.segments(HealthPresentation.downsample(self.samples, to: Self.drawLimit))
                phase = .loaded
                reanalyze(zones: zones)
            case .noData:
                clear(.noData)
            case .unavailable:
                clear(.unavailable)
            }
        } catch {
            // Cancelamento (a tela saiu): mantém o estado atual.
        }
    }

    private func clear(_ phase: Phase) {
        samples = []
        segments = []
        setMarkers = []
        analysis = nil
        self.phase = phase
    }

    func reanalyze(zones: HeartRateZones?) {
        guard var timeline, phase == .loaded else { return }
        timeline.pauses = pauses
        let analysis = SessionHeartRateAnalyzer.analyze(timeline, samples: samples, zones: zones, now: timeline.interval().end)
        self.analysis = analysis
        setMarkers = analysis.exercises.flatMap(\.sets).compactMap { set in
            bpm(near: set.completedAt).map { SetMarker(id: set.setID, date: set.completedAt, bpm: $0) }
        }
        var low = (samples.map(\.bpm).min() ?? 60) - 10
        var high = (samples.map(\.bpm).max() ?? 180) + 10
        if let zones { high = max(high, zones.range(for: .zone5).lowerBound + 10) }
        low = max(30, (low / 10).rounded(.down) * 10)
        high = max((high / 10).rounded(.up) * 10, low + 40)
        yDomain = low...high
    }

    /// FC da amostra mais próxima de uma data (até 30 s), por busca binária.
    func bpm(near date: Date) -> Double? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { samples.indices.contains($0) }.map { samples[$0] }
        guard let nearest = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
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
                         message: "A frequência cardíaca vem do Apple Watch ou de um sensor pareado. Se você usou um, confira se o FitRoute pode ler seus dados em Ajustes › Saúde › Acesso a Dados.",
                         tone: .neutral, systemImage: "heart.slash", actionTitle: "Abrir Ajustes") { HealthSettings.open(openURL) }
            case .loaded:
                if let analysis = model.analysis, let timeline = model.timeline {
                    chartCard(analysis)
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

    private func chartCard(_ analysis: SessionHeartRateAnalysis) -> some View {
        FJCard {
            HeartRateChartCard(model: model, analysis: analysis, highlighted: selectedExerciseID, clearHighlight: { selectedExerciseID = nil })
        }
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
                        ExerciseHeartRateRow(number: offset + 1, name: exercise.name.exerciseDisplayName, result: result, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .disabled(result == nil)
                }
            }
        }
    }
}

// MARK: - Cartão do gráfico (a seleção vive aqui para não reavaliar a tela inteira)

private struct HeartRateChartCard: View {
    let model: SessionHeartRateModel
    let analysis: SessionHeartRateAnalysis
    let highlighted: UUID?
    let clearHighlight: () -> Void

    @State private var selection: Date?

    private enum HeaderValue {
        case stats(HeartRateStats), point(Double), none
    }

    private var numbers: [UUID: Int] { Dictionary(uniqueKeysWithValues: model.bands.map { ($0.id, $0.number) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            header
            HeartRateChartBody(model: model, analysis: analysis, selection: $selection, highlighted: highlighted)
                .frame(height: 240)
                .accessibilityChartDescriptor(HeartRateChartDescriptor(samples: model.samples, start: analysis.interval.start))
            if analysis.zones == nil {
                Text("Sem as zonas: defina a FC máxima abaixo.").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        }
        .onChange(of: selection) { _, new in if new != nil { clearHighlight() } }
    }

    private var content: (title: String, value: HeaderValue) {
        if let selection {
            if let found = analysis.lookup(at: selection) {
                let title = HealthPresentation.selectionTitle(number: numbers[found.exercise.exerciseID], exercise: found.exercise.name.exerciseDisplayName,
                                                              setNumber: found.set?.number, stats: nil)
                let stats = found.set?.stats ?? found.exercise.stats
                return (title, stats.map { .stats($0) } ?? .none)
            }
            // Fora de qualquer série/exercício: só o ponto mais próximo, nunca a média geral.
            let minute = Int(selection.timeIntervalSince(analysis.interval.start) / 60)
            return (String(localized: "min \(minute)"), model.bpm(near: selection).map { .point($0) } ?? .none)
        }
        if let id = highlighted, let exercise = analysis.exercises.first(where: { $0.exerciseID == id }) {
            let title = HealthPresentation.selectionTitle(number: numbers[id], exercise: exercise.name.exerciseDisplayName, setNumber: nil, stats: nil)
            return (title, exercise.stats.map { .stats($0) } ?? .none)
        }
        return (String(localized: "Treino inteiro"), analysis.overall.map { .stats($0) } ?? .none)
    }

    private var header: some View {
        let content = content
        return VStack(alignment: .leading, spacing: FJSpacing.xs) {
            Text(verbatim: content.title)
                .font(FJFont.overline)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                switch content.value {
                case .stats(let stats):
                    Text(verbatim: HealthPresentation.bpm(stats.average)).font(FJFont.numberLarge)
                    Text("média").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                    Text(verbatim: "· " + HealthPresentation.bpm(stats.maximum)).font(FJFont.numberLarge)
                    Text("máx bpm").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                case .point(let bpm):
                    Text(verbatim: HealthPresentation.bpm(bpm)).font(FJFont.numberLarge)
                    Text("bpm").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                case .none:
                    Text(verbatim: "—").font(FJFont.numberLarge).foregroundStyle(FJColor.textSecondary)
                    Text("Sem leituras neste trecho").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: spoken(content)))
    }

    private func spoken(_ content: (title: String, value: HeaderValue)) -> String {
        switch content.value {
        case .stats(let stats):
            content.title + ". " + String(localized: "Frequência cardíaca média \(HealthPresentation.bpm(stats.average)), máxima \(HealthPresentation.bpm(stats.maximum)) batimentos por minuto")
        case .point(let bpm):
            content.title + ". " + String(localized: "\(HealthPresentation.bpm(bpm)) batimentos por minuto")
        case .none:
            content.title + ". " + String(localized: "Sem leituras neste trecho")
        }
    }
}

// MARK: - Corpo do gráfico

private struct HeartRateChartBody: View {
    let model: SessionHeartRateModel
    let analysis: SessionHeartRateAnalysis
    @Binding var selection: Date?
    let highlighted: UUID?

    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = 16

    private var interval: DateInterval { analysis.interval }
    private var isScrollable: Bool { interval.duration > 90 * 60 }
    private var visibleSeconds: TimeInterval { isScrollable ? 3_600 : interval.duration }

    private var zoneLines: [(zone: HeartRateZone, bpm: Double)] {
        analysis.zones.map(HealthPresentation.zoneLines) ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            chart(plotWidth: geometry.size.width - 44)
        }
    }

    private func chart(plotWidth: CGFloat) -> some View {
        let domain = model.yDomain
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
            ForEach(Array(model.bands.enumerated()), id: \.offset) { index, band in
                RectangleMark(xStart: .value("Início", band.interval.start), xEnd: .value("Fim", band.interval.end),
                              yStart: .value("min", domain.lowerBound), yEnd: .value("max", domain.upperBound))
                    .foregroundStyle(bandFill(index: index, band: band))
                    .annotation(position: .overlay, alignment: .top, spacing: 2) {
                        if HealthPresentation.showsBandLabel(band: band.interval, total: interval, plotWidth: plotWidth,
                                                             visibleSeconds: visibleSeconds) {
                            Text(verbatim: "\(band.number)")
                                .font(FJFont.numberCaption.weight(.bold))
                                .foregroundStyle(FJColor.textPrimary)
                                .frame(minWidth: badge, minHeight: badge)
                                .background(FJColor.fillStrong, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
            }
            ForEach(Array(model.segments.enumerated()), id: \.offset) { index, segment in
                ForEach(Array(segment.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Tempo", sample.date), y: .value("bpm", sample.bpm), series: .value("Trecho", index))
                        .foregroundStyle(FJColor.health)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
            ForEach(model.setMarkers) { marker in
                PointMark(x: .value("Série", marker.date), y: .value("bpm", marker.bpm))
                    .symbolSize(36)
                    .foregroundStyle(FJColor.textPrimary)
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
                // Abre no fim do treino, mostrando a última hora.
                chart.chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 3_600)
                    .chartScrollPosition(initialX: interval.end.addingTimeInterval(-3_600))
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

    @ScaledMetric(relativeTo: .footnote) private var circle: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Text(verbatim: "\(number)")
                .font(FJFont.numberCaption.weight(.bold))
                .frame(width: circle, height: circle)
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
                                            gridlinePositions: []) { $0.formatted(.number.precision(.fractionLength(0))) }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Batimentos por minuto"),
                                            range: (values.min() ?? 0)...max((values.max() ?? 1), (values.min() ?? 0) + 1),
                                            gridlinePositions: []) { $0.formatted(.number.precision(.fractionLength(0))) }
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

#if DEBUG
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
#endif
