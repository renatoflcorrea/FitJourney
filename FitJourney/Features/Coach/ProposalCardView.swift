import SwiftData
import SwiftUI

/// Cartão de proposta do Coach (SPEC §7): resumo + "Revisar e salvar". Nada é salvo antes do toque;
/// o resultado é inativo (`origin = .ai`) e abre no editor normal, com "Ativar" depois.
struct ProposalCardView: View {
    let proposal: CoachProposal
    /// Id da mensagem do chat: compõe a chave de estado (o id da chamada pode repetir).
    let messageID: UUID
    let defaults: UserDefaults
    let onOpenProgram: (TrainingProgram) -> Void
    let onOpenPlan: (NutritionPlan) -> Void

    @Environment(\.modelContext) private var context
    @State private var state: ProposalStateStore.State = .pending
    @State private var matches: [[Bool]]?
    @State private var errorMessage: String?
    @State private var expanded = false

    private var store: ProposalStateStore { ProposalStateStore(defaults: defaults) }
    private var stateKey: String { ProposalStateStore.key(messageID: messageID, proposalID: proposal.id) }
    private var isSaved: Bool { if case .saved = state { true } else { false } }
    private var model: ProposalCardModel { ProposalCardModel(proposal, matches: matches) }

    var body: some View {
        Group {
            if state != .discarded { card }
        }
        .onAppear { state = store.state(for: stateKey) }
        .task(id: stateKey) { computeMatches() }
    }

