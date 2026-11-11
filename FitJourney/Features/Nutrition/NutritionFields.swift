import SwiftData
import SwiftUI

// Campos de formulário compartilhados pelos editores da dieta.

/// Número opcional ("vazio = sem valor"). Aceita "2.600", "1.234,5", "12,5"; texto inválido mostra erro
/// inline e mantém o valor anterior (nunca zera). `zeroIsNil`: 0 = sem meta.
struct OptionalDoubleField: View {
    private let title: LocalizedStringKey
    @Binding private var value: Double?
    private let unit: String?
    private let field: NutritionInput.Field
    private let zeroIsNil: Bool
    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    init(_ title: LocalizedStringKey, value: Binding<Double?>, unit: String? = nil,
         field: NutritionInput.Field = .grams, zeroIsNil: Bool = false) {
        self.title = title
        self._value = value
        self.unit = unit
        self.field = field
        self.zeroIsNil = zeroIsNil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
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
            if isInvalid {
                Label("Valor inválido. Máximo \(FJFormat.number(field.maximum, maxFractionDigits: 0)).",
                      systemImage: "exclamationmark.circle")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.destructive)
            }
        }
        .onAppear { text = NutritionInput.format(value) }
        .onChange(of: text) { _, new in
            guard isFocused else { return } // só edição do usuário altera o valor
            switch NutritionInput.parse(new, field: field) {
            case .empty:
                isInvalid = false
                value = nil
            case .value(let number):
                isInvalid = false
                value = (zeroIsNil && number == 0) ? nil : number
            case .invalid:
                isInvalid = true // mantém o valor anterior
            }
        }
        .onChange(of: isFocused) { _, focused in
            // Ao sair do campo, volta ao último valor válido.
            if !focused {
                isInvalid = false
                text = NutritionInput.format(value)
            }
        }
        .onChange(of: value) { _, new in if !isFocused { text = NutritionInput.format(new) } }
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
        OptionalDoubleField("Calorias", value: $values.kcal, unit: "kcal", field: .kcal)
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

extension ModelContext {
    /// Salva só no contexto principal (autosave ligado). Contextos de rascunho (autosave desligado,
    /// ex.: "Novo plano") só persistem quando quem os criou confirma.
    func commitEdits() throws {
        if autosaveEnabled { try save() }
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
