import SwiftUI

// Consentimento de envio à IA (DESIGN_DIRECTION §4.16, decisões 41–48): o que é enviado, para quem e
// Permitir / Não permitir. Tudo sólido (lista de dados): vidro só nos dois botões da base.

/// Uma linha de "O que é enviado": símbolo, o dado em uma frase e o detalhe do que ele contém.
/// `.notSent` lista o que **não** vai (símbolo riscado, tom secundário) — a resposta à pergunta "e o resto?".
struct FJDisclosureRow: View {
    enum Kind: Sendable {
        case sent, notSent
    }

    private let title: Text
    private let detail: Text?
    private let systemImage: String
    private let kind: Kind

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, systemImage: String, kind: Kind = .sent) {
        self.init(Text(title), detail: detail.map { Text($0) }, systemImage: systemImage, kind: kind)
    }

    /// Texto já localizado (cópia montada por uma apresentação pura, com o nome de quem recebe).
    init(_ title: Text, detail: Text? = nil, systemImage: String, kind: Kind = .sent) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.kind = kind
    }

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            FJDisclosureSymbol(systemImage: kind == .sent ? systemImage : "nosign", tint: kind == .sent ? FJColor.coach : FJColor.textSecondary)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                title
                    .font(kind == .sent ? FJFont.body.weight(.semibold) : FJFont.label)
                    .foregroundStyle(kind == .sent ? FJColor.textPrimary : FJColor.textSecondary)
                if let detail {
                    detail
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, FJSpacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// Linha opcional de "O que é enviado" com `Toggle` (categorias do Coach: Perfil, Treinos, Dieta, Saúde).
/// Desligada por padrão no chamador; o detalhe diz exatamente o que a categoria leva.
struct FJDisclosureToggleRow: View {
    private let title: Text
    private let detail: Text
    private let systemImage: String
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>) {
        self.init(Text(title), detail: Text(detail), systemImage: systemImage, isOn: isOn)
    }

    init(_ title: Text, detail: Text, systemImage: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                FJDisclosureSymbol(systemImage: systemImage, tint: FJColor.coach)
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    title
                        .font(FJFont.body.weight(.semibold))
                        .foregroundStyle(FJColor.textPrimary)
                    detail
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .tint(FJColor.coachFill)
        .padding(.vertical, FJSpacing.s)
        .frame(minHeight: FJSize.minTap)
    }
}

/// Quadrado de 32 pt com o símbolo (cresce com o Dynamic Type). Decorativo.
private struct FJDisclosureSymbol: View {
    let systemImage: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.12), in: FJRadius.shape(FJRadius.chip))
            .accessibilityHidden(true)
    }
}

/// Link para a política de privacidade (ou página de parceiros) de quem recebe. Abre no Safari.
struct FJPolicyLink: Identifiable {
    let title: Text
    let url: URL
    /// `accessibilityIdentifier` do link (ex.: `aiConsent.policyLink.primary`). Também é o `id`.
    let identifier: String
    /// Rótulo do VoiceOver com o dono da política ("Política de privacidade: OpenAI"); `nil` = o título.
    let accessibilityLabel: Text?

    var id: String { identifier }

    init(_ title: LocalizedStringKey, url: URL, identifier: String) {
        self.init(Text(title), url: url, identifier: identifier)
    }

