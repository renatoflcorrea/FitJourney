import SwiftUI

// Campos reutilizáveis do editor de prescrição (modo em bloco e série a série compartilham `SetFields`).

// MARK: - Bindings auxiliares

private func optionalSecondsBinding(_ seconds: Binding<Int?>) -> Binding<Double> {
    Binding(get: { Double(seconds.wrappedValue ?? 0) }, set: { seconds.wrappedValue = Int($0.rounded()) })
}

// MARK: - Repetições

struct RepTargetField: View {
    @Binding var target: RepTarget?

    private enum Mode: Hashable { case fixed, range, amrap }

    private var mode: Mode {
        switch target {
        case .some(.range): .range
        case .some(.amrap): .amrap
        default: .fixed
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { new in
                guard new != mode else { return }
                let base = max(RepRangeEditing.minimumReps, target?.defaultReps ?? 10)
                switch new {
                case .fixed: target = .fixed(reps: base)
                case .range: target = .range(min: base, max: base + 4)
                case .amrap: target = .amrap
                }
            }
        )
    }

    private var low: Binding<Double> {
        Binding(
            get: { if case .range(let lo, _) = target { Double(lo) } else { 1 } },
            set: { if let t = target { target = RepRangeEditing.setLow(Int($0), of: t) } }
        )
    }

    private var high: Binding<Double> {
        Binding(
            get: { if case .range(_, let hi) = target { Double(hi) } else { 1 } },
            set: { if let t = target { target = RepRangeEditing.setHigh(Int($0), of: t) } }
        )
    }

    private var fixed: Binding<Double> {
        Binding(
            get: { if case .fixed(let n) = target { Double(n) } else { 1 } },
            set: { target = RepRangeEditing.setFixed(Int($0)) }
        )
    }

    var body: some View {
        Picker("Repetições", selection: modeBinding) {
            Text("Fixas").tag(Mode.fixed)
            Text("Faixa").tag(Mode.range)
            Text("AMRAP").tag(Mode.amrap)
        }
        .pickerStyle(.segmented)

        switch mode {
        case .fixed:
            NumberStepperField("Repetições", value: fixed, unit: "reps", range: 1...999)
        case .range:
            // Mexer no mínimo empurra o máximo (e vice-versa): a faixa nunca fica inválida.
            FJAdaptiveStack(spacing: FJSpacing.l, verticalAlignment: .top) {
                NumberStepperField("Mínimo (piso)", value: low, unit: "reps", range: 1...999)
                NumberStepperField("Máximo", value: high, unit: "reps", range: 1...999)
            }
        case .amrap:
            Text("Máximo possível")
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
        }
    }
}

// MARK: - Carga

struct LoadField: View {
    @Binding var load: Load?
    /// Carga atual divergente (R-T2), se houver.
    let divergentCurrent: Load?
    var allowsNone = true
    var perSide = false
    /// Última carga usada no exercício (histórico): valor inicial ao trocar para kg/lb ou peso corporal (P2.8).
    var lastKnown: Load? = nil
    let useCurrent: () -> Void

    @AppStorage(AppPreferenceKeys.loadStep) private var loadStep = 0.0
    @AppStorage(WeightUnitPreference.key) private var preferredUnitRaw = WeightUnit.kg.rawValue
    /// Último valor de cada modo, para não perder o número ao alternar (kg ↔ peso corporal ↔ sem carga).
    @State private var remembered: [Mode: Load] = [:]

    private enum Mode: Hashable { case none, weight, bodyweight }

    private var mode: Mode {
        switch load {
        case .none: .none
        case .some(.weight): .weight
        case .some(.bodyweight): .bodyweight
        }
    }

