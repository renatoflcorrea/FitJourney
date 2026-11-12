import SwiftData
import SwiftUI

/// Aba Treinos (DESIGN_DIRECTION §4.2): programa ativo, fichas, atalhos e programas anteriores.
struct TrainingRootView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]
    @Query(filter: #Predicate<TrainingProgram> { !$0.isActive && !$0.isArchived },
           sort: \TrainingProgram.startDate, order: .reverse) private var pastPrograms: [TrainingProgram]
    @Query(filter: #Predicate<TrainingProgram> { $0.isArchived }) private var archivedPrograms: [TrainingProgram]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?
    @Environment(CoachHandoff.self) private var coachHandoff: CoachHandoff?

    /// "Agora" da tela: atualizado ao aparecer, ao voltar ao primeiro plano e na virada do dia.
    @State private var now = Date.now
    @State private var path = NavigationPath()
    @State private var blockedBySession = false
    @State private var sheet: Sheet?
    @State private var routineToDelete: Routine?
    @State private var confirmArchive = false
    @State private var errorMessage: String?

    private enum Sheet: Identifiable {
        case newProgram
        case editProgram(TrainingProgram)
        case addRoutine(TrainingProgram)

        var id: String {
            switch self {
            case .newProgram: "new"
            case .editProgram(let p): "edit-\(p.id)"
            case .addRoutine(let p): "routine-\(p.id)"
            }
        }
    }

    private var active: TrainingProgram? { activePrograms.first }
    private var hasAnyProgram: Bool { active != nil || !pastPrograms.isEmpty || !archivedPrograms.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if blockedBySession {
                    Section { SessionBlockBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                if importCoordinator?.pending(kind: .program).isEmpty == false {
                    Section { ImportContinueCard(kind: .program).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                if !hasAnyProgram {
                    firstUseSection
                } else if let active {
                    activeSection(active)
                    routinesSection(active)
                } else {
                    noActiveSection
                }
                shortcutsSection
                if !pastPrograms.isEmpty {
                    pastSection
                }
            }
            .navigationTitle("Treinos")
            .navigationDestination(for: Routine.self) { RoutineEditorView(routine: $0) }
            .navigationDestination(for: TrainingProgram.self) { ProgramDetailView(program: $0) }
            .navigationDestination(for: Shortcut.self) { shortcut in
                switch shortcut {
                case .library: ExerciseLibraryView()
                case .history: WorkoutHistoryView()
                case .programs: ProgramsListView()
                }
            }
            .toolbar { toolbarContent }
            .onAppear {
                now = .now
                #if DEBUG
                // QA/evidências: `-fj.openFirstRoutine YES` abre o editor da primeira ficha.
                if UserDefaults.standard.bool(forKey: "fj.openFirstRoutine"), path.isEmpty,
                   let routine = active?.sortedRoutines.first { path.append(routine) }
                // QA/evidências: `-fj.sessionDemo set|rest|finish` inicia a primeira ficha (rest: conclui a 1ª série; finish: abre o encerramento).
                if let demo = UserDefaults.standard.string(forKey: "fj.sessionDemo"), let coordinator = sessionCoordinator,
                   coordinator.engine.snapshot == nil, let routine = active?.sortedRoutines.first {
                    coordinator.start(routine: routine)
                    if demo != "set", let setID = coordinator.engine.snapshot?.currentSetID {
                        coordinator.send(.completeSet(setID: setID, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil))
                    }
                }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
            .onChange(of: importCoordinator?.route) { openImportedProgram() }
            .onReceive(NotificationCenter.default.publisher(for: .fjImportWillUndo)) { _ in path = NavigationPath() }
            .onChange(of: coachHandoff?.request) { _, request in if request != nil { sheet = nil } }
            .task { openImportedProgram() }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .newProgram: ProgramEditorSheet(program: nil)
                case .editProgram(let program): ProgramEditorSheet(program: program)
                case .addRoutine(let program): RoutineMetaSheet(program: program)
                }
            }
            .confirmationDialog(
                Text("Excluir \(routineToDelete?.name ?? "")?"),
                isPresented: Binding(get: { routineToDelete != nil }, set: { if !$0 { routineToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Excluir ficha", role: .destructive) {
                    if let routine = routineToDelete { perform { try RoutineActions(context: context).delete(routine) } }
                    routineToDelete = nil
                }
                Button("Cancelar", role: .cancel) { routineToDelete = nil }
            } message: {
                Text("Os exercícios e séries desta ficha serão apagados. Os treinos já feitos continuam no histórico.")
            }
            .confirmationDialog(
                Text("Arquivar \(active?.name ?? "")?"), isPresented: $confirmArchive, titleVisibility: .visible
            ) {
                Button("Arquivar") {
                    if let active { perform { try ProgramStore(context: context).archive(active) } }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O programa sai de Hoje e fica em Programas, em Arquivados.")
            }
            .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let active, active.sortedRoutines.count > 1 {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Novo programa", systemImage: "square.stack.3d.up") { sheet = .newProgram }
                if let active {
                    Button("Nova ficha no programa ativo", systemImage: "plus.rectangle.on.rectangle") {
                        sheet = .addRoutine(active)
                    }
                }
                Divider()
                ImportWithAIMenuItem(kind: .program)
                if let active {
                    ImportWithAIMenuItem(kind: .program, target: .existingProgram(active.id), title: "Adicionar fichas com IA")
                }
            } label: {
                Label("Novo", systemImage: "plus")
            }
        }
    }

    // MARK: Seções

    private var firstUseSection: some View {
        Section {
            FJEmptyState("Nenhum programa ainda", systemImage: "dumbbell",
                         message: "Crie seu primeiro programa com as fichas da semana.",
                         actionTitle: "Criar programa") { sheet = .newProgram }
                .listRowBackground(Color.clear)
            ImportWithAIButton(kind: .program)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Button("Começar com um exemplo (ABC)") {
                perform { try SampleProgramFactory.makeStarterABC(in: context, activate: true) }
            }
            .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
        }
    }

    private var noActiveSection: some View {
        Section {
            FJBanner("Nenhum programa ativo",
                     message: "Reative um programa anterior ou crie um novo para ver a sugestão do dia.",
                     tone: .attention, actionTitle: "Criar programa") { sheet = .newProgram }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private func activeSection(_ program: TrainingProgram) -> some View {
        Section {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        Text(verbatim: program.name).font(FJFont.sectionTitle)
                        if !program.goalText.isEmpty {
                            Text(verbatim: program.goalText)
                                .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                    Spacer(minLength: FJSpacing.s)
                    Menu {
                        Button("Editar programa", systemImage: "pencil") { sheet = .editProgram(program) }
                        Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(program) }
                        Button("Arquivar", systemImage: "archivebox", role: .destructive) { confirmArchive = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: FJSize.minTap, height: FJSize.minTap)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Ações do programa"))
                }
                FJFlowLayout(spacing: FJSpacing.s) {
                    FJTag(LocalizedStringKey(program.goal.localizedName), area: .training)
                    FJTag(LocalizedStringKey(program.scheduleMode.localizedName), systemImage: program.scheduleMode.systemImage)
                    if let week = program.weekProgressText(on: now) { FJTag(LocalizedStringKey(week)) }
                }
                if let adherence = try? ProgramStore(context: context).weeklyAdherence(for: program, now: now) {
                    Text("Esta semana: \(adherence.done) de \(adherence.planned) treinos")
                        .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                if program.isExpired(on: now), let end = program.endDate {
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        FJBanner("Este programa terminou em \(end.formatted(.dateTime.day().month(.twoDigits).year()))",
                                 tone: .attention, actionTitle: "Estender") { sheet = .editProgram(program) }
                        Button("Criar novo") { sheet = .newProgram }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: FJSize.minTap)
                    }
                }
            }
            .padding(.vertical, FJSpacing.xs)
            .accessibilityElement(children: .contain)
        }
    }

    private func routinesSection(_ program: TrainingProgram) -> some View {
        let last = (try? ProgramStore(context: context).lastCompletionByRoutine(programID: program.id)) ?? [:]
        return Section {
            if program.sortedRoutines.isEmpty {
                FJEmptyState("Adicione a primeira ficha", systemImage: "rectangle.stack.badge.plus",
                             message: "Cada ficha é um treino do programa, como A, B e C.",
                             actionTitle: "Adicionar ficha") { sheet = .addRoutine(program) }
                    .listRowBackground(Color.clear)
            } else {
                ForEach(program.sortedRoutines) { routine in
                    NavigationLink(value: routine) {
                        RoutineRow(routine: routine, program: program, lastDone: last[routine.id], now: now)
                    }
                    .contextMenu {
                        Button("Iniciar", systemImage: "play.fill") { sessionCoordinator?.start(routine: routine) }
                        NavigationLink(value: routine) { Label("Editar", systemImage: "pencil") }
                        Button("Duplicar", systemImage: "plus.square.on.square") {
                            perform { try RoutineActions(context: context).duplicate(routine) }
                        }
                        if let coachHandoff {
                            Button("Editar com IA", systemImage: "sparkles") {
                                let scope = CoachHandoff.routineDraft(routineName: routine.name, programName: program.name)
                                coachHandoff.open(title: scope.title, draft: scope.draft)
                            }
                        }
                        Button("Excluir", systemImage: "trash", role: .destructive) { routineToDelete = routine }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Excluir", systemImage: "trash", role: .destructive) { routineToDelete = routine }
                        Button("Duplicar", systemImage: "plus.square.on.square") {
                            perform { try RoutineActions(context: context).duplicate(routine) }
                        }
                        .tint(FJColor.coach)
                    }
                }
                .onMove { source, destination in
                    perform { try RoutineActions(context: context).move(in: program, from: source, to: destination) }
                }
            }
            ImportWithAIButton(kind: .program, target: .existingProgram(program.id), title: "Adicionar fichas com IA",
                               fillsWidth: false)
                .listRowBackground(Color.clear)
        } header: {
            FJSectionHeader("Fichas", subtitle: program.scheduleMode == .sequential ? "A ordem define a sequência." : nil,
                            actionTitle: "Adicionar") { sheet = .addRoutine(program) }
                .textCase(nil)
                .listRowInsets(EdgeInsets())
        }
    }

    private var shortcutsSection: some View {
        Section("Atalhos") {
            NavigationLink(value: Shortcut.library) { Label("Biblioteca de exercícios", systemImage: "books.vertical") }
            NavigationLink(value: Shortcut.history) { Label("Histórico", systemImage: "clock.arrow.circlepath") }
            NavigationLink(value: Shortcut.programs) { Label("Programas", systemImage: "square.stack.3d.up") }
        }
    }

    private var pastSection: some View {
        Section("Programas anteriores") {
            ForEach(pastPrograms) { program in
                NavigationLink(value: program) { ProgramRow(program: program) }
            }
        }
    }

    // MARK: Ações

    /// Depois de importar com IA: abre o programa criado (ou o que recebeu as fichas).
    private func openImportedProgram() {
        guard let route = importCoordinator?.route, route.kind == .program else { return }
        let id = route.resultID
        var descriptor = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        importCoordinator?.consumeRoute()
        if let program = try? context.fetch(descriptor).first {
            path = NavigationPath()
            path.append(program)
        }
    }

    enum Shortcut: Hashable { case library, history, programs }

    /// "Duplicar" cria a cópia na hora e abre o editor dela; cancelar a edição mantém a cópia (inativa).
    private func duplicate(_ program: TrainingProgram) {
        do {
            let copy = try ProgramStore(context: context).duplicate(program)
            sheet = .editProgram(copy)
        } catch { errorMessage = userMessage(for: error) }
    }

    private func perform(_ work: () throws -> some Any) {
        blockedBySession = false
        do { _ = try work() } catch ProgramStoreError.sessionInProgress {
            blockedBySession = true
        } catch { errorMessage = userMessage(for: error) }
    }
}

/// Linha de ficha: selo, nome, metadados, dias (semanal) e última execução.
private struct RoutineRow: View {
    let routine: Routine
    let program: TrainingProgram
    let lastDone: Date?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            FJRoutineBadge(symbol: routine.symbol, name: routine.name, colorName: routine.colorName)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text(verbatim: routine.name).font(FJFont.cardTitle)
                Text(verbatim: routine.summaryText)
                    .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                if program.scheduleMode == .weekly {
                    WeekdayDots(weekdays: routine.weekdays, color: routine.routineColor)
                }
                Text(verbatim: lastDoneText(lastDone, now: now))
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                if routine.exerciseCount == 0 {
                    FJTag("Sem exercícios", systemImage: "exclamationmark.triangle.fill", tone: .attention)
                }
            }
        }
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Linha de programa: nome, período, nº de fichas, origem.
struct ProgramRow: View {
    let program: TrainingProgram

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack {
                Text(verbatim: program.name).font(FJFont.cardTitle)
                if program.isArchived { FJTag("Arquivado", systemImage: "archivebox") }
            }
            Text(verbatim: "\(program.periodText) · \(String(localized: "\((program.routines ?? []).count) fichas")) · \(program.originText)")
                .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
        }
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Treinos — com programa") {
    TrainingRootView()
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}

#Preview("Treinos — vazio") {
    TrainingRootView()
        .modelContainer(try! PersistenceController.makeContainer(inMemory: true))
        .tint(FJColor.training)
}
