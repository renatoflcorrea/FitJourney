import SwiftUI

/// Sessão em páginas **horizontais** (a Coroa fica livre para a carga): Controles · Série · Métricas · Ficha.
struct SessionView: View {
    @Environment(WatchSessionModel.self) private var model
    @State private var page: Int

    init(initialPage: Int = 1) { _page = State(initialValue: initialPage) }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ControlsPage().tag(0)
                SeriesPage().tag(1)
                MetricsPage().tag(2)
                SessionRoutinePage().tag(3)
            }
            .tabViewStyle(.page)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SessionClockLabel() }
            }
        }
    }
}

/// Tempo da sessão na toolbar (ou "Descanso" durante o descanso), mais o selo do iPhone.
struct SessionClockLabel: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if let display = model.display {
                    if display.status == .active, display.restRemaining(at: context.date) != nil {
                        Text("Descanso").foregroundStyle(WF.training)
                    } else {
                        Text(WatchFormat.clock(display.elapsed(at: context.date)))
                            .foregroundStyle(display.status == .paused ? WF.attention : WF.training)
                            .accessibilityLabel("Tempo de treino \(WatchFormat.clock(display.elapsed(at: context.date)))")
                    }
                }
                PhoneUnreachableBadge()
            }
            .font(WF.number(15, weight: .semibold))
        }
    }
}

/// Controles (página à esquerda): Pausar/Retomar · Finalizar · Próximo · Pular exercício.
struct ControlsPage: View {
    @Environment(WatchSessionModel.self) private var model
    @State private var finishing = false
    @State private var confirmDiscard = false

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        LazyVGrid(columns: columns, spacing: 6) {
            control(model.isPaused ? "Retomar" : "Pausar", model.isPaused ? "play.fill" : "pause.fill", prominent: true) {
                model.isPaused ? model.resume() : model.pause()
            }
            control("Finalizar", "flag.checkered") {
                if (model.display?.metrics.completedSets ?? 0) == 0 { confirmDiscard = true } else { finishing = true }
            }
            control("Próximo", "forward.end.fill") { model.focusNextExercise() }
            control("Pular", "arrow.uturn.forward", accessibilityLabel: "Pular exercício") {
                if let id = model.display?.currentExerciseID { model.skip(exerciseID: id) }
            }
            if model.canOfferWatchRecording {
                control("Gravar", "applewatch") { model.startRecordingOnWatch() }
                    .accessibilityLabel("Gravar no relógio")
                    .accessibilityHint("Usa a frequência cardíaca e as calorias do relógio neste treino")
            }
        }
        .padding(.horizontal, 4)
        .accessibilityLabel("Controles")
        .sheet(isPresented: $finishing) { FinishView() }
        .confirmationDialog("Descartar treino?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Descartar", role: .destructive) { model.discard() }
            Button("Voltar", role: .cancel) {}
        }
    }

    private func control(_ title: LocalizedStringResource, _ symbol: String, prominent: Bool = false, accessibilityLabel: LocalizedStringResource? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.glass)
        .tint(prominent ? WF.trainingFill : nil)
        .accessibilityLabel(Text(accessibilityLabel ?? title))
    }
}

/// Métricas: tempo, FC/zona, calorias e posição na ficha. Sem leitura = "—" (nunca "0 bpm").
struct MetricsPage: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let display = model.display {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(WatchFormat.clock(display.elapsed(at: context.date)))
                            .font(WF.number(38)).foregroundStyle(WF.training)
                            .accessibilityLabel("Tempo \(WatchFormat.clock(display.elapsed(at: context.date)))")
                    }
                    heartRate
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "flame.fill").foregroundStyle(WF.training).accessibilityHidden(true)
                        Text(model.liveMetrics.activeKilocalories.map { String(Int($0)) } ?? "—").font(WF.number(24, weight: .semibold))
                        Text("kcal").font(.footnote).foregroundStyle(WF.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Text(position(display)).font(.footnote).foregroundStyle(WF.textSecondary)
                    if model.healthAccess == .denied {
                        Text("Sem acesso ao Saúde · ajuste no iPhone").font(.caption2).foregroundStyle(WF.attention)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .accessibilityLabel("Métricas")
    }

    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "heart.fill")
                .foregroundStyle(model.liveMetrics.heartRate == nil ? WF.health.opacity(0.4) : WF.health)
                .accessibilityHidden(true)
            Text(model.liveMetrics.heartRate.map(String.init) ?? "—").font(WF.number(24, weight: .semibold))
            Text("bpm").font(.footnote).foregroundStyle(WF.textSecondary)
            if let zone = model.liveMetrics.heartRateZone {
                Spacer(minLength: 4)
                Label("Z\(zone)", systemImage: "circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(WF.zone(zone))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.liveMetrics.heartRate.map { String(localized: "Frequência cardíaca \($0) batimentos por minuto") } ?? String(localized: "Frequência cardíaca indisponível"))
    }

    private func position(_ display: SessionSnapshot) -> String {
        guard let id = display.currentExerciseID, let index = display.exercises.firstIndex(where: { $0.id == id }) else {
            return String(localized: "\(display.metrics.completedSets) de \(display.metrics.totalSets) séries")
        }
        let exercise = String(localized: "Exercício \(index + 1) de \(display.exercises.count)")
        guard let position = display.currentSetPosition else { return exercise }
        return String(localized: "\(exercise) · série \(position.index) de \(position.of)")
    }
}
