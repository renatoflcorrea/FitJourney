import SwiftData
import SwiftUI

/// Aba Dieta (SPEC §5, DESIGN §4.9): dia, registro avulso e plano. Tem `NavigationStack` próprio.
struct NutritionRootView: View {
    init() {}

    var body: some View {
        NavigationStack {
            NutritionDayView()
        }
    }
}

private enum DaySheet: Identifiable {
    case log(FoodEntry?)
    case adjust(Meal)
    case newPlan
    case calendar

    var id: String {
        switch self {
        case .log(let entry): "log-\(entry?.id.uuidString ?? "new")"
        case .adjust(let meal): "adjust-\(meal.id)"
        case .newPlan: "newPlan"
        case .calendar: "calendar"
        }
    }
}

struct NutritionDayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mealReminderScheduler) private var scheduler
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?
    @State private var model = NutritionDayModel()
    @AppStorage(AppPreferenceKeys.weekStart) private var weekStartRaw = WeekStart.monday.rawValue
    @State private var sheet: DaySheet?
    @State private var showPlans = false
    @State private var showHistory = false
    @State private var showFavorites = false
    @State private var toggledMeals: Set<UUID> = []
    @State private var entryToDelete: FoodEntry?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: FJSpacing.cardGap) {
                if importCoordinator?.pending(kind: .nutrition).isEmpty == false {
                    ImportContinueCard(kind: .nutrition)
                }
                dayNavigator
                WeekStrip(cells: model.weekStrip) { model.jump(to: $0) }
                if let message = model.errorMessage {
                    FJBanner("Algo deu errado", message: LocalizedStringKey(message), tone: .destructive,
                             systemImage: "exclamationmark.triangle", actionTitle: "Fechar") { model.errorMessage = nil }
                }
                NutritionTotalsCard(totals: model.totals, targets: model.targets, estimatedCount: model.estimatedCount)
                WaterCard(total: model.waterTotal, goal: model.targets.waterMilliliters,
                          isEditable: model.phase != .future,
                          onAdd: model.addCup, onRemove: model.removeCup)
                timeline
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.bottom, FJSpacing.xl)
        }
        .fjScreenBackground()
        .navigationTitle("Dieta")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Registrar comida", systemImage: "plus") { sheet = .log(nil) }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Plano", systemImage: "list.bullet.clipboard") { showPlans = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                ImportWithAIMenuItem(kind: .nutrition)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Histórico", systemImage: "calendar") { showHistory = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Favoritos", systemImage: "star") { showFavorites = true }
            }
        }
        .navigationDestination(isPresented: $showPlans) { NutritionPlanListView() }
        .navigationDestination(isPresented: $showHistory) { NutritionHistoryView { model.jump(to: $0) } }
        .navigationDestination(isPresented: $showFavorites) { NutritionFavoritesView(day: model.registrationDate) }
        .sheet(item: $sheet, onDismiss: { model.reload(); model.afterChange?() }) { sheet in
            switch sheet {
            case .log(let entry):
                LogFoodSheet(day: model.registrationDate, editing: entry)
            case .adjust(let meal):
                AdjustMealSheet(meal: meal, existing: model.entries(for: meal)) { drafts in
                    model.saveAdjusted(meal, drafts: drafts)
                }
            case .newPlan:
                NewPlanSheet()
            case .calendar:
                DayPickerSheet(date: model.date) { model.jump(to: $0) }
            }
        }
        .confirmationDialog("Apagar este registro?", isPresented: Binding(get: { entryToDelete != nil },
                                                                         set: { if !$0 { entryToDelete = nil } }),
                            titleVisibility: .visible, presenting: entryToDelete) { entry in
            Button("Apagar", role: .destructive) { model.delete(entry) }
        }
        .task {
            model.attach(context)
            model.afterChange = { Task { await scheduler?.reschedule(for: context) } }
            model.onMealResolved = { meal, day in Task { await scheduler?.clearNotifications(mealID: meal.id, day: day) } }
        }
        .onAppear { model.reload() }
        .onChange(of: weekStartRaw) { _, _ in model.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload() } }
        .onChange(of: importCoordinator?.route) { openImportedPlan() }
        .task { openImportedPlan() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in model.dayChanged() }
    }

    /// Depois de importar a dieta com IA: abre Plano, onde o plano criado aparece (inativo, a menos que tenha sido ativado).
    private func openImportedPlan() {
        guard let route = importCoordinator?.route, route.kind == .nutrition else { return }
        importCoordinator?.consumeRoute()
        showPlans = true
    }

    // MARK: Navegação de dia

    private var dayNavigator: some View {
        HStack {
            Button { model.shift(by: -1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .accessibilityLabel("Dia anterior")
            Spacer()
            Button { sheet = .calendar } label: {
                Text(model.title)
                    .font(FJFont.cardTitle)
                    .foregroundStyle(FJColor.textPrimary)
                    .frame(minHeight: FJSize.minTap)
            }
            .accessibilityHint("Abre o calendário")
            Spacer()
            Button { model.shift(by: 1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .accessibilityLabel("Próximo dia")
        }
    }

    // MARK: Linha do tempo

    @ViewBuilder private var timeline: some View {
        switch model.coverage {
        case .noPlan:
            FJCard {
                FJEmptyState("Cadastre sua dieta", systemImage: "fork.knife",
                             message: "Monte refeições e metas para marcar como feitas com 1 toque. Você pode registrar comidas avulsas mesmo sem plano.",
                             actionTitle: "Criar dieta", area: .nutrition) { sheet = .newPlan }
                ImportWithAIButton(kind: .nutrition)
            }
        case .outsideVigency(let name):
            FJBanner("Fora da vigência do plano", message: "\(name) não cobre este dia. Registros avulsos continuam funcionando.",
                     systemImage: "calendar.badge.exclamationmark", actionTitle: "Ver plano") { showPlans = true }
        case .covered:
            if !model.hasMealsPlanned {
                Text(model.phase == .today ? "Nenhuma refeição planejada para hoje" : "Nenhuma refeição planejada para este dia")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FJSpacing.xs)
            }
        }
        if !model.timeline.isEmpty {
            FJSectionHeader("Refeições", subtitle: model.phase == .future ? "Plano do dia, somente leitura" : nil)
            VStack(spacing: 0) {
                ForEach(model.timeline) { item in
                    TimelineRow(item: item, hasPlan: model.hasPlan) {
                        switch item {
                        case .meal(let row):
                            MealCard(row: row, phase: model.phase,
                                     isExpanded: isExpanded(row),
                                     onToggle: { toggle(row) },
                                     onDone: { model.markDone(row.meal) },
                                     onAdjust: { sheet = .adjust(row.meal) },
                                     onSkip: { model.skip(row.meal) },
                                     onUndo: { model.undo(row.meal) })
                        case .extra(let entry):
                            ExtraEntryCard(entry: entry, showsOffPlanTag: model.hasPlan)
                                .onTapGesture { sheet = .log(entry) }
                                .contextMenu {
                                    Button("Editar", systemImage: "pencil") { sheet = .log(entry) }
                                    Button("Apagar", systemImage: "trash", role: .destructive) { entryToDelete = entry }
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: "Apagar") { entryToDelete = entry }
                        }
                    }
                }
            }
        }
    }

    private func isExpanded(_ row: MealRowModel) -> Bool {
        (row.display == .next) != toggledMeals.contains(row.id)
    }

    private func toggle(_ row: MealRowModel) {
        if toggledMeals.contains(row.id) { toggledMeals.remove(row.id) } else { toggledMeals.insert(row.id) }
    }
}

/// Calendário para pular para um dia.
private struct DayPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var date: Date
    let onPick: (Date) -> Void

    init(date: Date, onPick: @escaping (Date) -> Void) {
        _date = State(initialValue: date)
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            DatePicker("Dia", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Ir para o dia")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Ir") { onPick(date); dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Dieta — com plano") {
    NutritionRootView()
        .modelContainer(PersistenceController.preview)
}

#Preview("Dieta — sem plano") {
    NutritionRootView()
        .modelContainer((try? PersistenceController.makeContainer(inMemory: true))!)
}
