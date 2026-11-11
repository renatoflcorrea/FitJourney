import SwiftUI

/// Cartão do treino do dia (DESIGN_DIRECTION §4.1, cartão 1): sobrelinha, selo + nome, metadados,
/// até 3 exercícios com prescrição, "Iniciar treino" e "Outra ficha".
struct TodayWorkoutCard: View {
    let program: TrainingProgram
    let routine: Routine
    let lastDone: Date?
    let badge: LocalizedStringKey
    let isPrimary: Bool
    let onStart: (Routine?) -> Void
    let onOther: () -> Void

    private var exercises: [RoutineExercise] { routine.sortedExercises }

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text(verbatim: program.name + (program.weekProgressText.map { " · \($0)" } ?? ""))
                    .font(FJFont.overline)
                    .foregroundStyle(FJColor.textSecondary)

                HStack(alignment: .center, spacing: FJSpacing.m) {
                    RoutineBadge(routine: routine, size: 52)
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        Text(verbatim: routine.name).font(FJFont.cardTitle)
                        FJTag(badge, systemImage: "arrow.forward.circle.fill")
                    }
                }
                .accessibilityElement(children: .combine)

                Text(verbatim: "\(routine.summaryText) · \(lastDoneText(lastDone))")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)

                if exercises.isEmpty {
                    FJBanner("Esta ficha ainda não tem exercícios",
                             message: "Adicione exercícios em Treinos. Você pode iniciar um treino livre com o nome da ficha.",
                             tone: .attention)
                } else {
                    VStack(alignment: .leading, spacing: FJSpacing.s) {
                        ForEach(exercises.prefix(3)) { item in
                            exerciseLine(item)
                        }
                        if exercises.count > 3 {
                            Text("+\(exercises.count - 3) exercícios")
                                .font(FJFont.caption)
                                .foregroundStyle(FJColor.textSecondary)
                        }
                    }
                }

                VStack(spacing: FJSpacing.s) {
                    if isPrimary {
                        FJPrimaryButton("Iniciar treino", systemImage: "play.fill") { onStart(routine) }
                    } else {
                        FJSecondaryButton("Iniciar treino", systemImage: "play.fill") { onStart(routine) }
                    }
                    if isPrimary {
                        FJSecondaryButton("Outra ficha", systemImage: "list.bullet", action: onOther)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func exerciseLine(_ item: RoutineExercise) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
            Text(verbatim: item.displayName)
                .font(FJFont.body)
                .lineLimit(2)
            Spacer(minLength: FJSpacing.s)
            Text(verbatim: item.prescriptionText)
                .font(FJFont.numberCaption)
                .foregroundStyle(FJColor.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
