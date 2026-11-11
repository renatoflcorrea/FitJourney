import Charts
import SwiftData
import SwiftUI

/// Aba Saúde › Dia (DESIGN §4.11): navegação de dia, FC do dia com treinos, treinos, força x aeróbico,
/// energia, FC em repouso e o resto. Cada métrica respeita o estado da leitura.
struct HealthDayView: View {
    @Bindable var model: HealthDayModel

    @Environment(\.modelContext) private var context
    @Environment(\.healthReader) private var injectedReader
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?
    @Environment(HealthWorkoutController.self) private var controller: HealthWorkoutController?
    @State private var showsCalendar = false
    @State private var reloadToken = 0
    @State private var linkTick = 0

    private var connection: HealthConnectionState { HealthConnectionState(authorization) }
    /// Sem autorização injetada (previews) conta como conectado.
    private var isConnected: Bool { authorization == nil || connection.isConnected }

    var body: some View {
        VStack(spacing: FJSpacing.cardGap) {
            dayNavigator
            switch model.phase {
            case .loading:
                FJCard { FJLoadingState("Lendo dados do Saúde…") }
            case .failed:
                FJBanner("Não foi possível ler o Saúde", message: "Os outros dados do dia continuam disponíveis.", tone: .destructive,
                         systemImage: "exclamationmark.triangle.fill", actionTitle: "Tentar de novo") { reloadToken += 1 }
            case .loaded(let data):
                loaded(data)
            }
        }
        .task(id: LoadKey(date: model.date, token: reloadToken, connected: authorization?.isConnectionEnabled,
                          access: authorization?.access, phase: scenePhase == .active)) {
            await load()
        }
        .fjHaptic(.celebration, trigger: linkTick)
        .sheet(isPresented: $showsCalendar) {
            HealthDayPickerSheet(date: model.date) { model.jump(to: $0) }
        }
    }

    private struct LoadKey: Hashable {
        var date: Date
        var token: Int
        var connected: Bool?
        var access: HealthAuthorization.Access?
        var phase: Bool
    }

    private func load() async {
        let reader: any HealthDataReading = injectedReader ?? HealthQueries.live
        await model.load(reader: reader, context: context, controller: controller)
    }

    // MARK: Navegação

