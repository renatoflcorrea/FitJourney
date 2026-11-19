import SwiftUI

/// Conteúdo "Antes de enviar" (`FJConsentView`) a partir da apresentação pura: linhas, toggles do Coach, cadeia
/// "Para quem" e a frase de aceite. Usado na folha e como tela da aba Coach.
struct AIConsentContentView: View {
    let content: AIConsentPresentation.Content
    /// Toggles das categorias (só no Coach).
    var categories: Binding<Set<AIDataCategory>>?
    var showsOrb = true
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        FJConsentView(
            titleText: Text(verbatim: content.title),
            message: content.message.map { Text(verbatim: $0) },
            footnote: Text(verbatim: content.footnote),
            acceptance: FJConsentAcceptance(sentence: content.acceptance.sentence, linkTitle: content.acceptance.linkTitle,
                                            url: content.acceptance.url),
            allowHint: Text(verbatim: content.allowHint),
            showsOrb: showsOrb,
            sent: { sentRows },
            recipient: { AIRecipientCardView(hops: content.hops, note: content.note) },
            onAllow: onAllow,
            onDeny: onDeny
        )
    }

    @ViewBuilder private var sentRows: some View {
        ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Divider() }
            disclosureRow(row).accessibilityIdentifier("aiConsent.row.\(index)")
        }
        if let caption = content.categoriesCaption, let categories {
            Divider()
            Text(verbatim: caption)
                .font(FJFont.caption.weight(.semibold))
                .foregroundStyle(FJColor.textSecondary)
                .padding(.top, FJSpacing.m)
                .padding(.bottom, FJSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(content.categories.enumerated()), id: \.element.id) { index, category in
                if index > 0 { Divider() }
                FJDisclosureToggleRow(Text(verbatim: category.title), detail: Text(verbatim: category.detail),
                                      systemImage: category.systemImage,
                                      isOn: Self.binding(categories, category.category))
                    .accessibilityIdentifier("coach.consent.toggle.\(category.category.rawValue)")
            }
        }
        if let notSent = content.notSent {
            Divider()
            disclosureRow(notSent).accessibilityIdentifier("aiConsent.row.notSent")
        }
    }

    private func disclosureRow(_ row: AIConsentPresentation.Row) -> some View {
        FJDisclosureRow(Text(verbatim: row.title), detail: row.detail.map { Text(verbatim: $0) },
                        systemImage: row.systemImage, kind: row.isSent ? .sent : .notSent)
    }

    static func binding(_ set: Binding<Set<AIDataCategory>>, _ category: AIDataCategory) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(category) },
                set: { isOn in
                    if isOn { set.wrappedValue.insert(category) } else { set.wrappedValue.remove(category) }
                })
    }
}

/// Cartão "Para quem" a partir dos elos da apresentação.
struct AIRecipientCardView: View {
    let hops: [AIConsentPresentation.Hop]
    let note: String?
    var identifier = "aiConsent.recipient"

    var body: some View {
        FJRecipientCard(hops: hops.map { hop in
            FJRecipientHop(id: hop.id, kind: hop.kind, name: hop.name, roleText: Text(verbatim: hop.role),
                           links: hop.links.map { link in
                               FJPolicyLink(Text(verbatim: link.title), url: link.url, identifier: link.identifier,
                                            accessibilityLabel: Text(verbatim: link.accessibilityLabel))
                           })
        }, noteText: note.map { Text(verbatim: $0) }, identifier: identifier)
    }
}

/// Folha "Antes de enviar" (`.large`, sem "×"). Permitir grava **só** o uso pedido para esse destino e chama
/// `onAllow` (quem chamou segue direto para o envio); Não permitir ou arrastar para fechar chama `onDeny` e nada é
/// enviado nem gravado.
struct AIConsentSheet: View {
    let request: AIConsentPresentation.Request
    let recipient: AIRecipient
    var defaults: UserDefaults = .standard
    let onAllow: () -> Void
    let onDeny: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var decided = false
    @State private var categories: Set<AIDataCategory> = []

    private var store: AIConsentStore { AIConsentStore(defaults: defaults) }
    private var isCoach: Bool { if case .coach = request { true } else { false } }

    var body: some View {
        let content = AIConsentPresentation.content(for: request, recipient: recipient)
        AIConsentContentView(content: content, categories: isCoach ? $categories : nil, onAllow: {
            decided = true
            AIConsentPresentation.grant(request, for: recipient, categories: categories, store: store)
            AccessibilityNotification.Announcement(content.allowedAnnouncement).post()
            dismiss()
            onAllow()
        }, onDeny: {
            decided = true
            dismiss()
            onDeny()
        })
        .accessibilityIdentifier("aiConsent.sheet")
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if isCoach {
                categories = AIConsentPresentation.initialCoachCategories(
                    stored: store.categories(for: recipient), legacy: CoachProfileStore(defaults: defaults).load().sharing)
            }
        }
        .onDisappear {
            // Arrastar para fechar = Não permitir.
            if !decided { onDeny() }
        }
    }
}

#if DEBUG
private func previewRecipient(_ provider: AIProviderID, model: String, url: String? = nil) -> AIRecipient {
    AIRecipientResolver.resolve(settings: ProviderSettings(provider: provider, models: [provider: model],
                                                           customBaseURL: url.flatMap(URL.init(string:))))
}

#Preview("Folha — empresa") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AIConsentSheet(request: .importFiles(kind: .program, fileCount: 1),
                       recipient: previewRecipient(.openAI, model: "gpt-6-luna"), onAllow: {}, onDeny: {})
    }
}

#Preview("Folha — roteador") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AIConsentSheet(request: .importFiles(kind: .program, fileCount: 3),
                       recipient: previewRecipient(.openCode, model: "claude-haiku-5-5"), onAllow: {}, onDeny: {})
    }
}

#Preview("Folha — servidor local, AX3") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AIConsentSheet(request: .mealLog(sharesDiet: true),
                       recipient: previewRecipient(.custom, model: "llama3.1", url: "http://192.168.0.10:11434/v1"),
                       onAllow: {}, onDeny: {})
            .environment(\.dynamicTypeSize, .accessibility3)
    }
}

#Preview("Folha — Coach, escuro") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AIConsentSheet(request: .coach(previous: previewRecipient(.anthropic, model: "claude-haiku-5-5")),
                       recipient: previewRecipient(.openRouter, model: "google/gemini-3-flash"), onAllow: {}, onDeny: {})
    }
    .preferredColorScheme(.dark)
}
#endif
