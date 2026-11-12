import SwiftData
import SwiftUI

/// Fluxo A de "Copiar para outro programa…" (DESIGN §4.2.1): uma ficha, escolhe o destino.
/// Só cópia; a original não muda. Destino semanal acrescenta o passo "Dias da semana"; termina em "Ficha copiada".
struct CopyRoutineSheet: View {
    let routine: Routine

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openProgram) private var openProgram
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?
    @Query(sort: \TrainingProgram.startDate, order: .reverse) private var allPrograms: [TrainingProgram]
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw == "inProgress" }) private var openSessions: [WorkoutSession]

    @State private var destinationID: UUID?
    @State private var showingDays = false
    @State private var days: [UUID: Set<Weekday>] = [:]
    @State private var daysDestinationID: UUID?
    @State private var creatingProgram = false
    @State private var result: CopyResult?
    @State private var isCopying = false
    @State private var forcedBlockedID: UUID?
    @State private var errorMessage: String?
    @State private var doneTrigger = 0
    @State private var blockTrigger = 0
    @State private var errorTrigger = 0
    /// "Ver treino": a sessão só abre depois que esta folha termina de fechar (`onDisappear`).
    @State private var presentSessionOnClose = false
    @AccessibilityFocusState private var resultFocused: Bool

    private struct CopyResult {
        let destination: TrainingProgram
        let name: String
        let renamed: Bool
    }

    private var candidates: [TrainingProgram] {
        RoutineCopyLogic.orderedPrograms(allPrograms, excluding: routine.program)
    }

    private var blockedIDs: Set<UUID> {
        Set([openSessions.first?.programID, forcedBlockedID].compactMap { $0 })
    }

    private var blockedProgram: TrainingProgram? { candidates.first { blockedIDs.contains($0.id) } }

    private var destination: TrainingProgram? {
        guard let destinationID, !blockedIDs.contains(destinationID) else { return nil }
        return candidates.first { $0.id == destinationID }
    }

    private var isWeeklyDestination: Bool { destination?.scheduleMode == .weekly }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    doneState(result)
                        .transition(.opacity)
                } else {
                    chooser
                        .transition(.opacity)
                }
            }
            .fjAnimation(FJMotion.structure, value: result != nil)
            .navigationTitle("Copiar ficha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $showingDays) { daysStep }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            guard presentSessionOnClose else { return }
            presentSessionOnClose = false
            sessionCoordinator?.present()
        }
        // Treino que termina: some o bloqueio forçado (o da consulta some sozinho).
        .onChange(of: openSessions.isEmpty) { _, isEmpty in if isEmpty { forcedBlockedID = nil } }
        // Destino que ficou indisponível (treino começou): o passo de dias não faz mais sentido.
        .onChange(of: destination == nil) { _, unavailable in if unavailable { showingDays = false } }
        .sheet(isPresented: $creatingProgram) {
            ProgramEditorSheet(program: nil) { created in destinationID = created.id }
                .tint(FJColor.training)
        }
        .alert("Não foi possível copiar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .fjHaptic(.celebration, trigger: doneTrigger)
        .fjHaptic(.warning, trigger: blockTrigger)
        .fjHaptic(.error, trigger: errorTrigger)
        .fjHaptic(.selection, trigger: destinationID)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if result == nil {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isWeeklyDestination {
                    Button("Continuar", action: goToDays).disabled(destination == nil)
                } else {
                    Button("Copiar", action: confirm).disabled(destination == nil || isCopying)
                }
            }
        } else {
            ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
        }
    }

    // MARK: Escolha do destino

    private var chooser: some View {
        List {
            if let blocked = blockedProgram {
                Section {
                    FJBanner("Há um treino em andamento em \(blocked.name)",
                             message: "Finalize ou descarte o treino para copiar fichas para esse programa.",
                             tone: .attention, actionTitle: "Ver treino") {
                        presentSessionOnClose = true
                        dismiss()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                sourceRow
            } footer: {
                Text("A cópia leva exercícios, séries, cargas, descansos e bi-sets, com a mesma cor e letra. A original não muda.")
            }

            if candidates.isEmpty {
                Section {
                    FJEmptyState("Nenhum outro programa", systemImage: "square.stack.3d.up",
                                 message: "Crie um programa para receber a cópia desta ficha.",
                                 actionTitle: "Novo programa") { creatingProgram = true }
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(candidates) { program in
                        DestinationRow(program: program, isSelected: program.id == destinationID,
                                       isBlocked: blockedIDs.contains(program.id)) {
                            destinationID = program.id
                        }
                    }
                    Button { creatingProgram = true } label: {
                        Label("Novo programa…", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                } header: {
                    Text("Copiar para")
                } footer: {
                    destinationFooter
                }
            }
        }
    }

    private var sourceRow: some View {
        FJAdaptiveStack(spacing: FJSpacing.m, verticalAlignment: .top) {
            FJRoutineBadge(symbol: routine.symbol, name: routine.name, colorName: routine.colorName)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text(verbatim: routine.name).font(FJFont.cardTitle)
                Text(verbatim: routine.summaryText)
                    .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                if let origin = routine.program {
                    Text("de \(origin.name)")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var destinationFooter: some View {
        if let destination {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text(verbatim: RoutineCopyLogic.placementFooter(for: destination))
                let final = RoutineCopyLogic.finalName(of: routine, in: destination)
                if final != routine.name {
                    Text("\(destination.name) já tem uma ficha com este nome. A cópia entra como \(final).")
                }
            }
        }
    }

    // MARK: Dias da semana

    private var daysStep: some View {
        Group {
            if let destination {
                RoutineCopyDaysStep(
                    destination: destination,
                    items: [CopyDayItem(id: routine.id, symbol: routine.symbol, colorName: routine.colorName,
                                        name: RoutineCopyLogic.finalName(of: routine, in: destination),
                                        suggested: ProgramStore.suggestedWeekdays(for: routine))],
                    days: $days, confirmTitle: "Copiar", confirmAccessibilityLabel: nil,
                    isDisabled: isCopying, onConfirm: confirm)
            }
        }
    }

    private func goToDays() {
        guard let destination else { return }
        if daysDestinationID != destination.id {
            days = [routine.id: ProgramStore.suggestedWeekdays(for: routine)]
            daysDestinationID = destination.id
        }
        showingDays = true
    }

    // MARK: Estado final

    private func doneState(_ result: CopyResult) -> some View {
        FJEmptyState("Ficha copiada", systemImage: "checkmark.circle.fill",
                     message: result.renamed
                        ? "Entrou em \(result.destination.name) como \(result.name). A original não mudou."
                        : "\(result.name) agora também está em \(result.destination.name). A original não mudou.",
                     actionTitle: openProgram == nil ? nil : "Ver programa") {
            let target = result.destination
            dismiss()
            openProgram?(target)
        }
        .accessibilityFocused($resultFocused)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            resultFocused = true
        }
    }

    // MARK: Ação

    private func confirm() {
        guard let destination, !isCopying else { return }
        isCopying = true
        defer { isCopying = false }
        do {
            let weekdays = destination.scheduleMode == .weekly ? [routine.id: days[routine.id] ?? ProgramStore.suggestedWeekdays(for: routine)] : [:]
            let copies = try ProgramStore(context: context).copyRoutines([routine], to: destination, weekdays: weekdays)
            guard let copy = copies.first else { return }
            showingDays = false
            result = CopyResult(destination: destination, name: copy.name, renamed: copy.name != routine.name)
            doneTrigger += 1
        } catch ProgramStoreError.sessionInProgress {
            // Treino começou com a folha aberta (ex.: pelo relógio): nada foi copiado.
            showingDays = false
            forcedBlockedID = destination.id
            blockTrigger += 1
        } catch {
            errorMessage = error.localizedDescription
            errorTrigger += 1
        }
    }
}

/// Linha de destino: nome, etiqueta (Ativo / Arquivado / Treino em andamento), "{Modo} · {n} fichas" e check.
private struct DestinationRow: View {
    let program: TrainingProgram
    let isSelected: Bool
    let isBlocked: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    if dynamicTypeSize.isAccessibilitySize {
                        title
                        tag
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                            title
                            tag
                        }
                    }
                    Text(verbatim: RoutineCopyLogic.summary(of: program))
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: FJSpacing.s)
                if !isBlocked {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? FJColor.training : FJColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: FJSize.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBlocked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: some View {
        Text(verbatim: program.name)
            .font(FJFont.cardTitle)
            .foregroundStyle(isBlocked ? FJColor.textSecondary : FJColor.textPrimary)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var tag: some View {
        if isBlocked {
            FJTag("Treino em andamento", tone: .attention)
        } else if program.isActive {
            FJTag("Ativo", systemImage: "checkmark.circle.fill", tone: .success)
        } else if program.isArchived {
            FJTag("Arquivado", systemImage: "archivebox")
        }
    }

    private var accessibilityText: String {
        let count = (program.routines ?? []).count
        var parts = [program.name, program.scheduleMode.localizedName.lowercased(), String(localized: "\(count) fichas")]
        if program.isActive { parts.append(String(localized: "ativo")) }
        if program.isArchived { parts.append(String(localized: "arquivado")) }
        if isBlocked { parts.append(String(localized: "indisponível, treino em andamento")) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Copiar ficha") {
    let container = PersistenceController.preview
    let program = (try? ProgramStore(context: container.mainContext).activeProgram())!
    return CopyRoutineSheet(routine: program.sortedRoutines[0])
        .modelContainer(container)
        .tint(FJColor.training)
}
