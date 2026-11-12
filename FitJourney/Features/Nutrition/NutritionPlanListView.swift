import SwiftData
import SwiftUI

extension NutritionPlanAuthor {
    var title: LocalizedStringKey {
        switch self {
        case .me: "Eu"
        case .nutritionist: "Nutricionista"
        case .ai: "IA"
        }
    }
}

extension NutritionPlan {
    /// Dieta anterior (já foi ativa e saiu): somente leitura, com "Duplicar e editar" / "Reativar".
    var isPrevious: Bool { !isActive && isArchived }

    var validitySummary: String {
        let start = startDate.formatted(.dateTime.day().month(.abbreviated).year())
        guard let endDate else { return String(localized: "desde \(start)") }
        return "\(start) – \(endDate.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    var targetsSummary: String? {
        var parts: [String] = []
        if let kcal = targetKcal, kcal > 0 { parts.append("\(FJFormat.number(kcal, maxFractionDigits: 0)) kcal") }
        if let p = targetProtein, p > 0 { parts.append("P \(FJFormat.number(p, maxFractionDigits: 0)) g") }
        if let c = targetCarbs, c > 0 { parts.append("C \(FJFormat.number(c, maxFractionDigits: 0)) g") }
        if let f = targetFat, f > 0 { parts.append("G \(FJFormat.number(f, maxFractionDigits: 0)) g") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Dieta → Plano: plano ativo, planos anteriores, criar.
struct NutritionPlanListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \NutritionPlan.updatedAt, order: .reverse) private var plans: [NutritionPlan]
    @State private var showNewPlan = false
    @State private var planToDelete: NutritionPlan?
    @State private var planToActivate: NutritionPlan?
    @State private var errorMessage: String?
    @Environment(\.mealReminderScheduler) private var scheduler
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization: RestNotificationAuthorization = .authorized
    @State private var hasReminders = false

    private var active: NutritionPlan? { plans.first(where: \.isActive) }
    private var others: [NutritionPlan] { plans.filter { !$0.isActive } }

    var body: some View {
        List {
            if let errorMessage {
                FJBanner("Não foi possível concluir", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if authorization == .denied && hasReminders {
                NotificationsDisabledBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if plans.isEmpty {
                FJEmptyState("Nenhum plano ainda", systemImage: "list.bullet.clipboard",
                             message: "Crie sua dieta com metas e refeições. Os registros avulsos funcionam sem plano.",
                             actionTitle: "Criar dieta", area: .nutrition) { showNewPlan = true }
                    .listRowBackground(Color.clear)
                ImportWithAIButton(kind: .nutrition)
                    .listRowBackground(Color.clear)
            }
            if let active {
                Section("Plano ativo") {
                    NavigationLink(value: active) { PlanRow(plan: active) }
                        .swipeActions(edge: .trailing) { actions(for: active) }
                }
            }
            if !others.isEmpty {
                Section("Anteriores e rascunhos") {
                    ForEach(others) { plan in
                        NavigationLink(value: plan) { PlanRow(plan: plan) }
                            .swipeActions(edge: .trailing) { actions(for: plan) }
                            .swipeActions(edge: .leading) {
                                Button("Ativar", systemImage: "checkmark.circle") { request(activate: plan) }
                                    .tint(FJColor.nutritionFill)
                            }
                            .contextMenu {
                                Button("Ativar", systemImage: "checkmark.circle") { request(activate: plan) }
                                Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(plan) }
                                Button("Excluir", systemImage: "trash", role: .destructive) { planToDelete = plan }
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle("Plano")
        .task { await refreshReminderState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshReminderState() } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: NutritionPlan.self) { PlanEditorView(plan: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Novo plano", systemImage: "plus") { showNewPlan = true }
                    ImportWithAIMenuItem(kind: .nutrition)
                } label: {
                    Label("Novo plano", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewPlan) { NewPlanSheet() }
        .confirmationDialog(planToDelete?.isActive == true ? "Excluir o plano ativo?" : "Excluir este plano?", isPresented: Binding(get: { planToDelete != nil },
                                                                       set: { if !$0 { planToDelete = nil } }),
                            titleVisibility: .visible, presenting: planToDelete) { plan in
            Button(plan.isActive ? "Excluir o plano ativo" : "Excluir \(plan.name)", role: .destructive) { delete(plan) }
        } message: { plan in
            if plan.isActive {
                Text("Este é o plano ativo. Sem ele, o dia mostra só registros avulsos até você criar ou ativar outro. Refeições e itens serão apagados; os registros já feitos continuam no histórico.")
            } else {
                Text("Refeições e itens do plano serão apagados. Os registros já feitos continuam no histórico.")
            }
        }
        .confirmationDialog("Ativar este plano?", isPresented: Binding(get: { planToActivate != nil },
                                                                      set: { if !$0 { planToActivate = nil } }),
                            titleVisibility: .visible, presenting: planToActivate) { plan in
            Button("Ativar \(plan.name)") { activate(plan) }
        } message: { plan in
            if let active { Text("\(active.name) vai para o histórico.") }
        }
    }

    @ViewBuilder private func actions(for plan: NutritionPlan) -> some View {
        Button("Excluir", systemImage: "trash", role: .destructive) { planToDelete = plan }
        Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(plan) }.tint(FJColor.coachFill)
    }

    private var store: NutritionStore { NutritionStore(context: context) }

    private func request(activate plan: NutritionPlan) {
        if active != nil { planToActivate = plan } else { activate(plan) }
    }

    private func activate(_ plan: NutritionPlan) {
        run { try store.switchActive(to: plan) }
    }

    private func duplicate(_ plan: NutritionPlan) {
        run { try store.duplicate(plan) }
    }

    private func delete(_ plan: NutritionPlan) {
        run { try store.delete(plan) }
    }

    private func run<T>(_ work: () throws -> T) {
        do { _ = try work() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
        Task { await scheduler?.reschedule(for: context); await refreshReminderState() }
    }

    private func refreshReminderState() async {
        authorization = await scheduler?.authorization() ?? .authorized
        hasReminders = ((try? context.fetchCount(FetchDescriptor<Meal>(predicate: #Predicate { $0.reminderEnabled }))) ?? 0) > 0
    }
}

private struct PlanRow: View {
    let plan: NutritionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.name.isEmpty ? String(localized: "Plano sem nome") : plan.name)
                    .font(FJFont.cardTitle)
                Spacer(minLength: FJSpacing.s)
                if plan.isActive { FJTag("Ativo", systemImage: "checkmark.circle.fill", tone: .success) }
                else if plan.isPrevious { FJTag("Anterior", systemImage: "clock.arrow.circlepath") }
                else { FJTag("Rascunho", systemImage: "pencil") }
            }
            if !plan.goal.isEmpty {
                Text(plan.goal).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
            Text("\(plan.validitySummary) · \(Text(plan.author.title))")
                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            if let targets = plan.targetsSummary {
                Text(targets).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
            } else {
                Text("Sem metas definidas").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        }
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Sheet "Criar dieta": edita um plano num contexto de rascunho (nada é persistido antes de confirmar);
/// ao salvar, ativa direto se não há dieta ativa, senão pergunta.
struct NewPlanSheet: View {
    @Environment(\.modelContext) private var mainContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mealReminderScheduler) private var scheduler
    @State private var draft: ModelContext?
    @State private var plan: NutritionPlan?
    @State private var showActivate = false
    @State private var currentActive: NutritionPlan?
    @State private var savedID: PersistentIdentifier?
    @State private var errorMessage: String?

    var body: some View {
        EditorSheet(title: "Novo plano", confirmTitle: "Salvar",
                    canConfirm: !(plan?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true),
                    onCancel: { dismiss() }, onConfirm: confirm) {
            if let plan, let draft {
                PlanEditorView(plan: plan, isNew: true)
                    .environment(\.modelContext, draft)
            } else {
                FJLoadingState()
            }
        }
        .interactiveDismissDisabled()
        .task { createIfNeeded() }
        .confirmationDialog(activateTitle, isPresented: $showActivate, titleVisibility: .visible) {
            Button("Ativar agora") { activate() }
            Button("Agora não", role: .cancel) { dismiss() }
        } message: {
            if let currentActive { Text("\(currentActive.name) vai para o histórico.") }
        }
        .alert("Não foi possível salvar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var activateTitle: LocalizedStringKey { "Ativar \(plan?.name ?? "") agora?" }

    private func createIfNeeded() {
        guard plan == nil else { return }
        let context = ModelContext(mainContext.container)
        context.autosaveEnabled = false
        let new = NutritionPlan(name: "")
        context.insert(new)
        let day = NutritionDay(name: String(localized: "Todos os dias"))
        context.insert(day)
        day.plan = new
        draft = context
        plan = new
    }

    private func confirm() {
        guard let plan, let draft else { return }
        plan.name = plan.name.trimmingCharacters(in: .whitespaces)
        plan.updatedAt = .now
        do {
            try draft.save()
            Task { await scheduler?.reschedule(for: mainContext) }
            savedID = plan.persistentModelID
            currentActive = try NutritionStore(context: mainContext).activePlan()
            if currentActive == nil { activate() } else { showActivate = true }
        } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }

    private func activate() {
        do {
            if let savedID, let saved = mainContext.model(for: savedID) as? NutritionPlan {
                try NutritionStore(context: mainContext).switchActive(to: saved)
                Task { await scheduler?.reschedule(for: mainContext) }
            }
            dismiss()
        } catch {
            errorMessage = String(localized: "O plano foi salvo, mas não foi ativado. Ative pela lista de planos.")
        }
    }
}

#Preview("Planos") {
    NavigationStack { NutritionPlanListView() }
        .modelContainer(PersistenceController.preview)
}
