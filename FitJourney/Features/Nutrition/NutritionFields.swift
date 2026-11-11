import SwiftUI

// Campos de formulário compartilhados pelos editores da dieta.

/// Número opcional ("vazio = sem valor"), com vírgula ou ponto decimal.
struct OptionalDoubleField: View {
    private let title: LocalizedStringKey
    @Binding private var value: Double?
    private let unit: String?
    @State private var text = ""
    @FocusState private var isFocused: Bool

    init(_ title: LocalizedStringKey, value: Binding<Double?>, unit: String? = nil) {
        self.title = title
        self._value = value
        self.unit = unit
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: FJSpacing.xs) {
                TextField("", text: $text, prompt: Text("—"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(FJFont.numberBody)
                    .focused($isFocused)
                    .fjKeyboardDone($isFocused)
                if let unit {
                    Text(unit).font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                }
            }
        } label: {
            Text(title)
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: text) { _, new in
            let trimmed = new.trimmingCharacters(in: .whitespaces)
            value = trimmed.isEmpty ? nil : NumberStepperField.parse(trimmed, allowsSign: false).map { max(0, $0) }
        }
        .onChange(of: value) { _, new in if !isFocused { text = Self.format(new) } }
        .accessibilityElement(children: .combine)
    }

    static func format(_ value: Double?) -> String {
        value.map { FJFormat.number($0, maxFractionDigits: 1) } ?? ""
    }
}

/// Seletor de unidade em menu.
struct FoodUnitPicker: View {
    @Binding var unit: FoodUnit

    var body: some View {
        Picker("Unidade", selection: $unit) {
            ForEach(FoodUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

/// kcal e macros opcionais (por porção/quantidade informada).
struct NutrientFields: View {
    @Binding var values: NutrientValues
    var includesFiber = true

    var body: some View {
        OptionalDoubleField("Calorias", value: $values.kcal, unit: "kcal")
        OptionalDoubleField("Proteína", value: $values.protein, unit: "g")
        OptionalDoubleField("Carboidrato", value: $values.carbs, unit: "g")
        OptionalDoubleField("Gordura", value: $values.fat, unit: "g")
        if includesFiber {
            OptionalDoubleField("Fibra", value: $values.fiber, unit: "g")
        }
    }
}

extension FoodUnit {
    /// Passo do stepper de quantidade para a unidade.
    var stepperStep: Double {
        switch self {
        case .grams, .milliliters: 10
        default: 1
        }
    }
}

/// Moldura de sheet de edição: título, Cancelar e confirmação.
struct EditorSheet<Content: View>: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    var canConfirm = true
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle, action: onConfirm).disabled(!canConfirm)
                    }
                }
        }
    }
}
