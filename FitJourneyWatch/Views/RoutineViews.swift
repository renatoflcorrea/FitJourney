import SwiftUI

/// Treinos (raiz): ficha do dia em destaque + demais fichas (DESIGN §9.4).
struct RoutineListView: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        Group {
            if !model.hasReceivedData && model.digest == nil {
                WatchEmptyState(symbol: "iphone.and.arrow.forward", title: "Abra o FitJourney no iPhone",
                                message: "para trazer seus treinos")
            } else if let digest = model.digest, !digest.routines.isEmpty {
                list(digest)
            } else {
                WatchEmptyState(symbol: "list.bullet.clipboard", title: "Nenhum programa ativo",
                                message: "Crie ou ative um no iPhone.")
            }
        }
        .navigationTitle("Treinos")
        .toolbar { ToolbarItem(placement: .topBarLeading) { PhoneUnreachableBadge() } }
    }

    private func list(_ digest: ProgramDigest) -> some View {
        List {
            if digest.suggestedRoutineIDs.isEmpty && digest.scheduleMode == "weekly" {
                Label("Descanso hoje", systemImage: "moon.zzz")
                    .font(.subheadline).foregroundStyle(WF.textSecondary)
                    .listRowBackground(Color.clear)
            }
            if let highlighted = model.suggestedRoutine {
                NavigationLink(value: highlighted.id) {
                    RoutineRow(routine: highlighted, overline: overline(for: digest.scheduleMode), highlighted: true)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            ForEach(model.otherRoutines) { routine in
                NavigationLink(value: routine.id) { RoutineRow(routine: routine, overline: nil, highlighted: false) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            ProgramFooter(digest: digest).listRowBackground(Color.clear)
            if let issue = model.incompatibility {
                Text(issue.peerIsOutdated ? "Atualize o FitJourney no iPhone." : "Atualize o app do relógio.")
                    .font(.footnote).foregroundStyle(WF.attention).listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
        .navigationDestination(for: UUID.self) { id in
            if let routine = model.routine(id: id) { RoutineDetailView(routine: routine) }
        }
    }

    private func overline(for mode: String) -> String {
        switch mode {
        case "weekly": "HOJE"
        case "sequential": "PRÓXIMA"
        default: "HÁ MAIS TEMPO"
        }
    }
}

struct RoutineRow: View {
    let routine: ProgramDigest.Routine
    let overline: String?
    let highlighted: Bool
    private var colorName: String? { routine.colorName }

    var body: some View {
        HStack(spacing: 8) {
            Text(routine.symbol)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(WatchRoutineColor.onFill(colorName))
                .frame(width: 26, height: 26)
                .background(WatchRoutineColor.fill(colorName), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if let overline {
                    Text(overline).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(WF.training)
                }
                Text(routine.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                if highlighted {
                    Text("\(routine.exercises.count) exercícios · ~\(routine.estimatedDurationSeconds / 60) min")
                        .font(.caption2).foregroundStyle(WF.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(highlighted ? .vertical : .vertical, highlighted ? 10 : 6)
        .frame(minHeight: highlighted ? 64 : 44)
        .background(highlighted ? WF.training.opacity(0.16) : WF.fill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(WF.training, lineWidth: 1.5) } }
        .accessibilityElement(children: .combine)
    }
}

/// Rodapé: programa + idade do resumo + indicador de sincronização.
struct ProgramFooter: View {
    @Environment(WatchSessionModel.self) private var model
    let digest: ProgramDigest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let age = context.date.timeIntervalSince(model.digestReceivedAt ?? digest.generatedAt)
            VStack(spacing: 2) {
                Text(digest.name).font(.caption2.weight(.semibold))
                HStack(spacing: 4) {
                    if model.connection == .syncing { ProgressView().controlSize(.mini) }
                    Text(WatchFormat.age(of: model.digestReceivedAt ?? digest.generatedAt, now: context.date))
                }
                .font(.caption2)
                .foregroundStyle(age > 24 * 3600 ? WF.attention : WF.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Ficha: exercícios e prescrição + Iniciar (toque duplo).
struct RoutineDetailView: View {
    @Environment(WatchSessionModel.self) private var model
    let routine: ProgramDigest.Routine
    @State private var phase: StartPhase?

    enum StartPhase: Identifiable { case permission, countdown; var id: Self { self } }

    var body: some View {
        List {
            ForEach(routine.exercises) { exercise in
                HStack(spacing: 8) {
                    if exercise.groupID != nil {
                        Capsule().fill(WF.training).frame(width: 3).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(exercise.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(prescription(exercise)).font(.caption2).foregroundStyle(WF.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
            }
            if routine.exercises.isEmpty {
                Text("Sem exercícios nesta ficha.").font(.footnote).foregroundStyle(WF.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
        .navigationTitle(routine.name)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { begin() } label: {
                    Label("Iniciar", systemImage: "play.fill").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).tint(WF.trainingFill)
                .handGestureShortcut(.primaryAction)
                .disabled(routine.exercises.isEmpty)
                .accessibilityLabel("Iniciar \(routine.name)")
            }
        }
        .sheet(item: $phase) { phase in
            switch phase {
            case .permission:
                HealthPermissionView {
                    await model.requestHealthAccess()
                    self.phase = .countdown
                }
            case .countdown:
                StartCountdownView(haptics: model.haptics) {
                    self.phase = nil
                    model.startSession(routineID: routine.id)
                }
            }
        }
    }

    private func begin() {
        phase = model.healthAccess == .notDetermined ? .permission : .countdown
    }

    /// "4 × 8–12 · 32,5 kg".
    private func prescription(_ exercise: ProgramDigest.Exercise) -> String {
        guard let first = exercise.sets.first else { return "—" }
        var text = "\(exercise.sets.count) × \(first.targetText)"
        if let load = first.load { text += " · \(WatchFormat.load(load, compact: true))" }
        return text
    }
}

/// Primeira vez antes de iniciar: explica FC e calorias e abre o pedido do sistema.
struct HealthPermissionView: View {
    let onContinue: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "heart.fill").font(.system(size: 30)).foregroundStyle(WF.health).accessibilityHidden(true)
                Text("Permitir Saúde").font(.headline)
                Text("Para mostrar frequência cardíaca e calorias e gravar o treino.")
                    .font(.footnote).foregroundStyle(WF.textSecondary).multilineTextAlignment(.center)
                Button("Continuar") { Task { await onContinue() } }
                    .buttonStyle(.glassProminent).tint(WF.trainingFill)
            }
        }
    }
}

/// "3, 2, 1" com clique por segundo e `.start` no zero (DESIGN §9.4/§9.6).
struct StartCountdownView: View {
    let haptics: any WatchHaptics
    var from = 3
    let onFinish: () -> Void
    @State private var value = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("\(value)")
            .font(WF.number(80))
            .foregroundStyle(WF.training)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .accessibilityLabel("Começando em \(value)")
            .task {
                value = from
                while value > 0 {
                    haptics.play(.countdownTick)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    if reduceMotion { value -= 1 } else { withAnimation { value -= 1 } }
                }
                haptics.play(.countdownGo)
                onFinish()
            }
    }
}
