import SwiftUI

/// Ficha (página à direita): exercícios com estado; toque abre as ações.
struct SessionRoutinePage: View {
    @Environment(WatchSessionModel.self) private var model
    @State private var selected: SessionSnapshot.Exercise?

    var body: some View {
        List {
            ForEach(model.display?.exercises ?? []) { exercise in
                Button { selected = exercise } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(exercise)).foregroundStyle(color(exercise)).frame(width: 18).accessibilityHidden(true)
                        Text(exercise.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                        Text("\(exercise.sets.filter(\.isCompleted).count)/\(exercise.sets.count)")
                            .font(WF.number(12, weight: .medium)).foregroundStyle(WF.textSecondary)
                    }
                    .frame(minHeight: 36)
                }
                .accessibilityLabel(String(localized: "\(exercise.name), \(statusText(exercise)), \(exercise.sets.filter(\.isCompleted).count) de \(exercise.sets.count) séries"))
            }
        }
        .accessibilityLabel("Ficha")
        .confirmationDialog(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible) {
            if let exercise = selected {
                Button("Ir para este") { model.focus(exerciseID: exercise.id) }
                Button("Concluir exercício") { model.complete(exerciseID: exercise.id) }
                Button("Pular") { model.skip(exerciseID: exercise.id) }
                Button("Pular · ocupado") { model.skip(exerciseID: exercise.id, reason: .equipmentBusy) }
                Button("Pular · dor") { model.skip(exerciseID: exercise.id, reason: .pain) }
                Button("Pular · tempo") { model.skip(exerciseID: exercise.id, reason: .time) }
            }
        }
    }

    private func isCurrent(_ e: SessionSnapshot.Exercise) -> Bool { e.id == model.display?.currentExerciseID }

    private func symbol(_ e: SessionSnapshot.Exercise) -> String {
        switch e.status {
        case .completed: "checkmark.circle.fill"
        case .partial: "checkmark.circle"
        case .skipped: "forward.end.fill"
        default: isCurrent(e) ? "circle.inset.filled" : "circle"
        }
    }

    private func color(_ e: SessionSnapshot.Exercise) -> Color {
        switch e.status {
        case .completed, .partial: WF.success
        case .skipped: WF.textSecondary
        default: isCurrent(e) ? WF.training : WF.textSecondary
        }
    }

    private func statusText(_ e: SessionSnapshot.Exercise) -> String {
        switch e.status {
        case .completed: String(localized: "concluído")
        case .partial: String(localized: "concluído parcialmente")
        case .skipped: String(localized: "pulado")
        default: isCurrent(e) ? String(localized: "atual") : String(localized: "pendente")
        }
    }
}

/// Finalizar: RPE 1–10 pela Coroa ou pelos − / + ao lado do número, + "Sem nota".
///
/// Sem ScrollView: dentro dela a Coroa rolava a tela e a nota não mudava (mesma regra do editor de carga).
struct FinishView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Double = 7
    @FocusState private var crownFocused: Bool

    private var value: Int { Int(rpe.rounded()) }

    var body: some View {
        VStack(spacing: 4) {
            Text("Como foi o treino?").font(.footnote).foregroundStyle(WF.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                stepButton(up: false)
                VStack(spacing: 0) {
                    Text("\(value)").font(WF.number(44)).foregroundStyle(WF.training)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(.numericText(value: rpe))
                    Text(WatchFormat.rpeLabel(value)).font(.footnote.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .focusable()
                .focused($crownFocused)
                .digitalCrownRotation($rpe, from: 1, through: 10, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Esforço percebido")
                .accessibilityValue("\(value), \(WatchFormat.rpeLabel(value))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(up: true)
                    case .decrement: step(up: false)
                    @unknown default: break
                    }
                }
                stepButton(up: true)
            }
            Spacer(minLength: 0)
            WatchPrimaryButton(title: "Salvar") { save(value) }
            Button("Sem nota") { save(nil) }
                .buttonStyle(WatchButtonStyle(height: 36))
        }
        .accessibilityElement(children: .contain)
        .onAppear { crownFocused = true }
    }

    private func stepButton(up: Bool) -> some View {
        Button { step(up: up) } label: {
            Image(systemName: up ? "plus" : "minus").font(.headline.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(up ? value >= 10 : value <= 1)
        .opacity((up ? value >= 10 : value <= 1) ? 0.4 : 1)
        .accessibilityHidden(true) // o número já é ajustável pelo VoiceOver
    }

    private func step(up: Bool) {
        rpe = Double(min(10, max(1, value + (up ? 1 : -1))))
    }

    private func save(_ value: Int?) {
        dismiss()
        model.finish(rpe: value)
    }
}

/// Resumo: check, duração, séries, calorias, FC média, cargas atualizadas.
struct SummaryView: View {
    @Environment(WatchSessionModel.self) private var model
    let summary: WatchSessionSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(WF.success).accessibilityHidden(true)
                    Text("Treino salvo").font(.headline)
                }
                row("Duração", WatchFormat.clock(summary.duration))
                row("Séries", "\(summary.completedSets)/\(summary.totalSets)")
                row("Calorias", summary.activeKilocalories.map { String(localized: "\(Int($0)) kcal") } ?? "—")
                row("FC média", summary.averageHeartRate.map { String(localized: "\($0) bpm") } ?? "—")
                if summary.loadsUpdated > 0 {
                    Text("\(summary.loadsUpdated) cargas atualizadas · revise no iPhone")
                        .font(.footnote).foregroundStyle(WF.textSecondary)
                }
                if model.connection == .phoneUnreachable {
                    Text("Salvo no relógio. Será enviado ao iPhone quando conectar.")
                        .font(.footnote).foregroundStyle(WF.attention)
                }
                WatchPrimaryButton(title: "OK") { model.dismissSummary() }
            }
        }
    }

    private func row(_ title: LocalizedStringResource, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(WF.textSecondary)
            Spacer()
            Text(value).font(WF.number(16, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
