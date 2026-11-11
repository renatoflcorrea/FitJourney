import SwiftData
import SwiftUI

/// Criar/editar programa (sheet `.large`): nome, objetivo, modo de agenda, datas, notas e ativação.
struct ProgramEditorSheet: View {
    /// `nil` = novo programa.
    let program: TrainingProgram?
    var onSaved: (TrainingProgram) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]
    @Query private var allPrograms: [TrainingProgram]

    @State private var name = ""
    @State private var goal: ProgramGoal = .hypertrophy
    @State private var goalText = ""
    @State private var mode: ScheduleMode = .sequential
    @State private var startDate = Date.now
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: .now) ?? .now
    @State private var notes = ""
    @State private var activate = true
    @State private var confirmActivation = false
    @State private var showNameError = false
    @State private var saveError: String?

    private var otherActive: TrainingProgram? {
        activePrograms.first { $0.persistentModelID != program?.persistentModelID }
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNameValid: Bool { !trimmedName.isEmpty }
    private var isEditing: Bool { program != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome do programa", text: $name)
                        .accessibilityLabel(Text("Nome do programa"))
                } footer: {
                    if showNameError && !isNameValid {
                        Label("Dê um nome ao programa", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(FJColor.destructive)
                    }
                }

                Section("Objetivo") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: FJSpacing.s) {
                            HStack(spacing: FJSpacing.s) {
                                ForEach(ProgramGoal.allCases, id: \.self) { option in
                                    FJFilterChip(LocalizedStringKey(option.localizedName), isSelected: goal == option) {
                                        goal = option
                                    }
                                }
                            }
                            .padding(.vertical, FJSpacing.xs)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: FJSpacing.l, bottom: 0, trailing: FJSpacing.l))
                    TextField("Detalhe do objetivo (opcional)", text: $goalText, axis: .vertical)
                }

                Section {
                    ForEach(ScheduleMode.allCases, id: \.self) { option in
                        ScheduleModeOption(mode: option, isSelected: mode == option) { mode = option }
                    }
                } header: {
                    Text("Modo de agenda")
                } footer: {
                    Text("Define o que a aba Hoje sugere. Você pode trocar depois.")
                }

                Section("Datas") {
                    DatePicker("Início", selection: $startDate, displayedComponents: .date)
                    Toggle("Tem data de fim", isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker("Fim", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }

                Section("Observações") {
                    TextField("Notas (opcional)", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Toggle("Tornar o programa ativo", isOn: $activate)
                } footer: {
                    if let current = otherActive, activate {
                        Text("\(current.name) vai para o histórico.")
                    } else if program?.isActive == true {
                        Text("Este é o programa ativo.")
                    }
                }
                .disabled(program?.isActive == true)
            }
            .navigationTitle(isEditing ? "Editar programa" : "Novo programa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: trySave)
                        .disabled(!isNameValid)
                }
            }
            .confirmationDialog(
                otherActive.map { Text("Ativar \(trimmedName) agora? \($0.name) vai para o histórico.") } ?? Text("Ativar agora?"),
                isPresented: $confirmActivation, titleVisibility: .visible
            ) {
                Button("Ativar") { save(activating: true) }
                Button("Só salvar") { save(activating: false) }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Não foi possível salvar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear(perform: load)
        .presentationDetents([.large])
    }

    private func load() {
        if let program {
            name = program.name
            goal = program.goal
            goalText = program.goalText
            mode = program.scheduleMode
            startDate = program.startDate
            hasEndDate = program.endDate != nil
            if let end = program.endDate { endDate = end }
            notes = program.notes
            activate = program.isActive
        } else {
            // Primeiro programa é ativado sem perguntar (fluxo 5.1); com outro ativo, o padrão é "só salvar".
            activate = otherActive == nil
        }
    }

    private func trySave() {
        guard isNameValid else { showNameError = true; return }
        if !isEditing, activate, otherActive != nil {
            confirmActivation = true
        } else {
            save(activating: activate)
        }
    }

    private func save(activating: Bool) {
        let store = ProgramStore(context: context)
        do {
            let target: TrainingProgram
            if let program {
                target = program
            } else {
                target = try store.createProgram(name: trimmedName, goal: goal, scheduleMode: mode,
                                                 startDate: startDate, origin: .manual)
            }
            target.name = trimmedName
            target.goal = goal
            target.goalText = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
            target.scheduleMode = mode
            target.startDate = startDate
            target.endDate = hasEndDate ? max(endDate, startDate) : nil
            target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            target.updatedAt = .now
            if activating && !target.isActive {
                try store.activate(target)
            } else {
                try context.save()
            }
            onSaved(target)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Cartão de opção do modo de agenda: símbolo, título, uma frase e check.
private struct ScheduleModeOption: View {
    let mode: ScheduleMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                Image(systemName: mode.systemImage)
                    .font(.title3)
                    .foregroundStyle(FJColor.training)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(verbatim: mode.localizedName)
                        .font(FJFont.cardTitle)
                        .foregroundStyle(FJColor.textPrimary)
                    Text(mode.explanation)
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: FJSpacing.s)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? FJColor.training : FJColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: FJSize.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Novo programa") {
    ProgramEditorSheet(program: nil)
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}
