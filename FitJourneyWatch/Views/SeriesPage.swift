import SwiftUI

/// Página Série (inicial): muda de conteúdo conforme o estado — série → descanso → sustentação/cardio → próximo exercício.
struct SeriesPage: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
                .transition(.opacity)
        }
        .accessibilityLabel("Série")
    }

    @ViewBuilder private func content(at date: Date) -> some View {
        if let display = model.display {
            if display.status == .paused {
                PausedView(display: display)
            } else if let remaining = display.restRemaining(at: date) {
                RestView(remaining: remaining)
            } else if let finished = model.restFinishedAt, date.timeIntervalSince(finished) < 2 {
                RestDoneView()
            } else if let set = model.currentSet, let exercise = model.currentExercise {
                if model.introExerciseID == exercise.id {
                    ExerciseIntroView(exercise: exercise)
                } else {
                    switch exercise.measurementKind {
                    case .isometric: HoldView(exercise: exercise, set: set)
                    case .timeOrDistance: CardioView(exercise: exercise, set: set)
                    default: ActiveSetView(exercise: exercise, set: set)
                    }
                }
            } else {
                AllDoneView()
            }
        }
    }
}

// MARK: - Carga pela Coroa

/// Carga efetiva exibida de uma série (`nil` = o exercício não usa carga).
func effectiveLoad(of set: SessionSnapshot.ExerciseSet, in exercise: SessionSnapshot.Exercise) -> WatchLoad? {
    if let load = set.load ?? set.plannedLoad { return load }
    return exercise.measurementKind == .repsAndLoad ? WatchLoad(value: 0) : nil
}

/// A Digital Crown ajusta a carga em passos de 0,5 kg com háptico de detente (DESIGN §9.1, SPEC D3).
struct LoadCrownModifier: ViewModifier {
    @Environment(WatchSessionModel.self) private var model
    let setID: UUID
    let load: WatchLoad
    @State private var crown: Double = 0

    func body(content: Content) -> some View {
        let range = WatchLoadStepping.range(for: load)
        content
            .focusable()
            .digitalCrownRotation($crown, from: range.lowerBound, through: range.upperBound, by: WatchLoadStepping.step,
                                  sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { _, new in
                let clamped = WatchLoadStepping.clamp(new, for: load)
                model.setLoad(setID: setID, to: clamped)
                if clamped != new { crown = clamped }
            }
            .onChange(of: load.value) { _, new in if abs(crown - new) > 0.01 { crown = new } }
            .onChange(of: setID) { _, _ in crown = load.value }
            .onAppear { crown = load.value }
    }
}

extension View {
    func loadCrown(setID: UUID?, load: WatchLoad?) -> some View {
        modifier(OptionalLoadCrown(setID: setID, load: load))
    }
}

private struct OptionalLoadCrown: ViewModifier {
    let setID: UUID?
    let load: WatchLoad?
    func body(content: Content) -> some View {
        if let load, let setID { content.modifier(LoadCrownModifier(setID: setID, load: load)) } else { content }
    }
}

// MARK: - Série ativa

struct ActiveSetView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exercise: SessionSnapshot.Exercise
    let set: SessionSnapshot.ExerciseSet
    @State private var showingLoadSheet = false

    private var isLargeText: Bool { typeSize >= .accessibility1 }
    private var load: WatchLoad? { effectiveLoad(of: set, in: exercise) }
    private var isLastSetOfExercise: Bool { exercise.sets.filter { !$0.isCompleted }.count <= 1 }
    private var position: (index: Int, of: Int) {
        (exercise.sets.firstIndex { $0.id == set.id }.map { $0 + 1 } ?? 1, exercise.sets.count)
    }