    init(_ title: Text, url: URL, identifier: String, accessibilityLabel: Text? = nil) {
        self.title = title
        self.url = url
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Um elo da cadeia de quem recebe: a empresa que o usuário configurou, o serviço a que ela repassa, ou um servidor.
struct FJRecipientHop: Identifiable {
    enum Kind: Sendable {
        /// Empresa que recebe e executa o modelo (OpenAI, Anthropic).
        case company
        /// Recebe e repassa a outro serviço (OpenRouter, OpenCode).
        case router
        /// Serviço que executa o modelo a pedido do roteador (criador do modelo ou parceiro de hospedagem).
        case modelHost
        /// Servidor num endereço configurado pelo usuário (fora da rede local).
        case server
        /// Servidor na rede local do usuário (Ollama no computador).
        case localServer

        var systemImage: String {
            switch self {
            case .company: "building.2.fill"
            case .router: "arrow.triangle.branch"
            case .modelHost: "cpu"
            case .server: "server.rack"
            case .localServer: "desktopcomputer"
            }
        }
    }

    let id: String
    let kind: Kind
    /// Nome próprio, mostrado como está (marca ou endereço): "OpenAI", "OpenCode (Anomaly)", "192.168.0.10".
    let name: String
    /// O papel em uma frase: "Executa o modelo gpt-6-luna", "Recebe e repassa ao serviço do modelo".
    let role: Text?
    let links: [FJPolicyLink]

    init(id: String, kind: Kind, name: String, role: LocalizedStringKey? = nil, links: [FJPolicyLink] = []) {
        self.init(id: id, kind: kind, name: name, roleText: role.map { Text($0) }, links: links)
    }

    init(id: String, kind: Kind, name: String, roleText: Text?, links: [FJPolicyLink] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.role = roleText
        self.links = links
    }
}

/// "Para quem": a cadeia de destinos (um elo para OpenAI/Anthropic/servidor; dois para OpenRouter/OpenCode),
/// ligados por um filete vertical, e uma nota opcional (ex.: "O FitJourney não sabe quem opera este servidor").
struct FJRecipientCard: View {
    private let hops: [FJRecipientHop]
    private let note: Text?
    private let identifier: String

    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 36

    init(hops: [FJRecipientHop], note: LocalizedStringKey? = nil) {
        self.init(hops: hops, noteText: note.map { Text($0) })
    }

    /// - Parameter identifier: `aiConsent.recipient` na folha; `privacy.recipient` em Ajustes.
    init(hops: [FJRecipientHop], noteText: Text?, identifier: String = "aiConsent.recipient") {
        self.hops = hops
        self.note = noteText
        self.identifier = identifier
    }

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                    if index > 0 { connector }
                    hopRow(hop)
                }
                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(FJColor.textSecondary)
                            .accessibilityHidden(true)
                        note
                            .foregroundStyle(FJColor.textSecondary)
                    }
                    .font(FJFont.caption)
                    .padding(.top, FJSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func hopRow(_ hop: FJRecipientHop) -> some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Image(systemName: hop.kind.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(FJColor.coach)
                .frame(width: iconSide, height: iconSide)
                .background(FJColor.coach.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(verbatim: hop.name)
                        .font(FJFont.cardTitle)
                        .foregroundStyle(FJColor.textPrimary)
                    if let role = hop.role {
                        role
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                ForEach(hop.links) { link in
                    Link(destination: link.url) {
                        Label {
                            link.title
                        } icon: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(FJFont.label.weight(.semibold))
                        .foregroundStyle(FJColor.coach)
                    }
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
                    .accessibilityLabel(link.accessibilityLabel ?? link.title)
                    .accessibilityIdentifier(link.identifier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Filete entre dois elos, alinhado ao centro do símbolo. Decorativo: a frase do papel já diz "repassa".
    private var connector: some View {
        Rectangle()
            .fill(FJColor.separator)
            .frame(width: 2, height: FJSpacing.l)
            .padding(.leading, iconSide / 2 - 1)
            .padding(.vertical, FJSpacing.xs)
            .accessibilityHidden(true)
    }
}

/// Frase de aceite logo acima de Permitir / Não permitir ("Ao tocar em Permitir, você concorda com o envio descrito
/// acima e com a Política de Privacidade do FitJourney."). A frase inteira é um link (alvo grande, um elemento para o
/// VoiceOver); só o nome da política leva a cor do Coach.
struct FJConsentAcceptance {
    /// Frase completa, já localizada, que contém `linkTitle`.
    let sentence: String
    /// Trecho destacado (nome da política).
    let linkTitle: String
    let url: URL
    let identifier: String

    init(sentence: String, linkTitle: String, url: URL, identifier: String = "aiConsent.appPolicyLink") {
        self.sentence = sentence
        self.linkTitle = linkTitle
        self.url = url
        self.identifier = identifier
    }

    fileprivate var attributed: AttributedString {
        var text = AttributedString(sentence)
        text.foregroundColor = FJColor.textSecondary
        if let range = text.range(of: linkTitle) {
            text[range].foregroundColor = FJColor.coach
            text[range].font = FJFont.caption.weight(.semibold)
        }
        return text
    }
}

/// Tela "Antes de enviar" (folha ou conteúdo da aba Coach): orbe, pergunta com o nome de quem recebe,
/// "O que é enviado" (linhas e toggles), "Para quem" (`FJRecipientCard`), nota e Permitir / Não permitir.
///
/// - Os dois botões têm o mesmo tamanho e ficam presos à base (na metade inferior); em tamanhos de
///   acessibilidade vão para o fim do conteúdo, que rola inteiro.
/// - Não há "×": fechar a folha (arrastar) equivale a "Não permitir" — nada é enviado.
/// - Identificadores: `aiConsent.title`, `aiConsent.allow`, `aiConsent.deny`, `aiConsent.recipient`,
///   `aiConsent.appPolicyLink` (aceite), mais os dos links.
struct FJConsentView<Sent: View, Recipient: View>: View {
    private let title: Text
    private let message: Text?
    private let footnote: Text?
    private let acceptance: FJConsentAcceptance?
    private let allowTitle: LocalizedStringKey
    private let denyTitle: LocalizedStringKey
    private let allowHint: Text?
    private let showsOrb: Bool
    private let isWorking: Bool
    private let sent: Sent
    private let recipient: Recipient
    private let onAllow: () -> Void
    private let onDeny: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        footnote: LocalizedStringKey? = nil,
        acceptance: FJConsentAcceptance? = nil,
        allowTitle: LocalizedStringKey = "Permitir",
        denyTitle: LocalizedStringKey = "Não permitir",
        allowHint: LocalizedStringKey? = nil,
        showsOrb: Bool = true,
        isWorking: Bool = false,
        @ViewBuilder sent: () -> Sent,
        @ViewBuilder recipient: () -> Recipient,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        self.init(titleText: Text(title), message: message.map { Text($0) }, footnote: footnote.map { Text($0) },
                  acceptance: acceptance, allowTitle: allowTitle, denyTitle: denyTitle, allowHint: allowHint.map { Text($0) },
                  showsOrb: showsOrb, isWorking: isWorking, sent: sent, recipient: recipient, onAllow: onAllow, onDeny: onDeny)
    }

    /// Textos já localizados (cópia montada por uma apresentação pura, com o nome de quem recebe).
    init(
        titleText: Text,
        message: Text? = nil,
        footnote: Text? = nil,
        acceptance: FJConsentAcceptance? = nil,
        allowTitle: LocalizedStringKey = "Permitir",
        denyTitle: LocalizedStringKey = "Não permitir",
        allowHint: Text? = nil,
        showsOrb: Bool = true,
        isWorking: Bool = false,
        @ViewBuilder sent: () -> Sent,
        @ViewBuilder recipient: () -> Recipient,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        self.title = titleText
        self.message = message
        self.footnote = footnote
        self.acceptance = acceptance
        self.allowTitle = allowTitle
        self.denyTitle = denyTitle
        self.allowHint = allowHint
        self.showsOrb = showsOrb
        self.isWorking = isWorking
        self.sent = sent()
        self.recipient = recipient()
        self.onAllow = onAllow
        self.onDeny = onDeny
    }

    private var actionsInline: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.sectionGap) {
                header
                section("O que é enviado") {
                    VStack(alignment: .leading, spacing: 0) { sent }
                        .padding(.horizontal, FJSpacing.l)
                        .padding(.vertical, FJSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
                }
                section("Para quem") { recipient }
                if let footnote {
                    footnote
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .padding(.horizontal, FJSpacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if actionsInline { actions }
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.top, FJSpacing.l)
            .padding(.bottom, FJSpacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Barra da base com o efeito de borda do iOS 26: o conteúdo some suavemente sob os botões.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !actionsInline {
                actions
                    .padding(.horizontal, FJSpacing.screenMargin)
                    .padding(.top, FJSpacing.m)
                    .padding(.bottom, FJSpacing.s)
            }
        }
        .fjScreenBackground()
    }

    private var header: some View {
        VStack(spacing: FJSpacing.m) {
            if showsOrb { FJAIOrb() }
            title
                .font(FJFont.sectionTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("aiConsent.title")
            if let message {
                message
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text(title)
                .textCase(.uppercase)
                .font(FJFont.overline)
                .foregroundStyle(FJColor.textSecondary)
                .padding(.horizontal, FJSpacing.l)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var actions: some View {
        VStack(spacing: FJSpacing.s) {
            if let acceptance {
                Link(destination: acceptance.url) {
                    Text(acceptance.attributed)
                        .font(FJFont.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, FJSpacing.xxs)
                .accessibilityIdentifier(acceptance.identifier)
            }
            FJPrimaryButton(allowTitle, area: .coach, isLoading: isWorking, action: onAllow)
                .accessibilityHint(allowHint ?? Text(""))
                .accessibilityIdentifier("aiConsent.allow")
            FJSecondaryButton(denyTitle, action: onDeny)
                .accessibilityIdentifier("aiConsent.deny")
                .disabled(isWorking)
        }
    }
}

#if DEBUG
private struct FJConsentPreview: View {
    @State private var workouts = false
    @State private var health = false
    let routed: Bool

    var body: some View {
        FJConsentView(
            routed ? "Enviar a ficha para o OpenCode?" : "Enviar a ficha para a OpenAI?",
            message: "Para ler a ficha, o FitJourney usa um serviço de IA de outra empresa. Nada é enviado sem a sua permissão.",
            footnote: "O FitJourney não tem servidor: nada passa pelo desenvolvedor. Você pode mudar isso em Ajustes › IA.",
            acceptance: FJConsentAcceptance(
                sentence: "Ao tocar em Permitir, você concorda com o envio descrito acima e com a Política de Privacidade do FitJourney.",
                linkTitle: "Política de Privacidade do FitJourney",
                url: URL(string: "https://renatocorrea.com.br/FitJourney/pt/privacy/#ia")!)
        ) {
            FJDisclosureRow("O arquivo que você escolheu",
                            detail: "Tudo o que estiver escrito ou visível nele, inclusive nomes, telefones e observações.",
                            systemImage: "doc.text")
            Divider()
            FJDisclosureRow("Suas respostas às perguntas da importação", systemImage: "text.bubble")
            Divider()
            FJDisclosureToggleRow("Treinos", detail: "Programas, fichas e treinos feitos, com séries e cargas.",
                                  systemImage: "dumbbell", isOn: $workouts)
            Divider()
            FJDisclosureToggleRow("Saúde", detail: "Do app Saúde, por dia: treinos, minutos, FC média e em repouso, energia ativa e passos.",
                                  systemImage: "heart", isOn: $health)
            Divider()
            FJDisclosureRow("Não vão: seu histórico, sua dieta, dados do Saúde e a localização das fotos.",
                            systemImage: "nosign", kind: .notSent)
        } recipient: {
            if routed {
                FJRecipientCard(hops: [
                    FJRecipientHop(id: "router", kind: .router, name: "OpenCode (Anomaly)", role: "Recebe e repassa ao serviço que executa o modelo.",
                                   links: [FJPolicyLink("Política de privacidade do OpenCode", url: URL(string: "https://opencode.ai/legal/privacy-policy")!,
                                                        identifier: "aiConsent.policyLink.primary")]),
                    FJRecipientHop(id: "host", kind: .modelHost, name: "Anthropic", role: "Executa o modelo claude-haiku-5-5."),
                ])
            } else {
                FJRecipientCard(hops: [
                    FJRecipientHop(id: "company", kind: .company, name: "OpenAI", role: "Executa o modelo gpt-6-luna.",
                                   links: [FJPolicyLink("Política de privacidade da OpenAI", url: URL(string: "https://openai.com/policies/privacy-policy/")!,
                                                        identifier: "aiConsent.policyLink.primary")]),
                ])
            }
        } onAllow: {} onDeny: {}
    }
}

#Preview("Consentimento — empresa") { FJConsentPreview(routed: false) }
#Preview("Consentimento — roteador") { FJConsentPreview(routed: true) }
#Preview("Consentimento — AX3") {
    FJConsentPreview(routed: true).environment(\.dynamicTypeSize, .accessibility3)
}
#endif
