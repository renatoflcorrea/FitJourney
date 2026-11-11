import Foundation

#if DEBUG
/// iPhone simulado: guarda o programa e a sessão "de verdade", aplica comandos com o mesmo
/// `SessionReducer`, devolve resposta + snapshot (revisão +1) e enfileira o que chega fora de alcance.
/// Usado em previews, testes e no harness de screenshots. Sem latência artificial por padrão.
@MainActor
final class MockWatchTransport: WatchTransport {
    private var continuations: [UUID: AsyncStream<WatchTransportEvent>.Continuation] = [:]

    func makeEventStream() -> AsyncStream<WatchTransportEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        }
    }

    private func yield(_ event: WatchTransportEvent) { for continuation in continuations.values { continuation.yield(event) } }

    private(set) var isReachable: Bool
    /// Programa que o "iPhone" publica (`nil` = sem programa ativo).
    var digest: ProgramDigest?
    /// Sessão do "iPhone" (fonte de verdade simulada).
    private(set) var phoneSnapshot: SessionSnapshot?
    /// Tudo o que o relógio enviou (para asserções).
    private(set) var sent: [WatchLinkMessage] = []
    /// Comandos recebidos fora de alcance (simula `transferUserInfo`); entregues ao reconectar.
    private var offlineQueue: [SessionCommand] = []
    private var appliedCommandIDs: Set<UUID> = []
    /// Recusa o próximo comando com este motivo (testes de rejeição).
    var rejectNext: SessionCommandRejection?
    /// Se `false`, o mock não responde sozinho (testes controlam respostas à mão com `emit`).
    var autoRespond = true
    /// O "iPhone" cria IDs novos de série/exercício ao iniciar sessão (como o `SessionStore` real) — não mascara o bug de IDs (A1).
    var generatesFreshIDs = true

    init(digest: ProgramDigest? = nil, snapshot: SessionSnapshot? = nil, reachable: Bool = true) {
        self.digest = digest
        self.phoneSnapshot = snapshot
        self.isReachable = reachable
    }

    func send(_ message: WatchLinkMessage) {
        sent.append(message)
        guard autoRespond else { return }
        switch message {
        case .command(let command):
            if isReachable { handle(command) } else { offlineQueue.append(command) }
        case .snapshotRequest:
            guard isReachable else { return }
            yield(.message(.programDigest(digest)))
            yield(.message(.snapshot(phoneSnapshot)))
        default:
            break
        }
    }

    /// Entrega uma mensagem ao relógio como se viesse do iPhone.
    func emit(_ message: WatchLinkMessage) { yield(.message(message)) }

    /// Muda a alcançabilidade; ao voltar, entrega a fila acumulada em ordem.
    func setReachable(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        yield(.reachability(reachable))
        if reachable {
            let queued = offlineQueue
            offlineQueue = []
            for command in queued { handle(command) }
        }
    }

    /// O iPhone mexe na sessão sozinho (ex.: sessão iniciada/alterada no aparelho) e publica o snapshot.
    func phoneApplies(_ command: SessionCommand) {
        handle(command, replyTo: false)
    }

    func publishDigest() { yield(.message(.programDigest(digest))) }

    func finish() { continuations.values.forEach { $0.finish() } }

    static func withFreshIDs(_ snapshot: SessionSnapshot) -> SessionSnapshot {
        var s = snapshot
        for e in s.exercises.indices {
            let old = s.exercises[e].id
            s.exercises[e].id = UUID()
            if s.currentExerciseID == old { s.currentExerciseID = s.exercises[e].id }
            for i in s.exercises[e].sets.indices {
                let oldSet = s.exercises[e].sets[i].id
                s.exercises[e].sets[i].id = UUID()
                if s.currentSetID == oldSet { s.currentSetID = s.exercises[e].sets[i].id }
            }
        }
        return s
    }

    private func handle(_ command: SessionCommand, replyTo: Bool = true) {
        let outcome: SessionCommandReply.Outcome
        if appliedCommandIDs.contains(command.commandID) {
            outcome = .duplicate
        } else if let reason = rejectNext {
            rejectNext = nil
            outcome = .rejected(reason)
        } else {
            let updated = SessionReducer.apply(command, to: phoneSnapshot, digest: digest)
            if var updated {
                if case .start = command.kind, generatesFreshIDs { updated = Self.withFreshIDs(updated) }
                updated.revision = (phoneSnapshot?.sessionID == updated.sessionID ? phoneSnapshot?.revision ?? 0 : 0) + 1
                phoneSnapshot = updated
                appliedCommandIDs.insert(command.commandID)
                outcome = .applied
            } else {
                outcome = .rejected(.unknownRoutine)
            }
        }
        if replyTo {
            yield(.message(.commandReply(.init(commandID: command.commandID, sessionID: command.sessionID,
                                                            outcome: outcome, revision: phoneSnapshot?.revision ?? 0))))
        }
        if case .rejected = outcome { return }
        yield(.message(.snapshot(phoneSnapshot)))
    }
}
#endif
