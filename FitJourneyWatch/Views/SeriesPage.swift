import SwiftUI

/// Página Série (inicial): muda de conteúdo conforme o estado — série → descanso → sustentação/cardio → próximo exercício.
///
/// W4: nesta página a Coroa **não altera nada** (o pulso dobrado na série girava a carga sem querer). A carga é um
/// botão que abre o editor (`LoadEditorView`); com texto grande a página rola e a Coroa só rola.
struct SeriesPage: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
                .transition(.opacity)
        }
        .accessibilityLabel("Série")
        // Editor de carga: o estado é do modelo (abre/fecha de forma síncrona e fecha sozinho se a sessão acaba ou a
        // série atual muda). A folha fica aqui, e não na série/descanso, para não fechar quando o descanso termina e
        // a página troca de conteúdo por baixo dela. Fechar a folha por qualquer caminho = Cancelar.
        .sheet(item: Binding(get: { model.loadEditor }, set: { if $0 == nil { model.cancelLoadEdit() } })) { draft in
            LoadEditorView(draft: draft)
        }
    }

    private func editLoad(_ setID: UUID) { model.openLoadEditor(setID: setID) }

    @ViewBuilder private func content(at date: Date) -> some View {
        if let display = model.display {
            if display.status == .paused {
                PausedView(display: display)
            } else if let remaining = display.restRemaining(at: date) {
                RestView(remaining: remaining, editLoad: editLoad)
            } else if let finished = model.restFinishedAt, date.timeIntervalSince(finished) < 2 {
                RestDoneView()
            } else if let set = model.currentSet, let exercise = model.currentExercise {
                if model.introExerciseID == exercise.id {
                    ExerciseIntroView(exercise: exercise)
                } else {
                    switch exercise.measurementKind {
                    case .isometric: HoldView(exercise: exercise, set: set)
                    case .timeOrDistance: CardioView(exercise: exercise, set: set)
                    default: ActiveSetView(exercise: exercise, set: set, editLoad: editLoad)
                    }
                }
            } else {
                AllDoneView()
            }
        }
    }
}

// MARK: - Série ativa

