import SwiftData
import SwiftUI

/// Etapa final: tudo o que será criado, com a confiança à vista (DESIGN §4.15.7). Nada foi gravado até o botão principal.
struct ImportReviewView: View {
    let session: ImportSession
    @Bindable var ui: ImportUIState

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TrainingProgram> { !$0.isArchived }, sort: \TrainingProgram.startDate, order: .reverse)
    private var programs: [TrainingProgram]
    @Query(filter: #Predicate<NutritionPlan> { $0.isActive }) private var activePlans: [NutritionPlan]

    @State private var errorMessage: String?
    @State private var expanded: Set<String> = []
    @State private var didSetupExpansion = false
    @State private var attentionCursor = 0
    @State private var confirmActivate = false

    private var isApplying: Bool { session.phase == .applying }
    private var sessionInProgress: Bool { (try? SessionStore(context: context).inProgressSession()) != nil }
    private var activeProgram: TrainingProgram? { programs.first(where: \.isActive) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    switch session.kind {
                    case .program: programContent(proxy)
                    case .nutrition: nutritionContent(proxy)
                    }
                }
                .padding(FJSpacing.screenMargin)
                .disabled(isApplying)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .confirmationDialog(activateTitle, isPresented: $confirmActivate, titleVisibility: .visible) {
            Button("Criar e ativar") { apply() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(activateMessage)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Voltar às perguntas") { session.backToInterview() }
                    .disabled(isApplying)
            }
        }
    }

    // MARK: Treino

    @ViewBuilder
    private func programContent(_ proxy: ScrollViewProxy) -> some View {
        if let draft = try? session.programDraft(), let extraction = session.programImport {
            let matches = ((try? session.exerciseMatches()) ?? []).map { $0.map { $0 != nil } }
            let offset = ImportOverrides.colorOffset(target: ui.target, context: context)
            let cards = ImportReviewBuilder.programCards(draft: draft, extraction: extraction, selected: session.selected,
                                                         matches: matches, overrides: ui.routines, colorOffset: offset)
            let attention = cards.flatMap(\.exercises).filter { $0.confidence < .high }.count
            header(name: draft.name, tags: programTags(draft), attention: attention) {
                let firstWithCheck = cards.filter(\.needsCheck)
                guard !firstWithCheck.isEmpty else { return }
                let target = firstWithCheck[attentionCursor % firstWithCheck.count]
                attentionCursor += 1
                expanded.insert("r\(target.id)")
                withAnimation(FJMotion.structure) { proxy.scrollTo("r\(target.id)", anchor: .top) }
            }
            destinationSection
            ForEach(cards) { card in
                routineCard(card)
                    .id("r\(card.id)")
            }
            optionsSection
                .onAppear { setupExpansion(cards) }
        } else {
            invalidDraft
        }
    }

    private func programTags(_ draft: ProgramDraft) -> [LocalizedStringKey] {
        [LocalizedStringKey(draft.goal.localizedName), LocalizedStringKey(draft.scheduleMode.localizedName)]
    }

    private func routineCard(_ card: ReviewRoutineCard) -> some View {
        let key = "r\(card.id)"
        let isOpen = expanded.contains(key)
        return VStack(alignment: .leading, spacing: FJSpacing.s) {
            Button { toggle(key) } label: {
                HStack(alignment: .top, spacing: FJSpacing.m) {
                    FJRoutineBadge(symbol: card.symbol, name: card.name, colorName: card.colorName)
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text(verbatim: card.name).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary)
                        Text(card.exercises.count == 1 ? "1 exercício" : "\(card.exercises.count) exercícios")
                            .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        if let source = card.source { FJSourceLabel(file: source.file, page: source.page) }
                        if card.attentionCount == 0 { FJConfidenceBadge(.high, style: .full) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(FJColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: FJSize.minTap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(isOpen ? "Recolhe a ficha" : "Mostra os exercícios"))
            if isOpen {
                ForEach(card.exercises) { row in
                    Divider()
                    exerciseRow(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .fjAnimation(FJMotion.structure, value: isOpen)
    }

    private func exerciseRow(_ row: ReviewExerciseRow) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            HStack(spacing: FJSpacing.s) {
                Text(verbatim: row.name).font(FJFont.body.weight(.semibold))
                if row.isNew { FJTag("novo", tone: .neutral) }
            }
            Text(verbatim: row.prescription).font(FJFont.numberBody).foregroundStyle(FJColor.textSecondary)
            if row.confidence < .high {
                FJConfidenceBadge(row.confidence, style: .compact)
                if let reason = row.reason {
                    Text(verbatim: reason).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Dieta

    @ViewBuilder
    private func nutritionContent(_ proxy: ScrollViewProxy) -> some View {
        if let draft = try? session.nutritionDraft(), let extraction = session.nutritionImport {
            let meals = ImportReviewBuilder.mealCards(draft: draft, extraction: extraction, selected: session.selected)
            let attention = meals.reduce(0) { $0 + $1.attentionCount }
            header(name: draft.name, tags: draft.days.count > 1 ? draft.days.map { LocalizedStringKey($0.name) } : [], attention: attention) {
                guard let target = meals.first(where: { $0.attentionCount > 0 }) else { return }
                expanded.insert("m\(target.id)")
                withAnimation(FJMotion.structure) { proxy.scrollTo("m\(target.id)", anchor: .top) }
            }
            targetsGrid(draft.targets)
            ForEach(meals) { meal in
                mealCard(meal).id("m\(meal.id)")
            }
            optionsSection
                .onAppear {
                    if !didSetupExpansion {
                        didSetupExpansion = true
                        expanded.insert("m0")
                        for meal in meals where meal.attentionCount > 0 { expanded.insert("m\(meal.id)") }
                    }
                }
        } else {
            invalidDraft
        }
    }

    private func targetsGrid(_ targets: NutritionPlanDraft.TargetsDraft) -> some View {
        FJMetricGrid {
            FJMetricCell("Calorias", value: targets.kcal.map { FJFormat.number($0, maxFractionDigits: 0) }, unit: "kcal")
            FJMetricCell("Proteína", value: targets.protein.map { FJFormat.number($0, maxFractionDigits: 0) }, unit: "g")
            FJMetricCell("Carboidrato", value: targets.carbs.map { FJFormat.number($0, maxFractionDigits: 0) }, unit: "g")
            FJMetricCell("Gordura", value: targets.fat.map { FJFormat.number($0, maxFractionDigits: 0) }, unit: "g")
        }
        .fjCard()
    }

    private func mealCard(_ meal: ReviewMealCard) -> some View {
        let key = "m\(meal.id)"
        let isOpen = expanded.contains(key)
        return VStack(alignment: .leading, spacing: FJSpacing.s) {
            Button { toggle(key) } label: {
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.m) {
                    Text(verbatim: meal.time).font(FJFont.numberMedium).foregroundStyle(FJColor.nutrition)
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text(verbatim: meal.name).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary)
                        if let kcal = meal.totalKcal {
                            Text("\(FJFormat.number(kcal, maxFractionDigits: 0)) kcal").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        }
                        if meal.attentionCount > 0 {
                            FJTag(meal.attentionCount == 1 ? "1 item para conferir" : "\(meal.attentionCount) itens para conferir",
                                  systemImage: "exclamationmark.triangle.fill", tone: .attention)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(FJColor.textTertiary).accessibilityHidden(true)
                }
                .frame(minHeight: FJSize.minTap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(meal.items) { item in
                    Divider()
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        HStack(spacing: FJSpacing.s) {
                            Text(verbatim: item.name).font(FJFont.body.weight(.semibold))
                            if item.isEstimated { FJTag("estimado", tone: .neutral) }
                        }
                        Text(verbatim: item.detail).font(FJFont.numberBody).foregroundStyle(FJColor.textSecondary)
                        if item.needsCheck { FJConfidenceBadge(.medium, style: .compact) }
                        if item.substitutions > 0 {
                            Text(item.substitutions == 1 ? "1 substituição" : "\(item.substitutions) substituições")
                                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if meal.estimatedCount > 0 {
                    Text("Valores estimados pela IA").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .fjAnimation(FJMotion.structure, value: isOpen)
    }

    // MARK: Comum

    private func header(name: String, tags: [LocalizedStringKey], attention: Int, onSeeAttention: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            FJAIBadge(session.attachments.count == 1 ? "Importado de 1 arquivo" : "Importado de \(session.attachments.count) arquivos")
            TextField(session.kind == .program ? "Nome do programa" : "Nome da dieta",
                      text: Binding(get: { ui.name ?? name }, set: { ui.name = $0 }))
                .font(FJFont.screenTitle)
                .accessibilityLabel(Text(session.kind == .program ? "Nome do programa" : "Nome da dieta"))
            if !tags.isEmpty {
                FJFlowLayout(spacing: FJSpacing.s) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in FJTag(tag) }
                }
            }
            if attention > 0 {
                HStack {
                    Label(attention == 1 ? "1 item para conferir" : "\(attention) itens para conferir",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(FJFont.label.weight(.semibold))
                        .foregroundStyle(FJColor.textPrimary)
                    Spacer()
                    Button("Ver", action: onSeeAttention)
                        .font(FJFont.label.weight(.semibold))
                        .frame(minHeight: FJSize.minTap)
                }
                .padding(.horizontal, FJSpacing.m)
                .background(FJTone.attention.soft, in: FJRadius.shape(FJRadius.field))
            } else {
                FJTag("Tudo lido com clareza", systemImage: "checkmark.circle.fill", tone: .success)
            }
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        if session.kind == .program, !programs.isEmpty {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text("Destino").font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                Picker("Destino", selection: $ui.target) {
                    Text("Novo programa").tag(ImportSession.Target.newProgram)
                    ForEach(programs) { program in
                        Text("Adicionar ao programa \(program.name)").tag(ImportSession.Target.existingProgram(program.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            Toggle("Ativar agora", isOn: Binding(get: { ui.activate && !sessionInProgress }, set: { ui.activate = $0 }))
                .disabled(sessionInProgress)
                .frame(minHeight: FJSize.minTap)
            if sessionInProgress {
                Text("Há um treino em andamento. Cria sem ativar; ative depois de finalizar o treino.")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            } else {
                Text(session.kind == .program ? "Desligado, o programa fica salvo sem trocar o ativo." : "Desligado, a dieta fica salva sem trocar a ativa.")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            if let errorMessage {
                FJBanner("Não foi possível criar", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Tentar de novo") { apply() }
            }
        }
        .padding(.top, FJSpacing.s)
    }

    private var invalidDraft: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            let message: String = {
                switch session.kind {
                case .program: (try? session.programDraft()).map { _ in "" } ?? lastIssue { _ = try session.programDraft() }
                case .nutrition: (try? session.nutritionDraft()).map { _ in "" } ?? lastIssue { _ = try session.nutritionDraft() }
                }
            }()
            FJBanner("Falta algo para criar", message: LocalizedStringKey(message), tone: .attention)
            FJSecondaryButton("Voltar às perguntas", systemImage: "arrow.uturn.backward") { session.backToInterview() }
        }
    }

    private func lastIssue(_ work: () throws -> Void) -> String {
        do { try work(); return "" } catch { return error.localizedDescription }
    }

    // MARK: Botão principal

    private var bottomBar: some View {
        FJPrimaryButton(primaryTitle, systemImage: "checkmark", area: session.kind == .program ? .training : .nutrition,
                        isLoading: isApplying) {
            if wantsActivation, hasOtherActive { confirmActivate = true } else { apply() }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.vertical, FJSpacing.s)
        .background(FJColor.background)
    }

    private var wantsActivation: Bool { ui.activate && !sessionInProgress }

    private var hasOtherActive: Bool {
        switch session.kind {
        case .program:
            if case let .existingProgram(id) = ui.target { return activeProgram != nil && activeProgram?.id != id }
            return activeProgram != nil
        case .nutrition: return !activePlans.isEmpty
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch (session.kind, ui.target) {
        case (.nutrition, _): wantsActivation ? "Criar e ativar" : "Criar dieta"
        case let (.program, .existingProgram(id)):
            if let program = programs.first(where: { $0.id == id }) {
                "Adicionar ao programa \(program.name)"
            } else {
                "Adicionar ao programa"
            }
        case (.program, _): wantsActivation ? "Criar e ativar" : "Criar programa"
        }
    }

    private var activateTitle: LocalizedStringKey {
        session.kind == .program ? "Ativar o novo programa agora?" : "Ativar a nova dieta agora?"
    }

    private var activateMessage: LocalizedStringKey {
        if session.kind == .program, let activeProgram { return "\(activeProgram.name) vai para o histórico." }
        if let plan = activePlans.first { return "\(plan.name) vai para o histórico." }
        return ""
    }

    // MARK: Ações

    private func apply() {
        errorMessage = nil
        do {
            let result = try session.apply(target: ui.target, activate: wantsActivation)
            let name = (try? ImportOverrides.apply(ui: ui, session: session, resultID: result, context: context)) ?? ui.name ?? ""
            var createdNew = true
            if case .existingProgram = ui.target { createdNew = false }
            coordinator?.complete(session, resultID: result, createdNew: createdNew, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func setupExpansion(_ cards: [ReviewRoutineCard]) {
        guard !didSetupExpansion else { return }
        didSetupExpansion = true
        if let first = cards.first { expanded.insert("r\(first.id)") }
        for card in cards where card.needsCheck { expanded.insert("r\(card.id)") }
    }
}

// MARK: - Mudanças de tela aplicadas ao resultado

/// Nome, letra e cor escolhidos na tela são aplicados ao programa/plano logo depois de gravar (o núcleo ainda não
/// tem API para editar a extração). Também dá a cor padrão de cada ficha (sequência da paleta).
@MainActor
enum ImportOverrides {
    /// Em "adicionar ao programa X" a sequência de cores continua a partir das fichas que ele já tem.
    static func colorOffset(target: ImportSession.Target, context: ModelContext) -> Int {
        guard case let .existingProgram(id) = target else { return 0 }
        var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.sortedRoutines.count ?? 0
    }

    /// Devolve o nome final do programa/plano.
    @discardableResult
    static func apply(ui: ImportUIState, session: ImportSession, resultID: UUID, context: ModelContext) throws -> String {
        switch session.kind {
        case .program:
            var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == resultID })
            descriptor.fetchLimit = 1
            guard let program = try context.fetch(descriptor).first else { return ui.name ?? "" }
            var isNew = true
            if case .existingProgram = ui.target { isNew = false }
            if isNew, let name = ui.name.nonEmpty { program.name = name }
            let routines = program.sortedRoutines
            let selected = session.selected.sorted()
            let start = max(0, routines.count - selected.count)
            let letters = Array("ABCDEFGHIJKL")
            for (position, index) in selected.enumerated() where start + position < routines.count {
                let routine = routines[start + position]
                let override = ui.routines[index]
                if let name = override?.name.nonEmpty { routine.name = name }
                if let symbol = override?.symbol.nonEmpty {
                    routine.symbol = symbol
                } else if routine.symbol.isEmpty {
                    routine.symbol = String(letters[min(start + position, letters.count - 1)])
                }
                routine.colorName = override?.colorName.nonEmpty ?? FJRoutineColor.suggested(forIndex: start + position).rawValue
            }
            try context.save()
            return program.name
        case .nutrition:
            guard let plan = try NutritionStore(context: context).plan(id: resultID) else { return ui.name ?? "" }
            if let name = ui.name.nonEmpty {
                plan.name = name
                try context.save()
            }
            return plan.name
        }
    }

    /// "Desfazer" do aviso: apaga o que foi criado (só quando era novo).
    static func undo(_ completion: ImportCompletion, context: ModelContext) throws {
        let resultID = completion.resultID
        switch completion.kind {
        case .program:
            var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == resultID })
            descriptor.fetchLimit = 1
            if let program = try context.fetch(descriptor).first { try ProgramStore(context: context).delete(program) }
        case .nutrition:
            if let plan = try NutritionStore(context: context).plan(id: resultID) {
                try NutritionStore(context: context).delete(plan)
            }
        }
    }
}