    var body: some View {
        Group {
            if isLargeText {
                ScrollView { VStack(spacing: 6) { header; loadRow; target } }
                    .safeAreaInset(edge: .bottom) { completeButton }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    header
                    Spacer(minLength: 0)
                    loadRow
                    target
                    Spacer(minLength: 0)
                    completeButton
                }
                .loadCrown(setID: set.id, load: load)
            }
        }
        .sheet(isPresented: $showingLoadSheet) {
            if let load { LoadSheet(setID: set.id, load: load) }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(exercise.name).font(WF.exerciseName).lineLimit(isLargeText ? 3 : (WatchLayout.isLargeCase ? 2 : 1))
            HStack(spacing: 4) {
                Text("Série \(position.index) de \(position.of)")
                if let kind = WatchFormat.setKindLabel(set.kind) { Text("· \(kind)") }
            }
            .font(.footnote).foregroundStyle(WF.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(exercise.name), série \(position.index) de \(position.of)")
        .accessibilitySortPriority(4)
    }

    @ViewBuilder private var loadRow: some View {
        if let load {
            HStack(spacing: 6) {
                if isLargeText { stepButton("minus", delta: -WatchLoadStepping.step, label: "Diminuir carga") }
                Button { showingLoadSheet = true } label: {
                    HStack(spacing: 6) {
                        Text(WatchFormat.load(load).replacingOccurrences(of: " kg", with: "").replacingOccurrences(of: " lb", with: ""))
                            .font(WF.number(WatchLayout.loadFontSize))
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        if !load.isBodyweight || load.value != 0 {
                            Text(load.unit == .kg ? "kg" : "lb").font(.footnote.weight(.semibold)).foregroundStyle(WF.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if !isLargeText {
                            Capsule().fill(WF.training).frame(width: 4, height: 30).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Carga")
                .accessibilityValue(WatchFormat.spokenLoad(load))
                .accessibilityHint("Toque para ajustar. Deslize para cima ou para baixo para mudar meio quilo.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.adjustLoad(setID: set.id, by: WatchLoadStepping.step)
                    case .decrement: model.adjustLoad(setID: set.id, by: -WatchLoadStepping.step)
                    @unknown default: break
                    }
                }
                .accessibilitySortPriority(3)
                if isLargeText { stepButton("plus", delta: WatchLoadStepping.step, label: "Aumentar carga") }
            }
        }
    }

    private func stepButton(_ symbol: String, delta: Double, label: LocalizedStringResource) -> some View {
        Button { model.adjustLoad(setID: set.id, by: delta) } label: {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(label))
    }

    private var target: some View {
        Text(WatchFormat.target(text: set.targetText, effort: set.effort))
            .font(.footnote).foregroundStyle(WF.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(WatchFormat.spokenTarget(text: set.targetText))
            .accessibilitySortPriority(2)
    }

    private var completeButton: some View {
        WatchPrimaryButton(title: isLastSetOfExercise ? "Concluir exercício" : "Concluir",
                           accessibilityLabel: isLastSetOfExercise ? "Concluir série \(position.index), último do exercício" : "Concluir série \(position.index)") {
            model.completeCurrentSet()
        }
        .accessibilitySortPriority(1)
    }
}

/// Folha "Carga": − / + grandes (alternativa sem Coroa).
struct LoadSheet: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let setID: UUID
    let load: WatchLoad

    var body: some View {
        let current = model.display?.exercises.flatMap(\.sets).first { $0.id == setID }?.load ?? load
        VStack(spacing: 6) {
            Text("Carga").font(.footnote).foregroundStyle(WF.textSecondary)
            Text(WatchFormat.load(current)).font(WF.number(34)).minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityValue(WatchFormat.spokenLoad(current))
            HStack(spacing: 8) {
                Button { model.adjustLoad(setID: setID, by: -WatchLoadStepping.step) } label: {
                    Image(systemName: "minus").font(.title3).frame(maxWidth: .infinity, minHeight: 48)
                }
                .accessibilityLabel("Diminuir carga")
                Button { model.adjustLoad(setID: setID, by: WatchLoadStepping.step) } label: {
                    Image(systemName: "plus").font(.title3).frame(maxWidth: .infinity, minHeight: 48)
                }
                .accessibilityLabel("Aumentar carga")
            }
            .buttonStyle(.glass)
            WatchPrimaryButton(title: "OK") { dismiss() }
        }
    }
}

// MARK: - Descanso

struct RestView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let remaining: TimeInterval
    @State private var showingReps = false

    private var next: (set: SessionSnapshot.ExerciseSet, exercise: SessionSnapshot.Exercise)? {
        guard let set = model.currentSet, let exercise = model.currentExercise else { return nil }
        return (set, exercise)
    }

    var body: some View {
        Group {
            if typeSize >= .accessibility1 { ScrollView { column }.safeAreaInset(edge: .bottom) { skipButton } }
            else { VStack(spacing: 4) { column; Spacer(minLength: 0); skipButton } }
        }
        .loadCrown(setID: next?.set.id, load: next.flatMap { effectiveLoad(of: $0.set, in: $0.exercise) })
        .sheet(isPresented: $showingReps) { RepsSheet() }
    }

    private var column: some View {
        VStack(spacing: 4) {
            Text(WatchFormat.clock(remaining.rounded(.up)))
                .font(WF.number(WatchLayout.timerFontSize, weight: .semibold))
                .minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityLabel("Descanso, \(Int(remaining.rounded(.up))) segundos restantes")
            progressBar
            if let next, let load = effectiveLoad(of: next.set, in: next.exercise) {
                Text("Próxima: \(WatchFormat.load(load))").font(.footnote).foregroundStyle(WF.textSecondary)
                    .accessibilityLabel("Próxima série, \(WatchFormat.spokenLoad(load)). Gire a Coroa para ajustar.")
            }
            HStack(spacing: 5) {
                Button { showingReps = true } label: { Text("+ reps").frame(maxWidth: .infinity, minHeight: 40) }
                    .accessibilityLabel("Registrar repetições")
                Button { model.extendRest() } label: { Text("+15 s").frame(maxWidth: .infinity, minHeight: 40) }
                    .accessibilityLabel("Mais quinze segundos")
            }
            .buttonStyle(.glass)
            .font(.footnote.weight(.semibold))
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let total = max(model.restTotalSeconds, remaining, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(WF.fillStrong)
                Capsule().fill(WF.training).frame(width: proxy.size.width * (1 - remaining / total))
            }
        }
        .frame(height: 4).padding(.horizontal, 3)
        .accessibilityHidden(true)
    }

    private var skipButton: some View { WatchPrimaryButton(title: "Pular", systemImage: "forward.fill", accessibilityLabel: "Pular descanso") { model.skipRest() } }
}

struct RestDoneView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(WF.success).accessibilityHidden(true)
            Text("Descanso concluído").font(.headline).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(String(localized: "Descanso concluído")).post() }
    }
}

/// "+ reps": seletor pela Coroa para a última série concluída; começa no piso da faixa; "Limpar" volta a não informado.
struct RepsSheet: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reps: Double = 0

