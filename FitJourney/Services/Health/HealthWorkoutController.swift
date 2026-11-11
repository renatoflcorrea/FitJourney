import Foundation
import Observation
import SwiftData

/// Gravação do treino no Apple Health acompanhando a sessão do FitJourney (SPEC §6.2).
///
/// **Como liga:** no lançamento do app, `startObservingMirroredSessions()` (ciclo 4b) e
/// `attach(to: engine)`. O controller assina `SessionEngine.events()` e reage sozinho:
/// - `sessionStarted` → `HKWorkoutSession` + `HKLiveWorkoutBuilder` **no iPhone** (iOS 26+) com o tipo
///   derivado da ficha, se o Saúde estiver conectado e a escrita de treinos autorizada. Publica FC
///   (`latestHeartRate`, `heartRateUpdates()`) e energia ativa ao vivo.
/// - `sessionPaused`/`sessionResumed` → pausa/retoma a sessão do Saúde (e registra as pausas para o
///   gravador simples).
/// - `sessionFinished` → grava o `HKWorkout` com metadados (`HKMetadataKeyExternalUUID` = ID da sessão,
///   nome da ficha, tipo recalculado no fim), um `.segment` por exercício e um `.marker` por série, e
///   salva `WorkoutSession.healthKitWorkoutID`. Se a gravação ao vivo falhar, descarta-a e grava pelo
///   gravador simples com o mesmo plano.
/// - `sessionDiscarded` → descarta sem gravar.
///
/// **Degradação:** sem sessão ao vivo possível, grava um `HKWorkout` simples no fim (energia estimada,
/// marcada com `FJEstimatedEnergy`, só se houver massa corporal); escrita negada ou Saúde desconectado →
/// nada. Nada aqui bloqueia ou falha a sessão do app.
///
/// **Retomada e reconciliação (no `attach`):** sessão em andamento → recupera a sessão do Saúde
/// (`recoverActiveWorkoutSession`) se o início bater (± `recoveryTolerance`) e ela estiver ativa; senão
/// encerra a recuperada e inicia outra com a data original; a pausa é conciliada nos dois sentidos.
/// Depois, sessões concluídas nos últimos `reconcileWindow` sem `healthKitWorkoutID` (e sem marca de
/// espelho) são gravadas pelo gravador simples — uma tentativa por sessão.
///
/// **Espelhamento (W2):** o relógio inicia a sessão e a espelha; o HealthKit entrega a sessão espelhada
/// e `attachMirroredSession(_:)` assume:
/// - descarta a gravação local e **marca a sessão** (`isMirrored(_:)`, persistido): o relógio grava o
///   treino; o iPhone nunca grava outro para ela (nem na reconciliação);
/// - `remoteData()` entrega os pacotes do relógio (o W2 decodifica com `WatchLinkCodec` e aplica com
///   `SessionEngine.apply`); `sendToRemote(_:)` envia snapshots/respostas;
/// - FC/energia do relógio chegam pelo canal de dados: o W2 chama `receiveRemoteMetrics(_:)`;
/// - se o W2 souber o ID da sessão antes do `sessionStarted`, chama `markMirrored(_:)`;
/// - ao finalizar, o estado fica `.awaitingRemoteWorkout` até o W2 chamar `linkWorkout(_:to:)` com o
///   `uuid` do treino do relógio (que deve trazer o ID da sessão em `HKMetadataKeyExternalUUID`);
/// - descartar uma sessão espelhada chama `onMirroredSessionDiscarded` (o W2 encerra no relógio).
///
/// **Espelho caiu com a sessão em andamento:** a marca é mantida e o estado vira `.mirrorDisconnected`.
/// O relógio continua gravando sozinho (SPEC §6.4: segue offline e reconcilia), então o iPhone **não**
/// retoma gravação local — isso duplicaria o treino. Só se o W2 souber que o relógio não vai gravar ele
/// chama `unmarkMirrored(_:)`, e aí a gravação simples do fim (ou a reconciliação) volta a valer.
@MainActor
@Observable
final class HealthWorkoutController {
    enum SkipReason: String, Sendable, Hashable {
        /// "Conectar ao Saúde" desligado.
        case notConnected
        /// Aparelho sem HealthKit.
        case unavailable
        /// Escrita de treinos não autorizada.
        case writeNotAuthorized
    }

