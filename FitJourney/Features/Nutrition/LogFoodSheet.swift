import SwiftData
import SwiftUI

/// "Registrar comida" (SPEC §5.2): registro avulso, também usado para editar/apagar uma entrada.
struct LogFoodSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let day: Date
    let editing: FoodEntry?

    @State private var name = ""
    @State private var quantity: Double = 100
    @State private var unit: FoodUnit = .grams
    @State private var time = Date.now
    @State private var values = NutrientValues()
    @State private var estimation: EstimationSource = .informed
    @State private var mealID: UUID?
    @State private var notes = ""
    @State private var suggestions: [FoodItem] = []
    @State private var meals: [Meal] = []
    @State private var hasPlan = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @FocusState private var nameFocused: Bool

    init(day: Date, editing: FoodEntry? = nil) {
        self.day = day
        self.editing = editing
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredSuggestions: [FoodItem] {
        let query = trimmedName
        let list = query.isEmpty ? suggestions : suggestions.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                && $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        return Array(list.prefix(8))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("O que você comeu?", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                }
                if !filteredSuggestions.isEmpty {
                    Section("Recentes e favoritos") {
                        ForEach(filteredSuggestions) { food in
                            Button { fill(from: food) } label: {
                                HStack {
                                    if food.isFavorite {
                                        Image(systemName: "star.fill").foregroundStyle(FJColor.nutrition)
                                            .accessibilityLabel("Favorito")
                                    }
                                    Text(food.name).foregroundStyle(FJColor.textPrimary)
                                    Spacer()
                                    Text(NutritionFormat.quantity(food.servingQuantity, food.unit))
                                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    NumberStepperField("Quantidade", value: $quantity, unit: unit.symbol, step: unit.stepperStep,
                                       range: 0...9_999, fractionDigits: 1)
                    FoodUnitPicker(unit: $unit)
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                }
                Section {
                    DisclosureGroup("Calorias e macros (opcional)") {
                        NutrientFields(values: $values)
                    }
                    Picker("Grau de estimativa", selection: $estimation) {
                        Text("Informado").tag(EstimationSource.informed)
                        Text("Estimado").tag(EstimationSource.estimated)
                        if estimation == .ai { Text("IA").tag(EstimationSource.ai) }
                    }
                    .pickerStyle(.segmented)
                }
                if !meals.isEmpty {
                    Section {
                        Picker("Vincular a uma refeição", selection: $mealID) {
                            Text(hasPlan ? "Nenhuma — fora da dieta" : "Nenhuma").tag(UUID?.none)
                            ForEach(meals) { meal in
                                Text("\(NutritionFormat.clock(minutes: meal.minutesFromMidnight)) · \(meal.name)").tag(UUID?.some(meal.id))
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section { FJBanner("Não foi possível salvar", message: LocalizedStringKey(errorMessage), tone: .destructive) }
                }
                if editing != nil {
                    Section {
                        Button("Apagar registro", role: .destructive) { showDeleteConfirm = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .fjScreenBackground()
            .navigationTitle(editing == nil ? "Registrar comida" : "Editar registro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                FJPrimaryButton(editing == nil ? "Registrar" : "Salvar", area: .nutrition, action: save)
                    .disabled(trimmedName.isEmpty)
                    .padding(.horizontal, FJSpacing.screenMargin)
                    .padding(.bottom, FJSpacing.s)
            }
            .confirmationDialog("Apagar este registro?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Apagar", role: .destructive, action: deleteEntry)
            }
            .task { load() }
        }
    }

    // MARK: Ações

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let store = NutritionStore(context: context)
        let recents = (try? store.recentFoods(limit: 20)) ?? []
        let favorites = (try? store.favoriteFoods()) ?? []
        var seen = Set<UUID>()
        suggestions = (favorites + recents).filter { seen.insert($0.id).inserted }
        let plan = try? store.activePlan()
        hasPlan = plan != nil
        meals = plan?.day(for: day)?.sortedMeals ?? []

        if let entry = editing {
            name = entry.name
            quantity = entry.quantity
            unit = entry.unit
            time = entry.date
            values = entry.values
            estimation = entry.estimation
            mealID = entry.mealID
            notes = entry.notes
            if let id = entry.mealID, !meals.contains(where: { $0.id == id }) { mealID = nil }
        } else {
            time = Self.defaultTime(for: day)
            nameFocused = true
        }
    }

    /// Hoje: agora. Outro dia: meio-dia daquele dia (editável).
    private static func defaultTime(for day: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.isDate(day, inSameDayAs: now) ? now
            : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day)
    }

    private func fill(from food: FoodItem) {
        name = food.name
        quantity = food.servingQuantity
        unit = food.unit
        values = food.values
        estimation = food.estimation
    }

    /// Mantém a data do dia exibido e usa só hora/minuto do seletor.
    private var entryDate: Date {
        let calendar = Calendar.current
        if let editing, calendar.isDate(time, inSameDayAs: editing.date) { return time }
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 12, minute: parts.minute ?? 0, second: 0, of: day) ?? time
    }

    private func save() {
        let store = NutritionStore(context: context)
        let meal = meals.first { $0.id == mealID }
        do {
            if let editing {
                try store.update(editing, name: trimmedName, quantity: quantity, unit: unit, values: values,
                                 estimation: estimation, at: entryDate, meal: meal, notes: notes)
            } else {
                try store.logFood(name: trimmedName, quantity: quantity, unit: unit, values: values,
                                  estimation: estimation, at: entryDate, meal: meal, notes: notes)
            }
            dismiss()
        } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }

    private func deleteEntry() {
        guard let editing else { return }
        do {
            try NutritionStore(context: context).delete(editing)
            dismiss()
        } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }
}

#Preview("Registrar comida") {
    LogFoodSheet(day: .now)
        .modelContainer(PersistenceController.preview)
}