    private var dayNavigator: some View {
        HStack {
            Button { model.shift(by: -1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .accessibilityLabel("Dia anterior")
            Spacer()
            Button { showsCalendar = true } label: {
                Text(model.title)
                    .font(FJFont.cardTitle)
                    .foregroundStyle(FJColor.textPrimary)
                    .frame(minHeight: FJSize.minTap)
            }
            .accessibilityHint("Abre o calendário")
            Spacer()
            Button { model.shift(by: 1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .disabled(model.isToday)
            .accessibilityLabel("Próximo dia")
        }
    }

    @ViewBuilder private func loaded(_ data: HealthDayModel.DayData) -> some View {
        weekStrip(data)
        if !isConnected {
            HealthConnectCard()
        }
        if isConnected { heartRateSection(data) }
        workoutsCard(data)
        strengthAerobicCard(data)
        FJAdaptiveStack(spacing: FJSpacing.cardGap, verticalAlignment: .top) {
            energyCard(data)
            restingCard(data)
        }
        moreCard(data)
    }

    // MARK: Faixa da semana

    private func weekStrip(_ data: HealthDayModel.DayData) -> some View {
        HStack(spacing: 0) {
            ForEach(data.weekDays, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: model.date)
                let isFuture = day > Date()
                Button { model.jump(to: day) } label: {
                    VStack(spacing: FJSpacing.xs) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(FJFont.numberBody.weight(isSelected ? .bold : .regular))
                            .frame(width: 32, height: 32)
                            .background(isSelected ? FJColor.health.opacity(0.18) : Color.clear, in: Circle())
                        Circle()
                            .fill(data.trainingDays.contains(day) ? FJColor.training : Color.clear)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                    .foregroundStyle(isFuture ? FJColor.textTertiary : FJColor.textPrimary)
                }
                .disabled(isFuture)
                .accessibilityLabel(Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))))
                .accessibilityValue(data.trainingDays.contains(day) ? Text("com treino") : Text(""))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: Frequência cardíaca

    @ViewBuilder private func heartRateSection(_ data: HealthDayModel.DayData) -> some View {
        switch data.summary.heartRate {
        case .available(let stats):
            DayHeartRateCard(data: data, stats: stats)
        case .noData:
            if data.hasRecentHeartRate == false {
                FJBanner("Sem dados de frequência cardíaca",
                         message: "A frequência cardíaca vem do Apple Watch ou de um sensor pareado. Se você usa um, confira se o FitJourney pode ler seus dados em Ajustes › Saúde › Acesso a Dados.",
                         tone: .attention, systemImage: "heart.slash.fill", actionTitle: "Abrir Ajustes") { HealthSettings.open(openURL) }
            } else {
                FJCard {
                    HStack(spacing: FJSpacing.m) {
                        Image(systemName: "heart.slash").foregroundStyle(FJColor.textSecondary)
                        Text("Sem leituras neste dia").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .unavailable:
            FJCard {
                Label("Frequência cardíaca indisponível", systemImage: "heart.slash")
                    .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    // MARK: Treinos

    private func workoutsCard(_ data: HealthDayModel.DayData) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                FJSectionHeader("Treinos")
                if data.rows.isEmpty {
                    Text("Nenhum treino neste dia").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        .frame(minHeight: FJSize.minTap, alignment: .leading)
                } else {
                    ForEach(data.rows) { row in
                        WorkoutRowView(row: row, style: row.sessionID.flatMap { data.styles[$0] },
                                       onLink: { link($0, to: $1) },
                                       onNotSame: { model.dismiss(sessionID: $0, workoutID: $1); reloadToken += 1 },
                                       onUndo: { model.unlink(sessionID: $0, workoutID: $1, controller: controller); reloadToken += 1 })
                        if row.id != data.rows.last?.id { Divider() }
                    }
                }
                permissionHint(for: data.summary.healthWorkouts)
            }
        }
    }

    @ViewBuilder private func permissionHint(for status: HealthReadingStatus) -> some View {
        if status == .noData, isConnected {
            Button { HealthSettings.open(openURL) } label: {
                Label("Treinos do Saúde: sem dados · Revisar permissões", systemImage: "gearshape")
                    .font(FJFont.caption)
                    .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
            }
        } else if status == .unavailable, isConnected {
            Text("Treinos do Saúde: indisponível").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
        }
    }

    private func link(_ workoutID: UUID, to sessionID: UUID) {
        model.link(workoutID: workoutID, to: sessionID, controller: controller)
        linkTick += 1
        reloadToken += 1
    }

    // MARK: Força x aeróbico

    private func strengthAerobicCard(_ data: HealthDayModel.DayData) -> some View {
        let todayMinutes = data.summary.minutesByCategory
        let strength = todayMinutes[.strength] ?? 0
        let aerobic = todayMinutes[.aerobic] ?? 0
        let selectedIndex = data.weekDays.firstIndex { Calendar.current.isDate($0, inSameDayAs: data.summary.day.start) }
        let weekTotals = data.weekMinutes.map { $0.values.reduce(0, +) }
        let weekAverage = weekTotals.reduce(0, +) / 7
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Força x aeróbico")
                if strength + aerobic > 0 {
                    StackedMinutesBar(strength: strength, aerobic: aerobic)
                    FJAdaptiveStack {
                        FJMetricCell("Força", value: HealthPresentation.minutes(strength), systemImage: FJWorkoutKind.strength.systemImage,
                                     tint: FJWorkoutKind.strength.color)
                        FJMetricCell("Aeróbico", value: HealthPresentation.minutes(aerobic), systemImage: FJWorkoutKind.aerobic.systemImage,
                                     tint: FJWorkoutKind.aerobic.color)
                    }
                } else {
                    Text("Nenhum treino neste dia").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                WeekMinutesChart(days: data.weekDays, minutes: data.weekMinutes, selectedIndex: selectedIndex, average: weekAverage,
                                 onSelect: { model.jump(to: $0) })
                    .frame(height: 140)
                if weekTotals.reduce(0, +) > 0 {
                    let today = selectedIndex.map { weekTotals[$0] } ?? 0
                    Text("\(model.isToday ? String(localized: "Hoje") : String(localized: "Dia")) \(HealthPresentation.minutes(today)) · média da semana \(HealthPresentation.minutes(weekAverage)) por dia")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                } else {
                    Text("Sem treinos nesta semana").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }

    // MARK: Energia e repouso

    private func energyCard(_ data: HealthDayModel.DayData) -> some View {
        let display = HealthPresentation.display(data.summary.activeEnergyKcal, format: HealthPresentation.wholeNumber)
        let comparison = data.summary.activeEnergyKcal.value.map {
            HealthPresentation.compare(today: $0, previousDays: data.energyPrevious, unit: .kcal, partialDay: data.isToday)
        }
        return MetricTrendCard(title: "Energia ativa", systemImage: "flame.fill", tint: FJColor.training, display: display, unit: "kcal",
                               comparison: comparison, extra: data.energyFromWorkouts.map { "\(HealthPresentation.wholeNumber($0)) kcal em treinos" },
                               series: data.energySeries, style: .bars) { HealthSettings.open(openURL) }
    }

    private func restingCard(_ data: HealthDayModel.DayData) -> some View {
        let display = HealthPresentation.display(data.summary.restingHeartRate, format: HealthPresentation.bpm)
        let comparison = data.summary.restingHeartRate.value.map {
            HealthPresentation.compare(today: $0, previousDays: data.restingPrevious, unit: .bpm)
        }
        return MetricTrendCard(title: "FC em repouso", systemImage: "heart.fill", tint: FJColor.health, display: display, unit: "bpm",
                               comparison: comparison, extra: nil, series: data.restingSeries, style: .line) { HealthSettings.open(openURL) }
    }

    private func moreCard(_ data: HealthDayModel.DayData) -> some View {
        let steps = HealthPresentation.display(data.summary.steps, format: HealthPresentation.wholeNumber)
        let weight = HealthPresentation.display(data.bodyMass) { FJFormat.number($0, maxFractionDigits: 1) }
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Mais")
                FJMetricGrid {
                    FJMetricCell("Passos", value: steps.value, systemImage: "figure.walk", tint: FJColor.health)
                    FJMetricCell("Peso", value: weight.value, unit: "kg", systemImage: "scalemass", tint: FJColor.health)
                }
                if steps.offersPermissionReview || weight.offersPermissionReview {
                    Button { HealthSettings.open(openURL) } label: {
                        Label("Sem dados · Revisar permissões", systemImage: "gearshape")
                            .font(FJFont.caption)
                            .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
                    }
                } else if steps.value == nil || weight.value == nil, steps.note != nil {
                    Text(HealthReadingDisplay.unavailableNote).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }
}

// MARK: - Cartão de FC do dia

private struct DayHeartRateCard: View {
    let data: HealthDayModel.DayData
    let stats: HeartRateStats

    @State private var selection: Date?

    private var buckets: [HeartRateBucket] { data.buckets.value ?? [] }
    private var day: DateInterval { data.summary.day }

    private var selectedBucket: HeartRateBucket? {
        guard let selection else { return nil }
        return buckets.first { $0.interval.contains(selection) }
    }

    private var selectedRow: HealthPresentation.WorkoutRow? {
        guard let selection else { return nil }
        return data.rows.first { $0.interval.contains(selection) }
    }

    private var hoursWithReadings: Int {
        Set(buckets.map { Calendar.current.component(.hour, from: $0.interval.start) }).count
    }

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text(data.isToday ? "FREQUÊNCIA CARDÍACA · ATÉ AGORA" : "FREQUÊNCIA CARDÍACA")
                    .font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                header
                chart.frame(height: 180)
                if hoursWithReadings < 20 {
                    Text("leituras em \(hoursWithReadings) h do dia").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        FJAdaptiveStack(verticalAlignment: .firstTextBaseline) {
            if let bucket = selectedBucket {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                        Text(bucket.interval.start.formatted(.dateTime.hour().minute())).font(FJFont.numberMedium)
                        Text(verbatim: "· \(HealthPresentation.bpm(bucket.minimum))–\(HealthPresentation.bpm(bucket.maximum)) bpm").font(FJFont.numberMedium)
                    }
                    if let row = selectedRow { Text(row.title).font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.xs) {
                    Text(verbatim: HealthPresentation.bpmRange(stats)).font(FJFont.numberHero)
                    Text("bpm").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: FJSpacing.s)
            if let resting = data.summary.restingHeartRate.value {
                Text("Repouso \(HealthPresentation.bpm(resting)) bpm").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let resting = data.summary.restingHeartRate.value
        let upper = max(stats.maximum + 10, 120)
        let lower = max(30, min(stats.minimum - 10, resting ?? 200, 50))
        let chart = Chart {
            ForEach(data.rows) { row in
                let kind = HealthPresentation.kind(row.category)
                RectangleMark(xStart: .value("Início", max(row.interval.start, day.start)), xEnd: .value("Fim", min(row.interval.end, day.end)),
                              yStart: .value("min", lower), yEnd: .value("max", upper))
                    .foregroundStyle((kind?.color ?? FJColor.textSecondary).opacity(0.18))
                    .annotation(position: .overlay, alignment: .top, spacing: 2) {
                        Image(systemName: kind?.systemImage ?? "figure.mixed.cardio")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(kind?.color ?? FJColor.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(FJColor.surface, in: Circle())
                            .accessibilityHidden(true)
                    }
            }
            ForEach(buckets, id: \.interval.start) { bucket in
                RectangleMark(xStart: .value("Início", bucket.interval.start), xEnd: .value("Fim", bucket.interval.end.addingTimeInterval(-20)),
                              yStart: .value("Mínimo", bucket.minimum), yEnd: .value("Máximo", max(bucket.maximum, bucket.minimum + 2)))
                    .foregroundStyle(FJColor.health)
                    .cornerRadius(1.5)
            }
            if let resting {
                RuleMark(y: .value("Repouso", resting))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(FJColor.textSecondary)
                    .annotation(position: .top, alignment: .leading, spacing: 0) {
                        Text("repouso").font(.caption2).foregroundStyle(FJColor.textSecondary)
                    }
            }
            if let selection {
                RuleMark(x: .value("Seleção", selection)).foregroundStyle(FJColor.textSecondary)
            }
        }
        .chartXScale(domain: day.start...day.end)
        .chartYScale(domain: lower...upper)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18].compactMap { Calendar.current.date(byAdding: .hour, value: $0, to: day.start) }) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: "\(Calendar.current.component(.hour, from: date))h").font(.caption2)
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
        return chart.accessibilityChartDescriptor(DayHeartRateDescriptor(buckets: buckets, day: day, stats: stats,
                                                                          resting: resting, workoutCount: data.rows.count))
    }
}

struct DayHeartRateDescriptor: AXChartDescriptorRepresentable {
    let buckets: [HeartRateBucket]
    let day: DateInterval
    let stats: HeartRateStats
    let resting: Double?
    let workoutCount: Int

    func makeChartDescriptor() -> AXChartDescriptor {
        let hours = buckets.map { $0.interval.start.timeIntervalSince(day.start) / 3_600 }
        let values = buckets.map(\.average)
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Hora do dia"), range: 0...24, gridlinePositions: []) { String(format: "%.0f h", $0) }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Batimentos por minuto"),
                                            range: (values.min() ?? 0)...max(values.max() ?? 1, (values.min() ?? 0) + 1),
                                            gridlinePositions: []) { String(format: "%.0f", $0) }
        let series = AXDataSeriesDescriptor(name: String(localized: "Frequência cardíaca"), isContinuous: false,
                                            dataPoints: zip(hours, values).map { AXDataPoint(x: $0, y: $1) })
        var summary = String(localized: "Frequência cardíaca entre \(Int(stats.minimum.rounded())) e \(Int(stats.maximum.rounded()))")
        if let resting { summary += String(localized: ", repouso \(Int(resting.rounded()))") }
        summary += String(localized: "; \(workoutCount) treinos")
        return AXChartDescriptor(title: String(localized: "Frequência cardíaca do dia"), summary: summary, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

// MARK: - Linha de treino

private struct WorkoutRowView: View {
    let row: HealthPresentation.WorkoutRow
    let style: HealthDayModel.RoutineStyle?
    let onLink: (_ workoutID: UUID, _ sessionID: UUID) -> Void
    let onNotSame: (_ sessionID: UUID, _ workoutID: UUID) -> Void
    let onUndo: (_ sessionID: UUID, _ workoutID: UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            main
            if let linked = row.linkedSuggestion?.workout ?? linkedWatch, let sessionID = row.sessionID {
                FJBanner("Vinculado ao treino do Apple Watch (\(range(linked.interval))).",
                         tone: .neutral, systemImage: "link", actionTitle: "Desfazer") { onUndo(sessionID, linked.id) }
            }
            if let suggestion = row.pendingSuggestion {
                PendingSuggestionCard(row: row, suggestion: suggestion,
                                      onLink: { onLink(suggestion.workout.id, suggestion.sessionID) },
                                      onNotSame: { onNotSame(suggestion.sessionID, suggestion.workout.id) })
            }
        }
        .padding(.vertical, FJSpacing.xs)
    }

    /// Treino do Watch já vinculado (sessão com `healthKitWorkoutID`) — para "Desfazer".
    private var linkedWatch: HealthWorkoutRecord? {
        guard row.origin == .appAndWatch, let record = row.workoutRecord, !record.isFromThisApp else { return nil }
        return record
    }

    @ViewBuilder private var main: some View {
        let content = HStack(alignment: .top, spacing: FJSpacing.m) {
            icon
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                HStack(spacing: FJSpacing.s) {
                    Text(row.title).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary).lineLimit(2)
                    kindTag
                }
                Text(verbatim: HealthPresentation.rowDetail(row)).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
                HStack(spacing: FJSpacing.xs) {
                    if row.origin == .appAndWatch { Image(systemName: "link").accessibilityHidden(true) }
                    Text(verbatim: HealthPresentation.originText(row.origin))
                }
                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            Spacer(minLength: 0)
            if canOpen { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(FJColor.textTertiary).accessibilityHidden(true) }
        }
        .frame(minHeight: FJSize.minTap)
        .contentShape(Rectangle())
        if let sessionID = row.sessionID, canOpen {
            NavigationLink(value: HealthRoute.session(sessionID)) { content }.buttonStyle(.plain)
        } else if let record = row.workoutRecord, row.sessionID == nil {
            NavigationLink(value: HealthRoute.external(record)) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var canOpen: Bool {
        if row.sessionID != nil { return style?.isInProgress != true }
        return row.workoutRecord != nil
    }

    @ViewBuilder private var icon: some View {
        if row.sessionID != nil {
            FJRoutineBadge(symbol: style?.symbol ?? "", name: row.title, colorName: style?.colorName ?? "", size: .sm)
        } else {
            let kind = HealthPresentation.kind(row.category)
            Image(systemName: kind?.systemImage ?? "figure.mixed.cardio")
                .font(.body.weight(.semibold))
                .foregroundStyle(kind?.color ?? FJColor.textSecondary)
                .frame(width: 36, height: 36)
                .background(FJColor.fill, in: FJRadius.shape(FJRadius.chip))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var kindTag: some View {
        if let kind = HealthPresentation.kind(row.category) {
            FJTag(kind)
        } else {
            FJTag(LocalizedStringKey(row.category.localizedName), tone: .neutral)
        }
    }

    private func range(_ interval: DateInterval) -> String {
        "\(interval.start.formatted(.dateTime.hour().minute()))–\(interval.end.formatted(.dateTime.hour().minute()))"
    }
}

/// Sugestão incerta: dois treinos que talvez sejam o mesmo (nunca alerta nem notificação).
private struct PendingSuggestionCard: View {
    let row: HealthPresentation.WorkoutRow
    let suggestion: HealthDayEntry.LinkSuggestion
    let onLink: () -> Void
    let onNotSame: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Label("Parece o mesmo treino", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FJColor.textPrimary)
            Text("Mesmo horário do treino \(suggestion.workout.routineName ?? "do FitJourney") · \(Int((suggestion.overlap * 100).rounded())) % em comum")
                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            FJAdaptiveStack(spacing: FJSpacing.s) {
                Button("Vincular", action: onLink).buttonStyle(.fjPrimary(.health, fillsWidth: false))
                Button("Não é o mesmo", action: onNotSame).buttonStyle(.fjSecondary(fillsWidth: false))
            }
        }
        .padding(FJSpacing.l)
        .background(FJTone.attention.soft, in: FJRadius.shape(FJRadius.card))
        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Força x aeróbico

private struct StackedMinutesBar: View {
    let strength: Double
    let aerobic: Double

    var body: some View {
        GeometryReader { geometry in
            let total = max(strength + aerobic, 1)
            HStack(spacing: 2) {
                if strength > 0 { Capsule().fill(FJWorkoutKind.strength.color).frame(width: geometry.size.width * strength / total) }
                if aerobic > 0 { Capsule().fill(FJWorkoutKind.aerobic.color).frame(width: geometry.size.width * aerobic / total) }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

private struct WeekMinutesChart: View {
    let days: [Date]
    let minutes: [[FJWorkoutKind: Double]]
    let selectedIndex: Int?
    let average: Double
    let onSelect: (Date) -> Void

    @State private var tapped: Date?

    private struct Item: Identifiable {
        var id: String { "\(index)-\(kind.rawValue)" }
        var index: Int
        var day: Date
        var kind: FJWorkoutKind
        var minutes: Double
    }

    private var items: [Item] {
        days.enumerated().flatMap { index, day in
            FJWorkoutKind.allCases.compactMap { kind in
                minutes[index][kind].map { Item(index: index, day: day, kind: kind, minutes: $0) }
            }
        }
    }

    var body: some View {
        Chart {
            ForEach(items) { item in
                BarMark(x: .value("Dia", item.day, unit: .day), y: .value("Minutos", item.minutes))
                    .foregroundStyle(by: .value("Tipo", item.kind.rawValue))
                    .opacity(item.index == selectedIndex ? 1 : 0.45)
            }
            if average > 0 {
                RuleMark(y: .value("Média", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
        .chartForegroundStyleScale([FJWorkoutKind.strength.rawValue: FJWorkoutKind.strength.color,
                                    FJWorkoutKind.aerobic.rawValue: FJWorkoutKind.aerobic.color])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: days) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: days[selectedIndex ?? 0]) && selectedIndex != nil
                        Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption.weight(isSelected ? .bold : .regular))
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
        .chartXSelection(value: $tapped)
        .onChange(of: tapped) { _, day in
            guard let day, let match = days.first(where: { Calendar.current.isDate($0, inSameDayAs: day) }), day <= Date() else { return }
            onSelect(match)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Minutos de treino por dia da semana"))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private var spoken: String {
        days.enumerated().map { index, day in
            let total = minutes[index].values.reduce(0, +)
            let label = day.formatted(.dateTime.weekday(.wide))
            return total > 0 ? "\(label) \(HealthPresentation.minutes(total))" : String(localized: "\(label) sem treino")
        }.joined(separator: ", ")
    }
}

// MARK: - Cartão de métrica com minigráfico

private struct MetricTrendCard: View {
    enum Style { case bars, line }

    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let display: HealthReadingDisplay
    let unit: String
    let comparison: HealthPresentation.Comparison?
    let extra: String?
    let series: [Double?]
    let style: Style
    let onReview: () -> Void

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                Label { Text(title).foregroundStyle(FJColor.textSecondary) } icon: { Image(systemName: systemImage).foregroundStyle(tint) }
                    .font(FJFont.caption)
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.xs) {
                    Text(verbatim: display.value ?? "—").font(FJFont.numberLarge)
                        .foregroundStyle(display.value == nil ? FJColor.textSecondary : FJColor.textPrimary)
                    if display.value != nil { Text(verbatim: unit).font(FJFont.unit).foregroundStyle(FJColor.textSecondary) }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                if let note = display.note {
                    Text(note).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    if display.offersPermissionReview {
                        Button("Revisar permissões", action: onReview).font(FJFont.caption)
                    }
                }
                if series.contains(where: { $0 != nil }) {
                    miniChart.frame(height: 44)
                }
                if let comparison {
                    Text(comparison.text).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        .accessibilityLabel(Text(comparison.spokenText))
                }
                if let extra { Text(extra).font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var points: [(index: Int, value: Double)] {
        series.enumerated().compactMap { index, value in value.map { (index, $0) } }
    }

    @ViewBuilder private var miniChart: some View {
        let last = series.count - 1
        Chart {
            ForEach(points, id: \.index) { point in
                switch style {
                case .bars:
                    BarMark(x: .value("Dia", point.index), y: .value("Valor", point.value))
                        .foregroundStyle(tint.opacity(point.index == last ? 1 : 0.45))
                        .cornerRadius(2)
                case .line:
                    LineMark(x: .value("Dia", point.index), y: .value("Valor", point.value)).foregroundStyle(tint.opacity(0.6))
                    PointMark(x: .value("Dia", point.index), y: .value("Valor", point.value))
                        .foregroundStyle(tint.opacity(point.index == last ? 1 : 0.6))
                        .symbolSize(point.index == last ? 40 : 18)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: style == .bars ? 0...(points.map(\.value).max() ?? 1) * 1.1
                     : ((points.map(\.value).min() ?? 0) - 3)...((points.map(\.value).max() ?? 1) + 3))
        .accessibilityHidden(true)
    }
}

// MARK: - Calendário

struct HealthDayPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var date: Date
    let onPick: (Date) -> Void

    init(date: Date, onPick: @escaping (Date) -> Void) {
        _date = State(initialValue: date)
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            DatePicker("Dia", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Ir para o dia")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Ir") { onPick(date); dismiss() } }
                }
        }
        .presentationDetents([.medium])
    }
}
