import SwiftData
import SwiftUI

/// Conversa com o Coach: bolhas, streaming, parar, tentar de novo, erros e cartões de proposta.
struct CoachChatView: View {
    let conversation: ChatConversation
    let service: CoachConversationService
    let secrets: any SecretStore
    let defaults: UserDefaults

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showSettings = false
    @State private var reviewProgram: TrainingProgram?
    @State private var reviewPlan: NutritionPlan?

    private var isRunningHere: Bool { service.runningConversationID == conversation.id }
    private var messages: [ChatMessage] { conversation.visibleMessages }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isRunning
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FJSpacing.m) {
                    if messages.isEmpty { suggestions }
                    ForEach(messages) { message in
                        MessageRow(message: message, defaults: defaults,
                                   canRetry: !service.isRunning, onRetry: { retry(message) },
                                   onOpenProgram: { reviewProgram = $0 }, onOpenPlan: { reviewPlan = $0 })
                            .id(message.id)
                    }
                    if let error = service.lastError { errorBanner(error) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(FJSpacing.screenMargin)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            .onChange(of: messages.last?.content.count) { scrollToBottom(proxy, animated: false) }
            .onChange(of: service.lastError) { scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(ConversationPreview.title(conversation))
        .navigationBarTitleDisplayMode(.inline)
        .fjScreenBackground()
        .navigationDestination(isPresented: $showSettings) { AISettingsView(secrets: secrets, defaults: defaults) }
        .navigationDestination(item: $reviewProgram) { ProgramReviewView(program: $0) }
        .navigationDestination(item: $reviewPlan) { PlanReviewView(plan: $0) }
        .onChange(of: isRunningHere) { old, new in
            if old, !new {
                AccessibilityNotification.Announcement(String(localized: "O Coach terminou de responder.")).post()
            }
        }
        .fjHaptic(.selection, trigger: isRunningHere) { old, new in old && !new }
    }

    // MARK: Partes

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            FJEmptyState("Como posso ajudar?", systemImage: "sparkles",
                         message: "Toque numa sugestão ou escreva seu pedido.", area: .coach)
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
        switch presentation.action {
        case .configureKey:
            FJBanner(LocalizedStringKey(presentation.title), message: LocalizedStringKey(presentation.message),
                     tone: .attention, actionTitle: "Configurar chave") { showSettings = true }
        case .retry:
            FJBanner(LocalizedStringKey(presentation.title), message: LocalizedStringKey(presentation.message),
                     tone: .destructive, actionTitle: "Fechar") { service.lastError = nil }
        case .none:
            FJBanner(LocalizedStringKey(presentation.title), message: LocalizedStringKey(presentation.message),
                     tone: .neutral, actionTitle: "Fechar") { service.lastError = nil }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: FJSpacing.s) {
            TextField("Pergunte ao Coach", text: $text, axis: .vertical)
                .lineLimit(1 ... 5)
                .focused($focused)
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
            }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.vertical, FJSpacing.s)
        .background(FJColor.background)
    }

    // MARK: Ações

    private func send(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !service.isRunning else { return }
        text = ""
        Task { await service.send(trimmed, in: conversation) }
    }

    /// Reenvia o último pedido do usuário anterior à resposta que parou ou falhou.
    private func retry(_ message: ChatMessage) {
        let previous = conversation.sortedMessages.last { $0.role == .user && $0.sortIndex < message.sortIndex }
        if let previous { send(previous.content) }
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
    let canRetry: Bool
    let onRetry: () -> Void
    let onOpenProgram: (TrainingProgram) -> Void
    let onOpenPlan: (NutritionPlan) -> Void

    private var display: CoachMessageDisplay {
        CoachMessageDisplay.resolve(role: message.role, state: message.state, content: message.content,
                                    failureReason: message.failureReason, hasProposal: message.proposal != nil)
    }

    var body: some View {
        switch display {
        case .proposal:
            if let proposal = message.proposal {
                ProposalCardView(proposal: proposal, defaults: defaults,
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
                    .accessibilityLabel(Text("Você: \(message.content)"))
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
                    .accessibilityLabel(Text("Coach: \(message.content)"))
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
