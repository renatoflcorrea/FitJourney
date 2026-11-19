import SwiftUI

/// Etapa 3: entrevista, uma pergunta por vez (DESIGN §4.15.5); exercícios fora do catálogo vêm numa lista só. As respostas atualizam a extração no aparelho, sem
/// chamar a IA; só as dúvidas que a própria IA levantou vão numa chamada de texto ("Revisar com IA").
struct ImportInterviewView: View {
    let session: ImportSession
    let ui: ImportUIState
    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?

    @State private var errorMessage: String?
    @State private var isRevising = false
    @State private var freeText = ""
    @State private var showFreeText = false
    @State private var expandedUnmatched: String?
    @State private var consentRecipient: AIRecipient?
    @State private var showConsent = false
    @FocusState private var freeFocused: Bool

    private var current: ImportQuestion? { session.questions.first }
    private var history: [InterviewHistoryItem] { ui.history }
    private var answeredCount: Int { max(history.count, 0) }
    private var total: Int { answeredCount + session.questions.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    Text("Esta conversa usa só os arquivos que você enviou.")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                    summary
                    ForEach(history) { item in
                        historyRow(item)
                    }
                    ForEach(session.warnings, id: \.self) { warning in
                        FJBanner(LocalizedStringKey(warning), tone: .attention)
                    }
                    if let current, current.gapKind == .unmatchedExercise, session.unmatchedExerciseQuestions.count > 1 {
                        unmatchedBatchBlock(session.unmatchedExerciseQuestions)
                            .id("unmatched-batch")
                            .transition(.opacity)
                    } else if let current {
                        questionBlock(current)
                            .id(current.id)
                            .transition(.opacity)
                    } else {
                        doneBlock
                    }
                    if let errorMessage {
                        FJBanner("Não foi possível responder", message: LocalizedStringKey(errorMessage), tone: .destructive,
                                 actionTitle: "Fechar") { self.errorMessage = nil }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(FJSpacing.screenMargin)
                .fjAnimation(FJMotion.structure, value: session.questions.map(\.id))
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: current?.id) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if total > 0 {
                FJQuestionProgress(current: min(answeredCount + 1, max(total, 1)), total: total)
                    .padding(.horizontal, FJSpacing.screenMargin)
                    .padding(.vertical, FJSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FJColor.background)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let current, !current.isRequired {
                        Button("Pular esta", systemImage: "forward") { skip(current) }
                    }
                    Button("Pular todas e revisar", systemImage: "forward.end") { finish() }
                        .disabled(!session.canFinishInterview)
                } label: {
                    Text("Pular")
                }
                .disabled(isRevising)
            }
        }
        .sheet(isPresented: $showConsent) {
            ImportConsentSheet(providerName: consentRecipient?.displayName ?? "") {
                let defaults = coordinator?.defaults ?? .standard
                if let recipient = consentRecipient { AIConsentStore(defaults: defaults).grant(.importFiles, for: recipient) }
                revise()
            }
        }
    }

    // MARK: Partes

    private var summary: some View {
        HStack(alignment: .top, spacing: FJSpacing.s) {
            FJAIBadge(style: .symbol).padding(.top, 2)
            Text(ImportOverview.summary(kind: session.kind, programImport: session.programImport,
                                        nutritionImport: session.nutritionImport, selected: session.selected,
                                        pending: session.questions.count))
                .font(FJFont.body)
        }
        .accessibilityElement(children: .combine)
    }

    private func historyRow(_ item: InterviewHistoryItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
            Image(systemName: "checkmark").foregroundStyle(FJColor.success).accessibilityHidden(true)
            Text("\(item.prompt): **\(item.answer)**")
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Respondida. \(item.prompt): \(item.answer)"))
    }

    private func questionBlock(_ question: ImportQuestion) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            Text(verbatim: question.prompt)
                .font(FJFont.cardTitle)
                .accessibilityAddTraits(.isHeader)
            if let detail = question.detail {
                Text(verbatim: detail).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
            if let source = question.source {
                FJSourceLabel(file: source.file, page: source.page)
                    .padding(FJSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FJColor.surface, in: FJRadius.shape(FJRadius.field))
            }
            if question.isRequired {
                Label("Obrigatória", systemImage: "exclamationmark.circle")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            QuestionControlView(question: question, isBusy: isRevising,
                                onAnswer: { answer in respond(question, answer) },
                                onFreeText: { showFreeText = true; freeFocused = true })
            if showFreeText {
                freeTextField(question)
            }
        }
        .id(question.id)
    }

    /// Exercícios fora do catálogo numa lista só (U4): "Criar todos como novos" ou escolher um por um.
    private func unmatchedBatchBlock(_ questions: [ImportQuestion]) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            Text("\(questions.count) exercícios não estão no catálogo")
                .font(FJFont.cardTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Crie todos como novos com o nome lido do arquivo, ou toque em um para escolher no catálogo.")
                .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            FJPrimaryButton("Criar todos como novos", systemImage: "plus.circle", area: .coach) { createAllAsNew() }
                .disabled(isRevising)
            ForEach(questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    Button {
                        expandedUnmatched = expandedUnmatched == question.id ? nil : question.id
                    } label: {
                        HStack {
                            Text(verbatim: question.suggestedText ?? question.prompt)
                                .font(FJFont.body)
                                .foregroundStyle(FJColor.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: expandedUnmatched == question.id ? "chevron.up" : "chevron.down")
                                .foregroundStyle(FJColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: FJSize.minTap)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Escolher este exercício"))
                    if expandedUnmatched == question.id {
                        if let source = question.source {
                            FJSourceLabel(file: source.file, page: source.page)
                        }
                        QuestionControlView(question: question, isBusy: isRevising,
                                            onAnswer: { answer in respond(question, answer) }, onFreeText: {})
                    }
                }
                .padding(.horizontal, FJSpacing.m)
                .padding(.vertical, FJSpacing.xs)
                .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
            }
        }
        .fjAnimation(FJMotion.structure, value: expandedUnmatched)
    }

    private func freeTextField(_ question: ImportQuestion) -> some View {
        HStack(alignment: .bottom, spacing: FJSpacing.s) {
            TextField("Responder…", text: $freeText, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($freeFocused)
                .padding(.horizontal, FJSpacing.m)
                .padding(.vertical, FJSpacing.s + 2)
                .frame(minHeight: FJSize.minTap)
                .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
            FJIconButton(systemImage: "arrow.up", label: "Enviar") {
                let value = freeText
                freeText = ""
                showFreeText = false
                respond(question, .text(value))
            }
            .opacity(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var doneBlock: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            FJBanner("Tudo respondido", message: "Confira o que será criado antes de salvar.", tone: .success)
            if session.hasPendingRevision {
                FJBanner("Suas respostas às dúvidas da IA", message: "A IA ainda não aplicou o que você respondeu. É uma chamada só de texto; os arquivos não são enviados de novo.",
                         tone: .neutral, systemImage: "sparkles")
                FJAIButton("Revisar com IA", systemImage: "sparkles", prominence: .subtle) { revise() }
                    .disabled(isRevising)
            }
            FJPrimaryButton("Continuar para a revisão", systemImage: "arrow.right", area: .coach, isLoading: isRevising) { finish() }
        }
    }

    // MARK: Ações

    private func respond(_ question: ImportQuestion, _ answer: ImportAnswer) {
        errorMessage = nil
        do {
            try session.answer(answer, for: question.id)
            // Exercício novo: o resumo mostra o nome efetivamente gravado.
            var summarized = answer
            if case .text = answer, let name = session.exerciseName(for: question.field) { summarized = .text(name) }
            ui.history.append(InterviewHistoryItem(id: question.id, prompt: ImportInterviewView.shortPrompt(question),
                                                   answer: ImportAnswerSummary.text(question: question, answer: summarized)))
            freeText = ""
            showFreeText = false
            reviseIfLastAnswer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAllAsNew() {
        errorMessage = nil
        do {
            for (question, name) in try session.createAllUnmatchedAsNew() {
                ui.history.append(InterviewHistoryItem(id: question.id, prompt: ImportInterviewView.shortPrompt(question),
                                                       answer: ImportAnswerSummary.text(question: question, answer: .text(name))))
            }
            expandedUnmatched = nil
            reviseIfLastAnswer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// U5: respondida a última pergunta com dúvidas da IA pendentes, aplica já (remendo curto), sem pedir outro toque.
    private func reviseIfLastAnswer() {
        if session.questions.isEmpty, session.hasPendingRevision, !isRevising { revise() }
    }

    private func skip(_ question: ImportQuestion) {
        errorMessage = nil
        do {
            try session.skip(question.id)
            ui.history.append(InterviewHistoryItem(id: question.id, prompt: ImportInterviewView.shortPrompt(question),
                                                   answer: String(localized: "pulada")))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        errorMessage = nil
        do {
            if session.hasPendingRevision {
                revise()
            } else {
                try session.finishInterview()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revise() {
        errorMessage = nil
        isRevising = true
        Task {
            defer { isRevising = false }
            do { try await session.reviseWithAI() }
            catch let ImportError.consentRequired(recipient) {
                consentRecipient = recipient
                showConsent = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    static func shortPrompt(_ question: ImportQuestion) -> String {
        let prompt = question.prompt
        return prompt.count > 48 ? String(prompt.prefix(45)) + "…" : prompt
    }
}

// MARK: - Controle por tipo de pergunta

private struct QuestionControlView: View {
    let question: ImportQuestion
    let isBusy: Bool
    let onAnswer: (ImportAnswer) -> Void
    let onFreeText: () -> Void

    @State private var multiSelection: Set<String> = []
    @State private var number: Double = 0
    @State private var unit = ""
    @State private var text = ""
    @State private var showPicker = false
    @State private var isNamingNew = false
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool

    private var trimmedNewName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Mesmo limite de `ProgramInterview.apply` (sem truncar em silêncio: o botão fica desabilitado acima dele).
    private static let maxNameLength = 80
    private var isNewNameTooLong: Bool { trimmedNewName.count > Self.maxNameLength }

    var body: some View {
        let control = ImportQuestionControl.make(for: question)
        Group {
            switch control {
            case let .chips(replies, allowsFreeText):
                FJQuickReplyChips(replies, onFreeText: allowsFreeText ? onFreeText : nil) { reply in
                    onAnswer(.choice(reply.id))
                }
            case let .multi(replies):
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    FJQuickReplyChips(replies, selected: multiSelection) { reply in
                        if multiSelection.contains(reply.id) { multiSelection.remove(reply.id) } else { multiSelection.insert(reply.id) }
                    }
                    FJPrimaryButton("Confirmar", systemImage: "checkmark", area: .coach) {
                        onAnswer(.choices(replies.map(\.id).filter { multiSelection.contains($0) }))
                    }
                    .disabled(multiSelection.isEmpty)
                }
            case let .number(spec):
                numberControl(spec)
            case let .exercise(suggestions, allowsNew):
                exerciseControl(suggestions, allowsNew: allowsNew)
            case let .text(placeholder):
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    TextField(placeholder ?? String(localized: "Resposta"), text: $text)
                        .padding(.horizontal, FJSpacing.m)
                        .frame(minHeight: FJSize.minTap)
                        .background(FJColor.surface, in: FJRadius.shape(FJRadius.field))
                        .submitLabel(.done)
                    FJPrimaryButton("Confirmar", systemImage: "checkmark", area: .coach) { onAnswer(.text(text)) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .disabled(isBusy)
    }

    private func numberControl(_ spec: ImportQuestionControl.NumberSpec) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            NumberStepperField("Valor", value: $number, unit: unit.isEmpty ? spec.defaultUnit : unit, step: spec.step,
                               range: spec.range, fractionDigits: spec.fractionDigits)
            if spec.units.count > 1 {
                FJQuickReplyChips(spec.units.map { FJQuickReply($0) }, selected: [unit.isEmpty ? spec.defaultUnit : unit]) { reply in
                    unit = reply.id
                }
            }
            if !spec.quickValues.isEmpty {
                FJQuickReplyChips(spec.quickValues.map { FJQuickReply(FJFormat.number($0, maxFractionDigits: 0), id: "\($0)") },
                                  selected: ["\(number)"]) { reply in
                    number = Double(reply.id) ?? number
                }
            }
            FJPrimaryButton("Confirmar", systemImage: "checkmark", area: .coach) {
                onAnswer(.number(number, unit: unit.isEmpty ? spec.defaultUnit : unit))
            }
            if spec.offersKeep {
                FJSecondaryButton("Manter o que li", systemImage: "checkmark.circle") { onAnswer(.keep) }
            }
        }
        .onAppear {
            number = spec.value
            unit = spec.defaultUnit
        }
    }

    private func exerciseControl(_ suggestions: [FJQuickReply], allowsNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            if !suggestions.isEmpty {
                Text("Sugestões da sua biblioteca")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                FJQuickReplyChips(suggestions) { reply in onAnswer(.exercise(reply.id)) }
            }
            FJSecondaryButton("Buscar no catálogo", systemImage: "magnifyingglass") { showPicker = true }
            if allowsNew {
                if isNamingNew {
                    newExerciseField
                } else {
                    FJSecondaryButton("Criar como novo", systemImage: "plus") {
                        newName = question.suggestedText ?? ""
                        isNamingNew = true
                    }
                }
            }
        }
        .fjAnimation(FJMotion.structure, value: isNamingNew)
        .sheet(isPresented: $showPicker) {
            ExercisePicker(allowsMultiple: false) { picked in
                guard let exercise = picked.first else { return }
                onAnswer(.exercise(exercise.catalogKey ?? "exercise:\(exercise.id.uuidString)"))
            }
        }
    }

    /// "Criar como novo": nome editável, já com o nome lido do arquivo; Confirmar envia `.text(nome)`.
    private var newExerciseField: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text("Nome do exercício novo")
                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                .accessibilityHidden(true)
            TextField("Nome do exercício", text: $newName)
                .focused($newNameFocused)
                .padding(.horizontal, FJSpacing.m)
                .frame(minHeight: FJSize.minTap)
                .background(FJColor.surface, in: FJRadius.shape(FJRadius.field))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { confirmNewExercise() }
                .accessibilityLabel(Text("Nome do exercício novo"))
                .accessibilityValue(Text(verbatim: newName))
                .accessibilityHint(Text("\(trimmedNewName.count) de 80 caracteres"))
                .task {
                    // Foco depois que o campo entra na hierarquia (no mesmo toque o teclado às vezes não abre).
                    await Task.yield()
                    newNameFocused = true
                }
            HStack(alignment: .firstTextBaseline) {
                if isNewNameTooLong {
                    Text("Use até 80 caracteres.")
                        .font(FJFont.caption).foregroundStyle(FJColor.destructive)
                }
                Spacer(minLength: FJSpacing.s)
                Text(verbatim: "\(trimmedNewName.count)/\(Self.maxNameLength)")
                    .font(FJFont.caption.monospacedDigit())
                    .foregroundStyle(isNewNameTooLong ? FJColor.destructive : FJColor.textSecondary)
                    .accessibilityHidden(true)
            }
            FJPrimaryButton("Criar exercício", systemImage: "checkmark", area: .coach) { confirmNewExercise() }
                .disabled(trimmedNewName.isEmpty || isNewNameTooLong)
            FJSecondaryButton("Cancelar", systemImage: "xmark") {
                isNamingNew = false
                newNameFocused = false
            }
        }
    }

    private func confirmNewExercise() {
        guard !trimmedNewName.isEmpty, !isNewNameTooLong else { return }
        newNameFocused = false
        onAnswer(.text(trimmedNewName))
    }
}
