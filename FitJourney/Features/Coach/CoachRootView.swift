import SwiftData
import SwiftUI

/// Aba Coach (SPEC §7): primeira abertura (consentimento + provedor) → lista de conversas → chat.
/// Tem `NavigationStack` próprio. A chave vem do Keychain; nada vai a servidor do FitJourney.
struct CoachRootView: View {
    @Environment(\.modelContext) private var context

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
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch gate {
                case .ready:
                    if let service {
                        ConversationListView(service: service, secrets: secrets, defaults: defaults, path: $path)
                    } else {
                        FJLoadingState()
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
    }

    private func refresh() {
        let hasKey = (try? secrets.string(for: ProviderCatalog.descriptor(
            for: ProviderSettingsStore(defaults: defaults).load().provider).secretKey))
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let readiness = ProviderReadiness.evaluate(ProviderSettingsStore(defaults: defaults).load(), hasAPIKey: hasKey)
        let next = CoachGate.evaluate(hasConsented: CoachProfileStore(defaults: defaults).hasConsented, readiness: readiness)
        if next != gate { gate = next }
        if service == nil {
            let secrets = secrets
            let defaults = defaults
            service = CoachConversationService(
                context: context,
                toolbox: FitnessToolbox(context: context, profile: { CoachProfileStore(defaults: defaults).load() }),
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

    var body: some View {
        List {
            if let errorMessage {
                FJBanner("Não foi possível concluir", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation, isRunning: service.runningConversationID == conversation.id)
                }
                .swipeActions {
                    Button("Apagar", systemImage: "trash", role: .destructive) { delete(conversation) }
                }
                .contextMenu {
                    Button("Apagar", systemImage: "trash", role: .destructive) { delete(conversation) }
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
    }

    private func newConversation() {
        do { path.append(try service.createConversation()) } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ conversation: ChatConversation) {
        do { try service.delete(conversation) } catch { errorMessage = error.localizedDescription }
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
