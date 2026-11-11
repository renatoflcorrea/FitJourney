import SwiftData
import SwiftUI

/// Aba Hoje (DESIGN_DIRECTION §4.1). Neste pacote só o cartão do treino do dia; dieta e saúde entram nos outros pacotes.
struct TodayView: View {
    /// Leva o usuário à aba Treinos (usado pelos estados vazios).
    var onOpenTraining: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]
    @Query private var allPrograms: [TrainingProgram]
    /// Só para reavaliar a sugestão quando uma sessão termina.
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw == "completed" }) private var completedSessions: [WorkoutSession]

    @State private var showPicker = false
    @State private var showComingSoon = false
    @State private var errorMessage: String?

    private var active: TrainingProgram? { activePrograms.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FJSpacing.cardGap) {
                    workoutSection
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.bottom, FJSpacing.xl)
            }
            .fjScreenBackground()
            .navigationTitle("Hoje")
            .navigationSubtitle(Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide)))
            .sheet(isPresented: $showPicker) {
                if let active {
                    RoutinePickerSheet(program: active, suggestedIDs: suggestion?.routineIDs ?? []) { routine in
                        showPicker = false
                        startWorkout(routine)
                    }
                }
            }
            .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .comingSoonAlert(isPresented: $showComingSoon)
        }
    }

    // MARK: Treino do dia

    private var suggestion: ScheduleSuggestion? {
        guard let active else { return nil }
        return try? ProgramStore(context: context).todaySuggestion(for: active)
    }

    @ViewBuilder
    private var workoutSection: some View {
        if allPrograms.isEmpty {
            firstUseCard
        } else if let active {
            programCards(active)
        } else {
            FJCard {
                FJEmptyState("Nenhum programa ativo", systemImage: "dumbbell",
                             message: "Ative um programa na aba Treinos para ver o treino do dia.",
                             actionTitle: "Ver programas", action: onOpenTraining)
            }
            freeWorkoutButton
        }
    }

    /// Primeiro uso (D4): sem programa, sem permissões, sem tela de boas-vindas.
    private var firstUseCard: some View {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                VStack(spacing: FJSpacing.m) {
                    FJEmptyState("Monte seu primeiro programa", systemImage: "dumbbell",
                                 message: "Fichas A, B, C… com os exercícios de cada dia. O app sugere o treino de hoje.")
                    VStack(spacing: FJSpacing.s) {
                        FJPrimaryButton("Começar com um exemplo (ABC)", systemImage: "sparkles") {
                            do { try StarterProgram.make(in: context) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        FJSecondaryButton("Criar do zero", systemImage: "plus") { createFromScratch = true }
                        FJSecondaryButton("Criar com IA — em breve", systemImage: "wand.and.stars") {}
                            .disabled(true)
                            .accessibilityHint(Text("Disponível em uma próxima versão"))
                    }
                }
            }
            freeWorkoutButton
        }
        .sheet(isPresented: $createFromScratch) { ProgramEditorSheet(program: nil) }
    }

    @State private var createFromScratch = false

    @ViewBuilder
    private func programCards(_ program: TrainingProgram) -> some View {
        let routines = program.sortedRoutines
        let last = (try? ProgramStore(context: context).lastCompletionByRoutine(programID: program.id)) ?? [:]
        switch suggestion {
        case .routine(let id):
            if let routine = routines.first(where: { $0.id == id }) {
                TodayWorkoutCard(program: program, routine: routine, lastDone: last[routine.id],
                                 badge: program.scheduleMode == .sequential ? "Próxima da sequência" : "Há mais tempo",
                                 isPrimary: true, onStart: startWorkout, onOther: { showPicker = true })
                freeWorkoutButton
            }
        case .routines(let ids):
            let todays = ids.compactMap { id in routines.first { $0.id == id } }
            ForEach(Array(todays.enumerated()), id: \.element.id) { index, routine in
                TodayWorkoutCard(program: program, routine: routine, lastDone: last[routine.id],
                                 badge: "Treino de hoje", isPrimary: index == 0,
                                 onStart: startWorkout, onOther: { showPicker = true })
            }
            freeWorkoutButton
        case .rest:
            restCard(program, routines: routines)
        case .noRoutines, nil:
            FJCard {
                FJEmptyState("Adicione a primeira ficha", systemImage: "rectangle.stack.badge.plus",
                             message: "\(program.name) ainda não tem fichas.",
                             actionTitle: "Abrir Treinos", action: onOpenTraining)
            }
            freeWorkoutButton
        }
    }

    private func restCard(_ program: TrainingProgram, routines: [Routine]) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text(verbatim: program.name + (program.weekProgressText.map { " · \($0)" } ?? ""))
                    .font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                Label("Descanso", systemImage: "moon.zzz.fill").font(FJFont.cardTitle)
                if let next = nextWeeklyWorkout(routines) {
                    Text("Próximo treino: \(next.day.fullName) — \(next.routine.name)")
                        .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                } else {
                    Text("Nenhuma ficha tem dia marcado. Defina os dias em Treinos.")
                        .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                FJSecondaryButton("Treinar mesmo assim", systemImage: "figure.strengthtraining.traditional") { showPicker = true }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var freeWorkoutButton: some View {
        FJSecondaryButton("Treino livre", systemImage: "plus") { startWorkout(nil) }
    }

    private func nextWeeklyWorkout(_ routines: [Routine]) -> (day: Weekday, routine: Routine)? {
        let today = Weekday(date: .now)
        for offset in 1...7 {
            let day = Weekday(calendarWeekday: today.calendarWeekday + offset)
            if let routine = routines.first(where: { $0.weekdays.contains(day) }) { return (day, routine) }
        }
        return nil
    }

    /// TODO(P2.2): iniciar a sessão de verdade (`SessionStore.start`) e abrir a tela de treino.
    /// `routine == nil` = treino livre.
    private func startWorkout(_ routine: Routine?) {
        showComingSoon = true
    }
}

#Preview("Hoje — com programa") {
    TodayView()
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}

#Preview("Hoje — primeiro uso") {
    TodayView()
        .modelContainer(try! PersistenceController.makeContainer(inMemory: true))
        .tint(FJColor.training)
}
