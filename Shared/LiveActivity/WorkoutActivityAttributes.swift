import ActivityKit
import Foundation

/// Atividade ao Vivo da sessão de treino (DESIGN_DIRECTION §4.14). Compilado no app e na extensão
/// `FitJourneyWidgets` — só Foundation/ActivityKit.
///
/// Uma atividade por sessão (`sessionID`). O app monta o `ContentState` a partir do `SessionSnapshot`
/// (`LiveActivityStateMapper`) com os textos já formatados (unidade de carga, alvo como prescrito);
/// a extensão só desenha. Tempos são datas: os contadores são desenhados pelo sistema
/// (`Text(timerInterval:)`), nunca por atualização a cada segundo.
struct WorkoutActivityAttributes: ActivityAttributes {
    /// Sessão dona da atividade (intents e reconciliação ao reabrir o app).
    var sessionID: UUID
    /// Nome da ficha ("A — Peito e tríceps"; vazio = treino livre).
    var routineName: String
    /// `Routine.colorName` (paleta de fichas, §2.1.1); vazio = sem cor.
    var routineColorName: String

    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            /// Exercitando: série atual.
            case exercising
            /// Descanso em curso (`restEndsAt`). Vencido sem atualização (`isStale`) = descanso concluído.
            case resting
            /// Descanso concluído anunciado pelo app (com alerta); volta a `exercising` depois.
            case restDone
            /// Sustentação isométrica: contagem regressiva até o alvo.
            case hold
            /// Cronômetro de cardio: contagem progressiva.
            case cardio
            case paused
            /// Todos os exercícios feitos, falta finalizar no app.
            case allDone
            /// Treino salvo (estado final, ao encerrar a atividade).
            case finished
        }

        var phase: Phase
        /// Exercício atual (ou o nome da ficha em `finished`).
        var exerciseName: String
        /// "Série 2 de 4" — posição (1-based) e total da série atual (a próxima, no descanso).
        var setIndex: Int?
        var setCount: Int?
        /// "26 kg", "PC +10 kg" (na unidade de Ajustes).
        var loadText: String?
        /// Alvo como prescrito: "8–12", "10", "AMRAP", "45 s".
        var targetText: String?
        /// "RIR 2" / "RPE 8,5".
        var effortText: String?
        /// Detalhe por extenso para o VoiceOver ("26 quilos, alvo 8 a 12 repetições").
        var spokenDetail: String
        /// Fim e duração total (com ajustes) do descanso em curso.
        var restEndsAt: Date?
        var restTotalSeconds: Double?
        /// Sustentação/cardio em curso (início já deslocado pelas pausas) e alvo em segundos.
        var holdStartedAt: Date?
        var holdTargetSeconds: Int?
        /// Base do tempo de sessão: `startedAt + pausas acumuladas` (contagem progressiva pelo sistema).
        var sessionTimerStart: Date
        /// Tempo de sessão congelado (pausado/concluído); `nil` = contando.
        var frozenElapsedSeconds: Int?
        /// Progresso "3 de 6" exercícios.
        var exercisesDone: Int
        var exercisesTotal: Int
        /// "52 min · 18 séries · 8.420 kg" (só `finished`).
        var summaryText: String?
    }
}

// MARK: - Apoio de apresentação (puro, testável nos dois alvos)

extension WorkoutActivityAttributes.ContentState {
    /// Fase a desenhar: descanso que venceu sem atualização (`context.isStale`) vira "Descanso concluído".
    func displayPhase(isStale: Bool, now: Date = Date()) -> Phase {
        guard phase == .resting else { return phase }
        if isStale { return .restDone }
        if let restEndsAt, restEndsAt <= now { return .restDone }
        return .resting
    }

    /// Início do descanso (para a barra regressiva).
    var restStartsAt: Date? {
        guard let restEndsAt else { return nil }
        return restEndsAt.addingTimeInterval(-max(1, restTotalSeconds ?? 1))
    }

    /// Intervalo do descanso para `Text(timerInterval:)`/`ProgressView(timerInterval:)`.
    var restInterval: ClosedRange<Date>? {
        guard let restEndsAt, let start = restStartsAt, start < restEndsAt else { return nil }
        return start...restEndsAt
    }

    /// Fim da sustentação (início + alvo).
    var holdInterval: ClosedRange<Date>? {
        guard let holdStartedAt else { return nil }
        let target = TimeInterval(max(1, holdTargetSeconds ?? 0))
        return holdStartedAt...holdStartedAt.addingTimeInterval(holdTargetSeconds == nil ? 8 * 3_600 : target)
    }

    /// Intervalo aberto do tempo de sessão (o sistema encerra atividades em 8 h).
    var sessionInterval: ClosedRange<Date> {
        sessionTimerStart...sessionTimerStart.addingTimeInterval(24 * 3_600)
    }

    /// "Série 2 de 4" (`nil` sem série atual).
    var setPositionText: String? {
        guard let setIndex, let setCount else { return nil }
        return String(localized: "Série \(setIndex) de \(setCount)")
    }

    /// "2/4" da ilha compacta.
    var compactSetText: String? {
        guard let setIndex, let setCount else { return nil }
        return "\(setIndex)/\(setCount)"
    }

    /// "26 kg · alvo 8–12 · RIR 2" (`includeEffort` = linha da série; o descanso mostra sem RIR).
    func detailText(includeEffort: Bool) -> String? {
        var parts: [String] = []
        if let loadText, !loadText.isEmpty { parts.append(loadText) }
        if let targetText, !targetText.isEmpty { parts.append(String(localized: "alvo \(targetText)")) }
        if includeEffort, let effortText, !effortText.isEmpty { parts.append(effortText) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3 de 6".
    var progressText: String { String(localized: "\(exercisesDone) de \(exercisesTotal)") }

    /// Fração do progresso da sessão (0…1).
    var progressFraction: Double {
        guard exercisesTotal > 0 else { return 0 }
        return min(1, max(0, Double(exercisesDone) / Double(exercisesTotal)))
    }

    /// Tempo de sessão congelado em "32:14".
    var frozenElapsedText: String? {
        frozenElapsedSeconds.map(Self.clock)
    }

    /// "1:05" / "1:02:03" (mesmo formato de `FJFormat.clock`, sem depender do DesignSystem).
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        guard h > 0 else { return "\(m):\(ss)" }
        return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)"
    }
}
