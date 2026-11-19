import Network
import Observation
import SwiftData
import SwiftUI

/// Folha `.large` do copiloto de importação (DESIGN §4.15.3): Arquivos → Análise → (Fichas) → Entrevista → Revisão.
/// As etapas seguem `ImportSession.phase`; a sessão vive no `ImportCoordinator`, então fechar a folha não cancela.
struct ImportFlowView: View {
    let session: ImportSession

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false

    private var ui: ImportUIState? { coordinator?.uiState(for: session) }
    private var kind: ImportSession.Kind { session.kind }

    var body: some View {
        stack
            .tint(FJColor.coach)
            .accessibilityIdentifier("import.sheet")
            .interactiveDismissDisabled(session.phase != .selecting || !session.attachments.isEmpty)
            .confirmationDialog(closeTitle, isPresented: $confirmClose, titleVisibility: .visible) {
                closeActions
            } message: {
                Text(closeMessage)
            }
            .sensoryFeedback(.success, trigger: session.phase) { old, new in
                Self.finishedReading(from: old, to: new)
            }
            .onChange(of: session.phase) { _, phase in
                if phase == .done { coordinator?.closeSheet() }
            }
    }

    private static func finishedReading(from old: ImportSession.Phase, to new: ImportSession.Phase) -> Bool {
        guard old == .analyzing else { return false }
        return new == .interviewing || new == .reviewing
    }

    private var stack: some View {
        NavigationStack {
            content
                .fjScreenBackground()
                .navigationTitle(kind == .program ? "Importar treino" : "Importar dieta")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { requestClose() }
                            .accessibilityIdentifier("import.cancel")
                    }
                }
        }
    }

    @ViewBuilder
    private var closeActions: some View {
        if session.phase == .analyzing {
            Button("Continuar em segundo plano") { closeKeeping() }
            Button("Cancelar importação", role: .destructive) { discard() }
        } else {
            Button("Continuar depois") { closeKeeping() }
            Button("Descartar", role: .destructive) { discard() }
        }
        Button("Voltar", role: .cancel) {}
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .selecting:
            ImportFilesView(session: session)
        case .analyzing:
            ImportAnalysisView(session: session)
        case .interviewing:
            if let ui, needsGroupPick(ui) {
                ImportGroupsView(session: session, ui: ui)
            } else if let ui {
                ImportInterviewView(session: session, ui: ui)
            }
        case .reviewing, .applying:
            if let ui { ImportReviewView(session: session, ui: ui) }
        case .failed:
            ImportFailureView(session: session)
        case .done:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Várias fichas/variações e nenhuma pergunta respondida ainda: escolher antes de perguntar (as perguntas só
    /// valem para as escolhidas).
    private func needsGroupPick(_ ui: ImportUIState) -> Bool {
        session.detectedGroupCount > 1 && !ui.groupsConfirmed && session.answers.isEmpty
    }

    // MARK: Fechar

    private var closeTitle: LocalizedStringKey {
        session.phase == .analyzing ? "Continuar em segundo plano?" : "Descartar importação?"
    }

    private var closeMessage: LocalizedStringKey {
        session.phase == .analyzing
            ? "A leitura segue. Quando terminar, “Continuar importação” aparece em \(kind == .program ? "Treinos" : "Dieta")."
            : "Você pode continuar depois: o que já foi lido e respondido fica guardado."
    }

    private func requestClose() {
        switch session.phase {
        case .selecting where session.attachments.isEmpty && !session.needsReattach:
            discard()
        case .done:
            coordinator?.closeSheet()
        default:
            confirmClose = true
        }
    }

    private func closeKeeping() {
        coordinator?.closeSheet()
    }

    private func discard() {
        coordinator?.discard(session.id)
    }
}

// MARK: - Provedor e rede

/// Nome do provedor configurado e prontidão (provedor + chave), lidos das preferências do Coach.
@MainActor
struct ImportProviderInfo {
    enum Readiness: Equatable { case ready, needsSetup }

    let name: String
    let readiness: Readiness
    /// Quem recebe os arquivos (provedor + criador do modelo + host), para o aviso e a folha de consentimento.
    let recipient: AIRecipient

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        let settings = ProviderSettingsStore(defaults: defaults).load()
        let descriptor = ProviderCatalog.descriptor(for: settings.provider)
        let hasKey = descriptor.hasCredential(in: secrets)
        name = descriptor.displayShortName
        recipient = AIRecipientResolver.resolve(settings: settings)
        readiness = ProviderReadiness.evaluate(settings, hasAPIKey: hasKey).isReady ? .ready : .needsSetup
    }
}

/// Conectividade para o aviso "Sem conexão" (os arquivos ficam; analisar volta quando a rede voltar).
@MainActor
@Observable
final class ImportNetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "import.network"))
    }

    deinit { monitor.cancel() }
}

// MARK: - Falha

/// Falha da leitura (resposta inválida, provedor, rede): o que houve e a saída. Nada é perdido.
struct ImportFailureView: View {
    let session: ImportSession
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: FJSpacing.l) {
                FJAIBadge(style: .hero)
                    .padding(.top, FJSpacing.l)
                Text("A leitura não deu certo")
                    .font(FJFont.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                FJBanner("O que aconteceu", message: LocalizedStringKey(session.failureMessage ?? String(localized: "Não foi possível analisar os arquivos.")),
                         tone: .destructive)
                if let errorMessage {
                    FJBanner("Não foi possível continuar", message: LocalizedStringKey(errorMessage), tone: .attention)
                }
                VStack(spacing: FJSpacing.s) {
                    FJAIButton("Tentar de novo", systemImage: "arrow.clockwise") { retry() }
                    FJSecondaryButton("Trocar arquivos", systemImage: "arrow.triangle.2.circlepath") { session.retry() }
                }
            }
            .padding(FJSpacing.screenMargin)
        }
    }

    private func retry() {
        session.retry()
        guard session.phase == .selecting, !session.attachments.isEmpty, !session.needsReattach else { return }
        Task {
            do { try await session.analyze() } catch { errorMessage = error.localizedDescription }
        }
    }
}
