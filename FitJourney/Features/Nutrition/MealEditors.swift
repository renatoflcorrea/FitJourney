import SwiftData
import SwiftUI

/// Seção "Refeições" de um dia do plano: lista por horário, adicionar, duplicar, excluir.
struct MealsSection: View {
    @Environment(\.modelContext) private var context
    let day: NutritionDay
    @State private var newMeal: Meal?
    @State private var mealToDelete: Meal?
    @State private var errorMessage: String?
    @Environment(\.mealReminderScheduler) private var scheduler

    var body: some View {
        Section {
            if let errorMessage {
                FJBanner("Não foi possível concluir", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
            }
            if day.sortedMeals.isEmpty {
                FJEmptyState("Adicione a primeira refeição", systemImage: "fork.knife",
                             message: "Café da manhã, almoço, lanche… com horário e itens.",
                             actionTitle: "Adicionar refeição", area: .nutrition, action: addMeal)
            } else {
                ForEach(day.sortedMeals) { meal in
                    NavigationLink { MealEditorView(meal: meal) } label: { MealRow(meal: meal) }
                        .swipeActions(edge: .trailing) {
                            Button("Excluir", systemImage: "trash", role: .destructive) { mealToDelete = meal }
                            Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(meal) }.tint(FJColor.coachFill)
                        }
                        .contextMenu {
                            Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(meal) }
                            Button("Excluir", systemImage: "trash", role: .destructive) { mealToDelete = meal }
                        }
                }
                Button("Adicionar refeição", systemImage: "plus", action: addMeal)
            }
        } header: {
            Text("Refeições")
        } footer: {
            if !day.sortedMeals.isEmpty { Text("Ordenadas por horário. Para mudar a ordem, altere o horário.") }
        }
        .sheet(item: $newMeal) { meal in
            EditorSheet(title: "Nova refeição", confirmTitle: "Adicionar",
                        canConfirm: !meal.name.trimmingCharacters(in: .whitespaces).isEmpty,
                        onCancel: { discard(meal) }, onConfirm: { confirm(meal) }) {
                MealEditorView(meal: meal)
            }
            .interactiveDismissDisabled()
        }
        .confirmationDialog("Excluir esta refeição?", isPresented: Binding(get: { mealToDelete != nil },
                                                                          set: { if !$0 { mealToDelete = nil } }),
                            titleVisibility: .visible, presenting: mealToDelete) { meal in
            Button("Excluir \(meal.name)", role: .destructive) { context.delete(meal); commit() }
        } message: { _ in Text("Os itens dela serão apagados.") }
    }

    private func addMeal() {
        let last = day.sortedMeals.last?.minutesFromMidnight
        let minutes = min(1_380, (last ?? 6 * 60 + 30) + (last == nil ? 0 : 180))
        let next = ((day.meals ?? []).map(\.sortIndex).max() ?? -1) + 1
        let meal = Meal(name: "", minutesFromMidnight: minutes, sortIndex: next)
        context.insert(meal)
        meal.day = day
        newMeal = meal
    }

    private func commit() {
        do { try context.commitEdits() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
        if context.autosaveEnabled { Task { await scheduler.reschedule(for: context) } }
    }

    private func discard(_ meal: Meal) {
        context.delete(meal)
        commit()
        newMeal = nil
    }

    private func confirm(_ meal: Meal) {
        meal.name = meal.name.trimmingCharacters(in: .whitespaces)
        commit()
        newMeal = nil
    }

    private func duplicate(_ meal: Meal) {
        NutritionStore(context: context).copyMeal(meal, into: day, name: String(localized: "\(meal.name) (cópia)"))
        commit()
    }
}

private struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.m) {
            Text(NutritionFormat.clock(minutes: meal.minutesFromMidnight))
                .font(FJFont.numberBody)
                .foregroundStyle(FJColor.textSecondary)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                HStack(spacing: FJSpacing.xs) {
                    Text(meal.name.isEmpty ? String(localized: "Refeição sem nome") : meal.name).font(FJFont.body)
                    if meal.reminderEnabled {
                        Image(systemName: "bell.fill").font(.caption).foregroundStyle(FJColor.textSecondary)
                            .accessibilityLabel("Com lembrete")
                    }
                }
                let summary = meal.plannedKcalSummary
                let count = summary.itemCount
                Text([count == 1 ? String(localized: "1 item") : String(localized: "\(count) itens"),
                      NutritionFormat.kcal(summary)]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Refeição: nome, horário, lembrete e itens (arrastar reordena).
struct MealEditorView: View {
    static let nameSuggestions = ["Café da manhã", "Lanche da manhã", "Almoço", "Lanche da tarde", "Pré-treino", "Jantar", "Ceia"]

    @Environment(\.modelContext) private var context
    @Bindable var meal: Meal
    @State private var newItem: MealItem?
    @State private var errorMessage: String?
    @Environment(\.mealReminderScheduler) private var scheduler
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization: RestNotificationAuthorization = .authorized
    @State private var showReminderExplanation = false

    /// Ligar o primeiro lembrete explica e só então pede a permissão (contextual).
    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { meal.reminderEnabled },
            set: { on in
                if on && authorization == .notDetermined { showReminderExplanation = true } else { meal.reminderEnabled = on }
            }
        )
    }

    private var time: Binding<Date> {
        Binding(
            get: { meal.time(on: .now) },
            set: {
                let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: $0)
                meal.minutesFromMidnight = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
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
            Section {
                TextField("Nome", text: $meal.name)
                    .textInputAutocapitalization(.sentences)
                Menu("Sugestões de nome", systemImage: "text.badge.plus") {
                    ForEach(Self.nameSuggestions, id: \.self) { name in
                        Button(name) { meal.name = name }
                    }
                }
                DatePicker("Horário", selection: time, displayedComponents: .hourAndMinute)
                Toggle("Lembrete", isOn: reminderBinding)
                    .tint(FJColor.nutritionFill)
                if meal.reminderEnabled && authorization == .denied { NotificationsDisabledBanner() }
            } footer: {
                Text("Avisa no horário da refeição, com a ação \"Marcar como feita\" na própria notificação.")
            }
            Section {
                let items = meal.sortedItems
                ForEach(items) { item in
                    NavigationLink { ItemEditorView(item: item) } label: { ItemRow(item: item) }
                        .contextMenu {
                            Button("Excluir", systemImage: "trash", role: .destructive) { delete(item) }
                        }
                }
                .onMove { source, destination in move(items, from: source, to: destination) }
                .onDelete { offsets in offsets.map { items[$0] }.forEach(delete) }
                Button("Adicionar item", systemImage: "plus", action: addItem)
            } header: {
                Text("Itens")
            } footer: {
                if meal.sortedItems.isEmpty { Text("Sem itens, a refeição não pode ser marcada como feita com 1 toque.") }
            }
            Section("Observação") {
                TextField("Opcional", text: $meal.notes, axis: .vertical)
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle(meal.name.isEmpty ? String(localized: "Refeição") : meal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .task { authorization = await scheduler.authorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { authorization = await scheduler.authorization() } }
        }
        .alert("Receber lembrete desta refeição?", isPresented: $showReminderExplanation) {
            Button("Permitir notificações") {
                meal.reminderEnabled = true
                Task {
                    _ = await scheduler.requestAuthorization()
                    authorization = await scheduler.authorization()
                }
            }
            Button("Agora não", role: .cancel) {}
        } message: {
            Text("O FitJourney avisa no horário da refeição. O iOS vai pedir sua permissão agora; você pode mudar depois em Ajustes.")
        }
        .onDisappear { if context.autosaveEnabled { Task { await scheduler.reschedule(for: context) } } }
        .sheet(item: $newItem) { item in
            EditorSheet(title: "Novo item", confirmTitle: "Adicionar",
                        canConfirm: !item.name.trimmingCharacters(in: .whitespaces).isEmpty && item.quantity > 0,
                        onCancel: { context.delete(item); commit(); newItem = nil },
                        onConfirm: { commit(); newItem = nil }) {
                ItemEditorView(item: item)
            }
            .interactiveDismissDisabled()
        }
    }

    private func addItem() {
        let next = ((meal.items ?? []).map(\.sortIndex).max() ?? -1) + 1
        let item = MealItem(name: "", quantity: 100, unit: .grams, sortIndex: next)
        context.insert(item)
        item.meal = meal
        newItem = item
    }

    private func commit() {
        do { try context.commitEdits() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
    }

    private func delete(_ item: MealItem) {
        context.delete(item)
        commit()
    }

    private func move(_ items: [MealItem], from source: IndexSet, to destination: Int) {
        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() { item.sortIndex = index }
    }
}

private struct ItemRow: View {
    let item: MealItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name.isEmpty ? String(localized: "Item sem nome") : item.name).font(FJFont.body)
                Text(NutritionFormat.quantity(item.quantity, item.unit)).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            if !item.substitutions.isEmpty {
                Image(systemName: "arrow.left.arrow.right").font(.caption).foregroundStyle(FJColor.textSecondary)
                    .accessibilityLabel("Tem substituições")
            }
            Spacer(minLength: FJSpacing.s)
            if let kcal = NutritionFormat.kcal(item.kcal) {
                Text(kcal).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Item da refeição: alimento (com sugestões), quantidade, kcal/macros, observação e substituições.
struct ItemEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: MealItem
    @State private var suggestions: [FoodItem] = []
    @State private var editingSubstitution: UUID?

    var body: some View {
        Form {
            Section {
                TextField("Alimento", text: $item.name)
                    .textInputAutocapitalization(.sentences)
                if !suggestions.isEmpty {
                    Menu("Favoritos e recentes", systemImage: "star") {
                        ForEach(suggestions) { food in
                            Button("\(food.name) · \(NutritionFormat.quantity(food.servingQuantity, food.unit))") { fill(food) }
                        }
                    }
                }
                NumberStepperField("Quantidade", value: $item.quantity, unit: item.unit.symbol,
                                   step: item.unit.stepperStep, range: 0...9_999, fractionDigits: 1)
                FoodUnitPicker(unit: $item.unit)
            }
            Section {
                NutrientFields(values: $item.values)
            } header: {
                Text("Calorias e macros (opcional)")
            } footer: {
                Text("Valores para a quantidade acima.")
            }
            Section("Observação") {
                TextField("Opcional", text: $item.notes, axis: .vertical)
            }
            Section {
                ForEach($item.substitutions) { $sub in
                    Button { editingSubstitution = sub.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sub.name.isEmpty ? String(localized: "Substituição sem nome") : sub.name)
                                    .foregroundStyle(FJColor.textPrimary)
                                Text(NutritionFormat.quantity(sub.quantity, sub.unit)).font(FJFont.caption)
                                    .foregroundStyle(FJColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(FJColor.textTertiary)
                        }
                    }
                }
                .onDelete { item.substitutions.remove(atOffsets: $0) }
                Button("Adicionar substituição", systemImage: "plus") {
                    let sub = MealSubstitution(name: "", quantity: item.quantity, unit: item.unit)
                    item.substitutions.append(sub)
                    editingSubstitution = sub.id
                }
            } header: {
                Text("Substituições")
            } footer: {
                Text("Alternativas equivalentes, oferecidas em Ajustar.")
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle(item.name.isEmpty ? String(localized: "Item") : item.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: editingSubstitution) { _, new in
            // Ao sair da edição, substituição sem nome não é salva.
            if new == nil { item.substitutions.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
        }
        .navigationDestination(item: $editingSubstitution) { id in
            if let index = item.substitutions.firstIndex(where: { $0.id == id }) {
                SubstitutionEditor(substitution: $item.substitutions[index])
            }
        }
        .task {
            let store = NutritionStore(context: context)
            var seen = Set<UUID>()
            suggestions = (((try? store.favoriteFoods()) ?? []) + ((try? store.recentFoods(limit: 10)) ?? []))
                .filter { seen.insert($0.id).inserted }
        }
    }

    private func fill(_ food: FoodItem) {
        item.name = food.name
        item.quantity = food.servingQuantity
        item.unit = food.unit
        item.values = food.values
    }
}

struct SubstitutionEditor: View {
    @Binding var substitution: MealSubstitution

    var body: some View {
        Form {
            Section {
                TextField("Alimento", text: $substitution.name)
                    .textInputAutocapitalization(.sentences)
                NumberStepperField("Quantidade", value: $substitution.quantity, unit: substitution.unit.symbol,
                                   step: substitution.unit.stepperStep, range: 0...9_999, fractionDigits: 1)
                FoodUnitPicker(unit: $substitution.unit)
            }
            Section("Calorias e macros (opcional)") {
                NutrientFields(values: $substitution.values)
            }
            Section("Observação") {
                TextField("Opcional", text: $substitution.notes, axis: .vertical)
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle(substitution.name.isEmpty ? String(localized: "Substituição") : substitution.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
