import Foundation

/// `SessionSnapshot` → conteúdo da Atividade ao Vivo (§4.14). Puro: mesma entrada, mesma saída.
///
/// O estado não guarda nada que mude sozinho com o tempo (o tempo da sessão é a data-base, não um
/// contador), então dois snapshots que não mudam o que a atividade mostra dão estados iguais — é isso
/// que deixa o controlador atualizar só quando algo visível mudou.
enum LiveActivityStateMapper {
    typealias State = WorkoutActivityAttributes.ContentState

    static func attributes(for snapshot: SessionSnapshot, routineColorName: String?) -> WorkoutActivityAttributes {
        WorkoutActivityAttributes(sessionID: snapshot.sessionID, routineName: snapshot.routineName,
                                  routineColorName: routineColorName ?? "")
    }

    /// Estado para o snapshot em `now`; `nil` para sessão descartada/desconhecida.
    static func state(for snapshot: SessionSnapshot, now: Date,
                      unit: WeightUnit = WeightUnitPreference.current) -> State? {
        let phase: State.Phase
        switch snapshot.status {
        case .finished: phase = .finished
        case .paused: phase = .paused
        case .active:
            if snapshot.holdStartedAt != nil, let hold = holdSet(in: snapshot) {
                phase = hold.exercise.measurementKind == .timeOrDistance ? .cardio : .hold
            } else if let end = snapshot.restEndsAt, end > now {
                phase = .resting
            } else if snapshot.currentExercise == nil {
                phase = .allDone
            } else {
                phase = .exercising
            }
        case .discarded, .unknown:
            return nil
        }

        // Exercício/série mostrados: o da sustentação em curso, senão o atual (no descanso, a próxima série).
        let focus: (exercise: SessionSnapshot.Exercise, set: SessionSnapshot.ExerciseSet?)?
        if phase == .hold || phase == .cardio, let hold = holdSet(in: snapshot) {
            focus = (hold.exercise, hold.set)
        } else if let exercise = snapshot.currentExercise {
            focus = (exercise, exercise.sets.first { $0.id == snapshot.currentSetID })
        } else {
            focus = nil
        }
        let position = focus.flatMap { focus in
            focus.set.flatMap { set in focus.exercise.sets.firstIndex { $0.id == set.id } }
                .map { (index: $0 + 1, of: focus.exercise.sets.count) }
        }
        let set = focus?.set
        let load = (set?.load ?? set?.plannedLoad).map { PrescriptionFormat.loadText($0.load, displayUnit: unit) }
        let target = set.map(\.targetText).flatMap { $0.isEmpty ? nil : $0 }

        var state = State(
            phase: phase,
            exerciseName: phase == .finished ? routineTitle(snapshot) : (focus?.exercise.name.exerciseDisplayName ?? routineTitle(snapshot)),
            setIndex: phase == .finished ? nil : position?.index,
            setCount: phase == .finished ? nil : position?.of,
            loadText: phase == .finished ? nil : load,
            targetText: phase == .finished ? nil : target,
            effortText: phase == .finished ? nil : set?.effort.map(effortText),
            spokenDetail: "",
            restEndsAt: phase == .resting ? snapshot.restEndsAt : nil,
            restTotalSeconds: phase == .resting ? restTotal(snapshot, exercise: focus?.exercise) : nil,
            holdStartedAt: phase == .hold || phase == .cardio ? snapshot.holdStartedAt : nil,
            holdTargetSeconds: phase == .hold ? set?.targetHoldSeconds
                : phase == .cardio ? set?.targetDurationSeconds : nil,
            sessionTimerStart: snapshot.startedAt.addingTimeInterval(snapshot.accumulatedPauseSeconds),
            frozenElapsedSeconds: phase == .paused || phase == .finished ? Int(snapshot.elapsed(at: now)) : nil,
            exercisesDone: snapshot.metrics.exercisesDone,
            exercisesTotal: snapshot.metrics.exercisesTotal,
            summaryText: phase == .finished ? summaryText(snapshot, now: now, unit: unit) : nil)
        state.spokenDetail = spokenDetail(load: phase == .finished ? nil : load,
                                          target: phase == .finished ? nil : target,
                                          countsReps: focus.map { isReps($0.exercise.measurementKind) } ?? false)
        return state
    }

