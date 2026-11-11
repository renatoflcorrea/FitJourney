import Foundation

/// Relógio da sessão derivado só de datas persistidas (SPEC §4.1): nunca de timer em memória.
/// A UI usa `TimelineView`/`Text(timerInterval:)` e chama `elapsed(at:)`/`restRemaining(at:)`.
struct SessionClock: Sendable, Hashable {
    var startedAt: Date
    var endedAt: Date?
    /// Início da pausa atual (`nil` = rodando).
    var pausedAt: Date?
    /// Soma das pausas já encerradas, em segundos.
    var accumulatedPauseSeconds: TimeInterval = 0
    /// Fim do descanso em curso (`nil` = sem descanso).
    var restEndsAt: Date?

    init(startedAt: Date, endedAt: Date? = nil, pausedAt: Date? = nil,
         accumulatedPauseSeconds: TimeInterval = 0, restEndsAt: Date? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedAt = pausedAt
        self.accumulatedPauseSeconds = accumulatedPauseSeconds
        self.restEndsAt = restEndsAt
    }

    var isPaused: Bool { pausedAt != nil && endedAt == nil }
    var isFinished: Bool { endedAt != nil }

    /// Tempo ativo: (fim ou início da pausa ou agora) − início − pausas. Nunca negativo.
    func elapsed(at now: Date) -> TimeInterval {
        // Se há pausa aberta (mesmo com fim gravado), o trecho pausado não conta.
        let reference = [endedAt, pausedAt].compactMap { $0 }.min() ?? now
        return max(0, reference.timeIntervalSince(startedAt) - accumulatedPauseSeconds)
    }

    /// Segundos de descanso restantes; `nil` sem descanso, encerrado ou já vencido.
    /// Durante a pausa o descanso fica congelado no valor do início da pausa.
    func restRemaining(at now: Date) -> TimeInterval? {
        guard let restEndsAt, endedAt == nil else { return nil }
        let reference = pausedAt ?? now
        let remaining = restEndsAt.timeIntervalSince(reference)
        return remaining > 0 ? remaining : nil
    }

    func isResting(at now: Date) -> Bool { restRemaining(at: now) != nil }

    // MARK: Transições (puras; o store persiste o resultado)

    mutating func pause(at now: Date) {
        guard pausedAt == nil, endedAt == nil else { return }
        pausedAt = now
    }

    /// Retoma; o descanso em curso é empurrado pela duração da pausa.
    mutating func resume(at now: Date) {
        guard let pausedAt, endedAt == nil else { return }
        let paused = max(0, now.timeIntervalSince(pausedAt))
        accumulatedPauseSeconds += paused
        if let restEndsAt, restEndsAt > pausedAt { self.restEndsAt = restEndsAt.addingTimeInterval(paused) }
        self.pausedAt = nil
    }

    mutating func startRest(seconds: Int, at now: Date) {
        guard endedAt == nil else { return }
        restEndsAt = seconds > 0 ? (pausedAt ?? now).addingTimeInterval(TimeInterval(seconds)) : nil
    }

    /// +15 s / −15 s. Se o resultado já venceu, encerra o descanso.
    mutating func adjustRest(by seconds: Int, at now: Date) {
        guard let restEndsAt else { return }
        let adjusted = restEndsAt.addingTimeInterval(TimeInterval(seconds))
        self.restEndsAt = adjusted > (pausedAt ?? now) ? adjusted : nil
    }

    mutating func skipRest() { restEndsAt = nil }

    mutating func finish(at now: Date) {
        guard endedAt == nil else { return }
        if let pausedAt {
            accumulatedPauseSeconds += max(0, now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
        endedAt = now
        restEndsAt = nil
    }
}
