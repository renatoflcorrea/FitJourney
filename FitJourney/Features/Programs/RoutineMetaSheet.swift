import SwiftData
import SwiftUI

/// Adicionar ficha ao programa (nome, letra, cor e, no modo semanal, dias). Os exercícios são editados no editor de ficha.
struct RoutineMetaSheet: View {
    let program: TrainingProgram
    var onAdded: (Routine) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var symbol = ""
    @State private var color: RoutineColor = .orange
    @State private var weekdays: Set<Weekday> = []
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome da ficha (ex.: A — Peito e tríceps)", text: $name)
                    TextField("Letra do selo (opcional)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: symbol) { _, new in symbol = String(new.prefix(2)) }
                }

                Section("Cor") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: FJSpacing.m) {
                            ForEach(RoutineColor.allCases) { option in
                                Button { color = option } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            if color == option {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(FJColor.onFill)
                                            }
                                        }
                                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(option.localizedName))
                                .accessibilityAddTraits(color == option ? .isSelected : [])
                            }
                        }
                    }
                }

                if program.scheduleMode == .weekly {
                    Section {
                        WeekdayPicker(selection: $weekdays)
                    } header: {
                        Text("Dias da semana")
                    } footer: {
                        Text("A semana começa na segunda. Dois treinos podem cair no mesmo dia.")
                    }
                }
            }
            .navigationTitle("Nova ficha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adicionar", action: add).disabled(trimmedName.isEmpty)
                }
            }
            .alert("Não foi possível salvar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let store = ProgramStore(context: context)
        do {
            let nextIndex = program.sortedRoutines.count
            let letter = symbol.trimmingCharacters(in: .whitespaces).uppercased()
            let routine = try store.addRoutine(
                to: program, name: trimmedName,
                symbol: letter.isEmpty ? String(Character(UnicodeScalar(UInt8(65 + nextIndex % 26)))) : letter,
                weekdays: program.scheduleMode == .weekly ? weekdays : [])
            routine.colorName = color.rawValue
            try context.save()
            onAdded(routine)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Sete botões de dia (semana começa na segunda), alvo mínimo de 44 pt.
struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(verbatim: day.initial)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(on ? FJColor.onFill : FJColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                        .background(on ? FJColor.trainingFill : FJColor.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: day.fullName))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

#Preview("Nova ficha") {
    let container = PersistenceController.preview
    let program = (try? ProgramStore(context: container.mainContext).activeProgram())!
    return RoutineMetaSheet(program: program)
        .modelContainer(container)
        .tint(FJColor.training)
}
