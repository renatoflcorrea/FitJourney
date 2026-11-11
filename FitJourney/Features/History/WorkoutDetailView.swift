import SwiftData
import SwiftUI

/// Detalhe de uma sessão concluída: resumo, intensidade, notas, séries (editáveis com marca "editado").
struct WorkoutDetailView: View {
    let session: WorkoutSession
    /// Exclusão pedida ao pai depois de a tela sair (nil: este detalhe exclui sozinho ao sair).
    var onDelete: ((WorkoutSession) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var editingSet: SetLog?
    @State private var progressExerciseID: UUID?
    @State private var confirmsDelete = false
    @State private var saveFailed = false
    @State private var deleteRequested = false

    private var exercises: [SessionExercise] { session.sortedExercises }
    private var performed: [PerformedSet] { exercises.flatMap(\.sortedSets).map(\.performed) }

    var body: some View {
        ScrollView {
            VStack(spacing: FJSpacing.cardGap) {
                if saveFailed {
                    FJBanner("Não foi possível salvar", message: "Tente de novo.", tone: .destructive)
                }
                summaryCard
                intensityCard
                moodCard
                notesCard
                SessionHeartRateChart(session: session)
                ForEach(exercises) { exercise in
                    exerciseCard(exercise)
                }
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.vertical, FJSpacing.s)
        }
        .fjScreenBackground()
        .navigationTitle(session.routineName.isEmpty ? String(localized: "Treino livre") : session.routineName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "OK" : "Editar") { isEditing.toggle() }
                    .fontWeight(isEditing ? .semibold : .regular)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmsDelete = true } label: { Label("Excluir sessão", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("Mais ações"))
            }
        }
        .sheet(item: $editingSet) { log in
            HistorySetEditSheet(log: log, measurementKind: log.sessionExercise?.measurementKind ?? .repsAndLoad) { saveFailed = !$0 }
        }
        .sheet(item: $progressExerciseID.identified) { item in
            NavigationStack {
                ExerciseProgressView(exerciseID: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Fechar") { progressExerciseID = nil } }
                    }
            }
            .tint(FJColor.training)
        }
        .confirmationDialog("Excluir esta sessão?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Excluir sessão", role: .destructive) {
                deleteRequested = true
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A sessão e suas séries saem do histórico.")
        }
        .onChange(of: isEditing) { _, editing in if !editing { persist() } }
        .onDisappear {
            if deleteRequested { performDelete() } else { persist() }
        }
    }

    // MARK: Cartões

    private var summaryCard: some View {
        let end = session.endedAt ?? session.updatedAt
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text(session.startedAt.formatted(date: .complete, time: .shortened))
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                FJMetricGrid {
                    FJMetricCell("Duração", value: FJFormat.clock(Int(session.clock.elapsed(at: end))), systemImage: "clock")
                    FJMetricCell(WorkoutMetrics.hasEstimatedVolume(performed) ? "Volume (estimado)" : "Volume",
                                 value: LoadDisplay.kgNumber(WorkoutMetrics.volumeKg(performed), maxFractionDigits: 0),
                                 unit: LoadDisplay.symbol(), systemImage: "scalemass")
                    FJMetricCell("Séries", value: "\(performed.filter(\.isCompleted).count)/\(performed.count)", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var intensityCard: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Intensidade percebida")
                if isEditing {
                    FJRPEScale(value: Bindable(session).sessionRPE)
                } else if let rpe = session.sessionRPE {
                    HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                        Text(verbatim: "\(rpe)").font(FJFont.numberHero)
                        Text(FJRPEScale.label(for: rpe)).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Não informada").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }

    /// Humor/energia 1–5 informado ao finalizar (some se não informado, fora da edição).
    @ViewBuilder
    private var moodCard: some View {
        if isEditing || session.mood != nil {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    FJSectionHeader("Humor e energia")
                    if isEditing {
                        SessionNumberScale(value: Bindable(session).mood, range: 1...5, title: "Humor e energia de 1 a 5") {
                            SessionPresentation.moodLabel($0)
                        }
                    } else if let mood = session.mood {
                        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                            Text(verbatim: "\(mood)/5").font(FJFont.numberHero)
                            Text(SessionPresentation.moodLabel(mood)).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Humor e energia"))
                        .accessibilityValue(Text("\(mood) de 5, \(SessionPresentation.moodLabel(mood))"))
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                FJSectionHeader("Nota")
                if isEditing {
                    TextField("Como foi o treino?", text: Bindable(session).notes, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(FJSpacing.m)
                        .background(FJColor.fill, in: FJRadius.shape(FJRadius.field))
                } else if session.notes.isEmpty {
                    Text("Sem nota").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                } else {
                    Text(session.notes).font(FJFont.body)
                }
            }
        }
    }

    private func exerciseCard(_ exercise: SessionExercise) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(exercise.name.exerciseDisplayName).font(FJFont.cardTitle).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let id = exercise.exerciseID {
                        Button { progressExerciseID = id } label: {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .frame(width: FJSize.minTap, height: FJSize.minTap)
                        }
                        .accessibilityLabel(Text("Ver evolução de \(exercise.name.exerciseDisplayName)"))
                    }
                }
                if let from = exercise.substitutedFromName {
                    Text("no lugar de \(from)").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
                if exercise.status == .skipped {
                    Label(skipText(exercise), systemImage: "forward.fill").font(FJFont.label)
                }
                ForEach(Array(exercise.sortedSets.enumerated()), id: \.element.id) { index, log in
                    setRow(log, index: index + 1, exercise: exercise)
                }
                if let pain = SessionPresentation.painText(score: exercise.painLevel, location: exercise.painLocation) {
                    Label(pain, systemImage: "bandage")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .accessibilityLabel(Text(SessionPresentation.spokenPain(score: exercise.painLevel, location: exercise.painLocation) ?? pain))
                }
                if !exercise.notes.isEmpty {
                    Text(exercise.notes).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }

    private func skipText(_ exercise: SessionExercise) -> String {
        switch exercise.skipReason {
        case .equipmentBusy: String(localized: "Pulado — equipamento ocupado")
        case .pain: String(localized: "Pulado — dor")
        case .time: String(localized: "Pulado — tempo")
        case .other, nil: exercise.skipReasonText.map { String(localized: "Pulado — \($0)") } ?? String(localized: "Pulado")
        }
    }

    private func setRow(_ log: SetLog, index: Int, exercise: SessionExercise) -> some View {
        let kind = exercise.measurementKind
        let target = SessionDisplay.targetText(measurement: kind, repTarget: log.repTarget, holdSeconds: log.targetHoldSeconds,
                                               cardio: log.cardioTarget)
        let realized = realizedText(log, kind: kind)
        let row = HStack(spacing: FJSpacing.m) {
            Text(verbatim: "\(index)").font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(log.isCompleted ? realized : String(localized: "Não feita"))
                    .font(FJFont.numberBody)
                    .foregroundStyle(log.isCompleted ? FJColor.textPrimary : FJColor.textSecondary)
                if let cardio = SessionPresentation.cardioDetailText(level: log.level, speedKmh: log.speedKmh, inclinePercent: log.inclinePercent) {
                    Text(cardio).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
                if !target.isEmpty {
                    Text("alvo \(target)").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: FJSpacing.s)
            if log.edited { FJTag("editado", systemImage: "pencil", tone: .attention) }
            if isEditing {
                Image(systemName: "pencil.circle").foregroundStyle(FJColor.training).accessibilityHidden(true)
            }
        }
        .frame(minHeight: FJSize.minTap)
        .contentShape(Rectangle())

        return Group {
            if isEditing {
                Button { editingSet = log } label: { row }.buttonStyle(.plain)
                    .accessibilityLabel(Text("Editar série \(index): \(realized)"))
            } else {
                row.accessibilityElement(children: .combine)
            }
        }
    }

    private func realizedText(_ log: SetLog, kind: MeasurementKind) -> String {
        let load = SessionPresentation.loadText((log.load ?? log.plannedLoad).map { WatchLoad($0) })
        switch kind {
        case .isometric:
            let time = log.durationSeconds.map { "\(Int($0.rounded())) s" }
            return [load, time].compactMap { $0 }.joined(separator: " · ")
        case .timeOrDistance:
            let time = log.durationSeconds.map { FJFormat.clock(Int($0.rounded())) }
            let distance = log.distanceMeters.map { $0 >= 1_000 ? "\(FJFormat.number($0 / 1_000)) km" : "\(Int($0)) m" }
            return [time, distance].compactMap { $0 }.joined(separator: " · ")
        default:
            let reps = log.reps.map { "× \($0)" }
            return [load, reps].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func persist() {
        do {
            try context.save()
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    /// Depois de a tela sair, para a view não ler um modelo apagado.
    private func performDelete() {
        if let onDelete {
            onDelete(session)
            return
        }
        do {
            context.delete(session)
            try context.save()
        } catch {
            context.rollback()
        }
    }
}

// MARK: - Edição de série passada

/// Corrige uma série de sessão concluída; `SessionStore.updateSet` marca "editado" (só se algo mudou).
/// A carga é editada na unidade nativa da série (kg ou lb), sem converter.
struct HistorySetEditSheet: View {
    let log: SetLog
    let measurementKind: MeasurementKind
    let onSaved: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var load: Double
    @State private var reps: Int?
    @State private var seconds: Double
    @State private var distanceKm: Double
    private let unit: WeightUnit

    init(log: SetLog, measurementKind: MeasurementKind, onSaved: @escaping (Bool) -> Void) {
        self.log = log
        self.measurementKind = measurementKind
        self.onSaved = onSaved
        let native = LoadEditing.native(log.load ?? log.plannedLoad)
        unit = native.unit
        _load = State(initialValue: native.value)
        _reps = State(initialValue: log.reps)
        _seconds = State(initialValue: log.durationSeconds ?? 0)
        _distanceKm = State(initialValue: (log.distanceMeters ?? 0) / 1_000)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                FJCard {
                    VStack(alignment: .leading, spacing: FJSpacing.m) {
                        if measurementKind != .timeOrDistance {
                            NumberStepperField(measurementKind == .repsOnly ? "Lastro" : "Carga", value: $load,
                                               unit: LoadEditing.unitText(unit),
                                               step: LoadDisplay.step(forLoadIn: unit), range: measurementKind == .repsOnly ? -300...300 : 0...999,
                                               fractionDigits: 2, showsSign: measurementKind == .repsOnly)
                        }
                        switch measurementKind {
                        case .repsAndLoad, .repsOnly:
                            FJOptionalNumberField("Repetições realizadas", prompt: "+ reps", value: $reps, unit: "reps")
                        case .isometric:
                            NumberStepperField("Sustentação", value: $seconds, unit: "s", step: 1, range: 0...3_600)
                        case .timeOrDistance:
                            NumberStepperField("Duração", value: $seconds, unit: "s", step: 10, range: 0...36_000)
                            NumberStepperField("Distância", value: $distanceKm, unit: "km", step: 0.1, range: 0...500, fractionDigits: 2)
                        }
                    }
                }
                .padding(FJSpacing.screenMargin)
            }
            .fjScreenBackground()
            .navigationTitle("Editar série")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let newLoad: Load? = measurementKind == .timeOrDistance ? log.load
            : LoadEditing.make(value: load, unit: unit, isBodyweight: measurementKind == .repsOnly)
        let newDuration = seconds > 0 ? seconds : log.durationSeconds
        let newDistance: Double? = measurementKind == .timeOrDistance ? (distanceKm > 0 ? distanceKm * 1_000 : nil) : log.distanceMeters
        // Compara com o que a tela mostrou ao abrir (carga exibida = realizada ou planejada).
        let shownLoad: Load? = measurementKind == .timeOrDistance ? log.load
            : LoadEditing.make(value: LoadEditing.native(log.load ?? log.plannedLoad).value, unit: unit,
                               isBodyweight: measurementKind == .repsOnly)
        let changed = LoadEditing.hasChanges(
            old: (log.reps, shownLoad, log.durationSeconds, log.distanceMeters),
            new: (reps, newLoad, newDuration, newDistance))
        guard changed else {
            dismiss()
            return
        }
        do {
            // Sem autosave: grava uma vez, ao confirmar.
            try SessionStore(context: context, autosave: false).updateSet(
                log, reps: reps, load: newLoad, durationSeconds: newDuration, distanceMeters: newDistance)
            try context.save()
            onSaved(true)
        } catch {
            context.rollback()
            onSaved(false)
        }
        dismiss()
    }
}

struct IdentifiedUUID: Identifiable { let id: UUID }

extension Binding where Value == UUID? {
    /// Adapta um `UUID?` para `sheet(item:)`.
    var identified: Binding<IdentifiedUUID?> {
        Binding<IdentifiedUUID?>(
            get: { wrappedValue.map { IdentifiedUUID(id: $0) } },
            set: { wrappedValue = $0?.id }
        )
    }
}

#Preview("Detalhe") {
    let container = PersistenceController.preview
    let session = try? SessionStore(context: container.mainContext).completedSessions(limit: 1).first
    return NavigationStack {
        if let session { WorkoutDetailView(session: session) }
    }
    .modelContainer(container)
    .tint(FJColor.training)
}