struct ActiveSetView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let exercise: SessionSnapshot.Exercise
    let set: SessionSnapshot.ExerciseSet
    /// Abre o editor de carga da série.
    var editLoad: (UUID) -> Void = { _ in }

    private var isLargeText: Bool { typeSize >= .accessibility1 }
    private var load: WatchLoad? { effectiveLoad(of: set, in: exercise) }
    private var isLastSetOfExercise: Bool { exercise.sets.filter { !$0.isCompleted }.count <= 1 }
    private var position: (index: Int, of: Int) {
        (exercise.sets.firstIndex { $0.id == set.id }.map { $0 + 1 } ?? 1, exercise.sets.count)
    }

    var body: some View {
        Group {
            if isLargeText {
                // Texto grande: a página rola (a Coroa só rola — nada nesta página reage a ela).
                ScrollView { VStack(spacing: 6) { header; loadButton; target } }
                    .safeAreaInset(edge: .bottom) { completeButton }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    header
                    Spacer(minLength: 0)
                    loadButton
                    target
                    Spacer(minLength: 0)
                    completeButton
                }
            }
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

    /// Carga como botão de vidro (W4): número grande como antes + "±" laranja de afordância. Toque abre o editor.
    @ViewBuilder private var loadButton: some View {
        if let load {
            let unset = isLoadUnset(set)
            Button { editLoad(set.id) } label: {
                LoadButtonLabel(load: load, isUnset: unset, fontSize: WatchLayout.loadFontSize)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Carga")
            .accessibilityValue(unset ? String(localized: "sem carga definida") : WatchFormat.spokenLoad(load))
            .accessibilityHint(unset ? Text("Toque para definir") : Text("Toque para ajustar"))
            .accessibilityAddTraits(.isButton)
            .accessibilitySortPriority(3)
        }
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

/// Rótulo do botão de carga da Série: "26,0 kg" · "PC +10 kg" · "Definir carga", com o "±" de afordância.
struct LoadButtonLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let load: WatchLoad
    let isUnset: Bool
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if isUnset {
                Text("Definir carga").font(.headline).foregroundStyle(WF.training)
                    .minimumScaleFactor(0.7).lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: number)
                        .font(WF.number(fontSize))
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: load.value))
                    if let unit {
                        Text(verbatim: unit).font(.footnote.weight(.semibold)).foregroundStyle(WF.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "plusminus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(WF.training)
                .accessibilityHidden(true)
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(.rect(cornerRadius: 18))
    }

    /// "26,0" · "PC +10" · "PC".
    private var number: String {
        WatchFormat.load(load).replacingOccurrences(of: " kg", with: "").replacingOccurrences(of: " lb", with: "")
    }

    private var unit: String? {
        load.isBodyweight && load.value == 0 ? nil : (load.unit == .kg ? "kg" : "lb")
    }
}

// MARK: - Descanso

struct RestView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let remaining: TimeInterval
    /// Abre o editor de carga da próxima série.
    var editLoad: (UUID) -> Void = { _ in }
    @State private var showingReps = false

    private var next: (set: SessionSnapshot.ExerciseSet, exercise: SessionSnapshot.Exercise)? {
        guard let set = model.currentSet, let exercise = model.currentExercise else { return nil }
        return (set, exercise)
    }

    var body: some View {
        Group {
            // Texto grande: tudo rola numa coluna só, com "Pular" logo após o tempo e "+ reps"/"+15 s" abaixo,
            // sem botão fixo cobrindo as secundárias. A Coroa só rola.
            if typeSize >= .accessibility1 { ScrollView { column(skipFirst: true) } }
            else { VStack(spacing: 4) { column(skipFirst: false); Spacer(minLength: 0); skipButton } }
        }
        .sheet(isPresented: $showingReps) { RepsSheet() }
    }

    private func column(skipFirst: Bool) -> some View {
        VStack(spacing: 4) {
            Text(WatchFormat.clock(remaining.rounded(.up)))
                .font(WF.number(WatchLayout.timerFontSize, weight: .semibold))
                .minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityLabel("Descanso, \(Int(remaining.rounded(.up))) segundos restantes")
            progressBar
            nextLoadChip
            if skipFirst { skipButton }
            // Mesma largura total do "Pular": as bordas externas coincidem com as dele.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { secondaryButtons }
                VStack(spacing: 5) { secondaryButtons }
            }
            .buttonStyle(WatchButtonStyle(height: WatchLayout.restSecondaryHeight))
            .font(.footnote.weight(.semibold))
        }
    }

    /// "Próxima: 26,0 kg ±" — botão de vidro em largura total que abre o editor da próxima série (W4); a área de
    /// toque ainda cresce um pouco para cima, sobre o tempo e a barra, que não são tocáveis.
    @ViewBuilder private var nextLoadChip: some View {
        if let next, let load = effectiveLoad(of: next.set, in: next.exercise) {
            let unset = isLoadUnset(next.set)
            Button { editLoad(next.set.id) } label: {
                HStack(spacing: 6) {
                    Text(unset ? "Próxima: definir carga" : "Próxima: \(WatchFormat.load(load))")
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "plusminus").font(.footnote.weight(.bold)).foregroundStyle(WF.training)
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: WatchLayout.restNextLoadHeight)
                .padding(.top, WatchLayout.chipTouchExtension)
                .contentShape(.rect)
                .padding(.top, -WatchLayout.chipTouchExtension)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unset ? Text("Próxima série sem carga definida") : Text("Próxima série, \(WatchFormat.spokenLoad(load))"))
            .accessibilityHint(unset ? Text("Toque para definir") : Text("Toque para ajustar"))
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        Button { showingReps = true } label: { Text("+ reps") }
            .accessibilityLabel("Registrar repetições")
        Button { model.extendRest() } label: { Text("+15 s") }
            .accessibilityLabel("Mais quinze segundos")
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

/// Aviso curto de 2 s — só com o alerta insistente desligado (ligado: `RestAlertView` em tela cheia).
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
                    .buttonStyle(WatchButtonStyle())
                Button("Salvar") { if let set = lastCompleted { model.updateReps(setID: set.id, reps: Int(reps)) }; dismiss() }
                    .buttonStyle(WatchButtonStyle(kind: .primary))
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
