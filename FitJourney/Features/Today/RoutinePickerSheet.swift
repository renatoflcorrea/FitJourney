import SwiftData
import SwiftUI

/// "Outra ficha": todas as fichas do programa; as sugeridas vêm marcadas.
struct RoutinePickerSheet: View {
    let program: TrainingProgram
    let suggestedIDs: [UUID]
    let onPick: (Routine) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if program.sortedRoutines.isEmpty {
                    FJEmptyState("Sem fichas", systemImage: "rectangle.stack",
                                 message: "Adicione fichas ao programa na aba Treinos.")
                        .listRowBackground(Color.clear)
                }
                ForEach(program.sortedRoutines) { routine in
                    Button { onPick(routine) } label: {
                        HStack(spacing: FJSpacing.m) {
                            RoutineBadge(routine: routine, size: 40)
                            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                                Text(verbatim: routine.name)
                                    .font(FJFont.cardTitle)
                                    .foregroundStyle(FJColor.textPrimary)
                                Text(verbatim: routine.summaryText)
                                    .font(FJFont.caption)
                                    .foregroundStyle(FJColor.textSecondary)
                            }
                            Spacer(minLength: FJSpacing.s)
                            if suggestedIDs.contains(routine.id) {
                                FJTag("Sugerida", systemImage: "star.fill")
                            }
                        }
                        .frame(minHeight: FJSize.minTap)
                        .contentShape(Rectangle())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Escolher ficha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
