import Foundation
import Observation
import SwiftData

/// Gravação do treino no Apple Health acompanhando a sessão do FitJourney (SPEC §6.2).
///
/// **Como liga:** no lançamento do app, `startObservingMirroredSessions()` (ciclo 4b) e
/// `attach(to: engine)`. O controller assina `SessionEngine.events()` e reage sozinho:
/// - `sessionStarted` → `HKWorkoutSession` + `HKLiveWorkoutBuilder` **no iPhone** (iOS 26+) com o tipo
///   derivado da ficha (`HealthWorkoutType.derive`), se o Saúde estiver conectado e a escrita de treinos
///   autorizada. Publica FC (`latestHeartRate`, `heartRateUpdates()`) e energia ativa ao vivo.
/// - `sessionPaused`/`sessionResumed` → pausa/retoma a sessão do Saúde.
/// - `sessionFinished` → grava o `HKWorkout` com metadados (`HKMetadataKeyExternalUUID` = ID da sessão,
///   nome da ficha), um evento `.segment` por exercício (1ª → última série) e um `.marker` por série, e
///   salva `WorkoutSession.healthKitWorkoutID`.
/// - `sessionDiscarded` → descarta sem gravar.
///
/// **Degradação:** sem sessão ao vivo possível (ou sem permissão no início), grava um `HKWorkout` simples
/// no fim (início/fim, tipo, eventos, energia estimada se houver massa corporal); escrita negada ou
/// Saúde desconectado → não grava nada. Nada aqui bloqueia ou falha a sessão do app.
///
/// **Retomada:** em `attach`, se o motor já tem sessão em andamento (app reaberto), tenta
/// `recoverActiveWorkoutSession`; senão inicia uma sessão ao vivo com a data de início original.
///
/// **Espelhamento (W2):** quando o relógio inicia a sessão e a espelha (`startMirroringToCompanionDevice`),
/// o HealthKit entrega a `HKWorkoutSession` espelhada em `workoutSessionMirroringStartHandler`;
/// `attachMirroredSession(_:)` assume: descarta a gravação local (o relógio grava o treino — sem dois
/// `HKWorkout`), passa a publicar a FC do relógio e abre o canal de dados:
/// - `remoteData()` — pacotes recebidos do relógio (o W2 decodifica `SessionCommand` com `WatchLinkCodec`
///   e aplica com `SessionEngine.apply`);
/// - `sendToRemote(_:)` — envia ao relógio (o W2 codifica `SessionSnapshot`/`SessionCommandReply`
///   vindos de `SessionEngine.snapshots()`).
/// Ao finalizar uma sessão espelhada, o treino é gravado pelo relógio (que deve pôr o ID da sessão em
/// `HKMetadataKeyExternalUUID`); o W2 chama `linkWorkout(_:to:)` com o `uuid` recebido.
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
        case saving(sessionID: UUID)
        case saved(sessionID: UUID, workoutID: UUID)
        case skipped(sessionID: UUID, reason: SkipReason)
        case failed(sessionID: UUID, message: String)
    }

    /// Limite de amostras guardadas em memória para o gráfico ao vivo (~7 h a 5 s).
    static let liveSampleLimit = 5_000

    private(set) var state: State = .idle
    /// Última FC ao vivo (Watch/sensor), `nil` = sem sinal (nunca zero).
    private(set) var latestHeartRate: HeartRateSample?
    /// Energia ativa acumulada na sessão, `nil` = não medida.
    private(set) var activeEnergyKcal: Double?
    /// FC ao vivo desta sessão, em ordem (para o gráfico durante o treino).
    private(set) var liveHeartRateSamples: [HeartRateSample] = []
    /// Última falha da sessão ao vivo (informativa; a sessão do app segue).
    private(set) var lastError: String?
    /// Há sessão do relógio espelhada.
    var hasRemoteSession: Bool { remote != nil }

    @ObservationIgnored private let store: any HealthStoreProtocol
    @ObservationIgnored private let authorization: HealthAuthorization
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var recorder: (any HealthWorkoutRecorder)?
    @ObservationIgnored private var recorderType: HealthWorkoutType?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var remote: (any HealthRemoteWorkoutSession)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var heartRateContinuations: [UUID: AsyncStream<HeartRateSample>.Continuation] = [:]
    @ObservationIgnored private var remoteDataContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    /// - Parameter context: o mesmo do `SessionEngine` (`engine.context`).
    init(store: any HealthStoreProtocol, authorization: HealthAuthorization, context: ModelContext) {
        self.store = store
        self.authorization = authorization
        self.context = context
    }

    // MARK: Ligação com o motor

    /// Assina os eventos do motor (substitui uma assinatura anterior) e retoma a sessão em andamento.
    func attach(to engine: SessionEngine) {
        listener?.cancel()
        let events = engine.events()
        let active = engine.activeSessionID
        listener = Task { [weak self] in
            if let active { await self?.resumeIfNeeded(sessionID: active) }
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
        resetLiveValues()
        currentSessionID = sessionID
        if remote != nil {
            state = .mirrored(sessionID: sessionID)
            return
        }
        guard let session = fetchSession(sessionID) else { return }
        await startLive(for: session, recovering: false)
    }

    func sessionPaused(at date: Date) {
        recorder?.pause(at: date)
        if case .recording(let id, let live) = state { state = .paused(sessionID: id, live: live) }
    }

    func sessionResumed(at date: Date) {
        recorder?.resume(at: date)
        if case .paused(let id, let live) = state { state = .recording(sessionID: id, live: live) }
    }

    /// Grava o `HKWorkout` da sessão finalizada. Idempotente: sessão já com `healthKitWorkoutID` não regrava.
    @discardableResult
    func sessionFinished(_ sessionID: UUID) async -> UUID? {
        defer {
            if currentSessionID == sessionID { currentSessionID = nil }
        }
        let recorder = currentSessionID == sessionID || currentSessionID == nil ? self.recorder : nil
        if recorder != nil { self.recorder = nil }
        let type = recorderType
        recorderType = nil

        guard let session = fetchSession(sessionID), session.status == .completed, let endedAt = session.endedAt else {
            recorder?.discard()
            state = .idle
            return nil
        }
        if let existing = session.healthKitWorkoutID {
            recorder?.discard()
            state = .saved(sessionID: sessionID, workoutID: existing)
            return existing
        }
        if remote != nil {
            // O relógio grava; o vínculo chega pelo W2 (`linkWorkout`).
            recorder?.discard()
            state = .mirrored(sessionID: sessionID)
            return nil
        }
        if let reason = skipReason() {
            recorder?.discard()
            state = .skipped(sessionID: sessionID, reason: reason)
            return nil
        }

        let timeline = HealthSessionTimeline.make(session: session, context: context)
        let workoutType = type ?? timeline.workoutType
        let interval = DateInterval(start: session.startedAt, end: max(session.startedAt, endedAt))
        let plan = HealthWorkoutEventPlan.make(timeline, workout: interval)
        let metadata = HealthWorkoutMetadata(sessionID: sessionID, routineName: session.routineName, workoutType: workoutType)
        let activeRecorder = recorder ?? store.makeBasicRecorder(type: workoutType)
        state = .saving(sessionID: sessionID)

        var estimate: Double?
        let measured = activeRecorder.isLive && activeEnergyKcal != nil
        if !measured, store.sharingStatus(for: .activeEnergy) == .authorized {
            estimate = HealthEnergyEstimate.activeKilocalories(type: workoutType,
                                                               activeDuration: timeline.activeDuration ?? interval.duration,
                                                               bodyMassKg: await store.latestBodyMassKg())
        }
        do {
            let workoutID = try await activeRecorder.finish(start: interval.start, end: interval.end, plan: plan,
                                                            metadata: metadata, estimatedEnergyKcal: estimate)
            guard let workoutID else {
                state = .failed(sessionID: sessionID, message: "HealthKit não devolveu o treino gravado.")
                return nil
            }
            linkWorkout(workoutID, to: session)
            state = .saved(sessionID: sessionID, workoutID: workoutID)
            return workoutID
        } catch {
            lastError = error.localizedDescription
            state = .failed(sessionID: sessionID, message: error.localizedDescription)
            return nil
        }
    }

    func sessionDiscarded(_ sessionID: UUID) {
        guard currentSessionID == sessionID || currentSessionID == nil else { return }
        recorder?.discard()
        recorder = nil
        recorderType = nil
        currentSessionID = nil
        state = remote != nil ? .mirrored(sessionID: nil) : .idle
    }

    /// App reaberto com sessão em andamento: recupera a sessão do Saúde (ou inicia uma com a data original).
    func resumeIfNeeded(sessionID: UUID) async {
        guard recorder == nil, remote == nil, let session = fetchSession(sessionID), session.status == .inProgress else { return }
        currentSessionID = sessionID
        await startLive(for: session, recovering: true)
        if let pausedAt = session.pausedAt { sessionPaused(at: pausedAt) }
    }

    // MARK: Vínculo

    /// Grava o vínculo sessão ↔ treino do Saúde (treino do relógio, ou sugestão confirmada na UI).
    /// Mexe só em sessão já encerrada: a sessão em andamento é escrita apenas pelo `SessionEngine`.
    @discardableResult
    func linkWorkout(_ workoutID: UUID?, to sessionID: UUID) -> Bool {
        guard let session = fetchSession(sessionID), session.status != .inProgress else { return false }
        linkWorkout(workoutID, to: session)
        return true
    }

    private func linkWorkout(_ workoutID: UUID?, to session: WorkoutSession) {
        session.healthKitWorkoutID = workoutID
        session.updatedAt = Date()
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
        remote.onLiveUpdate = { [weak self] update in self?.receive(update) }
        remote.onRemoteData = { [weak self] packets in
            guard let self else { return }
            for packet in packets {
                for continuation in self.remoteDataContinuations.values { continuation.yield(packet) }
            }
        }
        remote.onEnd = { [weak self] error in self?.remoteEnded(error: error) }
        state = .mirrored(sessionID: currentSessionID)
    }

    /// Envia dados ao relógio pela sessão espelhada.
    func sendToRemote(_ data: Data) async throws {
        guard let remote else { throw HealthMirroringError.noRemoteSession }
        try await remote.send(data)
    }

    private func remoteEnded(error: String?) {
        remote = nil
        if let error { lastError = error }
        if case .mirrored = state { state = .idle }
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
        if recovering { candidate = await store.recoverLiveRecorder() }
        let recovered = candidate != nil
        do {
            let live = try candidate ?? store.makeLiveRecorder(type: type)
            candidate = live
            live.onLiveUpdate = { [weak self] update in self?.receive(update) }
            if !recovered { try await live.start(at: session.startedAt) }
            // Sessão encerrada/trocada enquanto iniciava.
            guard currentSessionID == sessionID else {
                live.discard()
                return
            }
            recorder = live
            recorderType = type
            state = .recording(sessionID: sessionID, live: true)
        } catch {
            candidate?.discard()
            lastError = error.localizedDescription
            if currentSessionID == sessionID { state = .recording(sessionID: sessionID, live: false) }
        }
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
}

enum HealthMirroringError: Error {
    case noRemoteSession
}
