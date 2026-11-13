import ActivityKit
import SwiftUI
import WidgetKit

/// Atividade ao Vivo da sessão de treino (DESIGN_DIRECTION §4.14): Tela Bloqueada/banner e Dynamic
/// Island. Fundo e material do sistema (sem `activityBackgroundTint`); a ilha é sempre preta.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            let phase = state.displayPhase(isStale: context.isStale)
            let palette = LiveActivityPalette.island
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityStateLabel(state: state, phase: phase, palette: palette, exercisingShowsSet: true)
                        .padding(.leading, FJSpacing.xs)
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if phase != .paused {
                        LiveActivitySessionTime(state: state, palette: palette)
                            .padding(.trailing, FJSpacing.xs)
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    }
                }
                // `center` fica vazio (nada sob a câmera).
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityBody(state: state, phase: phase, palette: palette,
                                     sessionID: context.attributes.sessionID, timerSize: 40,
                                     exercisingTitleIsExercise: true)
                        .padding(.horizontal, FJSpacing.xs)
                        .padding(.top, FJSpacing.xs)
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
            } compactLeading: {
                IslandLeading(state: state, phase: phase, palette: palette)
            } compactTrailing: {
                IslandCompactTrailing(state: state, phase: phase, palette: palette)
            } minimal: {
                IslandLeading(state: state, phase: phase, palette: palette)
            }
            .keylineTint(palette.accent)
        }
    }
}

/// Compacta (esquerda) e mínima: anel regressivo no descanso; glifo na série; símbolo nos demais.
struct IslandLeading: View {
    let state: WorkoutState
    let phase: WorkoutState.Phase
    let palette: LiveActivityPalette

    var body: some View {
        Group {
            switch phase {
            case .resting:
                if let interval = state.restInterval {
                    ProgressView(timerInterval: interval, countsDown: true, label: { EmptyView() },
                                 currentValueLabel: { EmptyView() })
                    .progressViewStyle(.circular)
                    .tint(palette.accent)
                    .frame(width: 16, height: 16)
                } else {
                    StepsGlyph(size: 16).foregroundStyle(palette.accent)
                }
            case .restDone, .finished, .allDone:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
            case .paused:
                Image(systemName: "pause.fill").foregroundStyle(.white)
            case .exercising, .hold, .cardio:
                StepsGlyph(size: 16).foregroundStyle(palette.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityKey))
    }

    private var accessibilityKey: LocalizedStringKey {
        switch phase {
        case .resting: "FitRoute, descanso"
        case .restDone: "FitRoute, descanso concluído"
        case .exercising: "FitRoute, série"
        case .hold: "FitRoute, sustentação"
        case .cardio: "FitRoute, cardio"
        case .paused: "FitRoute, pausado"
        case .allDone: "FitRoute, treino completo"
        case .finished: "FitRoute, treino concluído"
        }
    }
}

/// Compacta (direita): contagem de largura fixa no descanso (a ilha não pulsa); "2/4" na série.
struct IslandCompactTrailing: View {
    let state: WorkoutState
    let phase: WorkoutState.Phase
    let palette: LiveActivityPalette

    var body: some View {
        switch phase {
        case .resting:
            if let interval = state.restCountdownInterval {
                Text(timerInterval: interval, countsDown: true)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.accent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44, alignment: .trailing)
            }
        case .hold, .cardio:
            if let interval = state.holdInterval {
                Text(timerInterval: interval, countsDown: state.holdCountsDown)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.accent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44, alignment: .trailing)
            }
        case .paused:
            Text(state.frozenElapsedText ?? "")
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(palette.secondary)
        case .exercising, .restDone:
            Text(state.compactSetText ?? "")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityLabel(Text(state.setPositionText ?? ""))
        case .allDone, .finished:
            Text("\(state.exercisesDone)/\(state.exercisesTotal)")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}
