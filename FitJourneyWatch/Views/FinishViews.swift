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
                .accessibilityLabel("\(exercise.name), \(statusText(exercise)), \(exercise.sets.filter(\.isCompleted).count) de \(exercise.sets.count) séries")
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
        case .completed: "concluído"
        case .partial: "concluído parcialmente"
        case .skipped: "pulado"
        default: isCurrent(e) ? "atual" : "pendente"
        }
    }
}

/// Finalizar: RPE 1–10 pela Coroa + "Sem nota".
struct FinishView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Double = 7

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Como foi o treino?").font(.footnote).foregroundStyle(WF.textSecondary)
                Text("\(Int(rpe))").font(WF.number(52)).foregroundStyle(WF.training)
                    .accessibilityHidden(true)
                Text(WatchFormat.rpeLabel(Int(rpe))).font(.footnote.weight(.semibold))
                WatchPrimaryButton(title: "Salvar") { save(Int(rpe)) }
                Button("Sem nota") { save(nil) }.buttonStyle(.glass)
            }
            .accessibilityElement(children: .contain)
        }
        .focusable()
        .digitalCrownRotation($rpe, from: 1, through: 10, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rpe = min(10, rpe + 1)
            case .decrement: rpe = max(1, rpe - 1)
            @unknown default: break
            }
        }
        .accessibilityLabel("Esforço percebido")
        .accessibilityValue("\(Int(rpe)), \(WatchFormat.rpeLabel(Int(rpe)))")
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
                row("Calorias", summary.activeKilocalories.map { "\(Int($0)) kcal" } ?? "—")
                row("FC média", summary.averageHeartRate.map { "\($0) bpm" } ?? "—")
                if summary.loadsUpdated > 0 {
                    Text("\(summary.loadsUpdated) \(summary.loadsUpdated == 1 ? "carga atualizada" : "cargas atualizadas") · revise no iPhone")
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

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(WF.textSecondary)
            Spacer()
            Text(value).font(WF.number(16, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
