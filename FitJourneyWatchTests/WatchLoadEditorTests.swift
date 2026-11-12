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
        -> (WatchSessionModel, MockWatchTransport, SessionSnapshot, RecordingHaptics, TestClock) {
        let digest = WatchFixtures.digest(now: t0)
        let snapshot = custom ?? WatchFixtures.snapshot(completed: completed, now: t0, startedAgo: 600, revision: 5)
        let transport = MockWatchTransport(digest: digest, snapshot: snapshot, reachable: true)
        transport.autoRespond = false
        let haptics = RecordingHaptics()
        let clock = TestClock(t0)
        let model = WatchSessionModel(transport: transport, haptics: haptics, health: FixedHealthProvider(access: .authorized),
                                      clock: { clock.now })
        model.loadCoalesceInterval = coalesce // valor de produção: o editor não pode depender dele
        model.receive(digest: digest)
        model.receive(snapshot: snapshot)
        return (model, transport, snapshot, haptics, clock)
    }

    private func adjustLoads(_ transport: MockWatchTransport) -> [(UUID, Double)] {
        transport.sent.compactMap {
            if case .command(let c) = $0, case .adjustLoad(let id, let delta) = c.kind { (id, delta) } else { nil }
        }
    }

    // MARK: Cancelar e salvar

    @Test func cancelarFechaOEditorSemEnviarNada() throws {
        let (model, transport, snapshot, _, _) = make(snapshot: planned())
        let setID = try #require(snapshot.currentSetID)
        model.openLoadEditor(setID: setID)
        var draft = try #require(model.loadEditor)
        #expect(model.isEditingLoad)
        draft.increment(); draft.increment(); draft.set(40)
        #expect(draft.value == 40)
        model.cancelLoadEdit()
        model.flushCoalescedCommands()
        #expect(model.loadEditor == nil)
        #expect(!model.isEditingLoad)
        #expect(adjustLoads(transport).isEmpty)
        #expect(model.pendingCount == 0)
        #expect(model.display?.exercises[0].sets[0].load == nil)
        #expect(model.display?.exercises[0].sets[0].plannedLoad?.value == 26)
    }

    @Test func salvarEnviaUmAdjustLoadComOTotalEPropaga() throws {
        let (model, transport, snapshot, _, _) = make(snapshot: planned())
        let setID = try #require(snapshot.currentSetID)
        model.openLoadEditor(setID: setID)
        var draft = try #require(model.loadEditor)
        draft.increment(); draft.increment(); draft.increment() // 26 → 27,5 (três detentes)
        draft.decrement(); draft.increment()
        model.saveLoad(draft)
        let sent = adjustLoads(transport)
        #expect(sent.count == 1) // enviado na hora, sem esperar a coalescência
        #expect(sent.first?.0 == setID)
        #expect(sent.first?.1 == 1.5)
        #expect(model.loadEditor == nil)
        #expect(model.display?.exercises[0].sets[0].load?.value == 27.5)
        // Mesma regra de hoje: as séries seguintes pendentes acompanham.
        let next = model.display?.exercises[0].sets[1]
        #expect((next?.load ?? next?.plannedLoad)?.value == 27.5)
    }

    @Test func salvarSemMudancaNaoEnvia() throws {
        let (model, transport, snapshot, _, _) = make()
        let setID = try #require(snapshot.currentSetID)
        model.openLoadEditor(setID: setID)
        model.saveLoad(try #require(model.loadEditor))
        #expect(adjustLoads(transport).isEmpty)
        #expect(model.loadEditor == nil)
    }

    @Test func salvarSemMexerEmCargaForaDaGradeNaoEnvia() throws {
        var snapshot = planned()
        snapshot.exercises[0].sets[0].load = WatchLoad(value: 22.25)
        let (model, transport, _, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[0].id
        let draft = try #require(model.loadDraft(setID: setID))
        #expect(draft.value == 22.25)
        #expect(!draft.hasChanges)
        model.saveLoad(draft)
        #expect(adjustLoads(transport).isEmpty)
        #expect(model.display?.exercises[0].sets[0].load?.value == 22.25)
    }

    @Test func pesoCorporalComLastroELibrasComMeioNaoArredonda() throws {
        var snapshot = planned()
        snapshot.exercises[0].sets[0].plannedLoad = WatchLoad(value: 0, isBodyweight: true)
        let (model, transport, _, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[0].id
        var draft = try #require(model.loadDraft(setID: setID))
        #expect(draft.range == WatchLoadStepping.bodyweightRange)
        draft.decrement(); draft.decrement() // assistência −1 kg
        #expect(draft.value == -1)
        draft.set(10)
        model.saveLoad(draft)
        #expect(adjustLoads(transport).count == 1)
        #expect(model.display?.exercises[0].sets[0].load == WatchLoad(value: 10, isBodyweight: true))

        var lb = WatchLoadDraft(setID: setID, base: WatchLoad(value: 22.5, unit: .lb), wasUnset: false)
        lb.increment()
        #expect(lb.value == 23.5) // detente relativo: 1 lb, sem arredondar o ",5"
        lb.setOffset(-2)
        #expect(lb.value == 20.5)
    }

    @Test func serieSemCargaSalvaACargaMostrada() throws {
        var snapshot = planned(completed: 1)
        snapshot.exercises[0].sets[1].plannedLoad = nil // "Definir carga"; base = última usada (26)
        let (model, transport, _, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[1].id
        let draft = try #require(model.loadDraft(setID: setID))
        #expect(draft.wasUnset)
        #expect(draft.canSave)
        #expect(draft.value == 26)
        model.saveLoad(draft)
        let sent = adjustLoads(transport)
        #expect(sent.count == 1)
        #expect(sent.first?.1 == 0)
        #expect(model.display?.exercises[0].sets[1].load?.value == 26)
    }

    @Test func serieSemCargaComBaseZeroSoSalvaDepoisDeMexer() throws {
        var snapshot = planned()
        snapshot.exercises[0].sets[0].plannedLoad = nil // sem carga e sem histórico: base 0 kg
        let (model, transport, _, _, _) = make(snapshot: snapshot)
        let setID = snapshot.exercises[0].sets[0].id
        var draft = try #require(model.loadDraft(setID: setID))
        #expect(!draft.canSave)
        model.saveLoad(draft)
        #expect(adjustLoads(transport).isEmpty)
        draft.increment()
        #expect(draft.canSave)
    }

    // MARK: Série trocada por baixo, sessão encerrada

    @Test func serieMudaComOEditorAbertoNaoSalvaNaSerieErrada() throws {
        let (model, transport, snapshot, _, _) = make(snapshot: planned(), coalesce: 0)
        let setID = try #require(snapshot.currentSetID)
        model.openLoadEditor(setID: setID)
        var draft = try #require(model.loadEditor)
        draft.increment()
        model.completeCurrentSet() // concluída (aqui ou no iPhone) com a folha aberta
        #expect(model.loadEditor == nil) // a folha fecha
        model.saveLoad(draft) // um Salvar atrasado não grava nada
        #expect(adjustLoads(transport).isEmpty)
        // E não abre para uma série que não é a atual.
        model.openLoadEditor(setID: setID)
        #expect(model.loadEditor == nil)
    }

    @Test func editorFechaQuandoASessaoTerminaTrocaOuFicaEsquecida() throws {
        // Fim confirmado pelo iPhone.
        let (model, _, snapshot, _, clock) = make(snapshot: planned())
        model.openLoadEditor(setID: try #require(snapshot.currentSetID))
        #expect(model.isEditingLoad)
        var finished = snapshot
        finished.status = .finished
        finished.revision = snapshot.revision + 1
        model.receive(snapshot: finished)
        #expect(!model.isEditingLoad)

        // Outra sessão.
        let (other, _, first, _, _) = make(snapshot: planned())
        other.openLoadEditor(setID: try #require(first.currentSetID))
        var replaced = planned()
        replaced.sessionID = UUID()
        replaced.revision = 1
        other.receive(snapshot: replaced)
        #expect(!other.isEditingLoad)

        // Treino esquecido (> 4 h sem série).
        let (stale, _, live, _, staleClock) = make(snapshot: planned())
        stale.openLoadEditor(setID: try #require(live.currentSetID))
        #expect(stale.isEditingLoad)
        staleClock.now = t0.addingTimeInterval(5 * 3600)
        stale.retryStalePending()
        #expect(!stale.isEditingLoad)
        _ = clock
    }

    @Test func editorAbertoNaoAbreAlertaDeTelaCheia() throws {
        let (model, _, _, haptics, _) = make(snapshot: planned(), coalesce: 0)
        model.completeCurrentSet()
        let end = try #require(model.display?.restEndsAt)
        model.openLoadEditor(setID: try #require(model.display?.currentSetID)) // próxima série, no descanso
        #expect(model.isEditingLoad)
        model.restDidEnd(at: end)
        #expect(model.restAlert == nil)
        #expect(haptics.events.last == .restEnded)
        #expect(model.restFinishedAt != nil)
        #expect(model.isEditingLoad) // o editor fica
    }
}
