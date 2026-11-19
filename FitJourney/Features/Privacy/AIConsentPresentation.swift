import Foundation

/// Cópia do consentimento de envio à IA (proposta `ai-consent-review.md` §3, DESIGN §4.16): título por uso e destino,
/// "O que é enviado" (inclusive o que **não** vai), "Para quem" (cadeia de elos com links de política), notas e aceite.
/// Puro e testável: os textos saem localizados pelo catálogo; o artigo do português vem do destino.
enum AIConsentPresentation {
    // MARK: Tipos

    /// O que pede a permissão.
    enum Request: Hashable, Sendable {
        /// Importar com IA (a folha de arquivos ou a revisão com IA).
        case importFiles(kind: ImportSession.Kind, fileCount: Int)
        /// Registrar refeição (análise e correção). `sharesDiet`: Dieta já permitida para este destino.
        case mealLog(sharesDiet: Bool)
        /// Coach (aba ou folha na conversa). `previous`: destino com que a conversa começou, se outro.
        case coach(previous: AIRecipient?)
        /// "Permitir comparar com o plano": só a categoria Dieta.
        case dietCategory

        /// Uso concedido ao permitir (`nil` = só categoria).
        var feature: AIFeature? {
            switch self {
            case .importFiles: .importFiles
            case .mealLog: .mealLog
            case .coach: .coach
            case .dietCategory: nil
            }
        }
    }

