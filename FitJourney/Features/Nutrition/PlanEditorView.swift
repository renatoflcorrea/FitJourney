import SwiftData
import SwiftUI

/// Editor de plano alimentar (DESIGN §4.10). Edita os modelos ao vivo (autosave no contexto principal;
/// em "Novo plano" o contexto é um rascunho que só persiste ao confirmar). Dieta anterior abre somente
/// leitura com "Duplicar e editar" (abre a cópia aqui mesmo) / "Reativar".
struct PlanEditorView: View {
    @State private var current: NutritionPlan
    var isNew = false

    init(plan: NutritionPlan, isNew: Bool = false) {
        _current = State(initialValue: plan)
        self.isNew = isNew
    }

    var body: some View {
        PlanEditorForm(plan: current, isNew: isNew) { current = $0 }
            .id(current.id)
    }
}

private struct PlanEditorForm: View {
    enum Variation: Hashable { case allDays, byWeekday }

    @Environment(\.modelContext) private var context
    @Bindable var plan: NutritionPlan
    let isNew: Bool
    let onSwitch: (NutritionPlan) -> Void

    @State private var variation: Variation = .allDays
    @State private var didSetup = false
    @State private var showCollapseConfirm = false
    @State private var dayToDelete: NutritionDay?
    @State private var errorMessage: String?
    @Environment(\.mealReminderScheduler) private var scheduler

    private var readOnly: Bool { plan.isPrevious && !isNew }

    private var hasEnd: Binding<Bool> {
        Binding(get: { plan.endDate != nil },
                set: { plan.endDate = $0 ? (plan.endDate ?? Calendar.autoupdatingCurrent.date(byAdding: .month, value: 3, to: plan.startDate)) : nil })
    }