    enum State: Sendable, Hashable {
        case idle
        /// `live == false`: sem sessão ao vivo; o treino é gravado no fim (se houver permissão).
        case recording(sessionID: UUID, live: Bool)
        case paused(sessionID: UUID, live: Bool)
        /// Sessão do relógio espelhada: o relógio grava o treino.
        case mirrored(sessionID: UUID?)
        /// O espelho caiu com a sessão em andamento; o relógio segue gravando (marca mantida).
        case mirrorDisconnected(sessionID: UUID)
        /// Sessão espelhada finalizada: aguardando `linkWorkout` com o treino do relógio.
        case awaitingRemoteWorkout(sessionID: UUID)
        case saving(sessionID: UUID)
        case saved(sessionID: UUID, workoutID: UUID)
        case skipped(sessionID: UUID, reason: SkipReason)
        case failed(sessionID: UUID, message: String)
    }

    /// Limite de amostras guardadas em memória para o gráfico ao vivo (~7 h a 5 s).
    static let liveSampleLimit = 5_000
    /// Diferença aceita entre o início da sessão recuperada do Saúde e o da sessão do app.
    static let recoveryTolerance: TimeInterval = 120
    /// Até quantos dias atrás a reconciliação procura sessões sem treino gravado.
    static let reconcileWindow: TimeInterval = 7 * 86_400
    static let mirroredKey = "health.mirroredSessionIDs"
    static let reconciledKey = "health.reconcileAttemptedSessionIDs"
    /// Quantos IDs cada lista persistida guarda.
    static let persistedIDLimit = 100

    private(set) var state: State = .idle
    /// Última FC ao vivo (Watch/sensor), `nil` = sem sinal (nunca zero).
    private(set) var latestHeartRate: HeartRateSample?
    /// Energia ativa acumulada na sessão, `nil` = não medida.
    private(set) var activeEnergyKcal: Double?
    /// FC ao vivo desta sessão, em ordem (para o gráfico durante o treino).
    private(set) var liveHeartRateSamples: [HeartRateSample] = []
    /// Última falha (informativa; a sessão do app segue).
    private(set) var lastError: String?
    /// Há sessão do relógio espelhada conectada.
    var hasRemoteSession: Bool { remote != nil }

    /// W2: chamado ao descartar uma sessão espelhada (encerrar a sessão no relógio).
    @ObservationIgnored var onMirroredSessionDiscarded: ((UUID) -> Void)?

    @ObservationIgnored private let store: any HealthStoreProtocol
    @ObservationIgnored private let authorization: HealthAuthorization
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored private var recorder: (any HealthWorkoutRecorder)?
    @ObservationIgnored private var recorderType: HealthWorkoutType?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var pauseLog: [HealthWorkoutEventPlan.PauseMark] = []
    @ObservationIgnored private var remote: (any HealthRemoteWorkoutSession)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var heartRateContinuations: [UUID: AsyncStream<HeartRateSample>.Continuation] = [:]
    @ObservationIgnored private var remoteDataContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    /// - Parameters:
    ///   - context: o mesmo do `SessionEngine` (`engine.context`).
    ///   - defaults: onde ficam as marcas de espelho e de reconciliação.
    init(store: any HealthStoreProtocol, authorization: HealthAuthorization, context: ModelContext,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.authorization = authorization
        self.context = context
        self.defaults = defaults
        self.now = now
    }

    // MARK: Ligação com o motor

