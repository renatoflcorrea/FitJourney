import SwiftUI

/// Campo numérico com − / + grandes para carga, reps, tempo e lastro. Toque no número abre o teclado;
/// segurar − / + repete. Os botões saltam para o múltiplo de `step` mais próximo na direção do toque.
struct NumberStepperField: View {
    private let label: LocalizedStringKey
    @Binding private var value: Double
    private let unit: String?
    private let step: Double
    private let range: ClosedRange<Double>
    private let fractionDigits: Int
    private let showsSign: Bool

    @FocusState private var isFocused: Bool
    @State private var upTicks = 0
    @State private var downTicks = 0

    /// - Parameters:
    ///   - step: incremento dos botões (ex.: 2,5 kg; 1 rep; 5 s).
    ///   - fractionDigits: casas decimais máximas exibidas e aceitas.
    ///   - showsSign: mostra "+"/"−" (peso corporal com lastro ou assistência).
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
        self.fractionDigits = fractionDigits
        self.showsSign = showsSign
    }

    private var format: FloatingPointFormatStyle<Double> {
        let base = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...max(0, fractionDigits)))
        return showsSign ? base.sign(strategy: .always(includingZero: false)) : base
    }

    private var spokenValue: String {
        [value.formatted(format), unit].compactMap(\.self).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: FJSpacing.xs) {
            Text(label)
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(1)

            HStack(spacing: FJSpacing.s) {
                stepButton(systemImage: "minus", enabled: value > range.lowerBound) { stepValue(up: false) }

                VStack(spacing: 0) {
                    TextField("0", value: $value, format: format)
                        .font(FJFont.numberLarge)
                        .foregroundStyle(FJColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .keyboardType(showsSign ? .numbersAndPunctuation : (fractionDigits > 0 ? .decimalPad : .numberPad))
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

                stepButton(systemImage: "plus", enabled: value < range.upperBound) { stepValue(up: true) }
            }
        }
        .onChange(of: value) { _, newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if clamped != newValue { value = clamped }
        }
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
        let next = up ? (ratio.rounded(.down) + 1) * step : (ratio.rounded(.up) - 1) * step
        let clamped = min(max((next * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        if up { upTicks += 1 } else { downTicks += 1 }
    }
}

#Preview("NumberStepperField") {
    @Previewable @State var load = 32.5
    @Previewable @State var reps = 10.0
    @Previewable @State var ballast = -20.0
    @Previewable @State var hold = 45.0

    return ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                HStack(spacing: FJSpacing.l) {
                    NumberStepperField("Carga", value: $load, unit: "kg", step: 2.5, range: 0...500, fractionDigits: 2)
                    NumberStepperField("Repetições", value: $reps, unit: "reps", range: 0...100)
                }
            }
            FJCard {
                NumberStepperField("Peso corporal ±", value: $ballast, unit: "kg", step: 2.5, range: -200...200, fractionDigits: 1, showsSign: true)
            }
            FJCard {
                NumberStepperField("Sustentação", value: $hold, unit: "s", step: 5, range: 0...600)
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
