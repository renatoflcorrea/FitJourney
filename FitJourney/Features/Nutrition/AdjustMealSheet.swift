import SwiftData
import SwiftUI

/// "Ajustar" refeição (DESIGN §4.9): comi/não comi por item, quantidade, trocar por substituição, adicionar item.
/// Salvar marca a refeição como "Feita com alteração".
struct AdjustMealSheet: View {
    @Environment(\.dismiss) private var dismiss

    let meal: Meal
    let onSave: ([AdjustDraftItem]) -> Void
    @State private var drafts: [AdjustDraftItem]

    init(meal: Meal, date: Date, existing: [FoodEntry], onSave: @escaping ([AdjustDraftItem]) -> Void) {
        self.meal = meal
        self.onSave = onSave
        _drafts = State(initialValue: AdjustDraftItem.drafts(for: meal, entries: existing))
    }

    private var canSave: Bool {
        drafts.contains { $0.included && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($drafts) { $item in
                        AdjustItemRow(item: $item)
                    }
                    .onDelete { offsets in
                        // Só itens adicionados somem; os do plano são desmarcados.
                        let removable = offsets.filter { drafts[$0].isAdded }
                        drafts.remove(atOffsets: IndexSet(removable))
                    }
                    Button("Adicionar item", systemImage: "plus") {
                        drafts.append(AdjustDraftItem(id: UUID(), name: "", quantity: 1, unit: .unit,
                                                      baseValues: NutrientValues(), baseQuantity: 1,
                                                      included: true, substitutions: [], isAdded: true))
                    }
                } footer: {
                    Text("Desmarque o que você não comeu. Para não registrar nada, use Pular.")
                }
                Section("Total desta refeição") {
                    let kcal = drafts.filter(\.included).compactMap(\.values.kcal).reduce(0, +)
                    LabeledContent("Calorias") { Text("\(FJFormat.number(kcal, maxFractionDigits: 0)) kcal").font(FJFont.numberBody) }
                }
            }
            .scrollContentBackground(.hidden)
            .fjScreenBackground()
            .navigationTitle(meal.name.isEmpty ? "Ajustar refeição" : "Ajustar \(meal.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                FJPrimaryButton("Salvar ajuste", area: .nutrition) {
                    onSave(drafts.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
                    dismiss()
                }
                .disabled(!canSave)
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.bottom, FJSpacing.s)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AdjustItemRow: View {
    @Binding var item: AdjustDraftItem

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            if item.isAdded {
                TextField("Alimento", text: $item.name)
                    .font(FJFont.body)
                    .textInputAutocapitalization(.sentences)
            } else {
                Toggle(isOn: $item.included) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).font(FJFont.body)
                        if item.included, let kcal = NutritionFormat.kcal(item.values.kcal) {
                            Text(kcal).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                }
                .tint(FJColor.nutritionFill)
                .accessibilityLabel(Text("\(item.name), \(item.included ? "comi" : "não comi")"))
            }
            if item.included {
                NumberStepperField("Quantidade", value: $item.quantity, unit: item.unit.symbol,
                                   step: item.unit.stepperStep, range: 0...9_999, fractionDigits: 1)
                if item.isAdded {
                    FoodUnitPicker(unit: $item.unit)
                    OptionalDoubleField("Calorias", value: Binding(
                        get: { item.values.kcal },
                        set: { item.baseValues.kcal = $0; item.baseQuantity = item.quantity }
                    ), unit: "kcal")
                }
                if !item.substitutions.isEmpty {
                    Menu {
                        ForEach(item.substitutions) { sub in
                            Button("\(sub.name) · \(NutritionFormat.quantity(sub.quantity, sub.unit))") { item.apply(sub) }
                        }
                    } label: {
                        Label("Trocar por…", systemImage: "arrow.left.arrow.right")
                            .font(FJFont.label)
                            .frame(minHeight: FJSize.minTap, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, FJSpacing.xs)
    }
}

#Preview("Ajustar refeição") {
    let container = PersistenceController.preview
    let meal = (try? container.mainContext.fetch(FetchDescriptor<Meal>()).first { $0.name == "Almoço" }) ?? nil
    return Group {
        if let meal {
            AdjustMealSheet(meal: meal, date: .now, existing: []) { _ in }
        }
    }
    .modelContainer(container)
}