    private var card: some View {
        let model = model
        return VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                FJTag(model.kind == .program ? "Programa" : "Plano alimentar",
                      systemImage: model.kind == .program ? "dumbbell.fill" : "fork.knife", area: .coach)
                Spacer()
                if case .saved = state { FJTag("Salvo", systemImage: "checkmark", tone: .success) }
            }
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text(model.title).font(FJFont.sectionTitle)
                Text(model.subtitle).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                if !model.targets.isEmpty {
                    Text(model.targets.joined(separator: " · "))
                        .font(FJFont.numberCaption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    ForEach(model.rows) { row in rowView(row) }
                }
                .padding(.top, FJSpacing.s)
            } label: {
                Text(model.kind == .program ? "Ver fichas e exercícios" : "Ver refeições")
                    .font(FJFont.label.weight(.semibold))
            }
            if model.newExerciseCount > 0, !isSaved {
                Label("\(model.newExerciseCount) exercícios novos serão criados na sua biblioteca.",
                      systemImage: "plus.circle")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
            if let errorMessage {
                FJBanner("Não foi possível salvar", message: CoachMarkdown.literal(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
            }
            actions
        }
        .fjCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowView(_ row: ProposalRow) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack {
                Text(row.title).font(FJFont.cardTitle)
                Spacer(minLength: FJSpacing.s)
                Text(row.detail).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: FJSpacing.s) {
                    Text(item.name).font(FJFont.label)
                    if item.isNew { FJTag("novo", tone: .attention) }
                    Spacer(minLength: FJSpacing.s)
                    Text(item.detail).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .saved(let id):
            FJPrimaryButton("Abrir para revisar", systemImage: "square.and.pencil", area: .coach) { openSaved(id) }
        default:
            VStack(spacing: FJSpacing.s) {
                FJPrimaryButton("Revisar e salvar", systemImage: "square.and.pencil", area: .coach, action: reviewAndSave)
                Button("Descartar") {
                    store.markDiscarded(stateKey)
                    state = .discarded
                }
                .buttonStyle(.fjSecondary())
            }
        }
    }

    /// Calcula uma vez por proposta (o cartão é recriado ao rolar a lista).
    private func computeMatches() {
        guard case let .program(draft) = proposal.content else { return }
        if let cached = ProposalMatchCache.values[stateKey] { matches = cached; return }
        guard let found = try? DraftApplier(context: context).exerciseMatches(for: draft) else { return }
        let value = found.map { $0.map { $0 != nil } }
        ProposalMatchCache.values[stateKey] = value
        matches = value
    }

    private func reviewAndSave() {
        let applier = DraftApplier(context: context)
        do {
            switch proposal.content {
            case let .program(draft):
                let program = try applier.makeProgram(from: draft)
                store.markSaved(stateKey, id: program.id)
                state = .saved(program.id)
                ProposalMatchCache.values[stateKey] = nil
                onOpenProgram(program)
            case let .nutritionPlan(draft):
                let plan = try applier.makeNutritionPlan(from: draft)
                store.markSaved(stateKey, id: plan.id)
                state = .saved(plan.id)
                onOpenPlan(plan)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSaved(_ id: UUID) {
        switch proposal.content {
        case .program:
            if let program = try? context.fetch(FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == id })).first {
                onOpenProgram(program)
            } else { resetMissing() }
        case .nutritionPlan:
            if let plan = try? context.fetch(FetchDescriptor<NutritionPlan>(predicate: #Predicate { $0.id == id })).first {
                onOpenPlan(plan)
            } else { resetMissing() }
        }
    }

    /// O item salvo foi apagado: volta a oferecer "Revisar e salvar".
    private func resetMissing() {
        store.clear(stateKey)
        ProposalMatchCache.values[stateKey] = nil
        state = .pending
        errorMessage = String(localized: "O item salvo não existe mais. Você pode salvar de novo.")
    }
}

@MainActor
private enum ProposalMatchCache {
    static var values: [String: [[Bool]]] = [:]
}

// MARK: - Revisão

/// Depois de "Revisar e salvar" (programa): fichas para abrir no editor e "Ativar programa".
struct ProgramReviewView: View {
    @Bindable var program: TrainingProgram
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                FJBanner("Rascunho do Coach",
                         message: "Este programa está inativo. Revise as fichas e ative quando estiver pronto.",
                         systemImage: "sparkles")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let errorMessage {
                Section {
                    FJBanner("Não foi possível ativar", message: CoachMarkdown.literal(errorMessage), tone: .destructive,
                             actionTitle: "Fechar") { self.errorMessage = nil }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section("Fichas") {
                ForEach(program.sortedRoutines) { routine in
                    NavigationLink {
                        RoutineEditorView(routine: routine)
                    } label: {
                        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                            Text(routine.symbol.isEmpty ? routine.name : "\(routine.symbol) · \(routine.name)")
                            Text("\(routine.sortedExercises.count) exercícios")
                                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                }
            }
        }
        .fjHaptic(.celebration, trigger: program.isActive) { old, new in !old && new }
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if program.isActive {
                    Label("Programa ativo", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(FJColor.success)
                        .frame(maxWidth: .infinity, minHeight: FJSize.primaryButton)
                } else {
                    FJPrimaryButton("Ativar programa", systemImage: "bolt.fill", area: .coach, action: activate)
                }
            }
            .padding(FJSpacing.screenMargin)
        }
    }

    private func activate() {
        do {
            try ProgramStore(context: context).activate(program)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Depois de "Revisar e salvar" (plano): editor do plano com "Ativar plano" embaixo.
struct PlanReviewView: View {
    @Bindable var plan: NutritionPlan
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        PlanEditorView(plan: plan)
            .fjHaptic(.celebration, trigger: plan.isActive) { old, new in !old && new }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: FJSpacing.s) {
                    if let errorMessage {
                        FJBanner("Não foi possível ativar", message: CoachMarkdown.literal(errorMessage), tone: .destructive,
                                 actionTitle: "Fechar") { self.errorMessage = nil }
                    }
                    if plan.isActive {
                        Label("Plano ativo", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(FJColor.success)
                            .frame(maxWidth: .infinity, minHeight: FJSize.primaryButton)
                    } else {
                        FJPrimaryButton("Ativar plano", systemImage: "bolt.fill", area: .coach, action: activate)
                    }
                }
                .padding(FJSpacing.screenMargin)
                .background(.bar)
            }
    }

    private func activate() {
        do {
            try NutritionStore(context: context).activate(plan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
