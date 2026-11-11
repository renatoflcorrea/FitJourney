import SwiftUI

/// Campo numérico com − / + grandes para carga, tempo e lastro.
///
/// Contrato:
/// - Os botões saltam para o múltiplo de `step` mais próximo na direção do toque; segurar repete.
///   Para carga use `step: 0.5` (padrão do app, configurável em Ajustes) e `fractionDigits: 2`.
/// - Tocar no número abre o teclado. O campo traz o próprio botão **OK** na barra do teclado
///   (fecha e confirma); a tela não precisa adicionar outro. Em sheet, o campo precisa estar
///   dentro de um `NavigationStack` para a barra do teclado aparecer.
/// - Aceita vírgula ou ponto como separador decimal em qualquer locale ("32.5" e "32,5" valem 32,5).
///   Não há separador de milhar. Com `showsSign`, aceita "+" ou "−" na frente; texto incompleto
///   ("", "-", ",") não altera o valor e é descartado ao fechar o teclado.
/// - O valor entregue ao binding é sempre arredondado a `fractionDigits` casas e limitado a `range`.
/// - Em tamanhos de acessibilidade do Dynamic Type o campo empilha: rótulo (sem truncar), valor, botões.
struct NumberStepperField: View {
    private let label: LocalizedStringKey
    @Binding private var value: Double
    private let unit: String?
    private let step: Double
    private let range: ClosedRange<Double>
    private let fractionDigits: Int
    private let showsSign: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var upTicks = 0
    @State private var downTicks = 0

    init(
        _ label: LocalizedStringKey,
        value: Binding<Double>,
        unit: String? = nil,
        step: Double = 1,
        range: ClosedRange<Double> = 0...999,
        fractionDigits: Int = 0,
        showsSign: Bool = false
    ) {
        self.label = label
        self._value = value
        self.unit = unit
        self.step = step
        self.range = range
        self.fractionDigits = max(0, fractionDigits)
        self.showsSign = showsSign
    }

    // MARK: Regras puras

    /// Interpreta o texto digitado. `nil` = incompleto ou inválido.
    static func parse(_ text: String, allowsSign: Bool) -> Double? {
        var digits = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        var sign = 1.0
        if let first = digits.first, first == "-" || first == "+" {
            guard allowsSign else { return nil }
            if first == "-" { sign = -1 }
            digits.removeFirst()
        }
        guard
            digits.contains(where: \.isNumber),
            digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            digits.filter({ $0 == "." }).count <= 1,
            let magnitude = Double(digits)
        else { return nil }
        return sign * magnitude
    }

    /// Arredonda a `fractionDigits` casas e limita a `range`.
    static func normalize(_ value: Double, fractionDigits: Int, range: ClosedRange<Double>) -> Double {
        let scale = pow(10, Double(max(0, fractionDigits)))
        return ((value * scale).rounded() / scale).fjClamped(to: range)
    }

    private func normalized(_ raw: Double) -> Double {
        Self.normalize(raw, fractionDigits: fractionDigits, range: range)
    }

