import SwiftData
import SwiftUI

/// Prescrição de um exercício da ficha (SPEC §3.4): em bloco ("N séries iguais") ou série a série.
/// Empurre dentro de uma `NavigationStack`. As mudanças são gravadas na hora.
struct PrescriptionEditorView: View {
    let item: RoutineExercise

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: PrescriptionDraft
    @State private var mode: PrescriptionMode
    @State private var expandedSetID: UUID?
    @State private var confirmingUniform = false
    @State private var pendingRemoval: PendingRemoval?
    @State private var errorMessage: String?
    /// Última carga usada no exercício (histórico), para o valor inicial da carga (P2.8).
    @State private var lastKnownLoad: Load?

    private enum PendingRemoval: Equatable {
        case set(Int)
        case resize(Int)
    }

    init(item: RoutineExercise) {
        self.item = item
        let initial = PrescriptionDraft(item)
        _draft = State(initialValue: initial)
        _mode = State(initialValue: initial.initialMode)
    }

    /// Em grupo, só o último exercício define o descanso (ao fim da rodada).
    private var isInnerGroupMember: Bool { RoutineEditorOps.isInnerGroupMember(item) }
    private var isGrouped: Bool { item.groupID != nil }

    private var catalogRest: Int? { item.exercise?.defaultRestSeconds }
    private var isUnilateral: Bool { item.exercise?.laterality == .unilateral }

    private func effectiveRest(_ set: SetDraft) -> Int {
        RoutineEditorOps.effectiveRest(set, exerciseRest: draft.exerciseRest, catalogRest: catalogRest)
    }

    private var modeBinding: Binding<PrescriptionMode> {
        Binding(
            get: { mode },
            set: { new in
                guard new != mode else { return }
                if new == .block && !draft.isUniform {
                    confirmingUniform = true
                } else {
                    mode = new
                }
            }
        )
    }

    var body: some View {
        Form {
            headerSection
            Section {
                Picker("Modo", selection: modeBinding) {
                    Text("Séries iguais").tag(PrescriptionMode.block)
                    Text("Série a série").tag(PrescriptionMode.perSet)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Modo de prescrição"))
            }
            switch mode {
            case .block: blockSection
            case .perSet: perSetSections
            }
            Section("Observações") {
                TextField("Ex.: banco a 30°", text: $draft.notes, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityLabel(Text("Observações do exercício"))
            }
        }
        .navigationTitle(item.displayName.exerciseDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.exercise?.id) {
            lastKnownLoad = try? SessionStore(context: context).lastUsedLoad(exerciseID: item.exercise?.id)
        }
        .onChange(of: draft) { _, new in
            do { try new.apply(to: item, context: context) } catch { errorMessage = error.localizedDescription }
        }
        .alert("Não foi possível salvar", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Remover série com carga atual?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remover", role: .destructive) {
                switch pendingRemoval {
                case .set(let i): performRemoveSet(at: i)
                case .resize(let n): draft.resize(to: n)
                case .none: break
                }
                pendingRemoval = nil
            }
            Button("Cancelar", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("A carga atual dessa série é diferente da inicial e será descartada junto com ela.")
        }
        .confirmationDialog("As séries são diferentes", isPresented: $confirmingUniform, titleVisibility: .visible) {
            Button("Igualar todas à série 1", role: .destructive) {
                draft.makeUniform()
                mode = .block
            }
            Button("Continuar série a série", role: .cancel) {}
        } message: {
            Text("Séries iguais exige que todas tenham a mesma prescrição. As demais séries copiarão os valores da série 1.")
        }
        .tint(FJColor.training)
    }

    // MARK: Topo

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                if item.exercise == nil {
                    FJTag("Exercício removido", systemImage: FJTone.attention.systemImage, tone: .attention)
                }
                let summary = PrescriptionSummary.line(sets: draft.sets, measurement: draft.measurement,
                                                       effectiveRest: effectiveRest)
                Text(summary.isEmpty ? String(localized: "Definir séries") : summary)
                    .font(FJFont.numberBody)
                    .foregroundStyle(FJColor.textPrimary)
                    .accessibilityLabel(Text(PrescriptionSummary.spoken(sets: draft.sets, measurement: draft.measurement,
                                                                         effectiveRest: effectiveRest)))
                if draft.measurement != .timeOrDistance, draft.hasDivergentCurrent {
                    Text("Há carga atual diferente da inicial (veja em Carga).")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            if let exercise = item.exercise {
                NavigationLink {
                    ExerciseDetailView(exercise: exercise)
                } label: {
                    Label("Ver exercício", systemImage: "info.circle")
                }
            }
        }
    }

    // MARK: Em bloco

    private var blockSection: some View {
        Section {
            NumberStepperField(
                "Séries",
                value: Binding(get: { Double(draft.sets.count) }, set: { requestResize(Int($0)) }),
                range: 1...20
            )
            SetFields(
                set: $draft.template,
                measurement: draft.measurement,
                isUnilateral: isUnilateral,
                showsRest: !isInnerGroupMember,
                defaultRest: catalogRest,
                rest: Binding(
                    get: { draft.template.restSeconds ?? draft.exerciseRest ?? catalogRest },
                    set: { new in
                        draft.exerciseRest = new
                        for i in draft.sets.indices { draft.sets[i].restSeconds = nil }
                    }
                ),
                lastKnownLoad: lastKnownLoad,
                useCurrent: {
                    draft.useCurrentAsInitial()
                    if !draft.isUniform { mode = .perSet }
                }
            )
        } header: {
            Text("\(draft.sets.count) séries iguais")
        } footer: {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text("Editar aqui aplica a todas as séries.")
                if isInnerGroupMember {
                    Text("Descanso só ao fim da rodada: defina no último exercício do grupo.")
                } else if isGrouped {
                    Text("Este é o último do grupo: o descanso daqui vale ao fim de cada rodada.")
                }
            }
        }
    }

