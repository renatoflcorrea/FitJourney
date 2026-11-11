import SwiftData
import SwiftUI

/// Aba Treinos (DESIGN_DIRECTION §4.2): programa ativo, fichas, atalhos e programas anteriores.
struct TrainingRootView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TrainingProgram> { $0.isActive }) private var activePrograms: [TrainingProgram]
    @Query(filter: #Predicate<TrainingProgram> { !$0.isActive && !$0.isArchived },
           sort: \TrainingProgram.startDate, order: .reverse) private var pastPrograms: [TrainingProgram]
    @Query(filter: #Predicate<TrainingProgram> { $0.isArchived }) private var archivedPrograms: [TrainingProgram]
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw == "completed" }) private var completedSessions: [WorkoutSession]

    @State private var sheet: Sheet?
    @State private var routineToDelete: Routine?
    @State private var confirmArchive = false
    @State private var showComingSoon = false
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
        NavigationStack {
            List {
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
            .navigationDestination(for: Routine.self) { RoutineEditorDestination(routine: $0) }
            .navigationDestination(for: TrainingProgram.self) { ProgramDetailView(program: $0) }
            .navigationDestination(for: Shortcut.self) { shortcut in
                switch shortcut {
                case .library: ExerciseLibraryPlaceholder() // TODO(P1.3)
                case .history: HistoryPlaceholder() // TODO(P2.4)
                case .programs: ProgramsListView()
                }
            }
            .toolbar { toolbarContent }
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
            .comingSoonAlert(isPresented: $showComingSoon)
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
            Button("Começar com um exemplo (ABC)") {
                perform { try StarterProgram.make(in: context) }
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
                FlowRow {
                    FJTag(LocalizedStringKey(program.goal.localizedName), area: .training)
                    FJTag(LocalizedStringKey(program.scheduleMode.localizedName), systemImage: program.scheduleMode.systemImage)
                    if let week = program.weekProgressText { FJTag(LocalizedStringKey(week)) }
                }
                if let adherence = program.weeklyAdherence(sessions: completedSessions) {
                    Text("Esta semana: \(adherence.done) de \(adherence.planned) treinos")
                        .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                if program.isExpired, let end = program.endDate {
                    FJBanner("Este programa terminou em \(end.formatted(.dateTime.day().month(.twoDigits).year()))",
                             tone: .attention, actionTitle: "Estender") { sheet = .editProgram(program) }
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
                        RoutineRow(routine: routine, program: program, lastDone: last[routine.id])
                    }
                    .contextMenu {
                        Button("Iniciar", systemImage: "play.fill") { showComingSoon = true } // TODO(P2.2)
                        NavigationLink(value: routine) { Label("Editar", systemImage: "pencil") }
                        Button("Duplicar", systemImage: "plus.square.on.square") {
                            perform { try RoutineActions(context: context).duplicate(routine) }
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

    enum Shortcut: Hashable { case library, history, programs }

    private func duplicate(_ program: TrainingProgram) {
        do {
            let copy = try ProgramStore(context: context).duplicate(program)
            sheet = .editProgram(copy)
        } catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ work: () throws -> some Any) {
        do { _ = try work() } catch { errorMessage = error.localizedDescription }
    }
}

/// Linha de ficha: selo, nome, metadados, dias (semanal) e última execução.
private struct RoutineRow: View {
    let routine: Routine
    let program: TrainingProgram
    let lastDone: Date?

    var body: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            RoutineBadge(routine: routine)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text(verbatim: routine.name).font(FJFont.cardTitle)
                Text(verbatim: routine.summaryText)
                    .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                if program.scheduleMode == .weekly {
                    WeekdayDots(weekdays: routine.weekdays, tint: routine.routineColor.color)
                }
                Text(verbatim: lastDoneText(lastDone))
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

/// Linha que quebra para a seguinte quando falta espaço (etiquetas do programa).
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: FJSpacing.s) { content }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
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
