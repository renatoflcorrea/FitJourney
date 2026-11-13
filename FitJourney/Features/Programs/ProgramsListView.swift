import SwiftData
import SwiftUI

/// Programas (push a partir de Treinos): Ativo, Anteriores e Arquivados.
struct ProgramsListView: View {
    @Query(sort: \TrainingProgram.startDate, order: .reverse) private var programs: [TrainingProgram]

    private var active: [TrainingProgram] { programs.filter(\.isActive) }
    private var previous: [TrainingProgram] { programs.filter { !$0.isActive && !$0.isArchived } }
    private var archived: [TrainingProgram] { programs.filter { !$0.isActive && $0.isArchived } }

    var body: some View {
        List {
            if programs.isEmpty {
                FJEmptyState("Nenhum programa ainda", systemImage: "square.stack.3d.up",
                             message: "Crie um programa na aba Treinos.")
                    .listRowBackground(Color.clear)
            }
            if !active.isEmpty {
                Section("Ativo") { rows(active) }
            }
            if !previous.isEmpty {
                Section("Anteriores") { rows(previous) }
            }
            if !archived.isEmpty {
                Section("Arquivados") { rows(archived) }
            }
        }
        .navigationTitle("Programas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rows(_ list: [TrainingProgram]) -> some View {
        ForEach(list) { program in
            NavigationLink(value: program) { ProgramRow(program: program) }
        }
    }
}

/// Detalhe de um programa (somente leitura): fichas e exercícios, com Duplicar e editar, Reativar, Arquivar e Excluir.
struct ProgramDetailView: View {
    let program: TrainingProgram

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]

    @State private var confirmReactivate = false
    @State private var confirmDelete = false
    @State private var editing: TrainingProgram?
    @State private var errorMessage: String?
    @State private var blockedBySession = false
    /// Nome do destino quando "Adicionar ficha de outro programa" é barrado por treino em andamento.
    @State private var blockedAddingTo: String?
    @State private var addingTo: TrainingProgram?
    @State private var copying: Routine?
    @State private var blockTrigger = 0
    /// Exclusão é feita só depois que a tela sai (evita ler o modelo apagado enquanto ela ainda renderiza).
    @State private var deleteOnDisappear = false

    private var currentActive: TrainingProgram? {
        activePrograms.first { $0.persistentModelID != program.persistentModelID }
    }

    var body: some View {
        if program.isDeleted || program.modelContext == nil {
            Color.clear.accessibilityHidden(true)
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if blockedBySession {
                Section { SessionBlockBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            } else if let blockedAddingTo {
                Section {
                    SessionBlockBanner(addingTo: blockedAddingTo).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    Text(verbatim: program.name).font(FJFont.sectionTitle)
                    if !program.goalText.isEmpty {
                        Text(verbatim: program.goalText).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    }
                    FJFlowLayout(spacing: FJSpacing.s) {
                        FJTag(LocalizedStringKey(program.goal.localizedName), area: .training)
                        FJTag(LocalizedStringKey(program.scheduleMode.localizedName), systemImage: program.scheduleMode.systemImage)
                        FJTag(LocalizedStringKey(program.originText))
                        if program.isActive { FJTag("Ativo", systemImage: "checkmark.circle.fill", tone: .success) }
                        if program.isArchived { FJTag("Arquivado", systemImage: "archivebox") }
                    }
                    Text(verbatim: program.periodText).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    if !program.notes.isEmpty {
                        Text(verbatim: program.notes).font(FJFont.label)
                    }
                }
                .padding(.vertical, FJSpacing.xs)
            }

            Section("Fichas") {
                if program.sortedRoutines.isEmpty {
                    Text("Este programa não tem fichas.").foregroundStyle(FJColor.textSecondary)
                }
                ForEach(program.sortedRoutines) { routine in
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        HStack(spacing: FJSpacing.m) {
                            HStack(spacing: FJSpacing.m) {
                                FJRoutineBadge(symbol: routine.symbol, name: routine.name, colorName: routine.colorName)
                                VStack(alignment: .leading) {
                                    Text(verbatim: routine.name).font(FJFont.cardTitle)
                                    Text(verbatim: routine.summaryText).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: FJSpacing.s)
                            // O "…" é o caminho visível da cópia para outro programa (§4.2.1).
                            Menu {
                                Button("Copiar para outro programa…", systemImage: "doc.on.doc") { copying = routine }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: FJSize.minTap, height: FJSize.minTap)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(Text("Ações de \(routine.name)"))
                        }
                        VStack(alignment: .leading, spacing: FJSpacing.xs) {
                            ForEach(routine.sortedExercises) { item in
                                Text(verbatim: "\(item.displayName.exerciseDisplayName) · \(item.prescriptionText)")
                                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.vertical, FJSpacing.xs)
                }
            }

            Section {
                FJSecondaryButton("Duplicar e editar", systemImage: "plus.square.on.square") { duplicate() }
                if !program.isActive {
                    FJPrimaryButton("Reativar", systemImage: "arrow.uturn.backward") { confirmReactivate = true }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: FJSpacing.xs, leading: 0, bottom: FJSpacing.xs, trailing: 0))
        }
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Adicionar ficha de outro programa", systemImage: "square.and.arrow.down.on.square") {
                        startAdding()
                    }
                    Divider()
                    if !program.isArchived {
                        Button("Arquivar", systemImage: "archivebox") {
                            perform { try ProgramStore(context: context).archive(program) }
                        }
                    }
                    Button("Excluir", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Label("Mais", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $editing) { ProgramEditorSheet(program: $0) }
        .sheet(item: $copying) { CopyRoutineSheet(routine: $0).tint(FJColor.training) }
        .addRoutinesSheet(destination: $addingTo)
        .fjHaptic(.warning, trigger: blockTrigger)
        .confirmationDialog(
            Text("Ativar \(program.name)? \(currentActive?.name ?? String(localized: "O programa atual")) vai para o histórico."),
            isPresented: $confirmReactivate, titleVisibility: .visible
        ) {
            Button("Ativar") { perform { try ProgramStore(context: context).activate(program) } }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(Text("Excluir \(program.name)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir programa", role: .destructive) {
                perform {
                    try ProgramStore(context: context).ensureNoSession(in: program) // falha antes de sair da tela
                    deleteOnDisappear = true
                    dismiss()
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As fichas e prescrições serão apagadas. Os treinos já feitos continuam no histórico.")
        }
        .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onDisappear {
            guard deleteOnDisappear else { return }
            deleteOnDisappear = false
            try? ProgramStore(context: context).delete(program)
        }
    }

    /// Cria a cópia na hora e abre o editor dela; cancelar a edição mantém a cópia (inativa).
    private func duplicate() {
        perform { editing = try ProgramStore(context: context).duplicate(program) }
    }

    /// Fluxo B: a folha não abre com treino em andamento neste programa; o aviso fica no topo da tela.
    private func startAdding() {
        blockedBySession = false
        blockedAddingTo = nil
        do {
            try ProgramStore(context: context).ensureNoSession(in: program)
            addingTo = program
        } catch ProgramStoreError.sessionInProgress {
            blockedAddingTo = program.name
            blockTrigger += 1
        } catch { errorMessage = userMessage(for: error) }
    }

    private func perform(_ work: () throws -> Void) {
        blockedBySession = false
        blockedAddingTo = nil
        do { try work() } catch ProgramStoreError.sessionInProgress {
            blockedBySession = true
        } catch { errorMessage = userMessage(for: error) }
    }
}

#Preview("Programas") {
    NavigationStack { ProgramsListView() }
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}
