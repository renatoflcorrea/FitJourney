import SwiftUI

/// Cartão de um exercício da sessão: recolhido (estado + resumo) ou expandido (séries editáveis).
struct SessionExerciseCard: View {
    let coordinator: SessionCoordinator
    let exercise: SessionSnapshot.Exercise
    let snapshot: SessionSnapshot
    let info: SessionCatalogInfo?
    let isExpanded: Bool
    let isCurrent: Bool
    let onHeaderTap: () -> Void
    let onMedia: () -> Void
    let onSubstitute: () -> Void
    let onSkip: () -> Void
    let onProgress: () -> Void
    let onEditSet: (SessionSnapshot.ExerciseSet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            if isExpanded { expandedHeader } else { collapsedHeader }
            if isExpanded {
                if exercise.sets.isEmpty {
                    Text("Sem séries. Adicione uma série ou conclua o exercício pelo menu.")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                }
                VStack(spacing: FJSpacing.s) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SessionSetRow(
                            coordinator: coordinator, exercise: exercise, entry: set, index: index + 1,
                            total: exercise.sets.count,
                            isCurrent: isCurrent && set.id == snapshot.currentSetID,
                            showsRepsAfterCompletion: set.id == latestCompletedSetID,
                            onEdit: { onEditSet(set) }
                        )
                    }
                }
                footer
            }
        }
        .fjCard()
        .overlay {
            if isCurrent {
                FJRadius.shape(FJRadius.card).strokeBorder(FJColor.training.opacity(0.5), lineWidth: 1.5)
            }
        }
        .fjAnimation(FJMotion.structure, value: isExpanded)
        .accessibilityElement(children: .contain)
    }

    /// Série concluída mais recentemente neste exercício (mantém "+ reps" acessível no descanso).
    private var latestCompletedSetID: UUID? {
        guard snapshot.restEndsAt != nil else { return nil }
        let overall = snapshot.exercises.flatMap(\.sets).filter(\.isCompleted).max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        return exercise.sets.contains { $0.id == overall?.id } ? overall?.id : nil
    }

    // MARK: Cabeçalhos

    private var collapsedHeader: some View {
        Button(action: onHeaderTap) {
            HStack(spacing: FJSpacing.m) {
                statusSymbol
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(exercise.name)
                        .font(FJFont.cardTitle)
                        .foregroundStyle(FJColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(SessionPresentation.exerciseSummary(exercise))
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: FJSpacing.s)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FJColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: FJSize.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(exercise.name), \(statusText)"))
        .accessibilityValue(Text(SessionPresentation.exerciseSummary(exercise)))
        .accessibilityHint(Text("Abre o exercício"))
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                statusSymbol
                Text(exercise.name)
                    .font(FJFont.cardTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if info?.media != nil {
                    Button(action: onMedia) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title3)
                            .foregroundStyle(FJColor.training)
                            .frame(width: FJSize.minTap, height: FJSize.minTap)
                            .background(FJColor.fill, in: FJRadius.shape(FJRadius.chip))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Ver mídia do exercício"))
                }
                menu
            }
            tags
            if let last = info?.lastTime {
                Text(last)
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var tags: some View {
        let hasTags = exercise.groupID != nil || info?.existsInCatalog == false
        if hasTags {
            HStack(spacing: FJSpacing.s) {
                if let groupID = exercise.groupID {
                    FJTag(LocalizedStringKey(SessionPresentation.groupName(memberCount: snapshot.exercises.filter { $0.groupID == groupID }.count)), systemImage: "link", area: .training)
                }
                if info?.existsInCatalog == false { FJTag("Fora do catálogo", systemImage: "exclamationmark.circle", tone: .neutral) }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(action: onSubstitute) { Label("Trocar exercício", systemImage: "arrow.triangle.2.circlepath") }
            Button(action: onSkip) { Label("Pular", systemImage: "forward.fill") }
            Button { coordinator.send(.completeExercise(exerciseID: exercise.id)) } label: {
                Label("Marcar como concluído", systemImage: "checkmark.circle")
            }
            if exercise.exerciseID != nil, info?.existsInCatalog != false {
                Button(action: onProgress) { Label("Ver evolução", systemImage: "chart.line.uptrend.xyaxis") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(FJColor.textSecondary)
                .frame(width: FJSize.minTap, height: FJSize.minTap)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Ações de \(exercise.name)"))
    }

    private var footer: some View {
        HStack {
            Button {
                coordinator.send(.addSet(exerciseID: exercise.id, kind: nil))
            } label: {
                Label("Série", systemImage: "plus")
                    .font(FJFont.label.weight(.semibold))
                    .frame(minHeight: FJSize.minTap)
            }
            .accessibilityLabel(Text("Adicionar série"))
            Spacer()
        }
    }

    // MARK: Estado

    private var statusSymbolName: String {
        switch exercise.status {
        case .pending, .unknown: "circle"
        case .inProgress: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .skipped: "forward.circle.fill"
        }
    }

    private var statusText: String {
        switch exercise.status {
        case .pending, .unknown: String(localized: "pendente")
        case .inProgress: String(localized: "em andamento")
        case .completed: String(localized: "concluído")
        case .partial: String(localized: "concluído parcialmente")
        case .skipped: String(localized: "pulado")
        }
    }

    private var statusSymbol: some View {
        Image(systemName: statusSymbolName)
            .font(.title3)
            .foregroundStyle(exercise.status == .completed ? FJColor.success
                             : (exercise.status == .pending ? FJColor.textTertiary : FJColor.training))
            .frame(width: FJSize.minTap - 12)
            .accessibilityHidden(true)
    }
}

// MARK: - Linha de série

struct SessionSetRow: View {
    let coordinator: SessionCoordinator
    let exercise: SessionSnapshot.Exercise
    let entry: SessionSnapshot.ExerciseSet
    let index: Int
    let total: Int
    let isCurrent: Bool
    let showsRepsAfterCompletion: Bool
    let onEdit: () -> Void

    private var spoken: String { SessionPresentation.spokenSet(index: index, of: total, set: entry) }

    var body: some View {
        if isCurrent { currentRow } else { compactRow }
    }

    private var checkState: FJCheckState { entry.isCompleted ? .done : .pending }

    // MARK: Compacta

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack(spacing: FJSpacing.m) {
                Button(action: onEdit) {
                    HStack(spacing: FJSpacing.m) {
                        numberBadge
                        Text(SessionPresentation.compactSetText(entry, kind: exercise.measurementKind))
                            .font(FJFont.numberBody)
                            .foregroundStyle(entry.isCompleted ? FJColor.textPrimary : FJColor.textSecondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: FJSpacing.s)
                    }
                    .frame(minHeight: FJSize.setCheck)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                FJCheckButton(state: checkState, accessibilityLabel: spoken) { coordinator.toggleSet(entry) }
                    .accessibilityAction(named: Text("Editar série"), onEdit)
            }
            if showsRepsAfterCompletion, entry.isCompleted, hasReps {
                repsField
            }
        }
    }

    private var hasReps: Bool {
        exercise.measurementKind == .repsAndLoad || exercise.measurementKind == .repsOnly
    }

    private var numberBadge: some View {
        VStack(spacing: 0) {
            Text(verbatim: "\(index)")
                .font(FJFont.numberCaption.weight(.semibold))
                .foregroundStyle(FJColor.textSecondary)
            if let tag = Self.kindTag(entry.kind) {
                Text(tag).font(.caption2).foregroundStyle(FJColor.textSecondary)
            }
        }
        .frame(width: 36)
    }

    static func kindTag(_ kind: WatchSetKind) -> LocalizedStringKey? {
        switch kind {
        case .warmup: "Aq."
        case .feeder: "Prep."
        case .dropSet: "Drop"
        case .restPause: "R-P"
        case .toFailure: "Falha"
        case .backOff: "Back-off"
        case .working, .unknown: nil
        }
    }

    // MARK: Atual (carga grande)

    private var currentRow: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(spacing: FJSpacing.m) {
                numberBadge
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(targetLine)
                        .font(FJFont.label.weight(.semibold))
                    if let cadence = effortText {
                        Text(cadence).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    }
                }
                Spacer(minLength: FJSpacing.s)
                FJCheckButton(state: checkState, accessibilityLabel: spoken) { coordinator.toggleSet(entry) }
            }
            switch exercise.measurementKind {
            case .repsAndLoad:
                loadStepper(label: "Carga", showsSign: false, range: 0...999)
                repsField
            case .repsOnly:
                loadStepper(label: "Lastro", showsSign: true, range: -300...300)
                repsField
            case .isometric:
                loadStepper(label: "Carga", showsSign: false, range: 0...999)
            case .timeOrDistance:
                NumberStepperField("Distância", value: distanceBinding, unit: "km", step: 0.1, range: 0...500, fractionDigits: 2)
            case .unknown:
                EmptyView()
            }
        }
        .padding(FJSpacing.m)
        .background(FJColor.fill.opacity(0.6), in: FJRadius.shape(FJRadius.field))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Editar série"), onEdit)
    }

    /// "alvo 8–12" — sempre como prescrito (D2).
    private var targetLine: String {
        entry.targetText.isEmpty ? String(localized: "Série \(index)") : String(localized: "alvo \(entry.targetText)")
    }

    private var effortText: String? {
        switch entry.effort {
        case .rir(let value): "RIR \(value)"
        case .rpe(let value): "RPE \(FJFormat.number(value, maxFractionDigits: 1))"
        case nil: nil
        }
    }

    private func loadStepper(label: LocalizedStringKey, showsSign: Bool, range: ClosedRange<Double>) -> some View {
        NumberStepperField(label, value: loadBinding, unit: unitText, step: LoadDisplay.step(forLoadIn: nativeUnit), range: range, fractionDigits: 2, showsSign: showsSign)
    }

    private var nativeUnit: WeightUnit {
        WeightUnit(rawValue: (SessionPresentation.displayLoad(entry)?.unit ?? .kg).rawValue) ?? .kg
    }

    private var unitText: String {
        (SessionPresentation.displayLoad(entry)?.unit ?? .kg) == .kg ? "kg" : "lb"
    }

    private var loadBinding: Binding<Double> {
        Binding(
            get: { SessionPresentation.displayLoad(entry)?.value ?? 0 },
            set: { newValue in
                let delta = newValue - (SessionPresentation.displayLoad(entry)?.value ?? 0)
                guard abs(delta) > 0.0001 else { return }
                coordinator.send(.adjustLoad(setID: entry.id, delta: delta))
            }
        )
    }

    private var distanceBinding: Binding<Double> {
        Binding(
            get: { (entry.distanceMeters ?? 0) / 1_000 },
            set: { newValue in
                coordinator.send(.updateSet(setID: entry.id, reps: entry.reps, load: entry.load, durationSeconds: entry.durationSeconds,
                                            distanceMeters: newValue > 0 ? newValue * 1_000 : nil))
            }
        )
    }

    /// Reps realizadas: opcionais, começam vazias (D2).
    private var repsField: some View {
        FJOptionalNumberField("Repetições realizadas", prompt: "+ reps", value: repsBinding, unit: "reps")
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var repsBinding: Binding<Int?> {
        Binding(
            get: { entry.reps },
            set: { newValue in
                guard newValue != entry.reps else { return }
                coordinator.send(.updateSet(setID: entry.id, reps: newValue, load: entry.load,
                                            durationSeconds: entry.durationSeconds, distanceMeters: entry.distanceMeters))
            }
        )
    }
}
