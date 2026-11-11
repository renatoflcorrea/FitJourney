import AppIntents
import SwiftUI
import WidgetKit

typealias WorkoutState = WorkoutActivityAttributes.ContentState

// MARK: - Peças comuns (Tela Bloqueada e ilha expandida)

/// Rótulo do estado (linha 1, à esquerda): glifo/símbolo + texto.
struct LiveActivityStateLabel: View {
    let state: WorkoutState
    let phase: WorkoutState.Phase
    let palette: LiveActivityPalette
    /// Na ilha expandida a série mostra "SÉRIE 2 DE 4" (o nome vai para baixo); na Tela Bloqueada, o nome.
    var exercisingShowsSet = false

    var body: some View {
        HStack(spacing: FJSpacing.s) {
            symbol
            label.lineLimit(1)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch phase {
        case .restDone, .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success).font(.body.weight(.semibold))
        case .paused:
            Image(systemName: "pause.fill").foregroundStyle(palette.secondary).font(.body.weight(.semibold))
        default:
            StepsGlyph(size: 20).foregroundStyle(palette.accent)
        }
    }

    @ViewBuilder private var label: some View {
        switch phase {
        case .resting:
            overline("DESCANSO", color: palette.accent)
        case .restDone:
            overline("DESCANSO CONCLUÍDO", color: palette.success)
        case .exercising:
            if exercisingShowsSet, let text = state.setPositionText {
                Text(text.uppercased()).font(FJFont.overline).foregroundStyle(palette.accent)
            } else {
                Text(state.exerciseName).font(FJFont.cardTitle).foregroundStyle(palette.primary)
            }
        case .hold:
            overline("SUSTENTAÇÃO", color: palette.accent)
        case .cardio:
            Text(state.exerciseName).font(FJFont.cardTitle).foregroundStyle(palette.primary)
        case .paused:
            overline("PAUSADO", color: palette.secondary)
        case .allDone:
            overline("TREINO COMPLETO", color: palette.accent)
        case .finished:
            overline("TREINO CONCLUÍDO", color: palette.success)
        }
    }

    private func overline(_ key: LocalizedStringKey, color: Color) -> some View {
        Text(key).font(FJFont.overline).foregroundStyle(color)
    }
}

/// Tempo da sessão (linha 1, à direita): contado pelo sistema, ou congelado (pausado/concluído).
struct LiveActivitySessionTime: View {
    let state: WorkoutState
    let palette: LiveActivityPalette

    var body: some View {
        Group {
            if let frozen = state.frozenElapsedText {
                Text(frozen)
            } else {
                Text(timerInterval: state.sessionInterval, countsDown: false)
            }
        }
        .font(FJFont.numberCaption)
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(Text("Tempo de treino"))
    }
}

/// Barra fina (4 pt) com trilho neutro.
struct LiveActivityBar<Fill: View>: View {
    let palette: LiveActivityPalette
    @ViewBuilder var fill: Fill

    var body: some View {
        fill
            .tint(palette.bar)
            .frame(height: 4)
            .clipShape(Capsule())
    }
}

/// Corpo por estado (abaixo da linha 1).
struct LiveActivityBody: View {
    let state: WorkoutState
    let phase: WorkoutState.Phase
    let palette: LiveActivityPalette
    let sessionID: UUID
    /// 44 pt na Tela Bloqueada, 40 pt na ilha expandida.
    var timerSize: CGFloat = 44
    /// Ilha expandida: a série mostra o nome do exercício como título.
    var exercisingTitleIsExercise = false

    var body: some View {
        switch phase {
        case .resting: resting
        case .restDone: titleBlock(state.setPositionText ?? state.exerciseName, detail: state.detailText(includeEffort: false))
        case .exercising: exercising
        case .hold, .cardio: holdOrCardio
        case .paused: paused
        case .allDone: allDone
        case .finished: titleBlock(state.exerciseName, detail: state.summaryText)
        }
    }

    // Descanso: contagem grande + "A seguir"; barra regressiva; +15 s e Pular.
    private var resting: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            HStack(alignment: .center, spacing: FJSpacing.l) {
                countdown
                ViewThatFits(in: .vertical) {
                    nextSet(showsCaption: true)
                    nextSet(showsCaption: false)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(restingAccessibilityLabel)
            if let interval = state.restInterval {
                LiveActivityBar(palette: palette) {
                    ProgressView(timerInterval: interval, countsDown: true, label: { EmptyView() },
                                 currentValueLabel: { EmptyView() })
                    .progressViewStyle(.linear)
                }
                .accessibilityHidden(true)
            }
            HStack(spacing: FJSpacing.s) {
                Button(intent: AdjustRestIntent(sessionID: sessionID, seconds: 15)) {
                    actionLabel("+ 15 s", fill: palette.neutralFill, text: palette.primary)
                }
                .accessibilityLabel(Text("Adicionar 15 segundos"))
                Button(intent: SkipRestIntent(sessionID: sessionID)) {
                    actionLabel("Pular", fill: palette.primaryFill, text: .white)
                }
                .accessibilityLabel(Text("Pular descanso"))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var countdown: some View {
        if let interval = state.restCountdownInterval {
            Text(timerInterval: interval, countsDown: true)
                .font(FJFont.timer(size: timerSize))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: timerSize * 2, alignment: .leading)
        }
    }

    private func nextSet(showsCaption: Bool) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            if showsCaption {
                Text("A seguir").font(FJFont.caption).foregroundStyle(palette.secondary)
            }
            if let position = state.setPositionText {
                Text(position).font(FJFont.label.weight(.semibold)).foregroundStyle(palette.primary)
            }
            if let detail = state.detailText(includeEffort: false) {
                Text(detail).font(FJFont.numberCaption).foregroundStyle(palette.secondary)
            }
        }
        .lineLimit(1)
    }

