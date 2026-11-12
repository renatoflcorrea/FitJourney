import Foundation
import Testing
@testable import FitJourneyWatch

/// W4: a carga só muda pelo editor. Cancelar não envia nada; Salvar envia um único `adjustLoad`.
@MainActor
struct WatchLoadEditorTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Sessão em que as séries do 1º exercício só têm a carga planejada (como no iPhone antes de qualquer edição),
    /// para a propagação valer.
    private func planned(completed: Int = 0) -> SessionSnapshot {
        var snapshot = WatchFixtures.snapshot(completed: completed, now: t0, startedAgo: 600, revision: 5)
        for i in snapshot.exercises[0].sets.indices where !snapshot.exercises[0].sets[i].isCompleted {
            snapshot.exercises[0].sets[i].load = nil
        }
        return snapshot
    }

    private func make(completed: Int = 0, snapshot custom: SessionSnapshot? = nil, coalesce: TimeInterval = 0.35)
        -> (WatchSessionModel, MockWatchTransport, SessionSnapshot, RecordingHaptics) {
        let digest = WatchFixtures.digest(now: t0)
        let snapshot = custom ?? WatchFixtures.snapshot(completed: completed, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: digest, snapshot: snapshot, reachable: true)
        transport.autoRespond = false
        let haptics = RecordingHaptics()
        let model = WatchSessionModel(transport: transport, haptics: haptics, health: FixedHealthProvider(access: .authorized),
                                      clock: { self.t0 })
        model.loadCoalesceInterval = coalesce // valor de produção: o editor não pode depender dele
        model.receive(digest: digest)
        model.receive(snapshot: snapshot)
        return (model, transport, snapshot, haptics)
    }

    private func adjustLoads(_ transport: MockWatchTransport) -> [(UUID, Double)] {
        transport.sent.compactMap {
            if case .command(let c) = $0, case .adjustLoad(let id, let delta) = c.kind { (id, delta) } else { nil }
        }
    }

    @Test func cancelarNaoEnviaComando() throws {
        let (model, transport, snapshot, _) = make(snapshot: planned())
        let setID = try #require(snapshot.currentSetID)
        var draft = try #require(model.loadDraft(setID: setID))
        draft.increment(); draft.increment(); draft.set(40)
        #expect(draft.value == 40)
        // Cancelar = descartar o rascunho; o modelo não é chamado.
        _ = draft
        model.flushCoalescedCommands()
        #expect(adjustLoads(transport).isEmpty)
        #expect(model.pendingCount == 0)
        #expect(model.display?.exercises[0].sets[0].plannedLoad?.value == 26)
        #expect(model.display?.exercises[0].sets[0].load == nil)
    }

    @Test func salvarEnviaUmAdjustLoadComOTotalEPropaga() throws {
        let (model, transport, snapshot, _) = make(snapshot: planned())
        let setID = try #require(snapshot.currentSetID)
        var draft = try #require(model.loadDraft(setID: setID))
        draft.increment(); draft.increment(); draft.increment() // 26 → 27,5 (três detentes)
        draft.decrement(); draft.increment()
        model.saveLoad(draft)
        let sent = adjustLoads(transport)
        #expect(sent.count == 1) // enviado na hora, sem esperar a coalescência
        #expect(sent.first?.0 == setID)
        #expect(sent.first?.1 == 1.5)
        #expect(model.display?.exercises[0].sets[0].load?.value == 27.5)
        // Mesma regra de hoje: as séries seguintes pendentes acompanham.
        let next = model.display?.exercises[0].sets[1]
        #expect((next?.load ?? next?.plannedLoad)?.value == 27.5)
    }

    @Test func salvarSemMudancaNaoEnvia() throws {
        let (model, transport, snapshot, _) = make()
        let setID = try #require(snapshot.currentSetID)
        let draft = try #require(model.loadDraft(setID: setID))
        model.saveLoad(draft)
        #expect(adjustLoads(transport).isEmpty)
    }

    @Test func pesoCorporalComLastroEPassoEmLibras() throws {
        var snapshot = planned()
        snapshot.exercises[0].sets[0].plannedLoad = WatchLoad(value: 0, isBodyweight: true)
        let (model, transport, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[0].id
        var draft = try #require(model.loadDraft(setID: setID))
        #expect(draft.range == WatchLoadStepping.bodyweightRange)
        draft.decrement(); draft.decrement() // assistência −1 kg
        #expect(draft.value == -1)
        draft.set(10)
        model.saveLoad(draft)
        #expect(adjustLoads(transport).count == 1)
        #expect(model.display?.exercises[0].sets[0].load == WatchLoad(value: 10, isBodyweight: true))

        var lb = WatchLoadDraft(setID: setID, base: WatchLoad(value: 50, unit: .lb), wasUnset: false)
        lb.increment()
        #expect(lb.value == 51)
    }

    @Test func serieSemCargaSalvaACargaMostrada() throws {
        var snapshot = planned(completed: 1)
        snapshot.exercises[0].sets[1].plannedLoad = nil // "Definir carga"; base = última usada (26)
        let (model, transport, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[1].id
        let draft = try #require(model.loadDraft(setID: setID))
        #expect(draft.wasUnset)
        #expect(draft.value == 26)
        model.saveLoad(draft)
        let sent = adjustLoads(transport)
        #expect(sent.count == 1)
        #expect(sent.first?.1 == 0)
        #expect(model.display?.exercises[0].sets[1].load?.value == 26)
    }

    @Test func editorAbertoNaoAbreAlertaDeTelaCheia() throws {
        let (model, _, _, haptics) = make(completed: 0, coalesce: 0)
        model.completeCurrentSet()
        let end = try #require(model.display?.restEndsAt)
        model.isEditingLoad = true
        model.restDidEnd(at: end)
        #expect(model.restAlert == nil)
        #expect(haptics.events.last == .restEnded)
        #expect(model.restFinishedAt != nil)
    }
}
