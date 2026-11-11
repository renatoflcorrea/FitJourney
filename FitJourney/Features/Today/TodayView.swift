import SwiftData
import SwiftUI

/// Aba Hoje (DESIGN_DIRECTION §4.1). Neste pacote só o cartão do treino do dia; dieta e saúde entram nos outros pacotes.
struct TodayView: View {
    /// Leva o usuário à aba Treinos (usado pelos estados vazios).
    var onOpenTraining: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]
    /// Só para saber se existe algum programa (primeiro uso x "nenhum ativo"); busca no máximo um.
    @Query(TodayView.anyProgramDescriptor) private var anyProgram: [TrainingProgram]

    /// "Agora" da tela: atualizado ao voltar ao primeiro plano e na virada do dia (a sugestão depende da data).
    @State private var now = Date.now
    @State private var showPicker = false
    @State private var createFromScratch = false
    @State private var errorMessage: String?

    private static var anyProgramDescriptor: FetchDescriptor<TrainingProgram> {
        var descriptor = FetchDescriptor<TrainingProgram>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Tudo que o cartão precisa, lido uma vez por renderização.
    private enum Content {
        case firstUse
        case noActive
        case failed
        case program(TrainingProgram, ScheduleSuggestion, [UUID: Date])
    }

    var body: some View {
        let content = loadContent()
        NavigationStack {
            ScrollView {
                VStack(spacing: FJSpacing.cardGap) {
                    workoutSection(content)
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.bottom, FJSpacing.xl)
            }
            .fjScreenBackground()
            .navigationTitle("Hoje")
            .navigationSubtitle(Text(now, format: .dateTime.weekday(.wide).day().month(.wide)))
            .sheet(isPresented: $showPicker) {
                if case .program(let program, let suggestion, _) = content {
                    RoutinePickerSheet(program: program, suggestedIDs: suggestion.routineIDs) { routine in
                        showPicker = false
                        startWorkout(routine)
                    }
                }
            }
            .sheet(isPresented: $createFromScratch) { ProgramEditorSheet(program: nil) }
            .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .onAppear { now = .now }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
    }

    // MARK: Dados

    private func loadContent() -> Content {
        guard let program = activePrograms.first else {
            return anyProgram.isEmpty ? .firstUse : .noActive
        }
        let store = ProgramStore(context: context)
        do {
            let suggestion = try store.todaySuggestion(for: program, on: now)
            let last = try store.lastCompletionByRoutine(programID: program.id)
            return .program(program, suggestion, last)
        } catch {
            return .failed
        }
    }

    // MARK: Treino do dia

    @ViewBuilder
    private func workoutSection(_ content: Content) -> some View {
        switch content {
        case .firstUse:
            firstUseCard
        case .noActive:
            FJCard {
                FJEmptyState("Nenhum programa ativo", systemImage: "dumbbell",
                             message: "Ative um programa na aba Treinos para ver o treino do dia.",
                             actionTitle: "Ver programas", action: onOpenTraining)
            }
            freeWorkoutButton
        case .failed:
            FJBanner("Não foi possível ler seus treinos",
                     message: "Seus dados continuam salvos. Tente de novo.",
                     tone: .destructive, actionTitle: "Tentar de novo") { now = .now }
            freeWorkoutButton
        case .program(let program, let suggestion, let last):
            if program.isExpired(on: now), let end = program.endDate {
                FJBanner("Este programa terminou em \(end.formatted(.dateTime.day().month(.twoDigits).year()))",
                         message: "Estenda a data de fim ou crie um novo programa em Treinos.",
                         tone: .attention, actionTitle: "Abrir Treinos", action: onOpenTraining)
            }
            programCards(program, suggestion: suggestion, last: last)
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
                            do { try SampleProgramFactory.makeStarterABC(in: context, activate: true) }
                            catch { errorMessage = userMessage(for: error) }
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
    }

    @ViewBuilder
    private func programCards(_ program: TrainingProgram, suggestion: ScheduleSuggestion, last: [UUID: Date]) -> some View {
        let routines = program.sortedRoutines
        switch suggestion {
        case .routine(let id):
            if let routine = routines.first(where: { $0.id == id }) {
                TodayWorkoutCard(program: program, routine: routine, lastDone: last[routine.id], now: now,
                                 badge: program.scheduleMode == .sequential ? "Próxima da sequência" : "Há mais tempo",
                                 isPrimary: true, onStart: startWorkout, onOther: { showPicker = true })
            }
            freeWorkoutButton
        case .routines(let ids):
            let todays = ids.compactMap { id in routines.first { $0.id == id } }
            ForEach(Array(todays.enumerated()), id: \.element.id) { index, routine in
                TodayWorkoutCard(program: program, routine: routine, lastDone: last[routine.id], now: now,
                                 badge: "Treino de hoje", isPrimary: index == 0,
                                 onStart: startWorkout, onOther: { showPicker = true })
            }
            freeWorkoutButton
        case .rest:
            restCard(program)
        case .noRoutines:
            FJCard {
                FJEmptyState("Adicione a primeira ficha", systemImage: "rectangle.stack.badge.plus",
                             message: "\(program.name) ainda não tem fichas.",
                             actionTitle: "Abrir Treinos", action: onOpenTraining)
            }
            freeWorkoutButton
        }
    }

    private func restCard(_ program: TrainingProgram) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text(verbatim: program.name + (program.weekProgressText(on: now).map { " · \($0)" } ?? ""))
                    .font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                Label("Descanso", systemImage: "moon.zzz.fill").font(FJFont.cardTitle)
                if let next = ProgramStore(context: context).nextWeeklyWorkout(for: program, after: now) {
                    Text("Próximo treino: \(next.weekday.fullName) — \(next.routine.name)")
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

    /// Inicia (ou reabre, se já houver uma em andamento) a sessão e abre a tela de treino.
    /// `routine == nil` = treino livre.
    private func startWorkout(_ routine: Routine?) {
        sessionCoordinator?.start(routine: routine)
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