    /// Assina os eventos do motor (substitui uma assinatura anterior), retoma a sessão em andamento e
    /// reconcilia sessões recentes sem treino gravado.
    func attach(to engine: SessionEngine) {
        listener?.cancel()
        let events = engine.events()
        let active = engine.activeSessionID
        listener = Task { [weak self] in
            if let active { await self?.resumeIfNeeded(sessionID: active) }
            await self?.reconcilePendingWorkouts()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    func detach() {
        listener?.cancel()
        listener = nil
    }

    /// Aplica um evento do motor (exposto para quem não usa `attach`, e para testes).
    func handle(_ event: SessionEvent) async {
        switch event {
        case .sessionStarted(let id): await sessionStarted(id)
        case .sessionPaused(let at): sessionPaused(at: at)
        case .sessionResumed(let at): sessionResumed(at: at)
        case .sessionFinished(let id, _): await sessionFinished(id)
        case .sessionDiscarded(let id): sessionDiscarded(id)
        default: break
        }
    }

    // MARK: Fluxos

    /// FC ao vivo (um fluxo por assinante; guarda as 32 mais recentes não lidas).
    func heartRateUpdates() -> AsyncStream<HeartRateSample> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            heartRateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.heartRateContinuations[id] = nil }
            }
        }
    }

    /// Pacotes recebidos do relógio pela sessão espelhada (atravessa sessões; W2 assina uma vez).
    func remoteData() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            remoteDataContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.remoteDataContinuations[id] = nil }
            }
        }
    }

    // MARK: Ciclo da sessão

    func sessionStarted(_ sessionID: UUID) async {
        if currentSessionID == sessionID, recorder != nil || remote != nil { return }
        recorder?.discard()
        recorder = nil
        recorderType = nil
        pauseLog = []
        resetLiveValues()
        currentSessionID = sessionID
        if remote != nil || isMirrored(sessionID) {
            markMirrored(sessionID)
            state = remote != nil ? .mirrored(sessionID: sessionID) : .mirrorDisconnected(sessionID: sessionID)
            return
        }
        guard let session = fetchSession(sessionID) else { return }
        await startLive(for: session, recovering: false)
    }

    func sessionPaused(at date: Date) {
        pauseLog.append(.init(kind: .pause, date: date))
        recorder?.pause(at: date)
        if case .recording(let id, let live) = state { state = .paused(sessionID: id, live: live) }
    }

    func sessionResumed(at date: Date) {
        pauseLog.append(.init(kind: .resume, date: date))
        recorder?.resume(at: date)
        if case .paused(let id, let live) = state { state = .recording(sessionID: id, live: live) }
    }

    /// Grava o `HKWorkout` da sessão finalizada. Idempotente: sessão já com `healthKitWorkoutID` não regrava.
    @discardableResult
    func sessionFinished(_ sessionID: UUID) async -> UUID? {
        let owned = currentSessionID == sessionID || currentSessionID == nil
        let recorder = owned ? self.recorder : nil
        let pauses = owned ? pauseLog : []
        if owned {
            self.recorder = nil
            recorderType = nil
            pauseLog = []
            currentSessionID = nil
        }

        guard let session = fetchSession(sessionID), session.status == .completed, session.endedAt != nil else {
            recorder?.discard()
            state = .idle
            return nil
        }
        if let existing = session.healthKitWorkoutID {
            recorder?.discard()
            state = .saved(sessionID: sessionID, workoutID: existing)
            return existing
        }
        if isMirrored(sessionID) || remote != nil {
            // O relógio grava; o vínculo chega pelo W2 (`linkWorkout`).
            markMirrored(sessionID)
            recorder?.discard()
            state = .awaitingRemoteWorkout(sessionID: sessionID)
            return nil
        }
        if let reason = skipReason() {
            recorder?.discard()
            state = .skipped(sessionID: sessionID, reason: reason)
            return nil
        }
        return await save(session, recorder: recorder, pauses: pauses)
    }

    func sessionDiscarded(_ sessionID: UUID) {
        guard currentSessionID == sessionID || currentSessionID == nil else { return }
        recorder?.discard()
        recorder = nil
        recorderType = nil
        pauseLog = []
        currentSessionID = nil
        if isMirrored(sessionID) || remote != nil {
            onMirroredSessionDiscarded?(sessionID)
        }
        state = remote != nil ? .mirrored(sessionID: nil) : .idle
    }

    /// App reaberto com sessão em andamento: recupera a sessão do Saúde (ou inicia outra com a data original).
    func resumeIfNeeded(sessionID: UUID) async {
        guard recorder == nil, let session = fetchSession(sessionID), session.status == .inProgress else { return }
        currentSessionID = sessionID
        pauseLog = session.pausedAt.map { [.init(kind: .pause, date: $0)] } ?? []
        if remote != nil || isMirrored(sessionID) {
            state = remote != nil ? .mirrored(sessionID: sessionID) : .mirrorDisconnected(sessionID: sessionID)
            return
        }
        await startLive(for: session, recovering: true)
    }

    /// Grava pelo gravador simples as sessões concluídas recentes sem treino no Saúde (falha de gravação,
    /// app encerrado antes de gravar). Uma tentativa por sessão; ignora sessões espelhadas.
    func reconcilePendingWorkouts() async {
        guard skipReason() == nil else { return }
        let since = now().addingTimeInterval(-Self.reconcileWindow)
        let completed = SessionStatus.completed.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.healthKitWorkoutID == nil && $0.startedAt > since },
            sortBy: [SortDescriptor(\.startedAt)])
        let sessions = (try? context.fetch(descriptor)) ?? []
        var attempted = idList(Self.reconciledKey)
        for session in sessions where session.endedAt != nil && !attempted.contains(session.id)
            && !isMirrored(session.id) && session.id != currentSessionID {
            attempted.append(session.id)
            saveIDList(attempted, key: Self.reconciledKey)
            _ = await save(session, recorder: nil, pauses: [], updatesState: false)
        }
    }

    // MARK: Vínculo

    /// Grava o vínculo sessão ↔ treino do Saúde (treino do relógio, ou sugestão confirmada na UI).
    /// Mexe só em sessão já encerrada: a sessão em andamento é escrita apenas pelo `SessionEngine`.
    @discardableResult
    func linkWorkout(_ workoutID: UUID?, to sessionID: UUID) -> Bool {
        guard let session = fetchSession(sessionID), session.status != .inProgress else { return false }
        linkWorkout(workoutID, to: session)
        if let workoutID, state == .awaitingRemoteWorkout(sessionID: sessionID) {
            state = .saved(sessionID: sessionID, workoutID: workoutID)
        }
        return true
    }

    private func linkWorkout(_ workoutID: UUID?, to session: WorkoutSession) {
        session.healthKitWorkoutID = workoutID
        session.updatedAt = now()
        do { try context.save() } catch { lastError = String(describing: error) }
    }

    // MARK: Espelhamento (ciclo 4b)

    /// Registra o receptor de sessões espelhadas do relógio. Chamar cedo no lançamento do app.
    func startObservingMirroredSessions() {
        store.setMirroringStartHandler { [weak self] remote in self?.attachMirroredSession(remote) }
    }

    /// Assume a sessão espelhada do relógio (ver doc da classe).
    func attachMirroredSession(_ remote: any HealthRemoteWorkoutSession) {
        recorder?.discard()
        recorder = nil
        recorderType = nil
        resetLiveValues()
        self.remote = remote
        if let currentSessionID { markMirrored(currentSessionID) }
        remote.onRemoteData = { [weak self] packets in
            guard let self else { return }
            for packet in packets {
                for continuation in self.remoteDataContinuations.values { continuation.yield(packet) }
            }
        }
        remote.onEnd = { [weak self, weak remote] error in
            guard let self, let remote, remote === self.remote else { return }
            self.remoteEnded(error: error)
        }
        state = .mirrored(sessionID: currentSessionID)
    }

    /// Envia dados ao relógio pela sessão espelhada.
    func sendToRemote(_ data: Data) async throws {
        guard let remote else { throw HealthMirroringError.noRemoteSession }
        try await remote.send(data)
    }

    /// W2: FC/energia do relógio recebidas pelo canal de dados → mesmos fluxos da FC ao vivo.
    func receiveRemoteMetrics(_ updates: [HealthLiveUpdate]) {
        for update in updates { receive(update) }
    }

    /// Sessão gravada pelo relógio (W2 chama assim que souber o ID, mesmo antes do `sessionStarted`).
    func markMirrored(_ sessionID: UUID) {
        var ids = idList(Self.mirroredKey)
        guard !ids.contains(sessionID) else { return }
        ids.append(sessionID)
        saveIDList(ids, key: Self.mirroredKey)
    }

    /// Remove a marca de espelho (o relógio confirmadamente não vai gravar o treino).
    func unmarkMirrored(_ sessionID: UUID) {
        saveIDList(idList(Self.mirroredKey).filter { $0 != sessionID }, key: Self.mirroredKey)
        if state == .mirrorDisconnected(sessionID: sessionID) { state = .recording(sessionID: sessionID, live: false) }
    }

    func isMirrored(_ sessionID: UUID) -> Bool { idList(Self.mirroredKey).contains(sessionID) }

    private func remoteEnded(error: String?) {
        remote = nil
        if let error { lastError = error }
        // A marca fica: o relógio grava o treino mesmo desconectado.
        if let id = currentSessionID, fetchSession(id)?.status == .inProgress {
            state = .mirrorDisconnected(sessionID: id)
        } else if case .mirrored = state {
            state = .idle
        }
    }

    // MARK: Interno

    private func startLive(for session: WorkoutSession, recovering: Bool) async {
        let sessionID = session.id
        guard skipReason() == nil else {
            state = .recording(sessionID: sessionID, live: false)
            return
        }
        let type = HealthSessionTimeline.make(session: session, context: context).workoutType
        var candidate: (any HealthWorkoutRecorder)?
        if recovering, let recovered = await store.recoverLiveRecorder() {
            if recovered.isActive, let start = recovered.startDate,
               abs(start.timeIntervalSince(session.startedAt)) <= Self.recoveryTolerance {
                candidate = recovered
            } else {
                recovered.discard()
            }
        }
        let isRecovered = candidate != nil
        do {
            let live = try candidate ?? store.makeLiveRecorder(type: type)
            candidate = live
            live.onLiveUpdate = { [weak self] update in self?.receive(update) }
            if !isRecovered { try await live.start(at: session.startedAt) }
            // Espelho chegou ou sessão encerrada/trocada enquanto iniciava.
            if remote != nil {
                live.discard()
                markMirrored(sessionID)
                if currentSessionID == sessionID { state = .mirrored(sessionID: sessionID) }
                return
            }
            guard currentSessionID == sessionID else {
                live.discard()
                return
            }
            recorder = live
            recorderType = type
            // Concilia a pausa nos dois sentidos, sem pausar o que já está pausado.
            if let pausedAt = session.pausedAt, !live.isPaused {
                live.pause(at: pausedAt)
            } else if session.pausedAt == nil, live.isPaused {
                live.resume(at: now())
            }
            state = session.pausedAt != nil ? .paused(sessionID: sessionID, live: true) : .recording(sessionID: sessionID, live: true)
        } catch {
            candidate?.discard()
            lastError = error.localizedDescription
            guard currentSessionID == sessionID else { return }
            if remote != nil {
                markMirrored(sessionID)
                state = .mirrored(sessionID: sessionID)
            } else {
                state = session.pausedAt != nil ? .paused(sessionID: sessionID, live: false)
                    : .recording(sessionID: sessionID, live: false)
            }
        }
    }

    /// Grava o treino (ao vivo se houver gravador; se falhar, descarta e tenta o simples com o mesmo plano).
    private func save(_ session: WorkoutSession, recorder: (any HealthWorkoutRecorder)?,
                      pauses: [HealthWorkoutEventPlan.PauseMark], updatesState: Bool = true) async -> UUID? {
        guard let endedAt = session.endedAt else { return nil }
        let sessionID = session.id
        let timeline = HealthSessionTimeline.make(session: session, context: context)
        // Tipo recalculado no fim (exercícios trocados/adicionados durante a sessão).
        let workoutType = timeline.workoutType
        let interval = DateInterval(start: session.startedAt, end: max(session.startedAt, endedAt))
        var pauseLog = pauses
        if let pausedAt = session.pausedAt, pauseLog.last?.kind != .pause {
            pauseLog.append(.init(kind: .pause, date: pausedAt))
        }
        let plan = HealthWorkoutEventPlan.make(timeline, workout: interval, pauseLog: pauseLog)
        let metadata = HealthWorkoutMetadata(sessionID: sessionID, routineName: session.routineName, workoutType: workoutType)
        if updatesState { state = .saving(sessionID: sessionID) }

        var estimate: Double?
        if store.sharingStatus(for: .activeEnergy) == .authorized {
            estimate = HealthEnergyEstimate.activeKilocalories(type: workoutType,
                                                               activeDuration: timeline.activeDuration ?? interval.duration,
                                                               bodyMassKg: await store.latestBodyMassKg())
        }
        func attempt(_ active: any HealthWorkoutRecorder) async throws -> UUID {
            // Ao vivo com energia medida: a estimativa não vai.
            let energy = active.isLive && activeEnergyKcal != nil ? nil : estimate
            guard let workoutID = try await active.finish(start: interval.start, end: interval.end, plan: plan,
                                                          metadata: metadata, estimatedEnergyKcal: energy) else {
                throw HealthRecorderError.failed
            }
            return workoutID
        }
        var lastFailure: String?
        var useBasic = true
        if let recorder {
            do {
                let workoutID = try await attempt(recorder)
                linkWorkout(workoutID, to: session)
                if updatesState { state = .saved(sessionID: sessionID, workoutID: workoutID) }
                return workoutID
            } catch {
                lastFailure = error.localizedDescription
                // Ao vivo falhou: descarta (`discardWorkout`) e cai para o simples. Simples falhou: para.
                useBasic = recorder.isLive
                if recorder.isLive { recorder.discard() }
            }
        }
        if useBasic {
            do {
                let workoutID = try await attempt(store.makeBasicRecorder(type: workoutType))
                linkWorkout(workoutID, to: session)
                if updatesState { state = .saved(sessionID: sessionID, workoutID: workoutID) }
                return workoutID
            } catch {
                lastFailure = error.localizedDescription
            }
        }
        lastError = lastFailure
        if updatesState { state = .failed(sessionID: sessionID, message: lastFailure ?? "Falha ao gravar no Saúde.") }
        return nil
    }

    private func skipReason() -> SkipReason? {
        guard store.isHealthDataAvailable else { return .unavailable }
        guard authorization.isConnectionEnabled else { return .notConnected }
        guard store.sharingStatus(for: .workouts) == .authorized else { return .writeNotAuthorized }
        return nil
    }

    private func receive(_ update: HealthLiveUpdate) {
        switch update {
        case .heartRate(let sample):
            guard sample.bpm > 0 else { return }
            latestHeartRate = sample
            liveHeartRateSamples.append(sample)
            if liveHeartRateSamples.count > Self.liveSampleLimit {
                liveHeartRateSamples.removeFirst(liveHeartRateSamples.count - Self.liveSampleLimit)
            }
            for continuation in heartRateContinuations.values { continuation.yield(sample) }
        case .activeEnergy(let kilocalories):
            activeEnergyKcal = kilocalories
        case .failed(let message):
            lastError = message
        }
    }

    private func resetLiveValues() {
        latestHeartRate = nil
        activeEnergyKcal = nil
        liveHeartRateSamples = []
        lastError = nil
    }

    private func fetchSession(_ id: UUID) -> WorkoutSession? {
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func idList(_ key: String) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func saveIDList(_ ids: [UUID], key: String) {
        defaults.set(ids.suffix(Self.persistedIDLimit).map(\.uuidString), forKey: key)
    }
}

enum HealthMirroringError: Error {
    case noRemoteSession
}