    private var restingAccessibilityLabel: Text {
        var next = [state.setPositionText, state.spokenDetail.isEmpty ? nil : state.spokenDetail]
            .compactMap { $0 }.joined(separator: ", ")
        if next.isEmpty { next = state.exerciseName }
        // Rótulo estático (o contador do sistema não entra num elemento `.ignore`): o horário do fim.
        guard let end = state.restEndsAt else { return Text("Descanso. A seguir: \(next)") }
        let time = end.formatted(date: .omitted, time: .shortened)
        return Text("Descanso até \(time). A seguir: \(next)")
    }

    private func actionLabel(_ key: LocalizedStringKey, fill: Color, text: Color) -> some View {
        Text(key)
            .font(FJFont.label.weight(.semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }

    // Série: "Série 2 de 4" + alvo; barra da sessão com "3 de 6".
    private var exercising: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            titleBlock(exercisingTitleIsExercise ? state.exerciseName : (state.setPositionText ?? state.exerciseName),
                       detail: state.detailText(includeEffort: true))
            sessionProgress
        }
    }

    private var sessionProgress: some View {
        HStack(spacing: FJSpacing.s) {
            // Progresso estático: barra desenhada (trilho neutro + preenchimento), sem `ProgressView`.
            Capsule().fill(palette.neutralFill)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(palette.bar).frame(width: proxy.size.width * state.progressFraction)
                    }
                }
                .frame(height: 4)
            Text(state.progressText).font(FJFont.numberCaption).foregroundStyle(palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(state.exercisesDone) de \(state.exercisesTotal) exercícios"))
    }

    // Sustentação (regressiva até o alvo) / cardio (progressiva).
    private var holdOrCardio: some View {
        HStack(alignment: .center, spacing: FJSpacing.l) {
            if let interval = state.holdInterval {
                Text(timerInterval: interval, countsDown: state.holdCountsDown)
                    .font(FJFont.timer(size: timerSize))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                if phase == .hold {
                    Text(state.exerciseName).font(FJFont.label.weight(.semibold)).foregroundStyle(palette.primary)
                }
                if let target = state.holdTargetSeconds {
                    Text("alvo \(WorkoutState.clock(target))").font(FJFont.numberCaption).foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // Pausado: tempo congelado (texto estático) + exercício.
    private var paused: some View {
        HStack(alignment: .center, spacing: FJSpacing.l) {
            Text(state.frozenElapsedText ?? "")
                .font(FJFont.timer(size: timerSize))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(state.exerciseName).font(FJFont.label.weight(.semibold)).foregroundStyle(palette.primary)
                if let position = state.setPositionText {
                    Text(position).font(FJFont.caption).foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var allDone: some View {
        titleBlock(String(localized: "Finalize no app para salvar"), detail: nil)
    }

    private func titleBlock(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            Text(title).font(FJFont.sectionTitle).foregroundStyle(palette.primary)
            if let detail {
                Text(detail).font(FJFont.numberCaption).foregroundStyle(palette.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tela Bloqueada / banner

struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutState
    let isStale: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let phase = state.displayPhase(isStale: isStale)
        let palette = LiveActivityPalette.lockScreen.luminanceReduced(isLuminanceReduced)
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            // Texto grande: some primeiro o tempo da sessão.
            ViewThatFits(in: .horizontal) {
                header(phase: phase, palette: palette, showsTime: true)
                header(phase: phase, palette: palette, showsTime: false)
            }
            LiveActivityBody(state: state, phase: phase, palette: palette, sessionID: attributes.sessionID)
        }
        .padding(FJSpacing.l)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func header(phase: WorkoutState.Phase, palette: LiveActivityPalette, showsTime: Bool) -> some View {
        HStack(spacing: FJSpacing.s) {
            LiveActivityStateLabel(state: state, phase: phase, palette: palette)
            Spacer(minLength: FJSpacing.s)
            if showsTime, phase != .paused {
                LiveActivitySessionTime(state: state, palette: palette).fixedSize()
            }
        }
    }
}
