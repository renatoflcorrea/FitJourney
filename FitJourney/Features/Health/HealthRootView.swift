import SwiftData
import SwiftUI

/// Destinos empurrados a partir da aba Saúde.
enum HealthRoute: Hashable {
    case session(UUID)
    case external(HealthWorkoutRecord)
    case connect
}

/// Aba Saúde (SPEC §6.3, DESIGN §4.11): Dia | Tendências. Tem `NavigationStack` próprio.
/// Lê o Saúde pelo `HealthDataReading` do ambiente (`\.healthReader`, padrão `HealthQueries.live`) e usa
/// `HealthAuthorization`/`HealthWorkoutController` do ambiente quando existem.
struct HealthRootView: View {
    init() {}

    enum Tab: String, CaseIterable, Identifiable {
        case day, trends
        var id: String { rawValue }
    }

    @State private var tab: Tab = .day
    @State private var dayModel = HealthDayModel()
    @State private var trendsModel = HealthTrendsModel()
    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FJSpacing.cardGap) {
                    Picker("Visão", selection: $tab) {
                        Text("Dia").tag(Tab.day)
                        Text("Tendências").tag(Tab.trends)
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .day: HealthDayView(model: dayModel)
                    case .trends: HealthTrendsView(model: trendsModel)
                    }
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.bottom, FJSpacing.xl)
            }
            .fjScreenBackground()
            .navigationTitle("Saúde")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: HealthRoute.connect) {
                        Image(systemName: "heart.text.square")
                    }
                    .accessibilityLabel(Text("Conexão com o Saúde"))
                }
            }
            .navigationDestination(for: HealthRoute.self) { route in
                switch route {
                case .session(let id): HealthSessionLoader(sessionID: id)
                case .external(let record): HealthExternalWorkoutView(record: record)
                case .connect: HealthConnectView()
                }
            }
            .task { await authorization?.refresh() }
        }
        .tint(FJColor.health)
    }
}

/// Abre o detalhe do histórico de uma sessão pelo ID (a linha do dia só guarda o ID).
private struct HealthSessionLoader: View {
    let sessionID: UUID
    @Environment(\.modelContext) private var context

    var body: some View {
        let id = sessionID
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        if let session = (try? context.fetch(descriptor))?.first {
            WorkoutDetailView(session: session)
        } else {
            FJEmptyState("Treino não encontrado", systemImage: "questionmark.folder")
        }
    }
}

/// Detalhe simples de um treino de fora (Apple Watch, outros apps): tipo, duração, FC média/máx, energia.
struct HealthExternalWorkoutView: View {
    let record: HealthWorkoutRecord

    @Environment(\.healthReader) private var injectedReader
    @State private var stats: HealthReading<HeartRateStats> = .noData
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: FJSpacing.cardGap) {
                FJCard {
                    VStack(alignment: .leading, spacing: FJSpacing.m) {
                        HStack(spacing: FJSpacing.s) {
                            if let kind = HealthPresentation.kind(record.category) { FJTag(kind) }
                            else { FJTag(LocalizedStringKey(record.category.localizedName), tone: .neutral) }
                            Text(verbatim: record.sourceName).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                        Text(record.start.formatted(date: .complete, time: .shortened))
                            .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        FJMetricGrid {
                            FJMetricCell("Duração", value: HealthPresentation.minutes(seconds: record.duration), systemImage: "clock")
                            FJMetricCell("FC média", value: (record.averageHeartRate ?? stats.value?.average).map(HealthPresentation.bpm),
                                         unit: "bpm", systemImage: "heart.fill", tint: FJColor.health)
                            FJMetricCell("FC máx", value: stats.value.map { HealthPresentation.bpm($0.maximum) }, unit: "bpm",
                                         systemImage: "heart.fill", tint: FJColor.health)
                            FJMetricCell("Energia", value: record.activeEnergyKcal.map(HealthPresentation.wholeNumber), unit: "kcal",
                                         systemImage: "flame.fill", tint: FJColor.training)
                        }
                    }
                }
                if !isLoading, record.averageHeartRate == nil, stats.value == nil {
                    FJBanner("Sem frequência cardíaca neste treino", tone: .neutral, systemImage: "heart.slash")
                }
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.vertical, FJSpacing.s)
        }
        .fjScreenBackground()
        .navigationTitle(record.workoutType?.localizedName ?? record.category.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let reader: any HealthDataReading = injectedReader ?? HealthQueries.live
            do {
                let samples = try await reader.heartRateSamples(in: record.interval)
                stats = samples.map { HeartRateAnalysis.stats($0) }.flattenedStats
            } catch {
                // Só `CancellationError` chega aqui (a tela saiu): não marca como carregado.
                return
            }
            isLoading = false
        }
    }
}

private extension HealthReading where Value == HeartRateStats? {
    var flattenedStats: HealthReading<HeartRateStats> {
        switch self {
        case .available(let value): value.map { .available($0) } ?? .noData
        case .noData: .noData
        case .unavailable: .unavailable
        }
    }
}

#if DEBUG
#Preview("Saúde — dia") {
    let container = PersistenceController.preview
    let now = Date()
    let start = Calendar.current.date(bySettingHour: 18, minute: 5, second: 0, of: now) ?? now
    let watch = HealthSampleData.record(start: start.addingTimeInterval(-3_600 * 6), minutes: 31)
    let reader = FakeHealthReader(
        buckets: .available(HealthSampleData.dayBuckets(day: now, workouts: [watch.interval], upTo: now)),
        workouts: .available([watch]), energy: .available(512), stepCount: .available(6_420),
        resting: .available((0..<8).map { HealthDailyValue(day: Calendar.current.startOfDay(for: now.addingTimeInterval(Double(-$0) * 86_400)), value: 56 + Double($0 % 3)) }),
        bodyMass: .available(78.4))
    return HealthRootView()
        .healthReader(reader)
        .modelContainer(container)
        .environment(HealthPreviewFixtures.connectedAuthorization(suite: "preview-day"))
}
#endif
