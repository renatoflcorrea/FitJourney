#if DEBUG
import SwiftUI
import WidgetKit

/// Exemplos do §4.14 (supino inclinado, série 3 de 4, 26 kg, alvo 8–12).
enum WorkoutActivitySamples {
    static let attributes = WorkoutActivityAttributes(
        sessionID: UUID(uuidString: "6C1F3A52-0F4B-4E3C-9B8E-2D5C9A1E7F10")!,
        routineName: "A — Peito e tríceps", routineColorName: "orange")

    private static func base(_ phase: WorkoutState.Phase) -> WorkoutState {
        WorkoutState(phase: phase, exerciseName: "Supino inclinado halter", setIndex: 2, setCount: 4,
                     loadText: "26 kg", targetText: "8–12", effortText: "RIR 2",
                     spokenDetail: "26 kg, alvo 8 a 12 repetições",
                     restEndsAt: nil, restTotalSeconds: nil, holdStartedAt: nil, holdTargetSeconds: nil,
                     sessionTimerStart: Date().addingTimeInterval(-(32 * 60 + 14)), frozenElapsedSeconds: nil,
                     exercisesDone: 3, exercisesTotal: 6, summaryText: nil)
    }

    static var exercising: WorkoutState { base(.exercising) }

    static var resting: WorkoutState {
        var state = base(.resting)
        state.setIndex = 3
        state.restEndsAt = Date().addingTimeInterval(75)
        state.restTotalSeconds = 120
        return state
    }

    static var restDone: WorkoutState {
        var state = base(.restDone)
        state.setIndex = 3
        return state
    }

    static var paused: WorkoutState {
        var state = base(.paused)
        state.frozenElapsedSeconds = 32 * 60 + 14
        return state
    }

    static var finished: WorkoutState {
        var state = base(.finished)
        state.exerciseName = "A — Peito e tríceps"
        state.setIndex = nil
        state.setCount = nil
        state.frozenElapsedSeconds = 52 * 60
        state.summaryText = "52 min · 18 séries · 8.420 kg"
        return state
    }
}

#Preview("Tela Bloqueada", as: .content, using: WorkoutActivitySamples.attributes) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivitySamples.resting
    WorkoutActivitySamples.restDone
    WorkoutActivitySamples.exercising
    WorkoutActivitySamples.paused
    WorkoutActivitySamples.finished
}

#Preview("Ilha compacta", as: .dynamicIsland(.compact), using: WorkoutActivitySamples.attributes) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivitySamples.resting
    WorkoutActivitySamples.exercising
    WorkoutActivitySamples.paused
    WorkoutActivitySamples.restDone
}

#Preview("Ilha expandida", as: .dynamicIsland(.expanded), using: WorkoutActivitySamples.attributes) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivitySamples.resting
    WorkoutActivitySamples.exercising
}

#Preview("Ilha mínima", as: .dynamicIsland(.minimal), using: WorkoutActivitySamples.attributes) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivitySamples.resting
    WorkoutActivitySamples.exercising
    WorkoutActivitySamples.paused
}
#endif
