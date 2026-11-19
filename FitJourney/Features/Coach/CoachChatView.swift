import SwiftData
import SwiftUI

/// Conversa com o Coach: bolhas, streaming, parar, tentar de novo, erros e cartões de proposta.
struct CoachChatView: View {
    let conversation: ChatConversation
    let service: CoachConversationService
    let secrets: any SecretStore
    let defaults: UserDefaults

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(CoachHandoff.self) private var handoff: CoachHandoff?
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showSettings = false
    @State private var reviewProgram: TrainingProgram?
    @State private var reviewPlan: NutritionPlan?
    @State private var nearBottom = true
    @State private var consentPrompt: AIConsentPromptState.Prompt?
    @State private var showPrivacy = false
    /// Muda quando o consentimento muda (Ajustes, folha): redesenha a linha "Enviando para…".
    @State private var consentRevision = 0

    private var isRunningHere: Bool { service.runningConversationID == conversation.id }
    private var otherConversationRunning: Bool { service.isRunning && !isRunningHere }
    private var messages: [ChatMessage] { conversation.visibleMessages(including: .shared) }
    private var hasConsent: Bool { CoachProfileStore(defaults: defaults).hasConsented }
    private var currentRecipient: AIRecipient { AIRecipientResolver.resolve(settings: ProviderSettingsStore(defaults: defaults).load()) }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isRunning
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FJSpacing.m) {
                    destinationLine
                    if messages.isEmpty { suggestions }
                    ForEach(messages) { message in
                        MessageRow(message: message, defaults: defaults, isActive: isRunningHere,
                                   canRetry: !service.isRunning && message.id == messages.last?.id,
                                   onRetry: { retry(message) },
                                   onAdjust: { text = $0; focused = true },
                                   onOpenProgram: { reviewProgram = $0 }, onOpenPlan: { reviewPlan = $0 })
                            .id(message.id)
                    }
                    if let error = service.lastError, service.lastErrorConversationID == conversation.id,
                       service.lastConsentRequired == nil { errorBanner(error) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(FJSpacing.screenMargin)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 120
            } action: { _, isNear in
                nearBottom = isNear
            }
            // Só acompanha o fim se o usuário já está perto dele; mensagem nova do usuário sempre desce.
            .onChange(of: messages.count) {
                if nearBottom || messages.last?.role == .user { scrollToBottom(proxy) }
            }
            .onChange(of: messages.last?.content.count) { if nearBottom { scrollToBottom(proxy, animated: false) } }
            .onChange(of: service.lastErrorConversationID) { if nearBottom { scrollToBottom(proxy) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(ConversationPreview.title(conversation))
        .navigationBarTitleDisplayMode(.inline)
        .fjScreenBackground()
        .navigationDestination(isPresented: $showSettings) { AISettingsView(secrets: secrets, defaults: defaults) }
        .navigationDestination(isPresented: $showPrivacy) { AIPrivacyView(secrets: secrets, defaults: defaults) }
        .sheet(item: $consentPrompt) { prompt in
            // Destino mudou (provedor trocado): pede de novo; o texto digitado fica no campo para tentar de novo.
            AIConsentSheet(request: prompt.request, recipient: prompt.recipient, defaults: defaults,
                           onAllow: { focused = true }, onDeny: {})
        }
        .onChange(of: service.lastConsentRequired) { _, required in
            guard required != nil, service.lastErrorConversationID == conversation.id else { return }
            service.clearError()
            askConsent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiConsentChanged)) { _ in consentRevision += 1 }
        .navigationDestination(item: $reviewProgram) { ProgramReviewView(program: $0) }
        .navigationDestination(item: $reviewPlan) { PlanReviewView(plan: $0) }
        .onAppear {
            if !service.isRunning { service.clearError() }
            // "Editar com IA": a conversa nasce com o escopo da ficha/dieta já no compositor.
            if let draft = handoff?.takeDraft(for: conversation.id) {
                text = draft
                focused = true
            }
        }
        .onChange(of: isRunningHere) { old, new in
            guard old, !new else { return }
            AccessibilityNotification.Announcement(completionAnnouncement).post()
        }
        .fjHaptic(.selection, trigger: isRunningHere) { old, new in old && !new }
    }

    /// O que o VoiceOver anuncia quando a resposta termina, conforme o estado final.
    private var completionAnnouncement: String {
        switch conversation.sortedMessages.last(where: { $0.role == .assistant })?.state {
        case .stopped: String(localized: "Resposta do Coach interrompida.")
        case .failed: String(localized: "A resposta do Coach falhou.")
        default: String(localized: "O Coach terminou de responder.")
        }
    }

    // MARK: Partes

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            FJEmptyState("Como posso ajudar?", systemImage: "sparkles",
                         message: "Toque numa sugestão ou escreva seu pedido.", area: .coach)
            if let importCoordinator {
                FJQuickReplyChips([
                    FJQuickReply(String(localized: "Importar um treino"), id: "import-program", systemImage: "dumbbell"),
                    FJQuickReply(String(localized: "Importar uma dieta"), id: "import-nutrition", systemImage: "fork.knife"),
                ]) { reply in
                    importCoordinator.start(kind: reply.id == "import-program" ? .program : .nutrition)
                }
            }
            ForEach(CoachSuggestions.prompts, id: \.self) { prompt in
                Button {
                    send(prompt)
                } label: {
                    HStack {
                        Text(prompt).multilineTextAlignment(.leading)
                        Spacer(minLength: FJSpacing.s)
                        Image(systemName: "arrow.up.circle").foregroundStyle(FJArea.coach.color)
                    }
                    .frame(minHeight: FJSize.minTap)
                    .fjCard(padding: FJSpacing.m)
                }
                .buttonStyle(.plain)
                .disabled(service.isRunning)
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ error: AIError) -> some View {
        let presentation = CoachErrorPresentation(error)
        let title = LocalizedStringKey(presentation.title)
        let message = CoachMarkdown.literal(presentation.message)
        switch presentation.action {
        case .configureKey:
            FJBanner(title, message: message, tone: .attention, actionTitle: "Configurar chave") { showSettings = true }
        case .signIn:
            FJBanner(title, message: message, tone: .attention, actionTitle: "Entrar de novo") { showSettings = true }
        case .retry:
            if let failed = retryableMessage {
                FJBanner(title, message: message, tone: .destructive, actionTitle: "Tentar de novo") { retry(failed) }
            } else {
                FJBanner(title, message: message, tone: .destructive, actionTitle: "Fechar") { service.clearError() }
            }
        case .none:
            FJBanner(title, message: message, tone: .neutral, actionTitle: "Fechar") { service.clearError() }
        }
    }

    /// Última mensagem da conversa, se for uma resposta parada ou falha (alvo do "Tentar de novo").
    private var retryableMessage: ChatMessage? {
        guard let last = conversation.sortedMessages.last, last.role == .assistant,
              last.state == .stopped || last.state == .failed else { return nil }
        return last
    }

    private var composer: some View {
        VStack(spacing: FJSpacing.xs) {
            if otherConversationRunning {
                Label("O Coach está respondendo em outra conversa", systemImage: "hourglass")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composerRow
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.vertical, FJSpacing.s)
        .background(FJColor.background)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: FJSpacing.s) {
            TextField("Pergunte ao Coach", text: $text, axis: .vertical)
                .lineLimit(1 ... 5)
                .focused($focused)
                .accessibilityIdentifier("coach.composer.field")
                .padding(.horizontal, FJSpacing.m)
                .padding(.vertical, FJSpacing.s + 2)
                .frame(minHeight: FJSize.minTap)
                .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
                .submitLabel(.send)
                .onSubmit { if canSend { send(text) } }
            if isRunningHere {
                FJIconButton(systemImage: "stop.fill", label: "Parar resposta") { service.stop() }
            } else {
                FJIconButton(systemImage: "arrow.up", label: "Enviar") { send(text) }
                    .opacity(canSend ? 1 : 0.4)
                    .disabled(!canSend)
                    .accessibilityIdentifier("coach.composer.send")
            }
        }
    }

    // MARK: Ações

    private func send(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !service.isRunning else { return }
        // Sem permissão do Coach para o destino atual (provedor trocado ou revogado): pede antes de enviar.
        guard hasConsent else {
            askConsent()
            return
        }
        text = ""
        Task { await service.send(trimmed, in: conversation) }
    }

    /// Refaz a resposta que parou ou falhou, com a mesma mensagem do usuário (nada é duplicado).
    private func retry(_ message: ChatMessage) {
        guard hasConsent else {
            askConsent()
            return
        }
        Task { await service.regenerate(after: message, in: conversation) }
    }

    private func askConsent() {
        let previous = AIConsentPresentation.conversationRecipient(
            providerRaw: conversation.providerRaw, model: conversation.modelID,
            current: ProviderSettingsStore(defaults: defaults).load())
        consentPrompt = AIConsentPromptState.Prompt(recipient: currentRecipient, request: .coach(previous: previous))
    }

    /// 1ª linha da conversa: para quem vai e o que esta conversa pode ler · Alterar.
    @ViewBuilder private var destinationLine: some View {
        let _ = consentRevision
        let recipient = currentRecipient
        if hasConsent {
            let categories = AIConsentStore(defaults: defaults).categories(for: recipient)
            HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(FJColor.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: AIConsentPresentation.conversationHeader(recipient: recipient, categories: categories))
                    .foregroundStyle(FJColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Alterar") { showPrivacy = true }
                    .fontWeight(.semibold)
                    .frame(minHeight: FJSize.minTap)
                    .accessibilityIdentifier("coach.destination.change")
            }
            .font(FJFont.caption)
            .padding(.horizontal, FJSpacing.xs)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(FJMotion.resolve(FJMotion.value, reduceMotion: reduceMotion)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - Linha de mensagem

private struct MessageRow: View {
    let message: ChatMessage
    let defaults: UserDefaults
    let isActive: Bool
    let canRetry: Bool
    let onRetry: () -> Void
    let onAdjust: (String) -> Void
    let onOpenProgram: (TrainingProgram) -> Void
    let onOpenPlan: (NutritionPlan) -> Void

    private var display: CoachMessageDisplay {
        CoachMessageDisplay.resolve(role: message.role, state: message.state, content: message.content,
                                    failureReason: message.failureReason, hasProposal: message.proposal != nil,
                                    isActive: isActive)
    }

    var body: some View {
        if let record = CopilotChangeStore.shared.record(for: message) {
            CopilotChangeCardView(changeID: record.changeSet.id, onAdjust: onAdjust)
        } else {
            row
        }
    }

    @ViewBuilder
    private var row: some View {
        switch display {
        case .proposal:
            if let proposal = message.proposal {
                ProposalCardView(proposal: proposal, messageID: message.id, defaults: defaults,
                                 onOpenProgram: onOpenProgram, onOpenPlan: onOpenPlan)
            }
        case .user:
            HStack {
                Spacer(minLength: FJSpacing.xxl)
                Text(message.content)
                    .font(FJFont.body)
                    .foregroundStyle(FJColor.onFill)
                    .padding(.horizontal, FJSpacing.l)
                    .padding(.vertical, FJSpacing.m)
                    .background(FJArea.coach.fill, in: FJRadius.shape(FJRadius.card))
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(verbatim: String(localized: "Você:") + " " + message.content))
            }
        default:
            assistant
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                DisclosureGroup {
                    Text(reasoning)
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, FJSpacing.xs)
                } label: {
                    Label("Raciocínio", systemImage: "brain")
                        .font(FJFont.caption.weight(.semibold))
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            if display == .thinking {
                HStack(spacing: FJSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Pensando…").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if !message.content.isEmpty {
                Text(CoachMarkdown.attributed(message.content))
                    .font(FJFont.body)
                    .foregroundStyle(FJColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Durante o streaming o rótulo fixo evita o VoiceOver reler a cada token.
                    .accessibilityLabel(display == .streaming
                        ? Text("Coach respondendo") : Text(verbatim: String(localized: "Coach:") + " " + message.content))
            }
            footer
        }
        .padding(FJSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        .padding(.trailing, FJSpacing.l)
    }

    @ViewBuilder
    private var footer: some View {
        switch display {
        case .streaming:
            HStack(spacing: FJSpacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Escrevendo…").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .stopped:
            statusRow(String(localized: "Resposta interrompida."), tone: .neutral)
        case let .failed(reason):
            statusRow(reason, tone: .destructive)
        default:
            EmptyView()
        }
    }

    private func statusRow(_ text: String, tone: FJTone) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            Label(text, systemImage: tone.systemImage)
                .font(FJFont.caption)
                .foregroundStyle(tone.color)
            if canRetry {
                Button("Tentar de novo", systemImage: "arrow.clockwise", action: onRetry)
                    .font(FJFont.label.weight(.semibold))
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Chat — com proposta") {
    let container = CoachPreviewData.container(withConversations: true)
    let conversation = (try? container.mainContext.fetch(FetchDescriptor<ChatConversation>()))?.first
    return NavigationStack {
        if let conversation {
            CoachChatView(conversation: conversation, service: CoachPreviewData.service(container),
                          secrets: InMemorySecretStore(), defaults: CoachPreviewData.defaults(consented: true))
        }
    }
    .modelContainer(container)
    .tint(FJColor.coach)
}
#endif
