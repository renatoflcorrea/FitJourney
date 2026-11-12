import SwiftUI

/// Doca de ação (base da tela): um modo por vez — concluir série, descanso, sustentação/cronômetro,
/// próximo exercício ou finalizar (DESIGN_DIRECTION §4.5).
struct SessionDock: View {
    let mode: SessionPresentation.DockMode
    let snapshot: SessionSnapshot
    let coordinator: SessionCoordinator
    let holdPrep: SessionHoldPrep?
    let onAddExercise: () -> Void
    let onAdvance: () -> Void
    let onFinish: () -> Void
    let onStartPrep: (UUID) -> Void
    let onCancelPrep: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                if dynamicTypeSize.isAccessibilitySize {
                    // Texto grande: doca compacta (Pular visível; ±15 s num menu) para não cobrir ~40 % da tela.
                    SessionCompactRest(
                        endsAt: endsAt, nextUp: nextUp,
                        onAdjust: { coordinator.send(.adjustRest(seconds: Int($0))) },
                        onSkip: { coordinator.send(.skipRest) },
                        signalsFinish: !coordinator.restAlertTakesOver
                    )
                } else {
                    FJRestTimerView(
                        endsAt: endsAt, total: total, nextUp: nextUp,
                        onAdjust: { coordinator.send(.adjustRest(seconds: Int($0))) },
                        // `skipRest` também dispensa o descanso já vencido (limpa no motor).
                        onSkip: { coordinator.send(.skipRest) },
                        // Com o alerta insistente a caminho, só ele vibra e anuncia.
                        signalsFinish: !coordinator.restAlertTakesOver
                    )
                }
            case .holding(let setID, let startedAt, let target, let isCardio, let targetDistance):
                SessionHoldPanel(
                    startedAt: startedAt, targetSeconds: target, targetDistanceMeters: targetDistance, isCardio: isCardio,
                    elapsedAt: { snapshot.holdElapsed(at: $0) ?? 0 }
                ) {
                    coordinator.send(.endHold(setID: setID))
                }
            case .set(let setID, let title, let detail, let measurement, _):
                Text(detail)
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                    .frame(maxWidth: .infinity)
                switch measurement {
                case .isometric:
                    SessionHoldStartButton(
                        title: title, countdown: holdPrep?.setID == setID ? holdPrep?.count : nil,
                        onPrepare: { onStartPrep(setID) }, onCancel: onCancelPrep,
                        onStartNow: { coordinator.send(.startHold(setID: setID)) })
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

// MARK: - Descanso compacto (texto grande)

/// Descanso em tamanhos de acessibilidade: tempo menor (`ScaledMetric` limitado), "Pular"/"Continuar" sempre
/// visível e −15 s / +15 s num menu. Mesmo cálculo por datas do `FJRestTimerView`.
struct SessionCompactRest: View {
    let endsAt: Date
    let nextUp: String?
    let onAdjust: (TimeInterval) -> Void
    let onSkip: () -> Void
    /// Vibra ao zerar; `false` quando o alerta insistente assume o aviso.
    var signalsFinish = true

    @ScaledMetric(relativeTo: .title) private var timerSize: CGFloat = 34

    var body: some View {
        TimelineView(.explicit(FJRestTimerView.ticks(until: endsAt, from: .now))) { context in
            let remaining = max(0, Int(endsAt.timeIntervalSince(context.date).rounded(.up)))
            let finished = remaining == 0
            VStack(spacing: FJSpacing.s) {
                Text(verbatim: FJFormat.clock(remaining))
                    .font(FJFont.timer(size: min(timerSize, 48)))
                    .foregroundStyle(finished ? FJColor.success : FJColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel(Text(finished ? "Descanso concluído" : "Descanso restante"))
                    .accessibilityValue(Text(verbatim: FJFormat.spokenDuration(remaining)))
                    .accessibilityAddTraits(.updatesFrequently)
                Button(action: onSkip) {
                    Text(finished ? "Continuar" : "Pular")
                        .font(.headline)
                        .foregroundStyle(FJColor.onFill)
                        .frame(maxWidth: .infinity, minHeight: FJSize.primaryButton)
                        .background(FJColor.trainingFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(finished ? "Continuar" : "Pular descanso"))
                Menu {
                    Button("−15 s") { onAdjust(-15) }.disabled(finished)
                    Button("+15 s") { onAdjust(15) }
                } label: {
                    Label("Ajustar descanso", systemImage: "plusminus")
                        .font(FJFont.label)
                        .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                }
            }
            .padding(FJSpacing.m)
            .frame(maxWidth: .infinity)
            .fjGlass(in: FJRadius.shape(FJRadius.panel))
            .fjHaptic(.timerFinished, trigger: finished) { _, isFinished in isFinished && signalsFinish }
        }
    }
}

// MARK: - Sustentação

/// "Iniciar sustentação" com 3 s de preparação ("3, 2, 1") e "Iniciar agora" sem contagem (VoiceOver).
/// A contagem vive na tela da sessão; aqui só se mostra.
struct SessionHoldStartButton: View {
    let title: String
    let countdown: Int?
    let onPrepare: () -> Void
    let onCancel: () -> Void
    let onStartNow: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var countSize: CGFloat = 60

    var body: some View {
        if let countdown {
            VStack(spacing: FJSpacing.s) {
                Text(verbatim: "\(countdown)")
                    .font(FJFont.timer(size: min(countSize, 96)))
                    .fjNumericTransition(countsDown: true)
                    .accessibilityLabel(Text("Preparação"))
                    .accessibilityValue(Text(verbatim: "\(countdown)"))
                Button("Iniciar agora", action: onStartNow)
                    .buttonStyle(.fjPrimary(.training))
                Button("Cancelar", action: onCancel)
                    .buttonStyle(.fjSecondary())
            }
            .frame(maxWidth: .infinity)
            .padding(FJSpacing.l)
            .fjGlass(in: FJRadius.shape(FJRadius.panel))
            .fjHaptic(.selection, trigger: countdown)
        } else {
            VStack(spacing: FJSpacing.s) {
                Button(action: onPrepare) { Label(title, systemImage: "timer") }
                    .buttonStyle(.fjPrimary(.training))
                Button("Iniciar agora", action: onStartNow)
                    .buttonStyle(.fjSecondary())
            }
        }
    }
}

/// Contagem regressiva da sustentação (ou cronômetro do cardio); depois da meta continua contando
/// o excedente até "Parar".
struct SessionHoldPanel: View {
    let startedAt: Date
    let targetSeconds: Int?
    var targetDistanceMeters: Double?
    let isCardio: Bool
    /// Tempo ativo no instante dado (`SessionSnapshot.holdElapsed(at:)`: congela na pausa).
    let elapsedAt: (Date) -> TimeInterval
    let onStop: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 60
    @ScaledMetric(relativeTo: .headline) private var stopHeight: CGFloat = FJSize.primaryButton
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = elapsedAt(context.date)
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
                    .font(FJFont.timer(size: min(timerSize, dynamicTypeSize.isAccessibilitySize ? 48 : 96)))
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
                if isCardio, let target = SessionPresentation.cardioTargetText(
                    durationSeconds: targetSeconds, distanceMeters: targetDistanceMeters) {
                    Text("alvo \(target)")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                }
                Button(action: onStop) {
                    Text(isCardio ? "Concluir" : "Parar")
                        .font(.headline)
                        .foregroundStyle(FJColor.onFill)
                        .frame(maxWidth: .infinity, minHeight: stopHeight)
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
