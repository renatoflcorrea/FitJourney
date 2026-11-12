import SwiftUI

/// Editor de carga (W4 · DESIGN §9.4): folha em tela cheia aberta pelo botão de carga da Série ou pelo
/// "Próxima: 26 kg" do descanso. É a **única** tela da sessão em que a Coroa mexe na carga (0,5 kg ou 1 lb por
/// detente, com o háptico de detente do sistema). Tudo fica num rascunho: "Salvar" (ou toque duplo) envia um
/// `adjustLoad` e volta; "Cancelar" (ou fechar de qualquer outro jeito) descarta.
struct LoadEditorView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: WatchLoadDraft
    @State private var crown: Double
    @FocusState private var crownFocused: Bool

    init(draft: WatchLoadDraft) {
        _draft = State(initialValue: draft)
        _crown = State(initialValue: draft.value)
    }

    private var isLargeText: Bool { typeSize >= .accessibility1 }
    /// Série sem carga e ainda intocada: o número aparece esmaecido (é só o ponto de partida).
    private var isPlaceholder: Bool { draft.wasUnset && !draft.hasChanges }

    var body: some View {
        NavigationStack {
            // Sem ScrollView nem em texto grande: a Coroa tem de continuar sendo da carga aqui. Sem Spacer: o número
            // é o único elemento compressível (encolhe até 70% se faltar altura).
            VStack(spacing: isLargeText ? 4 : 5) {
                valueRow
                // Linha de contexto só na caixa grande: no 41/42 mm ela custaria 30% do número.
                if !isLargeText, WatchLayout.isLargeCase { contextLine }
                stepButtons
                WatchPrimaryButton(title: "Salvar", systemImage: "checkmark", accessibilityLabel: "Salvar carga") {
                    model.saveLoad(draft)
                    dismiss()
                }
                .accessibilityHint(Text("Grava \(WatchFormat.spokenLoad(draft.load)) e volta à série"))
            }
            // Sem título: no relógio ele ocupa uma linha inteira abaixo da hora e espremeria o número. O número com a
            // unidade, o traço da Coroa e os − / + já dizem o que é a tela; a linha de contexto diz de qual série.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancelar")
                        .accessibilityHint("Descarta a mudança")
                }
            }
        }
        .onAppear {
            model.isEditingLoad = true
            crownFocused = true
        }
        .onDisappear { model.isEditingLoad = false }
    }

    // MARK: Número (Coroa + VoiceOver)

    private var valueRow: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let prefix = bodyweightPrefix {
                    Text(verbatim: prefix).font(.footnote.weight(.semibold)).foregroundStyle(WF.textSecondary)
                }
                Text(verbatim: numberText)
                    .font(WF.number(WatchLayout.loadEditorFontSize))
                    .foregroundStyle(isPlaceholder ? WF.textSecondary : WF.textPrimary)
                    .minimumScaleFactor(0.7).lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: draft.value))
                if let unit = unitText {
                    Text(verbatim: unit).font(.footnote.weight(.semibold)).foregroundStyle(WF.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            // Indicador da Coroa (traço laranja): só existe aqui, onde a Coroa ajusta a carga.
            Capsule().fill(WF.training).frame(width: 4, height: 30).accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crown, from: draft.range.lowerBound, through: draft.range.upperBound, by: draft.step,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, new in
            draft.set(new)
            if abs(draft.value - new) > 0.001 { crown = draft.value }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(contextText.map { Text("Carga, \($0)") } ?? Text("Carga"))
        .accessibilityValue(WatchFormat.spokenLoad(draft.load))
        .accessibilityHint(Text(draft.step == 1 ? "Deslize para cima ou para baixo para mudar uma libra" : "Deslize para cima ou para baixo para mudar meio quilo"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(up: true)
            case .decrement: step(up: false)
            @unknown default: break
            }
        }
    }

    /// "Série 2 de 4" (+ "· lastro"/"· assistência" no peso corporal, "· sem carga" enquanto a série não tem carga) —
    /// de qual série é a carga, inclusive quando o editor abre pelo descanso (próxima série).
    @ViewBuilder private var contextLine: some View {
        if let line = contextText {
            Text(verbatim: line).font(.footnote).foregroundStyle(WF.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private var contextText: String? {
        guard let exercise = model.display?.exercises.first(where: { $0.sets.contains { $0.id == draft.setID } }),
              let index = exercise.sets.firstIndex(where: { $0.id == draft.setID }) else { return nil }
        var line = String(localized: "Série \(index + 1) de \(exercise.sets.count)")
        if isPlaceholder {
            line += " · " + String(localized: "sem carga")
        } else if draft.base.isBodyweight, draft.value != 0 {
            line += " · " + (draft.value > 0 ? String(localized: "lastro") : String(localized: "assistência"))
        }
        return line
    }

    // MARK: − / +

    private var stepButtons: some View {
        HStack(spacing: 8) {
            Button { step(up: false) } label: {
                Image(systemName: "minus").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!draft.canDecrement)
            .accessibilityLabel("Diminuir carga")
            Button { step(up: true) } label: {
                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!draft.canIncrement)
            .accessibilityLabel("Aumentar carga")
        }
        .buttonStyle(.glass)
    }

    private func step(up: Bool) {
        if up { draft.increment() } else { draft.decrement() }
        crown = draft.value
    }

    // MARK: Formatação

    /// "26,0" · "+10" / "−10" (peso corporal com lastro/assistência) · "PC" (peso corporal puro).
    private var numberText: String {
        let load = draft.load
        if load.isBodyweight {
            if load.value == 0 { return String(localized: "PC", comment: "Abreviação de peso corporal na carga") }
            return (load.value > 0 ? "+" : "−") + WatchFormat.number(abs(load.value))
        }
        return WatchFormat.number(load.value, minFraction: 1)
    }

    private var bodyweightPrefix: String? {
        draft.load.isBodyweight && draft.load.value != 0 ? String(localized: "PC", comment: "Abreviação de peso corporal na carga") : nil
    }

    private var unitText: String? {
        draft.load.isBodyweight && draft.load.value == 0 ? nil : (draft.load.unit == .kg ? "kg" : "lb")
    }
}
