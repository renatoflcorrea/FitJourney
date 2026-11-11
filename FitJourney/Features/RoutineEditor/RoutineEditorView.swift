import SwiftData
import SwiftUI

/// Editor de ficha (SPEC §3.2, DESIGN §4.3): cabeçalho, exercícios reordenáveis, agrupamento e prescrição.
/// Empurre dentro de uma `NavigationStack`. Tudo é gravado na hora; "OK" volta.
struct RoutineEditorView: View {
    @Bindable var routine: Routine

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showingPicker = false
    @State private var prescribing: RoutineExercise?
    @State private var viewingExercise: Exercise?
    @State private var transferring: RoutineExercise?
    @State private var deleting: RoutineExercise?

    init(routine: Routine) {
        self.routine = routine
    }

    private var items: [RoutineExercise] { routine.sortedExercises }

    var body: some View {
        List {
            headerSection
            exercisesSection
        }
        .environment(\.editMode, .constant(.active))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(routine.name.isEmpty ? String(localized: "Nova ficha") : routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }
            }
            if !items.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSelecting ? "Cancelar" : "Selecionar") {
                        isSelecting.toggle()
                        selection = []
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showingPicker) {
            ExercisePicker(allowsMultiple: true) { picked in
                RoutineEditorOps.add(picked, to: routine, context: context)
            }
        }
        .sheet(item: $transferring) { item in
            MoveCopySheet(item: item, routine: routine)
        }
        .navigationDestination(item: $prescribing) { PrescriptionEditorView(item: $0) }
        .navigationDestination(item: $viewingExercise) { ExerciseDetailView(exercise: $0) }
        .confirmationDialog("Remover da ficha?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { item in
            Button("Remover \(item.displayName)", role: .destructive) {
                RoutineEditorOps.delete(item, context: context)
            }
        } message: { _ in
            Text("A prescrição deste exercício na ficha será apagada. O exercício continua no catálogo.")
        }
        .tint(FJColor.training)
    }

    // MARK: Cabeçalho

    private var headerSection: some View {
        Section {
            TextField("Nome da ficha", text: $routine.name)
                .font(FJFont.cardTitle)
                .submitLabel(.done)
                .accessibilityLabel(Text("Nome da ficha"))

            HStack(spacing: FJSpacing.m) {
                RoutineBadge(routine: routine)
                TextField("Letra ou símbolo", text: Binding(
                    get: { routine.symbol },
                    set: { routine.symbol = String($0.prefix(2)) }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .accessibilityLabel(Text("Letra ou símbolo da ficha"))
            }

            colorPicker

            if routine.program?.scheduleMode == .weekly {
                weekdayPicker
            }

            TextField("Observações da ficha", text: $routine.notes, axis: .vertical)
                .lineLimit(1...4)

            LabeledContent("Duração estimada") {
                Text(durationText)
                    .font(FJFont.numberBody)
                    .foregroundStyle(FJColor.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Duração estimada"))
            .accessibilityValue(Text(items.isEmpty ? "—" : FJFormat.spokenDuration(routine.estimatedDurationSeconds)))
        }
    }

    private var durationText: String {
        guard !items.isEmpty else { return "—" }
        return "~\(max(1, Int((Double(routine.estimatedDurationSeconds) / 60).rounded()))) min"
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text("Cor").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FJSpacing.s) {
                    ForEach(RoutineColor.allCases, id: \.self) { option in
                        let isOn = RoutineColor(name: routine.colorName) == option
                        Button {
                            routine.colorName = option.rawValue
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if isOn { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(FJColor.onFill) }
                                }
                                .frame(width: FJSize.minTap, height: FJSize.minTap)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(option.localizedName))
                        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private var weekdayPicker: some View {
        let otherDays: [Weekday: [String]] = (routine.program?.sortedRoutines ?? [])
            .filter { $0.id != routine.id }
            .reduce(into: [:]) { acc, r in
                for d in r.weekdays { acc[d, default: []].append(r.symbol.isEmpty ? r.name : r.symbol) }
            }
        return VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text("Dias da semana").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            HStack(spacing: FJSpacing.xs) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let isOn = routine.weekdays.contains(day)
                    let shared = otherDays[day]
                    Button {
                        var days = routine.weekdays
                        if isOn { days.remove(day) } else { days.insert(day) }
                        routine.weekdays = days
                    } label: {
                        VStack(spacing: FJSpacing.xxs) {
                            Text(day.shortName.prefix(3))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isOn ? FJColor.onFill : FJColor.textPrimary)
                                .frame(minWidth: FJSize.minTap - 8, minHeight: FJSize.minTap - 8)
                                .background(isOn ? FJColor.trainingFill : FJColor.fill, in: Circle())
                            Circle()
                                .fill(shared == nil ? .clear : FJColor.textSecondary)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: day.shortName))
                    .accessibilityValue(Text(shared.map { String(localized: "também em \($0.joined(separator: ", "))") } ?? ""))
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text("O ponto indica dia que outra ficha também usa; pode ser compartilhado.")
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
        }
    }

    // MARK: Exercícios

    @ViewBuilder
    private var exercisesSection: some View {
        let list = items
        let groupSizes = Dictionary(grouping: list.compactMap(\.groupID), by: { $0 }).mapValues(\.count)
        Section {
            if list.isEmpty {
                FJEmptyState("Adicione exercícios", systemImage: "dumbbell",
                             message: "Monte a ficha com exercícios do catálogo. Cada um entra com uma prescrição padrão que você ajusta depois.",
                             actionTitle: "Adicionar exercício") { showingPicker = true }
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                let position = position(of: index, in: list)
                RoutineExerciseRow(
                    item: item,
                    position: position,
                    groupCount: item.groupID.flatMap { groupSizes[$0] } ?? 0,
                    groupRest: RoutineEditorOps.effectiveRest(of: item),
                    isSelecting: isSelecting,
                    isSelected: selection.contains(item.id),
                    actions: actions(for: item)
                )
                .listRowBackground(GroupRailBackground(position: position))
                .listRowSeparator(position == .first || position == .middle ? .hidden : .automatic)
                .swipeActions(edge: .trailing) {
                    Button("Remover", systemImage: "trash", role: .destructive) { deleting = item }
                    Button("Duplicar", systemImage: "plus.square.on.square") {
                        RoutineEditorOps.duplicate(item, context: context)
                    }
                    .tint(FJColor.coachFill)
                }
            }
            .onMove { source, destination in
                RoutineEditorOps.move(in: routine, from: source, to: destination, context: context)
            }
        } header: {
            if !list.isEmpty { Text("Exercícios") }
        } footer: {
            if !list.isEmpty {
                Text("Arraste pela alça ou use o menu (…) para subir e descer. Selecione exercícios vizinhos para agrupar em bi-set, tri-set ou circuito.")
            }
        }
    }

    private func position(of index: Int, in list: [RoutineExercise]) -> GroupPosition {
        guard let gid = list[index].groupID else { return .none }
        let before = index > 0 && list[index - 1].groupID == gid
        let after = index + 1 < list.count && list[index + 1].groupID == gid
        switch (before, after) {
        case (false, true): return .first
        case (true, true): return .middle
        case (true, false): return .last
        case (false, false): return .none
        }
    }

    private func actions(for item: RoutineExercise) -> RowActions {
        RowActions(
            open: {
                if isSelecting {
                    if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                } else {
                    prescribing = item
                }
            },
            moveUp: { RoutineEditorOps.move(item, by: -1, context: context) },
            moveDown: { RoutineEditorOps.move(item, by: 1, context: context) },
            duplicate: { RoutineEditorOps.duplicate(item, context: context) },
            transfer: { transferring = item },
            showExercise: { viewingExercise = item.exercise },
            delete: { deleting = item },
            ungroup: {
                if let gid = item.groupID { RoutineEditorOps.ungroup(gid, in: routine, context: context) }
            },
            canMoveUp: RoutineEditorOps.canMove(item, by: -1),
            canMoveDown: RoutineEditorOps.canMove(item, by: 1)
        )
    }

    // MARK: Base

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: FJSpacing.s) {
            if isSelecting {
                let canGroup = RoutineEditorOps.canGroup(selected: selection, in: routine)
                let hasGrouped = items.contains { selection.contains($0.id) && $0.groupID != nil }
                Button(selection.count >= 2 ? "Agrupar (\(GroupLabel.name(forCount: selection.count)))" : "Agrupar") {
                    RoutineEditorOps.group(selected: selection, in: routine, context: context)
                    isSelecting = false
                    selection = []
                }
                .buttonStyle(.fjPrimary(.training))
                .disabled(!canGroup)
                .accessibilityHint(Text(canGroup ? "" : "Marque 2 ou mais exercícios vizinhos"))

                if hasGrouped {
                    FJSecondaryButton("Desagrupar", systemImage: "link.badge.minus") {
                        for gid in Set(items.filter { selection.contains($0.id) }.compactMap(\.groupID)) {
                            RoutineEditorOps.ungroup(gid, in: routine, context: context)
                        }
                        isSelecting = false
                        selection = []
                    }
                }
            } else {
                FJPrimaryButton("Adicionar exercício", systemImage: "plus") { showingPicker = true }
            }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.vertical, FJSpacing.s)
        .background(.bar)
    }
}

