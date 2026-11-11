import SwiftUI

/// Doca de ação (base da tela): um modo por vez — concluir série, descanso, sustentação/cronômetro,
/// próximo exercício ou finalizar (DESIGN_DIRECTION §4.5).
struct SessionDock: View {
    let mode: SessionPresentation.DockMode
    let coordinator: SessionCoordinator
    let onAddExercise: () -> Void
    let onContinueAfterRest: () -> Void
    let onAdvance: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: FJSpacing.s) {
            switch mode {
            case .empty:
                Button(action: onAddExercise) { Label("Adicionar exercício", systemImage: "plus") }
                    .buttonStyle(.fjPrimary(.training))
            case .paused:
                Button { coordinator.send(.resume) } label: { Label("Retomar treino", systemImage: "play.fill") }
                    .buttonStyle(.fjPrimary(.training))
            case .rest(let endsAt, let total, let nextUp):
                FJRestTimerView(
                    endsAt: endsAt, total: total, nextUp: nextUp,
                    onAdjust: { coordinator.send(.adjustRest(seconds: Int($0))) },
                    onSkip: {
                        coordinator.send(.skipRest)
                        onContinueAfterRest()
                    }
                )
            case .holding(let setID, let startedAt, let target, let isCardio):
                SessionHoldPanel(setID: setID, startedAt: startedAt, targetSeconds: target, isCardio: isCardio) {
                    coordinator.send(.endHold(setID: setID))
                }
            case .set(let setID, let title, let detail, let measurement, let target):
                Text(detail)
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                switch measurement {
                case .isometric:
                    SessionHoldStartButton(title: title, targetSeconds: target) {
                        coordinator.send(.startHold(setID: setID))
                    }
                case .timeOrDistance:
                    Button { coordinator.send(.startHold(setID: setID)) } label: { Label(title, systemImage: "stopwatch") }
                        .buttonStyle(.fjPrimary(.training))
                default:
                    Button {
                        completeCurrent(setID)
                    } label: {
                        Text(title)
                    }
                    .buttonStyle(.fjPrimary(.training))
                }
            case .next(_, let name):
                Button(action: onAdvance) {
                    Label("Próximo: \(name)", systemImage: "arrow.right")
                }
                .buttonStyle(.fjPrimary(.training))
            case .finish:
                Button(action: onFinish) { Label("Finalizar treino", systemImage: "flag.checkered") }
                    .buttonStyle(.fjPrimary(.training))
            }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.top, FJSpacing.s)
        .padding(.bottom, FJSpacing.s)
    }

    private func completeCurrent(_ setID: UUID) {
        coordinator.send(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil))
    }
}

// MARK: - Sustentação

/// "Iniciar sustentação" com 3 s de preparação ("3, 2, 1") antes de o motor registrar o início.
struct SessionHoldStartButton: View {
    let title: String
    let targetSeconds: Int?
    let onStart: () -> Void
    @State private var countdown: Int?

    var body: some View {
        if let countdown {
            VStack(spacing: FJSpacing.s) {
                Text(verbatim: "\(countdown)")
                    .font(FJFont.timer(size: 60))
                    .fjNumericTransition(countsDown: true)
                    .accessibilityLabel(Text("Preparação"))
                    .accessibilityValue(Text(verbatim: "\(countdown)"))
                Button("Cancelar") { self.countdown = nil }
                    .buttonStyle(.fjSecondary())
            }
            .frame(maxWidth: .infinity)
            .padding(FJSpacing.l)
            .fjGlass(in: FJRadius.shape(FJRadius.panel))
            .task(id: countdown) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let current = self.countdown else { return }
                if current > 1 {
                    self.countdown = current - 1
                } else {
                    self.countdown = nil
                    onStart()
                }
            }
            .fjHaptic(.selection, trigger: countdown)
        } else {
            Button { countdown = 3 } label: { Label(title, systemImage: "timer") }
                .buttonStyle(.fjPrimary(.training))
        }
    }
}

/// Contagem regressiva da sustentação (ou cronômetro do cardio); depois da meta continua contando
/// o excedente até "Parar".
struct SessionHoldPanel: View {
    let setID: UUID
    let startedAt: Date
    let targetSeconds: Int?
    let isCardio: Bool
    let onStop: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 60

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let reached = targetSeconds.map { elapsed >= Double($0) } ?? false
            let shown: Int = {
                guard let targetSeconds else { return Int(elapsed) }
                return reached ? Int(elapsed) - targetSeconds : targetSeconds - Int(elapsed)
            }()
            VStack(spacing: FJSpacing.m) {
                Label(
                    isCardio ? "Cronômetro" : (reached ? "Meta atingida" : "Sustentação"),
                    systemImage: isCardio ? "stopwatch" : (reached ? "checkmark.circle.fill" : "timer")
                )
                .font(FJFont.overline)
                .foregroundStyle(reached ? FJColor.success : FJColor.textSecondary)
                Text(verbatim: (reached ? "+" : "") + FJFormat.clock(shown))
                    .font(FJFont.timer(size: min(timerSize, 96)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .fjNumericTransition(countsDown: !isCardio && !reached)
                    .accessibilityLabel(Text(isCardio ? "Tempo decorrido" : (reached ? "Excedente" : "Sustentação restante")))
                    .accessibilityValue(Text(verbatim: FJFormat.spokenDuration(shown)))
                    .accessibilityAddTraits(.updatesFrequently)
                if let targetSeconds {
                    ProgressView(value: min(1, elapsed / Double(max(targetSeconds, 1))))
                        .tint(FJColor.training)
                        .accessibilityHidden(true)
                }
                Button(action: onStop) {
                    Text(isCardio ? "Concluir" : "Parar")
                        .font(.headline)
                        .foregroundStyle(FJColor.onFill)
                        .frame(maxWidth: .infinity, minHeight: FJSize.primaryButton)
                        .background(FJColor.trainingFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(FJSpacing.l)
            .frame(maxWidth: .infinity)
            .fjGlass(in: FJRadius.shape(FJRadius.panel))
            .fjHaptic(.timerFinished, trigger: reached) { _, new in new }
        }
    }
}
