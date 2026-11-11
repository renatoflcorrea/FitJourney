import Foundation

/// Comando idempotente sobre a sessão de treino (SPEC §6.4). O iPhone aplica cada `commandID`
/// uma única vez; reenviar o mesmo comando é seguro. `issuedAt` é o relógio de quem emitiu e vale
/// como horário do fato (ex.: `completedAt` da série) quando o comando chega atrasado (relógio offline).
struct SessionCommand: Codable, Sendable, Hashable, Identifiable {
    var commandID: UUID
    /// Sessão alvo. No `start`, é o ID que a nova sessão vai ter (o emissor já pode renderizar).
    var sessionID: UUID
    var issuedAt: Date
    var origin: WatchCommandOrigin
    var kind: Kind

    var id: UUID { commandID }

    init(commandID: UUID = UUID(), sessionID: UUID, issuedAt: Date = Date(), origin: WatchCommandOrigin, kind: Kind) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.origin = origin
        self.kind = kind
    }

    /// `setID` = `SetLog.id`; `exerciseID` = `SessionExercise.id` (o exercício dentro da sessão).
    /// Cargas e deltas na unidade da carga da série.
    enum Kind: Codable, Sendable, Hashable {
        /// Inicia sessão da ficha (`nil` = treino livre).
        case start(routineID: UUID?)
        /// Conclui com os valores informados; ausentes mantêm o já registrado/planejado. Reps opcionais (D2).
        case completeSet(setID: UUID, reps: Int?, load: WatchLoad?, durationSeconds: Double?, distanceMeters: Double?)
        case uncompleteSet(setID: UUID)
        /// Substitui os valores realizados (ausente = limpa), antes ou depois de concluir.
        case updateSet(setID: UUID, reps: Int?, load: WatchLoad?, durationSeconds: Double?, distanceMeters: Double?)
        /// Soma `delta` à carga exibida da série (Digital Crown: passos de 0,5 kg, D3).
        case adjustLoad(setID: UUID, delta: Double)
        /// Inicia descanso; `nil` = descanso prescrito do exercício atual.
        case startRest(seconds: Int?)
        /// +15 s / −15 s.
        case adjustRest(seconds: Int)
        case skipRest
        /// Isométrico: começa a sustentação (contagem do tempo alvo no emissor).
        case startHold(setID: UUID)
        /// Fim da sustentação: conclui a série com o tempo real (`issuedAt − início`).
        case endHold(setID: UUID)
        case skipExercise(exerciseID: UUID, reason: WatchSkipReason?)
        /// Conclusão manual (com séries pendentes = "concluído parcialmente").
        case completeExercise(exerciseID: UUID)
        /// Escolhe o exercício atual (sobrescreve a regra automática enquanto ele estiver aberto).
        case focusExercise(exerciseID: UUID)
        /// Série extra no exercício (copia alvo/carga da última).
        case addSet(exerciseID: UUID, kind: WatchSetKind?)
        case pause
        case resume
        /// Finaliza com RPE de sessão (1–10) e as propostas de carga confirmadas (`prescriptionID`s).
        case finish(rpe: Int?, applyLoadProposalIDs: [UUID])
        /// Descarta a sessão (nada fica no histórico).
        case discard
    }
}

/// Motivo de recusa de um comando (devolvido ao emissor).
enum SessionCommandRejection: String, Codable, Sendable, Hashable, Error {
    /// Não há sessão com esse ID (ou foi descartada).
    case unknownSession
    /// Já existe outra sessão em andamento (só uma por vez, SPEC §4.1).
    case anotherSessionInProgress
    /// A sessão não está em andamento (finalizada).
    case sessionNotInProgress
    case unknownRoutine
    case unknownSet
    case unknownExercise
    /// Operação não cabe no estado atual (ex.: `endHold` sem sustentação em curso).
    case invalidState
    /// Valor fora do domínio (ex.: reps negativas).
    case invalidValue
    /// Falha ao gravar no banco.
    case persistenceFailed
}

/// Resposta do iPhone a um comando.
struct SessionCommandReply: Codable, Sendable, Hashable {
    var commandID: UUID
    var sessionID: UUID
    var outcome: Outcome
    /// Revisão do estado depois do comando (sem mudança em duplicado/recusa).
    var revision: Int

    enum Outcome: Codable, Sendable, Hashable {
        case applied
        /// Já aplicado antes: nada mudou.
        case duplicate
        case rejected(SessionCommandRejection)
    }
}