    private var format: FloatingPointFormatStyle<Double> {
        let base = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...fractionDigits))
            .grouping(.never)
        return showsSign ? base.sign(strategy: .always(includingZero: false)) : base
    }

    private var formatted: String { value.formatted(format) }

    private var spokenValue: String {
        [formatted, unit].compactMap(\.self).joined(separator: " ")
    }

    // MARK: Corpo

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: FJSpacing.s) {
                    labelText
                    valueField
                    HStack(spacing: FJSpacing.l) {
                        minusButton
                        plusButton
                    }
                }
            } else {
                VStack(spacing: FJSpacing.xs) {
                    labelText.lineLimit(1)
                    HStack(spacing: FJSpacing.s) {
                        minusButton
                        valueField
                        plusButton
                    }
                }
            }
        }
        .onAppear { text = formatted }
        .onChange(of: text) { _, newText in
            guard isFocused, let parsed = Self.parse(newText, allowsSign: showsSign) else { return }
            let next = normalized(parsed)
            if next != value { value = next }
        }
        .onChange(of: value) { _, newValue in
            let next = normalized(newValue)
            if next != newValue { value = next }
            if !isFocused { text = next.formatted(format) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { text = formatted }
        }
        .fjKeyboardDone($isFocused)
        .fjHaptic(.stepUp, trigger: upTicks)
        .fjHaptic(.stepDown, trigger: downTicks)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: spokenValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepValue(up: true)
            case .decrement: stepValue(up: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Digitar valor")) { isFocused = true }
    }

    private var labelText: some View {
        Text(label)
            .font(FJFont.caption)
            .foregroundStyle(FJColor.textSecondary)
            .multilineTextAlignment(.center)
    }

    private var valueField: some View {
        VStack(spacing: 0) {
            TextField("0", text: $text)
                .font(FJFont.numberLarge)
                .foregroundStyle(FJColor.textPrimary)
                .multilineTextAlignment(.center)
                .keyboardType(showsSign ? .numbersAndPunctuation : (fractionDigits > 0 ? .decimalPad : .numberPad))
                .autocorrectionDisabled()
                .focused($isFocused)
                .minimumScaleFactor(0.6)
                .frame(minWidth: 56, minHeight: FJSize.minTap)
            if let unit {
                Text(verbatim: unit)
                    .font(FJFont.unit)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var minusButton: some View {
        stepButton(systemImage: "minus", enabled: value > range.lowerBound) { stepValue(up: false) }
    }

    private var plusButton: some View {
        stepButton(systemImage: "plus", enabled: value < range.upperBound) { stepValue(up: true) }
    }

    private func stepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(enabled ? FJColor.textPrimary : FJColor.textTertiary)
                .frame(width: FJSize.stepperButton, height: FJSize.stepperButton)
                .background(FJColor.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
    }

    private func stepValue(up: Bool) {
        guard step > 0 else { return }
        let ratio = (value / step * 1000).rounded() / 1000
        let raw = up ? (ratio.rounded(.down) + 1) * step : (ratio.rounded(.up) - 1) * step
        let next = normalized(raw)
        guard next != value else { return }
        value = next
        text = next.formatted(format)
        if up { upTicks += 1 } else { downTicks += 1 }
    }
}

/// Campo numérico opcional e discreto (reps realizadas): vazio mostra o convite ("+ reps");
/// tocar abre o teclado numérico com OK. `nil` = não informado (a série vale "dentro do alvo").
struct FJOptionalNumberField: View {
    private let label: LocalizedStringKey
    private let prompt: LocalizedStringKey
    @Binding private var value: Int?
    private let unit: String?
    private let range: ClosedRange<Int>

    @FocusState private var isFocused: Bool
    @State private var text = ""

    /// - Parameters:
    ///   - label: rótulo de acessibilidade ("Repetições realizadas").
    ///   - prompt: convite quando vazio ("+ reps").
    init(
        _ label: LocalizedStringKey,
        prompt: LocalizedStringKey,
        value: Binding<Int?>,
        unit: String? = nil,
        range: ClosedRange<Int> = 0...999
    ) {
        self.label = label
        self.prompt = prompt
        self._value = value
        self.unit = unit
        self.range = range
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(FJColor.textSecondary))
                .font(value == nil && !isFocused ? .subheadline.weight(.medium) : FJFont.numberBody.weight(.semibold))
                .foregroundStyle(FJColor.textPrimary)
                .keyboardType(.numberPad)
                .multilineTextAlignment(value == nil && !isFocused ? .center : .trailing)
                .focused($isFocused)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 28)
            if let unit, value != nil || isFocused {
                Text(verbatim: unit)
                    .font(FJFont.unit)
                    .foregroundStyle(FJColor.textSecondary)
            }
            if value != nil {
                Button {
                    value = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FJColor.textTertiary)
                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -FJSpacing.m)
                .accessibilityLabel(Text("Limpar"))
            }
        }
        .padding(.horizontal, FJSpacing.m)
        .frame(minHeight: FJSize.minTap)
        .background(FJColor.fill, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .onAppear { text = value.map(String.init) ?? "" }
        .onChange(of: text) { _, newText in
            let digits = newText.filter(\.isNumber)
            if digits != newText { text = digits }
            let next = Int(digits).map { $0.fjClamped(to: range) }
            if next != value { value = next }
        }
        .onChange(of: value) { _, newValue in
            let shown = newValue.map(String.init) ?? ""
            if shown != text, !(isFocused && newValue == Int(text)) { text = shown }
        }
        .fjKeyboardDone($isFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.map { Text(verbatim: [String($0), unit].compactMap(\.self).joined(separator: " ")) } ?? Text("Não informado"))
    }
}

extension View {
    /// Botão "OK" na barra do teclado, só enquanto este campo tem o foco (evita botões duplicados
    /// quando há vários campos na tela).
    func fjKeyboardDone(_ isFocused: FocusState<Bool>.Binding) -> some View {
        toolbar {
            if isFocused.wrappedValue {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") { isFocused.wrappedValue = false }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview("NumberStepperField") {
    @Previewable @State var load = 32.5
    @Previewable @State var reps: Int? = nil
    @Previewable @State var ballast = -20.0
    @Previewable @State var hold = 45.0

    return NavigationStack {
        ScrollView {
            VStack(spacing: FJSpacing.cardGap) {
                FJCard {
                    VStack(spacing: FJSpacing.m) {
                        NumberStepperField("Carga", value: $load, unit: "kg", step: 0.5, range: 0...500, fractionDigits: 2)
                        FJOptionalNumberField("Repetições realizadas", prompt: "+ reps", value: $reps, unit: "reps")
                    }
                }
                FJCard {
                    NumberStepperField("Peso corporal ±", value: $ballast, unit: "kg", step: 0.5, range: -200...200, fractionDigits: 1, showsSign: true)
                }
                FJCard {
                    NumberStepperField("Sustentação", value: $hold, unit: "s", step: 5, range: 0...600)
                }
            }
            .padding(FJSpacing.screenMargin)
        }
        .fjScreenBackground()
    }
}
