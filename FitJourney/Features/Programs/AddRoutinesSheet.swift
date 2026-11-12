import SwiftData
import SwiftUI

/// Fluxo B, "Adicionar ficha de outro programa" (DESIGN §4.2.1): destino fixo, escolhe uma ou mais fichas,
/// agrupadas por programa. Destino semanal acrescenta o passo "Dias da semana". Ao confirmar, fecha a folha.
struct AddRoutinesSheet: View {
    let destination: TrainingProgram
    /// Chamada depois de gravar, com o número de fichas adicionadas (a folha já fechou).
    var onAdded: (Int) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?
    @Query(sort: \TrainingProgram.startDate, order: .reverse) private var allPrograms: [TrainingProgram]
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw == "inProgress" }) private var openSessions: [WorkoutSession]

    @State private var selection: Set<UUID> = []
    @State private var showingDays = false
    @State private var days: [UUID: Set<Weekday>] = [:]
    @State private var isAdding = false
    @State private var forcedBlock = false
    @State private var errorMessage: String?
    @State private var selectionTrigger = 0
    @State private var blockTrigger = 0
    @State private var errorTrigger = 0

    private var sources: [TrainingProgram] {
        RoutineCopyLogic.orderedPrograms(allPrograms, excluding: destination)
    }

    /// Só programas com fichas entram na lista.
    private var groups: [TrainingProgram] { sources.filter { !$0.sortedRoutines.isEmpty } }

    private var isBlocked: Bool { forcedBlock || openSessions.first?.programID == destination.id }

    /// Linhas na ordem da lista, com o nome final de cada uma (contando o destino e as marcadas acima).
    private var entries: [CopyChoiceEntry] {
        var taken = destination.sortedRoutines.map(\.name)
        var result: [CopyChoiceEntry] = []
        for program in groups {
            for routine in program.sortedRoutines {
                let final = RoutineNaming.uniqueName(routine.name, among: taken)
                let selected = selection.contains(routine.id)
                result.append(CopyChoiceEntry(routine: routine, finalName: final, isSelected: selected))
                if selected { taken.append(final) }
            }
        }
        return result
    }

    private var selectedEntries: [CopyChoiceEntry] { entries.filter(\.isSelected) }
    private var count: Int { selection.count }
    private var isWeeklyDestination: Bool { destination.scheduleMode == .weekly }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Adicionar fichas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if isWeeklyDestination {
                            Button("Continuar", action: goToDays).disabled(count == 0 || isBlocked)
                        } else {
                            addButton(action: confirm)
                        }
                    }
                }
                .navigationDestination(isPresented: $showingDays) { daysStep }
        }
        .presentationDetents([.large])
        .alert("Não foi possível copiar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .fjHaptic(.selection, trigger: selectionTrigger)
        .fjHaptic(.warning, trigger: blockTrigger)
        .fjHaptic(.error, trigger: errorTrigger)
    }

    /// "Adicionar (2)" — o VoiceOver lê "Adicionar 2 fichas"; sem fichas, "Adicionar" desabilitado.
    private func addButton(action: @escaping () -> Void) -> some View {
        Group {
            if count == 0 {
                Button("Adicionar", action: action)
            } else {
                Button("Adicionar (\(count))", action: action)
                    .accessibilityLabel(Text(String(localized: "Adicionar \(count) fichas")))
            }
        }
        .disabled(count == 0 || isBlocked || isAdding)
    }

    // MARK: Lista

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            FJEmptyState("Nenhum outro programa", systemImage: "square.stack.3d.up",
                         message: "Quando houver mais de um programa, as fichas dos outros aparecem aqui para copiar.")
        } else if groups.isEmpty {
            FJEmptyState("Nenhuma ficha para copiar", systemImage: "rectangle.stack",
                         message: "Os outros programas ainda não têm fichas.")
        } else {
            list
        }
    }

    private var list: some View {
        let all = entries
        return List {
            if isBlocked {
                Section {
                    FJBanner("Há um treino em andamento",
                             message: "Finalize ou descarte o treino em andamento antes de adicionar fichas a \(destination.name).",
                             tone: .attention, actionTitle: "Ver treino") {
                        dismiss()
                        sessionCoordinator?.present()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    Text("As fichas marcadas são copiadas para \(destination.name). As originais não mudam.")
                    Text(verbatim: RoutineCopyLogic.placementIntro(for: destination))
                }
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: FJSpacing.s, bottom: 0, trailing: FJSpacing.s))
            }
            ForEach(groups) { program in
                Section {
                    ForEach(all.filter { $0.routine.program?.id == program.id }, id: \.routine.id) { entry in
                        RoutineChoiceRow(entry: entry, showsDays: program.scheduleMode == .weekly) {
                            toggle(entry.routine.id)
                        }
                    }
                } header: {
                    Text(verbatim: RoutineCopyLogic.groupTitle(for: program))
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if !selection.insert(id).inserted { selection.remove(id) }
        selectionTrigger += 1
    }

    // MARK: Dias da semana

    private var daysStep: some View {
        RoutineCopyDaysStep(
            destination: destination,
            items: selectedEntries.map {
                CopyDayItem(id: $0.routine.id, symbol: $0.routine.symbol, colorName: $0.routine.colorName,
                            name: $0.finalName, suggested: ProgramStore.suggestedWeekdays(for: $0.routine))
            },
            days: $days, confirmTitle: "Adicionar (\(count))",
            confirmAccessibilityLabel: Text(String(localized: "Adicionar \(count) fichas")),
            isDisabled: count == 0 || isBlocked || isAdding, onConfirm: confirm)
    }

    private func goToDays() {
        // Mantém o que o usuário já escolheu; fichas novas começam com os dias da original.
        for entry in selectedEntries where days[entry.routine.id] == nil {
            days[entry.routine.id] = ProgramStore.suggestedWeekdays(for: entry.routine)
        }
        showingDays = true
    }

    // MARK: Ação

    private func confirm() {
        let chosen = selectedEntries.map(\.routine)
        guard !chosen.isEmpty, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            let weekdays = isWeeklyDestination
                ? Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, days[$0.id] ?? ProgramStore.suggestedWeekdays(for: $0)) })
                : [:]
            let copies = try ProgramStore(context: context).copyRoutines(chosen, to: destination, weekdays: weekdays)
            let added = copies.count
            dismiss()
            onAdded(added)
        } catch ProgramStoreError.sessionInProgress {
            // Treino começou com a folha aberta (ex.: pelo relógio): nada foi copiado.
            showingDays = false
            forcedBlock = true
            blockTrigger += 1
        } catch {
            errorMessage = error.localizedDescription
            errorTrigger += 1
        }
    }
}

