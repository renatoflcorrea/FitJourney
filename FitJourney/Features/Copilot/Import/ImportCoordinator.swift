import Foundation
import Observation
import SwiftData

/// Importação em andamento, para o cartão "Continuar importação" (SPEC §7A.1, DESIGN §4.15.9).
struct PendingCopilotImport: Identifiable, Equatable {
    let id: UUID
    let kind: ImportSession.Kind
    let phase: ImportSession.Phase
    let createdAt: Date
    let fileCount: Int

    /// "parou na entrevista", "lendo os arquivos"…
    var detail: String {
        switch phase {
        case .selecting: String(localized: "parou na escolha dos arquivos")
        case .analyzing: String(localized: "lendo os arquivos")
        case .interviewing: String(localized: "parou na entrevista")
        case .reviewing, .applying: String(localized: "pronta para revisar")
        case .failed: String(localized: "a leitura falhou")
        case .done: String(localized: "concluída")
        }
    }
}

/// Resultado de uma importação aplicada: leva o app ao programa/plano criado e mostra o aviso com "Desfazer".
struct ImportCompletion: Identifiable, Equatable {
    let id = UUID()
    let kind: ImportSession.Kind
    let resultID: UUID
    /// `false` quando as fichas foram acrescentadas a um programa existente (sem "Desfazer").
    let createdNew: Bool
    let name: String
    /// Foi ativado ao criar (trocou o ativo): sem "Desfazer", que não saberia reativar o anterior.
    var wasActivated = false
    /// Aviso quando criou mas não conseguiu aplicar os ajustes de nome/cor.
    var warning: String?
    var canUndo: Bool { createdNew && !wasActivated }
}

/// Dona das importações: mantém as sessões vivas (fechar a folha não cancela — Q-CP3), apresenta a folha única
/// do app e guarda o destino de cada uma. Um por app (`FitJourneyApp`), no ambiente.
@MainActor
@Observable
final class ImportCoordinator {
    private(set) var sessions: [UUID: ImportSession] = [:]
    /// Sessão na folha. `AppRoot` apresenta `ImportFlowView` quando não é `nil`.
    private(set) var presented: ImportSession?
    private(set) var storedPending: [ImportSessionState] = []
    /// Rota ainda não consumida pela aba (abrir o programa/plano criado).
    private(set) var route: ImportCompletion?
    /// Aviso global "Programa criado" · Desfazer.
    var banner: ImportCompletion?

    /// Um monitor de rede para todas as telas da importação.
    let network = ImportNetworkMonitor()
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let store: any ImportSessionStoring
    @ObservationIgnored private var uiStates: [UUID: ImportUIState] = [:]

    private static let targetsKey = "copilot.import.targets.v1"

    init(context: ModelContext, defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore(),
         store: (any ImportSessionStoring)? = nil) {
        self.context = context
        self.defaults = defaults
        self.secrets = secrets
        self.store = store ?? FileImportSessionStore()
        refreshStored()
    }

    // MARK: Composição

    func providerInfo() -> ImportProviderInfo { ImportProviderInfo(defaults: defaults, secrets: secrets) }

    /// Mesma resolução do Coach: provedor das preferências + chave do Keychain.
    func makeSession(kind: ImportSession.Kind, id: UUID = UUID()) -> ImportSession {
        ImportSession(kind: kind, context: context, resolveChat: resolver(), hasConsented: consentCheck(), store: store, id: id)
    }

    private func resolver() -> @MainActor () throws -> ResolvedChat {
        let defaults = defaults
        let secrets = secrets
        return { try ProviderFactory.makeChat(settingsStore: ProviderSettingsStore(defaults: defaults), secrets: secrets) }
    }

    private func consentCheck() -> @MainActor () -> Bool {
        let defaults = defaults
        return { CoachProfileStore(defaults: defaults).hasConsented }
    }

    // MARK: Ciclo de vida

    /// Começa uma importação nova e abre a folha.
    @discardableResult
    func start(kind: ImportSession.Kind, target: ImportSession.Target? = nil) -> ImportSession {
        let session = makeSession(kind: kind)
        sessions[session.id] = session
        uiState(for: session).target = target ?? (kind == .program ? .newProgram : .newNutritionPlan)
        saveTarget(for: session.id)
        presented = session
        return session
    }

    /// Reabre (da memória) ou retoma (do disco) uma importação.
    func resume(_ id: UUID) {
        if let session = sessions[id] {
            presented = session
            return
        }
        guard let state = store.load(id: id) else { refreshStored(); return }
        let session = ImportSession.resume(state, context: context, resolveChat: resolver(), hasConsented: consentCheck(), store: store)
        sessions[id] = session
        uiState(for: session).target = Self.loadTarget(id: id, kind: state.kind, defaults: defaults)
        presented = session
    }