    /// `staleDate` da atividade: o fim do descanso (o sistema redesenha como "Descanso concluído").
    static func staleDate(for state: State) -> Date? {
        state.phase == .resting ? state.restEndsAt : nil
    }

    /// "Descanso concluído" anunciado pelo app: a próxima série sobe para o título; sem contagem.
    static func restDone(from state: State) -> State {
        var done = state
        done.phase = .restDone
        done.restEndsAt = nil
        done.restTotalSeconds = nil
        return done
    }

    /// Corpo do alerta de fim de descanso: "Série 3 de 4 · 26 kg".
    static func restDoneAlertBody(_ state: State) -> String {
        [state.setPositionText, state.loadText].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Apoio

    private static func routineTitle(_ snapshot: SessionSnapshot) -> String {
        snapshot.routineName.isEmpty ? String(localized: "Treino livre") : snapshot.routineName
    }

    private static func holdSet(in snapshot: SessionSnapshot)
        -> (exercise: SessionSnapshot.Exercise, set: SessionSnapshot.ExerciseSet)? {
        guard let id = snapshot.holdSetID else { return nil }
        for exercise in snapshot.exercises {
            if let set = exercise.sets.first(where: { $0.id == id }) { return (exercise, set) }
        }
        return nil
    }

    /// Duração total do descanso (com ajustes); sem o valor no snapshot, o descanso prescrito do
    /// exercício. Nunca depende de `now` (o estado tem de ser estável para a deduplicação).
    private static func restTotal(_ snapshot: SessionSnapshot, exercise: SessionSnapshot.Exercise?) -> Double? {
        guard snapshot.restEndsAt != nil else { return nil }
        if let total = snapshot.restTotalSeconds, total >= 1 { return total }
        return exercise?.restSeconds.flatMap { $0 > 0 ? Double($0) : nil }
    }

    static func effortText(_ effort: WatchEffort) -> String {
        switch effort {
        case .rir(let value): "RIR \(value)"
        case .rpe(let value): "RPE \(FJFormat.number(value, maxFractionDigits: 1))"
        }
    }

    private static func isReps(_ kind: WatchMeasurementKind) -> Bool {
        kind == .repsAndLoad || kind == .repsOnly
    }

    /// "26 kg, alvo 8 a 12 repetições" (o VoiceOver lê "kg" por extenso).
    private static func spokenDetail(load: String?, target: String?, countsReps: Bool) -> String {
        var parts: [String] = []
        if let load { parts.append(load) }
        if let target {
            let spoken = target.replacingOccurrences(of: "–", with: " a ")
            let numeric = target.unicodeScalars.first.map { CharacterSet.decimalDigits.contains($0) } ?? false
            parts.append(countsReps && numeric ? String(localized: "alvo \(spoken) repetições")
                                               : String(localized: "alvo \(spoken)"))
        }
        return parts.joined(separator: ", ")
    }

    /// "52 min · 18 séries · 8.420 kg".
    private static func summaryText(_ snapshot: SessionSnapshot, now: Date, unit: WeightUnit) -> String {
        let minutes = Int((snapshot.elapsed(at: now) / 60).rounded())
        var parts = [String(localized: "\(minutes) min"),
                     String(localized: "\(snapshot.metrics.completedSets) séries")]
        if snapshot.metrics.volumeKg > 0 {
            parts.append(LoadDisplay.kgText(snapshot.metrics.volumeKg, maxFractionDigits: 0, display: unit))
        }
        return parts.joined(separator: " · ")
    }
}