    var body: some View {
        Form {
            if readOnly {
                Section {
                    FJBanner("Dieta anterior", message: "Somente leitura. Reative ou duplique para editar.",
                             systemImage: "lock")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if let errorMessage {
                Section {
                    FJBanner("Não foi possível concluir", message: LocalizedStringKey(errorMessage), tone: .destructive,
                             actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Group {
                planSection
                targetsSection
                variationSection
            }
            .disabled(readOnly)
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle(plan.name.isEmpty ? String(localized: "Novo plano") : plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Opções", systemImage: "ellipsis.circle") {
                        Button("Reativar", systemImage: "checkmark.circle", action: reactivate)
                        Button("Duplicar e editar", systemImage: "plus.square.on.square", action: duplicateAndEdit)
                    }
                }
            }
        }
        .task { setupIfNeeded() }
        .onDisappear { reschedule() }
        .onChange(of: plan.startDate) { _, start in
            if let end = plan.endDate, end < start { plan.endDate = start } // fim nunca antes do início
        }
        .confirmationDialog("Usar o mesmo plano em todos os dias?", isPresented: $showCollapseConfirm, titleVisibility: .visible) {
            Button("Manter só a primeira variação", role: .destructive, action: collapseToUniform)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As outras variações e suas refeições serão apagadas.")
        }
        .confirmationDialog("Apagar esta variação?", isPresented: Binding(get: { dayToDelete != nil },
                                                                        set: { if !$0 { dayToDelete = nil } }),
                            titleVisibility: .visible, presenting: dayToDelete) { day in
            Button("Apagar variação", role: .destructive) {
                context.delete(day)
                commit()
            }
        } message: { _ in Text("As refeições dela serão apagadas.") }
    }

    // MARK: Seções

    private var planSection: some View {
        Section("Plano") {
            TextField("Nome", text: $plan.name)
                .textInputAutocapitalization(.sentences)
            TextField("Objetivo", text: $plan.goal)
                .textInputAutocapitalization(.sentences)
            DatePicker("Início", selection: $plan.startDate, displayedComponents: .date)
            Toggle("Definir fim", isOn: hasEnd)
                .tint(FJColor.nutritionFill)
            if let end = plan.endDate {
                DatePicker("Fim", selection: Binding(get: { end }, set: { plan.endDate = max($0, plan.startDate) }),
                           in: plan.startDate..., displayedComponents: .date)
            }
            Picker("Autor", selection: $plan.author) {
                ForEach(NutritionPlanAuthor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var targetsSection: some View {
        Section {
            OptionalDoubleField("Calorias", value: $plan.targetKcal, unit: "kcal", field: .kcal, zeroIsNil: true)
            OptionalDoubleField("Proteína", value: $plan.targetProtein, unit: "g", zeroIsNil: true)
            OptionalDoubleField("Carboidrato", value: $plan.targetCarbs, unit: "g", zeroIsNil: true)
            OptionalDoubleField("Gordura", value: $plan.targetFat, unit: "g", zeroIsNil: true)
            OptionalDoubleField("Fibra", value: $plan.targetFiber, unit: "g", zeroIsNil: true)
            OptionalDoubleField("Água", value: $plan.targetWaterMilliliters, unit: "ml", field: .milliliters, zeroIsNil: true)
        } header: {
            Text("Metas diárias")
        } footer: {
            Text("Todas opcionais. Vazio ou 0 = sem meta.")
        }
    }

    @ViewBuilder private var variationSection: some View {
        Section {
            Picker("Variação", selection: Binding(get: { variation }, set: setVariation)) {
                Text("Todos os dias").tag(Variation.allDays)
                Text("Por dia da semana").tag(Variation.byWeekday)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Variação")
        } footer: {
            if variation == .byWeekday {
                Text("Ex.: dia de treino x descanso. A variação sem dias marcados vale para os dias que nenhuma outra cobre (só pode haver uma).")
            }
        }
        if variation == .allDays {
            if let day = plan.sortedDays.first {
                MealsSection(day: day)
            }
        } else {
            Section("Variações") {
                ForEach(plan.sortedDays) { day in
                    NavigationLink { DayVariantEditor(day: day, plan: plan) } label: { DayVariantRow(day: day) }
                        .swipeActions { Button("Apagar", systemImage: "trash", role: .destructive) { dayToDelete = day } }
                }
                Button("Adicionar variação", systemImage: "plus", action: addVariant)
            }
        }
    }

    // MARK: Lógica

    private func commit() {
        do { try context.commitEdits() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
        reschedule()
    }

    /// Só com o contexto principal (o rascunho de "Novo plano" não está salvo).
    private func reschedule() {
        if context.autosaveEnabled { Task { await scheduler?.reschedule(for: context) } }
    }

    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        let days = plan.sortedDays
        if days.isEmpty { addDay(name: String(localized: "Todos os dias"), weekdays: []) }
        variation = (days.count <= 1 && (days.first?.appliesToAllDays ?? true)) ? .allDays : .byWeekday
    }

    private func setVariation(_ new: Variation) {
        guard !readOnly, new != variation else { return }
        if new == .allDays, plan.sortedDays.count > 1 {
            showCollapseConfirm = true
            return
        }
        if new == .allDays, let only = plan.sortedDays.first { only.weekdays = [] }
        variation = new
    }

    private func collapseToUniform() {
        let days = plan.sortedDays
        guard let keep = days.first else { return }
        for other in days.dropFirst() { context.delete(other) }
        keep.weekdays = []
        commit()
        variation = .allDays
    }

    @discardableResult
    private func addDay(name: String, weekdays: Set<Weekday>) -> NutritionDay {
        let next = (plan.sortedDays.map(\.sortIndex).max() ?? -1) + 1
        let day = NutritionDay(name: name, weekdays: weekdays, sortIndex: next)
        context.insert(day)
        day.plan = plan
        return day
    }

    /// Nova variação já começa no primeiro dia da semana livre (só uma variação pode valer para "demais dias").
    private func addVariant() {
        let taken = plan.sortedDays.reduce(into: Set<Weekday>()) { $0.formUnion($1.weekdays) }
        let free = Weekday.allCases.first { !taken.contains($0) }
        addDay(name: String(localized: "Nova variação"), weekdays: free.map { [$0] } ?? [])
    }

    private func reactivate() {
        do { try NutritionStore(context: context).switchActive(to: plan) } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }

    private func duplicateAndEdit() {
        do {
            let copy = try NutritionStore(context: context).duplicate(plan)
            onSwitch(copy) // abre a cópia (editável) no próprio editor
        } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }
}

private struct DayVariantRow: View {
    let day: NutritionDay

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            Text(day.name.isEmpty ? String(localized: "Variação") : day.name).font(FJFont.body)
            Text(summary).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let days = day.appliesToAllDays ? String(localized: "Demais dias") : day.weekdays.sorted().map(\.shortName).joined(separator: ", ")
        let count = day.meals?.count ?? 0
        return "\(days) · \(count == 1 ? String(localized: "1 refeição") : String(localized: "\(count) refeições"))"
    }
}

/// Uma variação do plano: nome, dias da semana e refeições (com "Copiar de…").
struct DayVariantEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var day: NutritionDay
    let plan: NutritionPlan
    @State private var errorMessage: String?

    private func owner(of weekday: Weekday) -> NutritionDay? {
        plan.sortedDays.first { $0.id != day.id && $0.weekdays.contains(weekday) }
    }

    /// Outra variação já vale para "demais dias" e esta também (sem dias marcados).
    private var hasFallbackConflict: Bool {
        day.appliesToAllDays && plan.sortedDays.contains { $0.id != day.id && $0.appliesToAllDays }
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    FJBanner("Não foi possível concluir", message: LocalizedStringKey(errorMessage), tone: .destructive,
                             actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section("Variação") {
                TextField("Nome (ex.: Dia de treino)", text: $day.name)
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: FJSpacing.s)], alignment: .leading, spacing: FJSpacing.s) {
                    ForEach(Weekday.displayOrder, id: \.self) { weekday in
                        let taken = owner(of: weekday)
                        FJFilterChip(LocalizedStringKey(weekday.shortName), isSelected: day.weekdays.contains(weekday), area: .nutrition) {
                            var set = day.weekdays
                            if set.contains(weekday) { set.remove(weekday) } else { set.insert(weekday) }
                            day.weekdays = set
                        }
                        .disabled(taken != nil)
                        .opacity(taken != nil ? 0.4 : 1)
                        .accessibilityHint(taken.map { Text("Já usado por \($0.name)") } ?? Text(""))
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if hasFallbackConflict {
                    FJBanner("Já existe uma variação para os demais dias",
                             message: "Marque ao menos um dia aqui, ou esta variação não será usada.",
                             tone: .attention, systemImage: "exclamationmark.triangle")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Dias da semana")
            } footer: {
                Text("Sem dias marcados = vale para os dias que nenhuma outra variação cobre.")
            }
            MealsSection(day: day)
            let others = plan.sortedDays.filter { $0.id != day.id && !($0.meals ?? []).isEmpty }
            if !others.isEmpty {
                Section {
                    Menu("Copiar refeições de…", systemImage: "doc.on.doc") {
                        ForEach(others) { other in
                            Button(other.name.isEmpty ? String(localized: "Variação") : other.name) { copy(from: other) }
                        }
                    }
                } footer: {
                    Text("Adiciona uma cópia das refeições escolhidas a esta variação.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle(day.name.isEmpty ? String(localized: "Variação") : day.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copy(from other: NutritionDay) {
        let store = NutritionStore(context: context)
        for meal in other.sortedMeals { store.copyMeal(meal, into: day, name: meal.name) }
        do { try context.commitEdits() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
    }
}

#Preview("Editor de plano") {
    let container = PersistenceController.preview
    let plan = try? container.mainContext.fetch(FetchDescriptor<NutritionPlan>()).first
    return NavigationStack {
        if let plan { PlanEditorView(plan: plan) }
    }
    .modelContainer(container)
}