    /// Fecha a folha sem cancelar nada.
    func closeSheet() {
        // Folha vazia fechada por gesto não deixa "Continuar importação" para trás.
        if let session = presented, session.phase == .selecting, session.attachments.isEmpty, !session.needsReattach {
            discard(session.id)
            return
        }
        presented = nil
        refreshStored()
    }

    /// Descarta de vez (apaga o estado gravado).
    func discard(_ id: UUID) {
        sessions[id]?.discard()
        store.delete(id: id)
        sessions[id] = nil
        uiStates[id] = nil
        removeTarget(for: id)
        if presented?.id == id { presented = nil }
        refreshStored()
    }

    func uiState(for session: ImportSession) -> ImportUIState {
        if let state = uiStates[session.id] { return state }
        let state = ImportUIState(target: session.kind == .program ? .newProgram : .newNutritionPlan)
        uiStates[session.id] = state
        return state
    }

    func refreshStored() {
        storedPending = store.pending()
    }

    /// Importações não concluídas de um tipo: as vivas na memória e as gravadas no disco.
    func pending(kind: ImportSession.Kind) -> [PendingCopilotImport] {
        var result: [PendingCopilotImport] = []
        for session in sessions.values where session.kind == kind && session.phase != .done && session.id != presented?.id {
            result.append(PendingCopilotImport(id: session.id, kind: kind, phase: session.phase, createdAt: session.createdAt,
                                        fileCount: session.attachments.count))
        }
        for state in storedPending where state.kind == kind && state.phase != .done && sessions[state.id] == nil {
            result.append(PendingCopilotImport(id: state.id, kind: kind, phase: state.phase, createdAt: state.createdAt,
                                        fileCount: state.attachments.count))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Conclusão

    /// Importação aplicada: fecha a folha, abre o resultado e mostra o aviso.
    func complete(_ session: ImportSession, resultID: UUID, createdNew: Bool, name: String, wasActivated: Bool = false,
                  warning: String? = nil) {
        let completion = ImportCompletion(kind: session.kind, resultID: resultID, createdNew: createdNew, name: name,
                                          wasActivated: wasActivated, warning: warning)
        sessions[session.id] = nil
        uiStates[session.id] = nil
        removeTarget(for: session.id)
        presented = nil
        route = completion
        banner = completion
        refreshStored()
    }

    func consumeRoute() { route = nil }

    // MARK: Destino persistido (sobrevive ao fechar o app)

    private func saveTarget(for id: UUID) {
        guard let target = uiStates[id]?.target, case let .existingProgram(programID) = target else { return }
        var map = defaults.dictionary(forKey: Self.targetsKey) as? [String: String] ?? [:]
        map[id.uuidString] = programID.uuidString
        defaults.set(map, forKey: Self.targetsKey)
    }

    private func removeTarget(for id: UUID) {
        var map = defaults.dictionary(forKey: Self.targetsKey) as? [String: String] ?? [:]
        map[id.uuidString] = nil
        defaults.set(map, forKey: Self.targetsKey)
    }

    private static func loadTarget(id: UUID, kind: ImportSession.Kind, defaults: UserDefaults) -> ImportSession.Target {
        if kind == .nutrition { return .newNutritionPlan }
        let map = defaults.dictionary(forKey: targetsKey) as? [String: String] ?? [:]
        if let raw = map[id.uuidString], let programID = UUID(uuidString: raw) { return .existingProgram(programID) }
        return .newProgram
    }
}

/// Estado só de tela da importação (sobrevive a fechar e reabrir a folha na mesma execução): destino, "Ativar agora"
/// e os nomes/letras/cores que o usuário mudou. O núcleo ainda não tem API para editar a extração; as mudanças
/// são aplicadas ao programa/plano criado logo depois de gravar.
@MainActor
@Observable
final class ImportUIState {
    struct RoutineOverride: Equatable {
        var name: String?
        var symbol: String?
        var colorName: String?
    }

    var target: ImportSession.Target
    var activate = false
    var groupsConfirmed = false
    var name: String?
    /// Por índice da ficha na extração.
    var routines: [Int: RoutineOverride] = [:]
    /// Dúvidas já respondidas nesta execução (recolhidas na entrevista).
    var history: [InterviewHistoryItem] = []

    init(target: ImportSession.Target) { self.target = target }
}

extension Notification.Name {
    /// "Desfazer" da importação: as abas largam o programa/plano criado antes de ele ser apagado.
    static let fjImportWillUndo = Notification.Name("fj.import.willUndo")
}