/// Uma ficha na lista do fluxo B, com o nome final e a marcação.
private struct CopyChoiceEntry {
    let routine: Routine
    let finalName: String
    let isSelected: Bool
}

/// Linha de ficha do fluxo B: a linha inteira alterna a marcação (indicador à esquerda), selo decorativo,
/// nome, resumo, dias (origem semanal) e "Entra como {Nome} (2)" quando o nome se repete.
private struct RoutineChoiceRow: View {
    let entry: CopyChoiceEntry
    let showsDays: Bool
    let action: () -> Void

    private var routine: Routine { entry.routine }
    private var isRenamed: Bool { entry.finalName != routine.name }

    var body: some View {
        Button(action: action) {
            FJAdaptiveStack(spacing: FJSpacing.m, verticalAlignment: .top) {
                HStack(spacing: FJSpacing.m) {
                    Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(entry.isSelected ? FJColor.training : FJColor.textTertiary)
                        .accessibilityHidden(true)
                    FJRoutineBadge(symbol: routine.symbol, name: routine.name, colorName: routine.colorName)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    Text(verbatim: routine.name)
                        .font(FJFont.cardTitle)
                        .foregroundStyle(FJColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: routine.summaryText)
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                    if showsDays {
                        WeekdayDots(weekdays: routine.weekdays, color: routine.routineColor)
                            .accessibilityHidden(true)
                    }
                    if isRenamed {
                        Text("Entra como \(entry.finalName)")
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, FJSpacing.xs)
            .frame(minHeight: FJSize.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(entry.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var parts = [routine.name]
        if routine.exerciseCount == 0 {
            parts.append(String(localized: "Sem exercícios"))
        } else {
            parts.append(routine.exerciseCountText)
            if routine.estimatedMinutesText != nil {
                let minutes = max(5, Int((Double(routine.estimatedDurationSeconds) / 60 / 5).rounded()) * 5)
                parts.append(String(localized: "cerca de \(minutes) minutos"))
            }
        }
        if showsDays, !routine.weekdays.isEmpty {
            parts.append(String(localized: "dias da semana: \(routine.weekdays.sorted().map(\.fullName).joined(separator: ", "))"))
        }
        if isRenamed {
            let spoken = entry.finalName.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            parts.append(String(localized: "entra como \(spoken)"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Anexa a folha do fluxo B e, depois da cópia, vibra (`celebration`) e anuncia "2 fichas adicionadas a {Destino}".
/// A folha já fechou nesse momento: o háptico e o anúncio vêm da tela de baixo.
private struct AddRoutinesPresenter: ViewModifier {
    @Binding var destination: TrainingProgram?
    @State private var addedTrigger = 0

    func body(content: Content) -> some View {
        content
            .sheet(item: $destination) { target in
                AddRoutinesSheet(destination: target) { count in
                    addedTrigger += 1
                    AccessibilityNotification.Announcement(
                        String(localized: "\(count) fichas adicionadas a \(target.name)")).post()
                }
                .tint(FJColor.training)
            }
            .fjHaptic(.celebration, trigger: addedTrigger)
    }
}

extension View {
    /// Folha "Adicionar fichas" com `destination` como programa de destino (nil = fechada).
    func addRoutinesSheet(destination: Binding<TrainingProgram?>) -> some View {
        modifier(AddRoutinesPresenter(destination: destination))
    }
}

#Preview("Adicionar fichas") {
    let container = PersistenceController.preview
    let program = (try? ProgramStore(context: container.mainContext).activeProgram())!
    return AddRoutinesSheet(destination: program)
        .modelContainer(container)
        .tint(FJColor.training)
}
