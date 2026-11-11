import SwiftUI

/// Escala numérica opcional (dor 0–10, humor 1–5): toque de novo para desmarcar. Mesmo visual do `FJRPEScale`.
struct SessionNumberScale: View {
    @Binding var value: Int?
    let range: ClosedRange<Int>
    let title: LocalizedStringKey
    var caption: (Int) -> String = { _ in "" }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Grid(horizontalSpacing: FJSpacing.s, verticalSpacing: FJSpacing.s) {
                ForEach(rows, id: \.first) { row in
                    GridRow {
                        ForEach(row, id: \.self) { cell($0) }
                        // Completa a última linha para as células manterem a largura.
                        ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(height: 0) }
                    }
                }
            }
            if let value, !caption(value).isEmpty {
                Text(caption(value)).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            }
        }
        .fjHaptic(.selection, trigger: value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    /// Em tamanhos de acessibilidade, 3 colunas (células maiores, sem cortar).
    private var columns: Int { typeSize.isAccessibilitySize ? min(3, range.count) : (range.count > 6 ? 6 : range.count) }

    private var rows: [[Int]] {
        let all = Array(range)
        return stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
    }

    private func cell(_ number: Int) -> some View {
        let isSelected = value == number
        let spoken = caption(number).isEmpty ? "\(number)" : "\(number), \(caption(number))"
        return Button {
            value = isSelected ? nil : number
        } label: {
            Text(verbatim: "\(number)")
                .font(FJFont.numberMedium)
                .foregroundStyle(isSelected ? FJColor.onFill : FJColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: FJSize.setCheck)
                .background(isSelected ? FJColor.trainingFill : FJColor.fill, in: FJRadius.shape(FJRadius.field))
                .overlay {
                    if isSelected {
                        FJRadius.shape(FJRadius.field).strokeBorder(FJColor.textPrimary.opacity(0.35), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Campo decimal opcional (velocidade, inclinação): vazio = sem valor. O valor gravado é limitado a ±1000
/// e arredondado a 1 casa; `allowsNegative` mostra o botão ± (o teclado decimal não tem sinal).
struct SessionOptionalDecimalField: View {
    let label: LocalizedStringKey
    let unit: String
    var allowsNegative = false
    @Binding var value: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    static let limit = 1_000.0

    /// Valor normalizado: arredondado a 1 casa e dentro de ±1000 (sem negativo quando não permitido).
    static func normalized(_ value: Double?, allowsNegative: Bool) -> Double? {
        guard let value, value.isFinite else { return nil }
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, allowsNegative ? -limit : 0), limit)
    }

    private var field: Binding<Double?> {
        Binding(get: { value }, set: { value = Self.normalized($0, allowsNegative: allowsNegative) })
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    Text(label).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    HStack(spacing: FJSpacing.s) { input; Text(verbatim: unit).font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
                }
            } else {
                HStack(spacing: FJSpacing.s) {
                    Text(label).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    Spacer(minLength: FJSpacing.s)
                    input
                    Text(verbatim: unit).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .frame(minHeight: FJSize.minTap)
        .padding(.horizontal, FJSpacing.m)
        .background(FJColor.fill, in: FJRadius.shape(FJRadius.field))
        .accessibilityElement(children: .contain)
    }

    private var input: some View {
        HStack(spacing: FJSpacing.xs) {
            TextField(label, value: field, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                .font(FJFont.numberBody)
                .frame(minWidth: 56, maxWidth: typeSize.isAccessibilitySize ? .infinity : 96)
            if allowsNegative {
                Button {
                    if let value { field.wrappedValue = -value }
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                }
                .disabled(value == nil || value == 0)
                .accessibilityLabel(Text("Inverter o sinal"))
            }
        }
    }
}

/// Campos opcionais do cardio: nível, velocidade e inclinação. Recebe bindings: na linha da sessão cada alteração
/// vai direto ao motor (`live`); na folha de edição ficam locais até "Salvar".
struct SessionCardioFields: View {
    @Binding var level: Int?
    @Binding var speed: Double?
    @Binding var incline: Double?

    var body: some View {
        VStack(spacing: FJSpacing.s) {
            FJOptionalNumberField("Nível do aparelho", prompt: "+ nível", value: $level, unit: nil, range: 0...99)
                .frame(maxWidth: .infinity, alignment: .leading)
            SessionOptionalDecimalField(label: "Velocidade", unit: "km/h", value: $speed)
            SessionOptionalDecimalField(label: "Inclinação", unit: "%", allowsNegative: true, value: $incline)
        }
    }

    /// Bindings que enviam `updateCardio` ao motor a cada alteração.
    static func live(coordinator: SessionCoordinator, set: SessionSnapshot.ExerciseSet) -> SessionCardioFields {
        func send(_ level: Int?, _ speed: Double?, _ incline: Double?) {
            coordinator.send(.updateCardio(setID: set.id, level: level, speedKmh: speed, inclinePercent: incline))
        }
        return SessionCardioFields(
            level: Binding(get: { set.level }, set: { if $0 != set.level { send($0, set.speedKmh, set.inclinePercent) } }),
            speed: Binding(get: { set.speedKmh }, set: { if $0 != set.speedKmh { send(set.level, $0, set.inclinePercent) } }),
            incline: Binding(get: { set.inclinePercent }, set: { if $0 != set.inclinePercent { send(set.level, set.speedKmh, $0) } }))
    }
}

// MARK: - Anotação

/// Anotação livre do exercício ou da sessão. Vazio apaga.
struct SessionNoteSheet: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool
    private let initial: String

    init(title: LocalizedStringKey, prompt: LocalizedStringKey, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focused)
                    .padding(FJSpacing.m)
                    .background(FJColor.fill, in: FJRadius.shape(FJRadius.field))
                    .onChange(of: text) { _, new in
                        if new.count > SessionEngine.maxTextLength { text = String(new.prefix(SessionEngine.maxTextLength)) }
                    }
                Spacer(minLength: 0)
            }
            .padding(FJSpacing.screenMargin)
            .fjScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Sem alteração, nada é enviado.
                        if trimmed != initial.trimmingCharacters(in: .whitespacesAndNewlines) { onSave(trimmed) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .tint(FJColor.training)
    }
}

// MARK: - Dor / desconforto

/// Dor ou desconforto do exercício: local e nota 0–10. "Limpar" remove os dois.
struct SessionPainSheet: View {
    let coordinator: SessionCoordinator
    let exercise: SessionSnapshot.Exercise

    @Environment(\.dismiss) private var dismiss
    @State private var score: Int?
    @State private var location: String
    static let maxLocationLength = 80

    init(coordinator: SessionCoordinator, exercise: SessionSnapshot.Exercise) {
        self.coordinator = coordinator
        self.exercise = exercise
        _score = State(initialValue: exercise.painScore)
        _location = State(initialValue: exercise.painLocation ?? "")
    }

    private var hasExisting: Bool { exercise.painScore != nil || !(exercise.painLocation ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.cardGap) {
                    FJCard {
                        VStack(alignment: .leading, spacing: FJSpacing.m) {
                            Text(exercise.name).font(FJFont.cardTitle)
                            FJSectionHeader("Intensidade", subtitle: "0 = nenhuma · 10 = a pior · toque de novo para desmarcar")
                            SessionNumberScale(value: $score, range: 0...10, title: "Dor ou desconforto de 0 a 10") {
                                String(localized: "\($0) de 10")
                            }
                            FJSectionHeader("Onde")
                            TextField("Ex.: ombro direito", text: $location)
                                .textInputAutocapitalization(.sentences)
                                .padding(FJSpacing.m)
                                .frame(minHeight: FJSize.minTap)
                                .background(FJColor.fill, in: FJRadius.shape(FJRadius.field))
                                .onChange(of: location) { _, new in
                                    if new.count > Self.maxLocationLength { location = String(new.prefix(Self.maxLocationLength)) }
                                }
                            if location.count >= Self.maxLocationLength {
                                Text("Limite de \(Self.maxLocationLength) caracteres atingido.")
                                    .font(FJFont.caption)
                                    .foregroundStyle(FJColor.attention)
                            }
                        }
                    }
                    if hasExisting {
                        Button("Limpar dor", role: .destructive) {
                            coordinator.send(.setPain(exerciseID: exercise.id, location: nil, score: nil))
                            dismiss()
                        }
                        .frame(minHeight: FJSize.minTap)
                    }
                }
                .padding(FJSpacing.screenMargin)
            }
            .scrollDismissesKeyboard(.interactively)
            .fjScreenBackground()
            .navigationTitle("Dor ou desconforto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(FJColor.training)
    }

    private func save() {
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator.send(.setPain(exerciseID: exercise.id, location: place.isEmpty ? nil : place, score: score))
        dismiss()
    }
}

// MARK: - Relógio

/// Selo/botão do Apple Watch na sessão: "Gravar no relógio", "Gravando no Apple Watch" ou aviso de versão.
struct SessionWatchStatus: View {
    let snapshot: SessionSnapshot
    @Environment(PhoneWatchLink.self) private var watchLink
    @State private var isRequesting = false

    var body: some View {
        switch SessionPresentation.watchBadge(
            canRequest: watchLink.canRequestWatchRecording, recordingSessionID: watchLink.watchRecordingSessionID,
            currentSessionID: snapshot.sessionID, incompatibility: watchLink.watchIncompatibility
        ) {
        case .none:
            EmptyView()
        case .offer:
            Button {
                isRequesting = watchLink.requestWatchRecording()
            } label: {
                Label(isRequesting ? "Pedindo ao relógio…" : "Gravar no relógio", systemImage: "applewatch")
                    .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
            }
            .buttonStyle(.fjSecondary())
            .disabled(isRequesting)
            // Sem resposta do relógio em 15 s, o botão volta.
            .task(id: isRequesting) {
                guard isRequesting else { return }
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { isRequesting = false }
            }
            .accessibilityHint(Text("Usa a frequência cardíaca e as calorias do Apple Watch neste treino"))
        case .recording:
            FJTag("Gravando no Apple Watch", systemImage: "applewatch.radiowaves.left.and.right", area: .health)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        case .incompatible(let phoneIsOutdated):
            FJBanner(
                phoneIsOutdated ? "Atualize o FitJourney no iPhone" : "Atualize o app no relógio",
                message: phoneIsOutdated
                    ? "O app do relógio é mais novo que este. Atualize para voltar a sincronizar."
                    : "O app do Apple Watch é antigo demais para sincronizar este treino. Atualize-o no relógio.",
                tone: .attention, systemImage: "applewatch.slash")
        }
    }
}