    private var preferredUnit: WeightUnit { WeightUnit(rawValue: preferredUnitRaw) ?? .kg }
    private var unit: WeightUnit { load?.unit ?? preferredUnit }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { new in
                guard new != mode else { return }
                if let load { remembered[mode] = load }
                switch new {
                case .none: load = nil
                case .weight: load = remembered[.weight] ?? known(.weight) ?? .weight(value: 0, unit: unit)
                case .bodyweight: load = remembered[.bodyweight] ?? known(.bodyweight) ?? .bodyweight(delta: 0, unit: unit)
                }
            }
        )
    }

    /// A última carga conhecida, se for do modo pedido (peso 0 não conta).
    private func known(_ mode: Mode) -> Load? {
        switch Load.defined(lastKnown) {
        case .some(let load) where mode == .weight && !load.isBodyweight: load
        case .some(let load) where mode == .bodyweight && load.isBodyweight: load
        default: nil
        }
    }

    /// Troca kg/lb convertendo o valor (arredondado a 0,1).
    private var unitBinding: Binding<WeightUnit> {
        Binding(
            get: { unit },
            set: { new in
                let old = unit
                guard new != old else { return }
                func convert(_ v: Double) -> Double {
                    ((new.fromKilograms(old.toKilograms(v))) * 10).rounded() / 10
                }
                switch load {
                case .some(.weight(let v, _)): load = .weight(value: convert(v), unit: new)
                case .some(.bodyweight(let d, _)): load = .bodyweight(delta: convert(d), unit: new)
                case .none: break
                }
                remembered = [:]
            }
        )
    }

    private var weightValue: Binding<Double> {
        Binding(
            get: { if case .weight(let v, _) = load { v } else { 0 } },
            set: { load = .weight(value: $0, unit: unit) }
        )
    }

    private var delta: Binding<Double> {
        Binding(
            get: { if case .bodyweight(let d, _) = load { d } else { 0 } },
            set: { load = .bodyweight(delta: $0, unit: unit) }
        )
    }

    var body: some View {
        Picker("Carga", selection: modeBinding) {
            if allowsNone || mode == .none { Text("Sem carga").tag(Mode.none) }
            Text(verbatim: PrescriptionFormat.unitText(unit)).tag(Mode.weight)
            Text("Peso corporal").tag(Mode.bodyweight)
        }
        .pickerStyle(.segmented)

        switch mode {
        case .none:
            EmptyView()
        case .weight:
            // Passo de 0,5 kg (D3; 1 lb); a digitação aceita qualquer valor.
            NumberStepperField(perSide ? "Carga por lado" : "Carga", value: weightValue,
                               unit: PrescriptionFormat.unitText(unit), step: LoadDisplay.step(forLoadIn: unit, preferred: preferredUnit, stored: loadStep),
                               range: 0...999, fractionDigits: 1)
            if load?.isUnsetWeight == true {
                // Peso 0 = sem carga definida: o treino começa pela última carga usada (ou "Definir carga").
                Text("0 = sem carga definida. O treino usa a última carga registrada deste exercício.")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
        case .bodyweight:
            NumberStepperField("Lastro (+) ou assistência (−)", value: delta,
                               unit: PrescriptionFormat.unitText(unit), step: LoadDisplay.step(forLoadIn: unit, preferred: preferredUnit, stored: loadStep),
                               range: -300...300, fractionDigits: 1, showsSign: true)
            Text("0 = só o peso do corpo")
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
        }

        if mode != .none {
            Picker("Unidade", selection: unitBinding) {
                Text("kg").tag(WeightUnit.kg)
                Text("lb").tag(WeightUnit.lb)
            }
            .pickerStyle(.segmented)
        }

        if let current = divergentCurrent {
            FJAdaptiveStack(spacing: FJSpacing.s) {
                Label("atual: \(PrescriptionFormat.loadText(current))", systemImage: "arrow.triangle.2.circlepath")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textPrimary)
                Spacer(minLength: 0)
                Button("Usar a atual como inicial", action: useCurrent)
                    .font(FJFont.label.weight(.semibold))
                    .buttonStyle(.borderless)
                    .frame(minHeight: FJSize.minTap)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { useCurrent() }
        }
    }
}

// MARK: - Descanso

struct RestField: View {
    @Binding var seconds: Int?
    /// Quando informado, mostra o chip "Padrão (N s)" que limpa o valor.
    var defaultSeconds: Int?
    var showsDefaultChip = false

    private static let presets = [30, 45, 60, 90, 120, 180]

    private var isCustom: Bool {
        guard let seconds else { return false }
        return !Self.presets.contains(seconds)
    }