    private var lastCompleted: SessionSnapshot.ExerciseSet? {
        model.display?.exercises.flatMap(\.sets).filter(\.isCompleted).max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Repetições").font(.footnote).foregroundStyle(WF.textSecondary)
            Text("\(Int(reps))").font(WF.number(48))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Repetições")
                .accessibilityValue("\(Int(reps))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: reps = min(100, reps + 1)
                    case .decrement: reps = max(0, reps - 1)
                    @unknown default: break
                    }
                }
            HStack(spacing: 5) {
                Button("Limpar") { if let set = lastCompleted { model.updateReps(setID: set.id, reps: nil) }; dismiss() }
                    .buttonStyle(.glass)
                Button("Salvar") { if let set = lastCompleted { model.updateReps(setID: set.id, reps: Int(reps)) }; dismiss() }
                    .buttonStyle(.glassProminent).tint(WF.trainingFill)
                    .handGestureShortcut(.primaryAction)
            }
        }
        .focusable()
        .digitalCrownRotation($reps, from: 0, through: 100, by: 1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear {
            guard let set = lastCompleted else { return }
            if let done = set.reps { reps = Double(done) } else {
                switch set.repTarget {
                case .fixed(let n): reps = Double(n)
                case .range(let min, _): reps = Double(min)
                default: reps = 0
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Sustentação e cardio

struct HoldView: View {
    @Environment(WatchSessionModel.self) private var model
    let exercise: SessionSnapshot.Exercise
    let set: SessionSnapshot.ExerciseSet
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var reachedTarget = false

    private var target: Int { self.set.targetHoldSeconds ?? 0 }
    private var isHolding: Bool { model.display?.holdSetID == self.set.id }

    var body: some View {
        VStack(spacing: 4) {
            Text(exercise.name).font(WF.exerciseName).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if isHolding {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Tempo ativo do snapshot: congela na pausa e não conta o tempo parado.
                    let elapsed = model.display?.holdElapsed(at: context.date) ?? 0
                    Spacer(minLength: 0)
                    Text(WatchFormat.clock(elapsed)).font(WF.number(WatchLayout.timerFontSize, weight: .semibold))
                        .accessibilityLabel("Sustentando \(Int(elapsed)) segundos")
                    holdBar(elapsed: elapsed)
                    Text("alvo \(WatchFormat.clock(Double(target)))").font(.footnote).foregroundStyle(WF.textSecondary)
                        .onChange(of: elapsed >= Double(target) && target > 0) { _, reached in
                            if reached && !reachedTarget { reachedTarget = true; model.haptics.play(.holdTargetReached) }
                        }
                }
                Spacer(minLength: 0)
                WatchPrimaryButton(title: "Parar", systemImage: "stop.fill") { model.endHold() }
            } else if let countdown {
                Spacer()
                Text("\(countdown)").font(WF.number(72)).foregroundStyle(WF.training)
                    .accessibilityLabel("Começando em \(countdown)")
                Spacer()
            } else {
                Spacer(minLength: 0)
                Text("Sustentação").font(.footnote).foregroundStyle(WF.textSecondary)
                Text("alvo \(WatchFormat.clock(Double(target)))").font(WF.number(30, weight: .semibold))
                Spacer(minLength: 0)
                WatchPrimaryButton(title: "Iniciar", systemImage: "play.fill", accessibilityLabel: "Iniciar sustentação") { beginCountdown() }
            }
        }
        .onChange(of: set.id) { _, _ in reachedTarget = false; cancelCountdown() }
        .onChange(of: model.display?.status) { _, _ in cancelCountdown() }
        .onDisappear { cancelCountdown() }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func holdBar(elapsed: TimeInterval) -> some View {
        GeometryReader { proxy in
            let total = Double(max(target, 1)) * 1.25
            ZStack(alignment: .leading) {
                Capsule().fill(WF.fillStrong)
                Capsule().fill(WF.training).frame(width: proxy.size.width * min(1, elapsed / total))
                Rectangle().fill(.white).frame(width: 2, height: 10)
                    .offset(x: proxy.size.width * Double(target) / total - 1)
            }
        }
        .frame(height: 4).padding(.horizontal, 3).accessibilityHidden(true)
    }

    private func beginCountdown() {
        let setID = set.id
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for value in stride(from: 3, through: 1, by: -1) {
                countdown = value
                model.haptics.play(.countdownTick)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            model.haptics.play(.countdownGo)
            model.startHold(setID: setID) // valida que a série ainda é a atual e a sessão está ativa
        }
    }
}

/// Cardio: "Iniciar" liga o cronômetro (o iPhone vê o mesmo); depois, tempo grande, FC/zona e Concluir
/// (distância/nível ficam no iPhone).
struct CardioView: View {
    @Environment(WatchSessionModel.self) private var model
    let exercise: SessionSnapshot.Exercise
    let set: SessionSnapshot.ExerciseSet

    private var isRunning: Bool { model.display?.holdSetID == set.id }

    var body: some View {
        VStack(spacing: 4) {
            Text(exercise.name).font(WF.exerciseName).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = model.display?.holdElapsed(at: context.date) ?? 0 // congela na pausa
                    Text(WatchFormat.clock(elapsed)).font(WF.number(WatchLayout.timerFontSize, weight: .semibold))
                        .accessibilityLabel("Tempo \(WatchFormat.clock(elapsed))")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                heartRate
            } else {
                Text("Cardio").font(.footnote).foregroundStyle(WF.textSecondary)
                if let seconds = set.targetDurationSeconds {
                    Text(WatchFormat.clock(Double(seconds))).font(WF.number(30, weight: .semibold))
                }
            }
            Text(WatchFormat.target(text: set.targetText, effort: nil)).font(.footnote).foregroundStyle(WF.textSecondary)
            Spacer(minLength: 0)
            if isRunning {
                WatchPrimaryButton(title: "Concluir", accessibilityLabel: "Concluir \(exercise.name)") {
                    model.completeCurrentSet() // encerra o cronômetro; duração = tempo ativo
                }
            } else {
                WatchPrimaryButton(title: "Iniciar", systemImage: "play.fill", accessibilityLabel: "Iniciar \(exercise.name)") {
                    model.startCardio()
                }
            }
        }
    }

    private var heartRate: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill").foregroundStyle(WF.health.opacity(model.liveMetrics.heartRate == nil ? 0.4 : 1)).accessibilityHidden(true)
            Text(model.liveMetrics.heartRate.map(String.init) ?? "—").font(WF.number(20, weight: .semibold))
            if let zone = model.liveMetrics.heartRateZone {
                Text("Z\(zone)").font(.footnote.weight(.semibold)).foregroundStyle(WF.zone(zone))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entre exercícios, pausa, fim

struct ExerciseIntroView: View {
    @Environment(WatchSessionModel.self) private var model
    let exercise: SessionSnapshot.Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRÓXIMO").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(WF.training)
            Text(exercise.name).font(.headline).lineLimit(3)
            Text(summary).font(.footnote).foregroundStyle(WF.textSecondary)
            Spacer(minLength: 0)
            WatchPrimaryButton(title: "Começar") { model.startIntroExercise() }
        }
        .accessibilityElement(children: .contain)
    }

    /// "3 × 12–15 · 15 kg".
    private var summary: String {
        guard let first = exercise.sets.first else { return "—" }
        var line = "\(exercise.sets.count) × \(first.targetText)"
        if let load = first.load ?? first.plannedLoad, !load.isBodyweight || load.value != 0 {
            line += " · \(WatchFormat.load(load, compact: true))"
        }
        return line
    }
}

struct PausedView: View {
    @Environment(WatchSessionModel.self) private var model
    let display: SessionSnapshot

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("Pausado").font(.headline).foregroundStyle(WF.attention)
            Text(WatchFormat.clock(display.elapsed(at: Date()))).font(WF.number(WatchLayout.timerFontSize, weight: .semibold))
            Spacer(minLength: 0)
            WatchPrimaryButton(title: "Retomar", systemImage: "play.fill") { model.resume() }
        }
    }
}

struct AllDoneView: View {
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(WF.success).accessibilityHidden(true)
            Text("Treino completo").font(.headline)
            Spacer(minLength: 0)
            WatchPrimaryButton(title: "Finalizar", systemImage: "flag.checkered") { finishing = true }
        }
        .sheet(isPresented: $finishing) { FinishView() }
    }
}