    struct Row: Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String?
        let systemImage: String
        /// `false` = a linha do que **não** vai.
        let isSent: Bool
    }

    struct Link: Hashable, Identifiable, Sendable {
        let title: String
        let url: URL
        let identifier: String
        let accessibilityLabel: String
        var id: String { identifier }
    }

    struct Hop: Hashable, Identifiable, Sendable {
        let id: String
        let kind: FJRecipientHop.Kind
        let name: String
        let role: String
        let links: [Link]
    }

    struct Category: Hashable, Identifiable, Sendable {
        let category: AIDataCategory
        let title: String
        let detail: String
        let systemImage: String
        var id: AIDataCategory { category }
    }

    struct Acceptance: Hashable, Sendable {
        let sentence: String
        let linkTitle: String
        let url: URL
    }

    struct Content: Hashable, Sendable {
        let title: String
        let message: String?
        let rows: [Row]
        /// Coach: "O Coach também pode ler, se você ligar:" e os quatro toggles.
        let categoriesCaption: String?
        let categories: [Category]
        let notSent: Row?
        let hops: [Hop]
        let note: String?
        let footnote: String
        let allowHint: String
        let acceptance: Acceptance
        /// Anúncio do VoiceOver ao permitir.
        let allowedAnnouncement: String
    }

    // MARK: Destino

    private static func isPortuguese(_ language: String) -> Bool { language != AppLanguageCode.english }

    /// Nome com artigo em português ("a OpenAI", "o OpenCode", "o servidor em 192.168.0.10") e sem artigo em inglês
    /// ("OpenAI", "the server at …"). Vai nos títulos e frases: "Enviar a ficha para {destino}?".
    static func destination(_ recipient: AIRecipient, language: String = AppLanguageCode.current) -> String {
        switch recipient.provider {
        case .custom:
            return String(localized: "o servidor em \(recipient.host ?? "")")
        case .chatGPT:
            return String(localized: "a OpenAI (conta ChatGPT)")
        case .openAI, .anthropic, .openRouter, .openCode:
            let name = company(recipient)
            return isPortuguese(language) ? "\(recipient.article) \(name)" : name
        }
    }

    /// Nome próprio sem artigo: "OpenAI", "OpenRouter", "OpenCode", o host, "OpenAI (ChatGPT)".
    static func company(_ recipient: AIRecipient) -> String {
        switch recipient.provider {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode"
        case .custom: recipient.host ?? ""
        case .chatGPT: String(localized: "OpenAI (ChatGPT)")
        }
    }

    /// Cadeia "Para quem": um elo (empresa ou servidor) ou dois (roteador → criador do modelo).
    static func hops(_ recipient: AIRecipient) -> [Hop] {
        let model = recipient.model
        let runs = model.isEmpty ? String(localized: "Executa o modelo escolhido.") : String(localized: "Executa o modelo \(model).")
        let created = model.isEmpty ? String(localized: "Criou o modelo escolhido.") : String(localized: "Criou o modelo \(model).")
        switch recipient.provider {
        case .openAI, .anthropic:
            return [Hop(id: "company", kind: .company, name: company(recipient), role: runs,
                        links: policyLink(recipient, name: company(recipient)))]
        case .chatGPT:
            let name = String(localized: "OpenAI (sua conta ChatGPT)")
            return [Hop(id: "company", kind: .company, name: name, role: runs, links: policyLink(recipient, name: "OpenAI"))]
        case .openRouter:
            let creator = recipient.creator?.name ?? model
            var creatorLinks: [Link] = []
            if let url = recipient.modelURL {
                creatorLinks.append(Link(title: String(localized: "Quem executa este modelo"), url: url,
                                         identifier: "aiConsent.policyLink.secondary",
                                         accessibilityLabel: String(localized: "Quem executa este modelo: \(model)")))
            }
            return [
                Hop(id: "router", kind: .router, name: "OpenRouter",
                    role: String(localized: "Recebe e repassa a um serviço que executa o modelo e não guarda seus dados."),
                    links: policyLink(recipient, name: "OpenRouter")),
                Hop(id: "creator", kind: .modelHost, name: creator, role: created, links: creatorLinks),
            ]
        case .openCode:
            let creator = recipient.creator?.name ?? model
            return [
                Hop(id: "router", kind: .router, name: "OpenCode (Anomaly)",
                    role: String(localized: "Recebe e repassa ao serviço que executa o modelo."),
                    links: policyLink(recipient, name: "OpenCode")),
                Hop(id: "creator", kind: .modelHost, name: creator, role: created, links: []),
            ]
        case .custom:
            let local = recipient.isLocalNetwork
            return [Hop(id: "server", kind: local ? .localServer : .server, name: recipient.host ?? "",
                        role: local ? String(localized: "Servidor na sua rede local, configurado por você.")
                                    : String(localized: "Servidor que você configurou."),
                        links: [])]
        }
    }

    private static func policyLink(_ recipient: AIRecipient, name: String) -> [Link] {
        guard let url = recipient.privacyURL else { return [] }
        return [Link(title: String(localized: "Política de privacidade"), url: url, identifier: "aiConsent.policyLink.primary",
                     accessibilityLabel: String(localized: "Política de privacidade: \(name)"))]
    }

    /// Nota do cartão "Para quem": servidor próprio (não sabemos quem opera) ou conta ChatGPT (controles da conta).
    static func note(_ recipient: AIRecipient) -> String? {
        switch recipient.provider {
        case .custom: String(localized: "O FitJourney não sabe quem opera este servidor nem como ele trata os dados.")
        case .chatGPT: String(localized: "Os controles de dados da sua conta ChatGPT valem para estes envios.")
        default: nil
        }
    }

    // MARK: Política do FitJourney

    /// Endereço da seção de IA da política, no idioma escolhido para o app.
    static func appPolicyURL(language: String = AppLanguageCode.current) -> URL {
        let path = language == AppLanguageCode.english ? "en/privacy/#ai" : "pt/privacy/#ia"
        return URL(string: "https://renatocorrea.com.br/FitJourney/\(path)")!
    }

    /// "Ao tocar em Permitir, você concorda com o envio descrito acima e com a Política de Privacidade do FitJourney."
    static func acceptance(language: String = AppLanguageCode.current) -> Acceptance {
        let linkTitle = String(localized: "Política de Privacidade do FitJourney")
        return Acceptance(sentence: String(localized: "Ao tocar em Permitir, você concorda com o envio descrito acima e com a \(linkTitle)."),
                          linkTitle: linkTitle, url: appPolicyURL(language: language))
    }

    // MARK: Conteúdo

    static func content(for request: Request, recipient: AIRecipient, language: String = AppLanguageCode.current) -> Content {
        let dest = destination(recipient, language: language)
        let noServer = String(localized: "O FitJourney não tem servidor: nada passa pelo desenvolvedor.")
        let handled = String(localized: "Os dados são tratados conforme a política de privacidade de quem recebe e os termos da sua conta.")
        let sending = String(localized: "Permitido. Enviando para \(company(recipient)).")
        let remembers = String(localized: "Envia agora e lembra a sua escolha para \(dest).")
        switch request {
        case let .importFiles(kind, fileCount):
            return Content(
                title: kind == .program ? String(localized: "Enviar a ficha para \(dest)?")
                                        : String(localized: "Enviar a dieta para \(dest)?"),
                message: String(localized: "Para ler o arquivo, o FitJourney usa um serviço de IA de outra empresa. Nada é enviado sem a sua permissão."),
                rows: importRows(kind: kind, fileCount: fileCount),
                categoriesCaption: nil, categories: [],
                notSent: Row(id: "notSent", title: String(localized: "Não vão: seus treinos, sua dieta, dados do app Saúde nem a localização das fotos."),
                             detail: nil, systemImage: "nosign", isSent: false),
                hops: hops(recipient), note: note(recipient),
                footnote: [String(localized: "Sua escolha vale para as próximas importações com \(dest); trocar de provedor pergunta de novo."),
                           noServer, handled, String(localized: "Os arquivos não ficam guardados no app.")].joined(separator: " "),
                allowHint: remembers, acceptance: acceptance(language: language), allowedAnnouncement: sending)
        case let .mealLog(sharesDiet):
            var rows = [
                Row(id: "text", title: String(localized: "O texto que você escreveu"), detail: nil, systemImage: "text.alignleft", isSent: true),
                Row(id: "photos", title: String(localized: "As fotos que você escolher (até 4)"),
                    detail: String(localized: "Reduzidas e sem localização nem dados da câmera."), systemImage: "photo", isSent: true),
                Row(id: "date", title: String(localized: "A data e a hora do registro"),
                    detail: String(localized: "Para separar as refeições do dia."), systemImage: "clock", isSent: true),
            ]
            if sharesDiet {
                rows.append(Row(id: "plan", title: String(localized: "As refeições planejadas do dia"),
                                detail: String(localized: "Porque você permitiu Dieta para \(dest)."), systemImage: "fork.knife", isSent: true))
            }
            let notSent = sharesDiet
                ? String(localized: "Não vão: seus treinos nem dados do app Saúde.")
                : String(localized: "Não vão: seu plano alimentar, seus treinos nem dados do app Saúde.")
            return Content(
                title: String(localized: "Enviar a refeição para \(dest)?"),
                message: String(localized: "Para estimar itens, porções e calorias, o FitJourney usa um serviço de IA de outra empresa."),
                rows: rows, categoriesCaption: nil, categories: [],
                notSent: Row(id: "notSent", title: notSent, detail: nil, systemImage: "nosign", isSent: false),
                hops: hops(recipient), note: note(recipient),
                footnote: [String(localized: "Sua escolha vale para as próximas análises de refeições com \(dest); trocar de provedor pergunta de novo."),
                           String(localized: "As fotos não ficam guardadas no registro."), noServer, handled].joined(separator: " "),
                allowHint: remembers, acceptance: acceptance(language: language), allowedAnnouncement: sending)
        case let .coach(previous):
            var rows = [Row(id: "messages", title: String(localized: "Suas mensagens e o histórico da conversa"),
                            detail: String(localized: "Inclui o que você escrever e o nome de fichas ou planos ao usar Editar com IA."),
                            systemImage: "bubble.left.and.bubble.right", isSent: true)]
            if let previous, previous.key != recipient.key {
                rows.append(Row(id: "history", title: String(localized: "O histórico desta conversa, que começou com \(Self.destination(previous, language: language))"),
                                detail: nil, systemImage: "clock.arrow.circlepath", isSent: true))
            }
            return Content(
                title: String(localized: "Enviar suas mensagens para \(dest)?"),
                message: String(localized: "O Coach responde com um serviço de IA de outra empresa. Tudo o que ele propõe é um rascunho que você revisa antes de salvar."),
                rows: rows,
                categoriesCaption: String(localized: "O Coach também pode ler, se você ligar:"),
                categories: AIDataCategory.allCases.map(category),
                notSent: Row(id: "notSent", title: String(localized: "Nada do seu histórico vai sem você ligar acima."),
                             detail: nil, systemImage: "nosign", isSent: false),
                hops: hops(recipient), note: note(recipient),
                footnote: [String(localized: "O Coach não faz diagnóstico nem substitui médico, nutricionista ou educador físico."),
                           String(localized: "Sua escolha vale para \(dest); trocar de provedor pergunta de novo."), noServer].joined(separator: " "),
                allowHint: String(localized: "Lembra a sua escolha para \(dest)."),
                acceptance: acceptance(language: language),
                allowedAnnouncement: String(localized: "Permitido. O Coach envia para \(company(recipient))."))
        case .dietCategory:
            return Content(
                title: String(localized: "Permitir que \(dest) veja sua dieta?"),
                message: String(localized: "Assim a IA compara o que você comeu com as refeições planejadas do dia."),
                rows: [Row(id: "nutrition", title: String(localized: "Dieta"),
                           detail: String(localized: "Planos alimentares e o que você registrou (até 31 dias). Também vale para o Coach."),
                           systemImage: "fork.knife", isSent: true)],
                categoriesCaption: nil, categories: [], notSent: nil,
                hops: hops(recipient), note: note(recipient),
                footnote: [String(localized: "Você pode desligar em Ajustes › Coach e IA › O que é enviado e para quem."), noServer].joined(separator: " "),
                allowHint: String(localized: "Lembra a sua escolha para \(dest)."),
                acceptance: acceptance(language: language),
                allowedAnnouncement: String(localized: "Permitido. A IA vai comparar com o plano."))
        }
    }

    private static func importRows(kind: ImportSession.Kind, fileCount: Int) -> [Row] {
        let plural = fileCount > 1
        var rows = [
            Row(id: "files",
                title: plural ? String(localized: "Os \(fileCount) arquivos que você escolheu") : String(localized: "O arquivo que você escolheu"),
                detail: plural
                    ? String(localized: "Tudo o que estiver escrito ou visível neles, inclusive nomes, telefones e observações. Fotos vão reduzidas e sem localização.")
                    : String(localized: "Tudo o que estiver escrito ou visível nele, inclusive nomes, telefones e observações. Fotos vão reduzidas e sem localização."),
                systemImage: "doc.text", isSent: true),
            Row(id: "answers", title: String(localized: "Suas respostas às dúvidas da importação"),
                detail: String(localized: "Só se a IA precisar perguntar algo. Os arquivos não são reenviados."),
                systemImage: "text.bubble", isSent: true),
        ]
        if kind == .program {
            rows.append(Row(id: "catalog", title: String(localized: "Nomes de exercícios do catálogo do app"),
                            detail: String(localized: "Para casar a ficha com a sua biblioteca. Não são dados seus."),
                            systemImage: "list.bullet.rectangle", isSent: true))
        }
        return rows
    }

    // MARK: Usos e categorias (Ajustes, toggles)

    static func category(_ category: AIDataCategory) -> Category {
        switch category {
        case .profile:
            Category(category: .profile, title: String(localized: "Perfil"),
                     detail: String(localized: "Idade, sexo, altura, peso, nível, objetivo, restrições e lesões, equipamentos e preferências alimentares."),
                     systemImage: "person.crop.circle")
        case .workouts:
            Category(category: .workouts, title: String(localized: "Treinos"),
                     detail: String(localized: "Programas, fichas e treinos feitos, com séries e cargas (até 1 ano por exercício)."),
                     systemImage: "dumbbell")
        case .nutrition:
            Category(category: .nutrition, title: String(localized: "Dieta"),
                     detail: String(localized: "Planos alimentares e o que você registrou (até 31 dias). Também vale para o registro de refeições."),
                     systemImage: "fork.knife")
        case .health:
            Category(category: .health, title: String(localized: "Saúde"),
                     detail: String(localized: "Do app Saúde, por dia: treinos, minutos, FC média e em repouso, energia ativa e passos (até 31 dias)."),
                     systemImage: "heart")
        }
    }

    static func featureTitle(_ feature: AIFeature) -> String {
        switch feature {
        case .importFiles: String(localized: "Importar com IA")
        case .mealLog: String(localized: "Registrar refeições")
        case .coach: String(localized: "Coach")
        }
    }

    static func featureDetail(_ feature: AIFeature) -> String {
        switch feature {
        case .importFiles: String(localized: "Arquivos, fotos e texto que você escolher, e suas respostas")
        case .mealLog: String(localized: "Texto, fotos, data e hora")
        case .coach: String(localized: "Suas mensagens e a conversa")
        }
    }

    /// Nome curto do uso no resumo ("Importar, Coach").
    static func featureShortTitle(_ feature: AIFeature) -> String {
        switch feature {
        case .importFiles: String(localized: "Importar")
        case .mealLog: String(localized: "Refeições")
        case .coach: String(localized: "Coach")
        }
    }

    static func featureIdentifier(_ feature: AIFeature) -> String {
        switch feature {
        case .importFiles: "privacy.toggle.import"
        case .mealLog: "privacy.toggle.mealLog"
        case .coach: "privacy.toggle.coach"
        }
    }

    /// "Treinos e Dieta" (ordem fixa das categorias, lista localizada).
    static func categoryList(_ categories: Set<AIDataCategory>) -> String {
        AIDataCategory.allCases.filter(categories.contains).map { category($0).title }.formatted(.list(type: .and))
    }

    /// Resumo de um destino: "Importar, Coach (Treinos, Dieta)"; `nil` = nada permitido.
    static func permissionSummary(features: Set<AIFeature>, categories: Set<AIDataCategory>) -> String? {
        let ordered = AIFeature.allCases.filter(features.contains)
        let cats = AIDataCategory.allCases.filter(categories.contains).map { category($0).title }.joined(separator: ", ")
        var parts = ordered.map { feature -> String in
            let title = featureShortTitle(feature)
            return feature == .coach && !cats.isEmpty ? "\(title) (\(cats))" : title
        }
        if !features.contains(.coach), !cats.isEmpty { parts.append("(\(cats))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Linha de Ajustes de IA: "OpenAI · Importar, Coach (Treinos, Dieta)" ou "Nada permitido".
    static func settingsSummary(recipient: AIRecipient, record: AIConsentStore.Record?) -> String {
        let features = Set(record?.features.keys.compactMap(AIFeature.init(rawValue:)) ?? [])
        guard let summary = permissionSummary(features: features, categories: record?.categories ?? []) else {
            return String(localized: "Nada permitido")
        }
        return "\(recipient.displayName) · \(summary)"
    }

    /// Conversa: "Enviando para OpenAI. Esta conversa pode ler: Treinos · Dieta."
    static func conversationHeader(recipient: AIRecipient, categories: Set<AIDataCategory>) -> String {
        let names = AIDataCategory.allCases.filter(categories.contains).map { category($0).title }
        if names.isEmpty {
            return String(localized: "Enviando para \(company(recipient)). Esta conversa não lê o seu histórico.")
        }
        return String(localized: "Enviando para \(company(recipient)). Esta conversa pode ler: \(names.joined(separator: " · ")).")
    }

    /// Rodapé da lista de conversas: "OpenAI · gpt-6-luna · lendo Treinos e Dieta".
    static func conversationListFooter(recipient: AIRecipient, categories: Set<AIDataCategory>) -> String {
        let reading = categories.isEmpty ? String(localized: "sem ler o seu histórico")
                                         : String(localized: "lendo \(categoryList(categories))")
        return [company(recipient), recipient.model, reading].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Avisos nas telas

    struct Notice: Hashable, Sendable {
        let title: String
        let message: String
    }

    /// Aviso fixo da folha de importação: para quem vão os arquivos (e a quem o roteador repassa).
    static func importNotice(_ recipient: AIRecipient, language: String = AppLanguageCode.current) -> Notice {
        let dest = destination(recipient, language: language)
        var message = String(localized: "Tudo o que estiver escrito neles é enviado. Depois da importação eles não ficam guardados no FitJourney.")
        if recipient.provider == .openRouter || recipient.provider == .openCode, let creator = recipient.creator?.name {
            message += " " + String(localized: "\(company(recipient)) repassa ao serviço que executa o modelo (\(creator)).")
        }
        return Notice(title: String(localized: "Os arquivos vão para \(dest) para serem lidos"), message: message)
    }

    /// Depois de Não permitir na importação: nada foi enviado e os arquivos continuam aqui.
    static func importDenied(kind: ImportSession.Kind) -> Notice {
        Notice(title: String(localized: "Nada foi enviado"),
               message: kind == .program
                ? String(localized: "Sem permissão, a IA não lê seus arquivos. Você ainda pode criar o programa à mão.")
                : String(localized: "Sem permissão, a IA não lê seus arquivos. Você ainda pode criar a dieta à mão."))
    }

    /// Depois de Não permitir no registro de refeição.
    static var mealLogDenied: Notice {
        Notice(title: String(localized: "Nada foi enviado"),
               message: String(localized: "Sem permissão, registre os itens à mão pelo +."))
    }

    /// Aviso fixo do registro de refeição.
    static func mealLogNotice(_ recipient: AIRecipient, language: String = AppLanguageCode.current) -> String {
        String(localized: "O texto e as fotos vão para \(destination(recipient, language: language))")
    }

    // MARK: Destinos gravados

    /// Destino de uma conversa, pelo provedor e modelo gravados nela (`nil` se a conversa nunca enviou).
    static func conversationRecipient(providerRaw: String?, model: String?, current: ProviderSettings) -> AIRecipient? {
        guard let raw = providerRaw, let provider = AIProviderID(rawValue: raw) else { return nil }
        let model = model ?? ""
        return AIRecipientResolver.resolve(settings: ProviderSettings(
            provider: provider, models: model.isEmpty ? [:] : [provider: model],
            customBaseURL: provider == .custom ? current.customBaseURL : nil))
    }

    /// Reconstrói um destino a partir da chave gravada (`openAI`, `openRouter:google`, `custom:host`) — só para
    /// remover outros provedores em Ajustes; a chave do destino devolvido é igual à recebida.
    static func recipient(forKey key: String) -> AIRecipient? {
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let provider = AIProviderID(rawValue: parts[0]) else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        switch provider {
        case .openRouter, .openCode:
            return AIRecipient(provider: provider, creator: .init(id: rest, name: rest, article: "o"), host: nil, model: rest)
        case .custom:
            return AIRecipient(provider: .custom, creator: nil, host: rest, model: "")
        case .openAI, .anthropic, .chatGPT:
            return AIRecipient(provider: provider, creator: nil, host: nil, model: "")
        }
    }

    // MARK: Permitir

    /// O que "Permitir" grava: só o uso pedido, para esse destino (a categoria Dieta não concede uso nenhum).
    static func grant(_ request: Request, for recipient: AIRecipient, categories: Set<AIDataCategory> = [],
                      store: AIConsentStore, at date: Date = .now) {
        switch request {
        case .importFiles:
            store.grant(.importFiles, for: recipient, at: date)
        case .mealLog:
            store.grant(.mealLog, for: recipient, at: date)
        case .coach:
            store.grant(.coach, for: recipient, categories: categories, at: date)
        case .dietCategory:
            store.setCategories(store.categories(for: recipient).union([.nutrition]), for: recipient, at: date)
        }
    }

    /// Pré-seleção dos toggles do Coach: as categorias já gravadas para o destino ou, na primeira vez, os toggles
    /// antigos (`CoachProfile.sharing`). Nada vale até tocar em Permitir.
    static func initialCoachCategories(stored: Set<AIDataCategory>, legacy: CoachProfile.Sharing) -> Set<AIDataCategory> {
        stored.isEmpty ? legacy.categories : stored
    }
}

/// Estado da folha de consentimento numa tela (importar, registrar): a folha aberta para um destino e o aviso
/// "Nada foi enviado" depois de Não permitir. Negar não mexe no que o usuário escolheu (arquivos, texto, fotos) e
/// não é gravado: o próximo Analisar pergunta de novo.
struct AIConsentPromptState: Equatable {
    struct Prompt: Identifiable, Equatable {
        let recipient: AIRecipient
        let request: AIConsentPresentation.Request
        var id: String { "\(recipient.key)|\(request)" }
    }

    var prompt: Prompt?
    private(set) var denied = false

    mutating func ask(_ request: AIConsentPresentation.Request, recipient: AIRecipient) {
        prompt = Prompt(recipient: recipient, request: request)
    }

    mutating func allow() {
        prompt = nil
        denied = false
    }

    mutating func deny() {
        prompt = nil
        denied = true
    }

    mutating func clearDenied() { denied = false }
}