    @State private var customOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text("Descanso").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FJSpacing.s) {
                    if showsDefaultChip {
                        FJFilterChip(defaultSeconds.map { "Padrão (\($0) s)" } ?? "Padrão", isSelected: seconds == nil) {
                            seconds = nil; customOpen = false
                        }
                    }
                    ForEach(Self.presets, id: \.self) { n in
                        FJFilterChip("\(n) s", isSelected: seconds == n && !customOpen) {
                            seconds = n; customOpen = false
                        }
                    }
                    FJFilterChip("Outro", isSelected: isCustom || customOpen) {
                        customOpen = true
                        if seconds == nil || !isCustom { seconds = seconds ?? defaultSeconds ?? PrescriptionDefaults.restSeconds() }
                    }
                }
                .padding(.vertical, FJSpacing.xxs)
            }
            if isCustom || customOpen {
                NumberStepperField("Descanso", value: optionalSecondsBinding($seconds), unit: "s", step: 5, range: 0...900)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Esforço e cadência

struct EffortField: View {
    @Binding var effort: EffortTarget?

    private enum Mode: Hashable { case none, rir, rpe }

    private var mode: Mode {
        switch effort {
        case .none: .none
        case .some(.rir): .rir
        case .some(.rpe): .rpe
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { new in
                switch new {
                case .none: effort = nil
                case .rir: effort = .rir(2)
                case .rpe: effort = .rpe(8)
                }
            }
        )
    }

    private var value: Binding<Double> {
        Binding(
            get: {
                switch effort {
                case .some(.rir(let n)): Double(n)
                case .some(.rpe(let v)): v
                case .none: 0
                }
            },
            set: {
                switch effort {
                case .some(.rir): effort = .rir(Int($0.rounded()))
                case .some(.rpe): effort = .rpe($0)
                case .none: break
                }
            }
        )
    }

    var body: some View {
        Picker("Esforço alvo", selection: modeBinding) {
            Text("Nenhum").tag(Mode.none)
            Text("RIR").tag(Mode.rir)
            Text("RPE").tag(Mode.rpe)
        }
        .pickerStyle(.segmented)
        switch mode {
        case .none: EmptyView()
        case .rir: NumberStepperField("Repetições em reserva (RIR)", value: value, step: 1, range: 0...5)
        case .rpe: NumberStepperField("Percepção de esforço (RPE)", value: value, step: 0.5, range: 1...10, fractionDigits: 1)
        }
    }
}

struct TempoField: View {
    @Binding var tempo: String?

    var body: some View {
        TextField("Cadência (opcional)", text: Binding(
            get: { tempo ?? "" },
            set: { raw in
                let cleaned = String(raw.filter { $0.isNumber || $0 == "-" || $0 == "x" || $0 == "X" }.prefix(11))
                tempo = cleaned.isEmpty ? nil : cleaned
            }
        ), prompt: Text("ex.: 3-1-1-0"))
        .keyboardType(.numbersAndPunctuation)
        .autocorrectionDisabled()
        .accessibilityLabel(Text("Cadência"))
    }
}

// MARK: - Cardio

private struct OptionalNumberRow: View {
    let label: LocalizedStringKey
    @Binding var value: Double?
    var unit: String
    var step: Double = 1
    var range: ClosedRange<Double> = 0...999
    var fractionDigits = 0
    var initial: Double

    var body: some View {
        if let current = value {
            VStack(spacing: FJSpacing.xs) {
                NumberStepperField(label, value: Binding(get: { current }, set: { value = $0 }), unit: unit,
                                   step: step, range: range, fractionDigits: fractionDigits)
                Button("Remover") { value = nil }
                    .font(FJFont.caption)
                    .buttonStyle(.borderless)
                    .frame(minHeight: FJSize.minTap)
                    .accessibilityLabel(Text("Remover \(Text(label))"))
            }
        } else {
            Button {
                value = initial
            } label: {
                Label("Adicionar \(Text(label))", systemImage: "plus.circle")
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct CardioFields: View {
    @Binding var cardio: CardioTarget?

    private var target: Binding<CardioTarget> {
        Binding(get: { cardio ?? CardioTarget() }, set: { cardio = $0 })
    }

    private var minutes: Binding<Double?> {
        Binding(get: { target.wrappedValue.durationSeconds.map { Double($0) / 60 } },
                set: { target.wrappedValue.durationSeconds = $0.map { Int(($0 * 60).rounded()) } })
    }

    private var km: Binding<Double?> {
        Binding(get: { target.wrappedValue.distanceMeters.map { $0 / 1000 } },
                set: { target.wrappedValue.distanceMeters = $0.map { ($0 * 1000).rounded() } })
    }

    private var level: Binding<Double?> {
        Binding(get: { target.wrappedValue.level.map(Double.init) },
                set: { target.wrappedValue.level = $0.map { Int($0.rounded()) } })
    }

    var body: some View {
        OptionalNumberRow(label: "Duração", value: minutes, unit: "min", step: 1, range: 0...600, initial: 20)
        OptionalNumberRow(label: "Distância", value: km, unit: "km", step: 0.1, range: 0...500, fractionDigits: 2, initial: 3)
        OptionalNumberRow(label: "Nível", value: level, unit: "", step: 1, range: 0...50, initial: 5)
        OptionalNumberRow(label: "Velocidade", value: target.speedKmh, unit: "km/h", step: 0.5, range: 0...60,
                          fractionDigits: 1, initial: 8)
        OptionalNumberRow(label: "Inclinação", value: target.inclinePercent, unit: "%", step: 0.5, range: 0...40,
                          fractionDigits: 1, initial: 1)
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            HStack {
                Text("Zona de FC alvo").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                Spacer()
                if let z = target.wrappedValue.heartRateZone, let zone = FJHeartRateZone(rawValue: z) {
                    FJHeartRateZoneBadge(zone)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FJSpacing.s) {
                    FJFilterChip("Nenhuma", isSelected: target.wrappedValue.heartRateZone == nil) {
                        target.wrappedValue.heartRateZone = nil
                    }
                    ForEach(1...5, id: \.self) { z in
                        FJFilterChip("Z\(z)", isSelected: target.wrappedValue.heartRateZone == z) {
                            target.wrappedValue.heartRateZone = z
                        }
                    }
                }
                .padding(.vertical, FJSpacing.xxs)
            }
        }
    }
}

// MARK: - Campos de uma série

/// Campos de prescrição de uma série (ou da série-modelo no modo em bloco).
struct SetFields: View {
    @Binding var set: SetDraft
    let measurement: MeasurementKind
    var isUnilateral = false
    var showsRest = true
    /// Descanso do exercício, para o chip "Padrão" por série.
    var defaultRest: Int?
    var showsDefaultRestChip = false
    @Binding var rest: Int?
    /// Última carga usada no exercício (histórico), para o `LoadField`.
    var lastKnownLoad: Load? = nil
    let useCurrent: () -> Void

    var body: some View {
        Picker("Tipo de série", selection: $set.kind) {
            ForEach(SetKind.allCases, id: \.self) { Text($0.localizedName).tag($0) }
        }

        switch measurement {
        case .repsAndLoad, .repsOnly:
            RepTargetField(target: $set.repTarget)
        case .isometric:
            NumberStepperField("Tempo de sustentação",
                               value: Binding(get: { Double(set.holdSeconds ?? HoldLimits.defaultSeconds) },
                                              set: { set.holdSeconds = Int($0.rounded()) }),
                               unit: "s", step: 5,
                               range: Double(HoldLimits.minimumSeconds)...600)
        case .timeOrDistance:
            CardioFields(cardio: $set.cardio)
        }

        if measurement != .timeOrDistance {
            LoadField(
                load: Binding(get: { set.initialLoad }, set: { set.setInitialLoad($0) }),
                divergentCurrent: set.divergentCurrent,
                allowsNone: measurement != .repsOnly,
                perSide: isUnilateral,
                lastKnown: lastKnownLoad,
                useCurrent: useCurrent
            )
        }

        if showsRest {
            RestField(seconds: $rest, defaultSeconds: defaultRest, showsDefaultChip: showsDefaultRestChip)
        }

        if measurement != .timeOrDistance {
            TempoField(tempo: $set.tempo)
            EffortField(effort: $set.effort)
        }
    }
}
