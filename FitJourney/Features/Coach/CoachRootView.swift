import SwiftData
import SwiftUI

/// Aba Coach (SPEC §7): primeira abertura (consentimento + provedor) → lista de conversas → chat.
/// Pronta para a aba: `CoachRootView()` tem `NavigationStack` próprio e precisa de `modelContainer` no ambiente.
/// A chave vem do Keychain; nada vai a servidor do FitJourney.
///
/// **O App deve chamar `CoachConversationService.repairInterruptedMessages(in:)` no launch**; se não chamar,
/// a UI ainda mostra respostas `.streaming` sem tarefa ativa como paradas.
struct CoachRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// Conexão com o Saúde para `get_health_summary` (ausente em previews: cai no padrão do sistema).
    @Environment(HealthAuthorization.self) private var healthAuthorization: HealthAuthorization?

    private let secrets: any SecretStore
    private let defaults: UserDefaults

    @State private var gate: CoachGate = .needsConsent
    @State private var service: CoachConversationService?
    @State private var path: [ChatConversation] = []

    init() {
        self.init(secrets: KeychainSecretStore(), defaults: .standard)
    }

    /// Para previews e testes.
    init(secrets: any SecretStore, defaults: UserDefaults) {
        self.secrets = secrets
        self.defaults = defaults
        // Gate calculado já no init: sem piscar a tela errada na primeira renderização.
        _gate = State(initialValue: Self.currentGate(secrets: secrets, defaults: defaults))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch gate {
                case .ready:
                    if let service {
                        ConversationListView(service: service, secrets: secrets, defaults: defaults, path: $path)
                    } else {
                        Color.clear.fjScreenBackground()
                    }
                case .needsConsent, .needsProvider:
                    CoachWelcomeView(gate: gate, secrets: secrets, defaults: defaults, onChange: refresh)
                }
            }
            .navigationDestination(for: ChatConversation.self) { conversation in
                if let service {
                    CoachChatView(conversation: conversation, service: service, secrets: secrets, defaults: defaults)
                }
            }
        }
        .tint(FJColor.coach)
        .onAppear(perform: refresh)
        .onChange(of: path) { refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .fjDataWillReset)) { _ in
            // Substituir/apagar tudo: nenhuma resposta em curso pode escrever em conversas que vão sumir.
            service?.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .coachConsentChanged)) { _ in
            // Revogação (ou nova concessão) em Ajustes: para qualquer resposta e revalida o gate.
            if !CoachProfileStore(defaults: defaults).hasConsented { service?.stop() }
            refresh()
        }
    }

    private static func currentGate(secrets: any SecretStore, defaults: UserDefaults) -> CoachGate {
        let settings = ProviderSettingsStore(defaults: defaults).load()
        let hasKey = ProviderCatalog.descriptor(for: settings.provider).hasCredential(in: secrets)
        return CoachGate.evaluate(hasConsented: CoachProfileStore(defaults: defaults).hasConsented,
                                  readiness: ProviderReadiness.evaluate(settings, hasAPIKey: hasKey))
    }

    private func refresh() {
        let next = Self.currentGate(secrets: secrets, defaults: defaults)
        if next != gate { gate = next }
        if next != .ready, !path.isEmpty { path = [] }
        if service == nil {
            let secrets = secrets
            let defaults = defaults
            let healthAccess = healthAuthorization.map(HealthToolAccess.from) ?? HealthToolAccess.system
            service = CoachConversationService(
                context: context,
                toolbox: FitnessToolbox(context: context, profile: { CoachProfileStore(defaults: defaults).load() },
                                        health: HealthQueries.live, healthAccess: healthAccess),
                resolveChat: {
                    try ProviderFactory.makeChat(settingsStore: ProviderSettingsStore(defaults: defaults), secrets: secrets)
                })
        }
    }
}

// MARK: - Lista de conversas

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ChatConversation> { !$0.isArchived }, sort: \ChatConversation.updatedAt, order: .reverse)
    private var conversations: [ChatConversation]

    let service: CoachConversationService
    let secrets: any SecretStore
    let defaults: UserDefaults
    @Binding var path: [ChatConversation]

    @State private var errorMessage: String?
    @State private var conversationToDelete: ChatConversation?

    var body: some View {
        List {
            if let errorMessage {
                FJBanner("Não foi possível concluir", message: CoachMarkdown.literal(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation, isRunning: service.runningConversationID == conversation.id)
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("Apagar", systemImage: "trash", role: .destructive) { conversationToDelete = conversation }
                }
                .contextMenu {
                    Button("Apagar", systemImage: "trash", role: .destructive) { conversationToDelete = conversation }
                }
            }
        }
        .overlay {
            if conversations.isEmpty {
                FJEmptyState("Converse com o Coach", systemImage: "sparkles",
                             message: "Peça um programa de treino, ajuste a dieta ou pergunte sobre sua evolução.",
                             actionTitle: "Nova conversa", area: .coach, action: newConversation)
            }
        }
        .navigationTitle("Coach")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Nova conversa", systemImage: "square.and.pencil", action: newConversation)
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink {
                    AISettingsView(secrets: secrets, defaults: defaults)
                } label: {
                    Label("Ajustes de IA", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink {
                    CoachProfileView(defaults: defaults)
                } label: {
                    Label("Perfil do Coach", systemImage: "person.text.rectangle")
                }
            }
        }
        .fjScreenBackground()
        .confirmationDialog("Apagar esta conversa?", isPresented: Binding(
            get: { conversationToDelete != nil }, set: { if !$0 { conversationToDelete = nil } }
        ), titleVisibility: .visible, presenting: conversationToDelete) { conversation in
            Button("Apagar", role: .destructive) { delete(conversation) }
        } message: { conversation in
            Text(service.runningConversationID == conversation.id
                 ? "O Coach está respondendo: a resposta será interrompida e a conversa apagada."
                 : "As mensagens desta conversa serão apagadas. Programas e planos já salvos não são afetados.")
        }
        .onAppear { if !service.isRunning { service.clearError() } }
    }

    private func newConversation() {
        do { path.append(try service.createConversation()) } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ conversation: ChatConversation) {
        let messageIDs = (conversation.messages ?? []).map(\.id)
        Task {
            do {
                try await service.delete(conversation)
                ProposalStateStore(defaults: defaults).clear(messageIDs: messageIDs)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: ChatConversation
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack {
                Text(ConversationPreview.title(conversation))
                    .font(FJFont.cardTitle)
                    .lineLimit(1)
                Spacer(minLength: FJSpacing.s)
                if isRunning {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("Respondendo"))
                } else {
                    Text(conversation.updatedAt, format: .dateTime.day().month(.abbreviated))
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            Text(ConversationPreview.preview(conversation))
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Coach — lista") {
    let container = CoachPreviewData.container(withConversations: true)
    return CoachRootView(secrets: CoachPreviewData.readySecrets(), defaults: CoachPreviewData.defaults(consented: true))
        .modelContainer(container)
}

#Preview("Coach — boas-vindas") {
    CoachRootView(secrets: InMemorySecretStore(), defaults: CoachPreviewData.defaults(consented: false))
        .modelContainer(CoachPreviewData.container(withConversations: false))
}