    // MARK: Série a série

    @ViewBuilder
    private var perSetSections: some View {
        Section {
            ForEach(Array(draft.sets.enumerated()), id: \.element.id) { index, set in
                setRow(index: index, set: set)
            }

            Button {
                var new = draft.sets.last.map { last -> SetDraft in
                    var copy = last
                    copy.id = UUID(); copy.currentLoad = nil
                    return copy
                } ?? PrescriptionDefaults.set(for: draft.measurement)
                new.id = UUID()
                draft.sets.append(new)
                expandedSetID = new.id
            } label: {
                Label("Adicionar série", systemImage: "plus.circle.fill")
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
            }
        } header: {
            Text("Séries")
        } footer: {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text("Toque numa série para editar. Deslize para remover.")
                if isInnerGroupMember {
                    Text("Descanso só ao fim da rodada: defina no último exercício do grupo.")
                } else if isGrouped {
                    Text("Este é o último do grupo: o descanso daqui vale ao fim de cada rodada.")
                }
            }
        }
    }

    @ViewBuilder
    private func setRow(index: Int, set: SetDraft) -> some View {
        let isOpen = expandedSetID == set.id
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(spacing: FJSpacing.s) {
                Button {
                    withAnimation(FJMotion.resolve(FJMotion.structure, reduceMotion: reduceMotion)) { expandedSetID = isOpen ? nil : set.id }
                } label: {
                    HStack(spacing: FJSpacing.s) {
                        Text("\(index + 1)")
                            .font(FJFont.numberBody)
                            .foregroundStyle(FJColor.textSecondary)
                            .frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                            Text(set.kind.localizedName)
                                .font(FJFont.label.weight(.semibold))
                                .foregroundStyle(FJColor.textPrimary)
                            Text(rowSummary(set))
                                .font(FJFont.numberCaption)
                                .foregroundStyle(FJColor.textSecondary)
                            if !set.isValid {
                                Label("Faixa inválida", systemImage: FJTone.attention.systemImage)
                                    .font(FJFont.caption)
                                    .symbolRenderingMode(.multicolor)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(FJColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: FJSize.minTap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Série \(index + 1), \(set.kind.localizedName)"))
                .accessibilityValue(Text(rowSummary(set)))
                .accessibilityHint(Text(isOpen ? "Recolhe os campos" : "Expande para editar"))
                .accessibilityAddTraits(.isButton)

                Menu {
                    Button("Aplicar a todas as séries", systemImage: "rectangle.stack") { applyToAll(from: index) }
                    Button("Duplicar série", systemImage: "plus.square.on.square") { duplicateSet(at: index) }
                    Button("Remover série", systemImage: "trash", role: .destructive) { removeSet(at: index) }
                        .disabled(draft.sets.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Ações da série \(index + 1)"))
            }

            if isOpen, let binding = binding(for: set.id) {
                SetFields(
                    set: binding,
                    measurement: draft.measurement,
                    isUnilateral: isUnilateral,
                    showsRest: !isInnerGroupMember,
                    defaultRest: draft.exerciseRest ?? catalogRest,
                    showsDefaultRestChip: true,
                    rest: Binding(
                        get: { binding.wrappedValue.restSeconds },
                        set: { binding.wrappedValue.restSeconds = $0 }
                    ),
                    lastKnownLoad: lastKnownLoad,
                    useCurrent: { binding.wrappedValue.useCurrentAsInitial() }
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if draft.sets.count > 1 {
                Button("Remover", role: .destructive) { removeSet(at: index) }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<SetDraft>? {
        guard draft.sets.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.sets.first { $0.id == id } ?? SetDraft() },
            set: { new in if let i = draft.sets.firstIndex(where: { $0.id == id }) { draft.sets[i] = new } }
        )
    }

    private func rowSummary(_ set: SetDraft) -> String {
        let text = PrescriptionSummary.line(sets: [set], measurement: draft.measurement, effectiveRest: effectiveRest)
        // "1 × 12 · 20 kg · 60 s" → "12 · 20 kg · 60 s"
        if let range = text.range(of: "1 × ") , text.hasPrefix("1 × ") { return String(text[range.upperBound...]) }
        return text
    }

    private func applyToAll(from index: Int) {
        let source = draft.sets[index]
        for i in draft.sets.indices where i != index { draft.sets[i].copyTarget(from: source) }
    }

    private func duplicateSet(at index: Int) {
        var copy = draft.sets[index]
        copy.id = UUID(); copy.currentLoad = nil
        draft.sets.insert(copy, at: index + 1)
    }

    private func removeSet(at index: Int) {
        guard draft.sets.count > 1, draft.sets.indices.contains(index) else { return }
        if draft.sets[index].divergentCurrent != nil {
            pendingRemoval = .set(index)
        } else {
            performRemoveSet(at: index)
        }
    }

    private func performRemoveSet(at index: Int) {
        guard draft.sets.count > 1, draft.sets.indices.contains(index) else { return }
        draft.sets.remove(at: index)
    }

    private func requestResize(_ count: Int) {
        let target = max(1, count)
        if target < draft.sets.count, draft.sets[target...].contains(where: { $0.divergentCurrent != nil }) {
            pendingRemoval = .resize(target)
        } else {
            draft.resize(to: target)
        }
    }
}

#Preview("Prescrição") {
    let container = PersistenceController.preview
    let item = try! container.mainContext.fetch(FetchDescriptor<RoutineExercise>()).first!
    return NavigationStack { PrescriptionEditorView(item: item) }
        .modelContainer(container)
}