/// Selo quadrado da ficha: letra/símbolo sobre a cor escolhida.
struct RoutineBadge: View {
    let routine: Routine

    var body: some View {
        let text = routine.symbol.isEmpty ? String(routine.name.prefix(1)).uppercased() : routine.symbol
        Text(text.isEmpty ? "?" : text)
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(FJColor.onFill)
            .frame(width: 44, height: 44)
            .background(RoutineColor(name: routine.colorName).color, in: FJRadius.shape(FJRadius.chip))
            .accessibilityHidden(true)
    }
}

/// Mover ou copiar um exercício para outra ficha do mesmo programa.
struct MoveCopySheet: View {
    let item: RoutineExercise
    let routine: Routine

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var copies = false

    private var targets: [Routine] {
        (routine.program?.sortedRoutines ?? []).filter { $0.id != routine.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Ação", selection: $copies) {
                        Text("Mover").tag(false)
                        Text("Copiar").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(copies ? "A cópia usa a carga atual como carga inicial." : "O exercício sai desta ficha e entra no fim da outra.")
                }
                Section("Ficha de destino") {
                    if targets.isEmpty {
                        Text("Este programa não tem outras fichas.")
                            .foregroundStyle(FJColor.textSecondary)
                    }
                    ForEach(targets) { target in
                        Button {
                            RoutineEditorOps.transfer(item, to: target, copy: copies, context: context)
                            dismiss()
                        } label: {
                            HStack(spacing: FJSpacing.m) {
                                RoutineBadge(routine: target)
                                Text(target.name.isEmpty ? String(localized: "Sem nome") : target.name)
                                    .foregroundStyle(FJColor.textPrimary)
                                Spacer()
                            }
                            .frame(minHeight: FJSize.minTap)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(FJColor.training)
    }
}

#Preview("Editor de ficha") {
    let container = PersistenceController.preview
    let routine = try! container.mainContext.fetch(FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.sortIndex)])).first!
    return NavigationStack { RoutineEditorView(routine: routine) }
        .modelContainer(container)
}
