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
    @State private var color: FJRoutineColor
    @State private var weekdays: Set<Weekday> = []
    @State private var error: String?

    init(program: TrainingProgram, onAdded: @escaping (Routine) -> Void = { _ in }) {
        self.program = program
        self.onAdded = onAdded
        _color = State(initialValue: FJRoutineColor.suggested(forIndex: program.sortedRoutines.count))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Dias já marcados em outras fichas do programa → nomes dessas fichas.
    private var usedDays: [Weekday: [String]] {
        var result: [Weekday: [String]] = [:]
        for routine in program.sortedRoutines {
            for day in routine.weekdays { result[day, default: []].append(routine.name) }
        }
        return result
    }

    /// Aviso "dia já usado por outra ficha" para os dias escolhidos que colidem.
    private var conflictText: String? {
        let clashes = weekdays.sorted().compactMap { day in usedDays[day].map { (day, $0) } }
        guard !clashes.isEmpty else { return nil }
        let list = clashes.map { "\($0.0.shortName) (\($0.1.joined(separator: ", ")))" }.joined(separator: "; ")
        return String(localized: "Dia já usado por outra ficha: \(list). Os dois treinos aparecem no mesmo dia.")
    }

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
                    FJRoutineColorPicker(selection: $color)
                }

                if program.scheduleMode == .weekly {
                    Section {
                        WeekdayPicker(selection: $weekdays, usedByOthers: Set(usedDays.keys))
                    } header: {
                        Text("Dias da semana")
                    } footer: {
                        VStack(alignment: .leading, spacing: FJSpacing.xs) {
                            Text("A semana começa na segunda. Dois treinos podem cair no mesmo dia.")
                            if let conflict = conflictText {
                                Label(conflict, systemImage: "info.circle.fill")
                            }
                        }
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

/// Sete botões de dia (semana começa como em Ajustes, segunda por padrão), alvo mínimo de 44 pt.
/// Dia já usado por outra ficha leva um ponto e é anunciado pelo VoiceOver; pode ser compartilhado.
struct WeekdayPicker: View {
    @AppStorage(AppPreferenceKeys.weekStart) private var weekStartRaw = WeekStart.monday.rawValue
    @Binding var selection: Set<Weekday>
    var usedByOthers: Set<Weekday> = []

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            ForEach(Weekday.ordered(startingOn: WeekStart(rawValue: weekStartRaw) ?? .monday), id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(verbatim: day.initial)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(on ? FJColor.onFill : FJColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                        .background(on ? FJColor.trainingFill : FJColor.fill, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if usedByOthers.contains(day) {
                                Circle()
                                    .fill(FJColor.attention)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: day.fullName))
                .accessibilityValue(usedByOthers.contains(day) ? Text("já usado por outra ficha") : Text(verbatim: ""))
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
