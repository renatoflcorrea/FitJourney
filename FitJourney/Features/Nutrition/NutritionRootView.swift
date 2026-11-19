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
    case mealLog

    var id: String {
        switch self {
        case .log(let entry): "log-\(entry?.id.uuidString ?? "new")"
        case .adjust(let meal): "adjust-\(meal.id)"
        case .newPlan: "newPlan"
        case .calendar: "calendar"
        case .mealLog: "mealLog"
        }
    }
}

struct NutritionDayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mealReminderScheduler) private var scheduler
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?
    @Environment(CoachHandoff.self) private var coachHandoff: CoachHandoff?
    @Environment(AIAvailability.self) private var aiAvailability: AIAvailability?
    @State private var model = NutritionDayModel()
    @AppStorage(AppPreferenceKeys.weekStart) private var weekStartRaw = WeekStart.monday.rawValue
    @State private var sheet: DaySheet?
    @State private var showPlans = false
    @State private var showHistory = false
    @State private var showFavorites = false
    @State private var toggledMeals: Set<UUID> = []
    @State private var entryToDelete: FoodEntry?
    /// Registro com IA: a sessão sobrevive ao "Continuar depois"; o Desfazer vale até sair da tela ou por 12 s.
    @State private var mealSession: MealLogSession?
    @State private var mealStartsWithCamera = false
    @State private var lastUndo: MealLogUndo?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: FJSpacing.cardGap) {
                if aiAvailability.isOn, importCoordinator?.pending(kind: .nutrition).isEmpty == false {
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
        .safeAreaInset(edge: .bottom, spacing: 0) { mealLogInset }
        .navigationTitle("Dieta")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Registrar comida", systemImage: "plus") { sheet = .log(nil) }
            }
            // Menu "…" explícito (antes itens `.secondaryAction`): o mesmo menu do sistema, com identificador para o
            // teste de interface chegar a "Importar com IA".
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Plano", systemImage: "list.bullet.clipboard") { showPlans = true }
                    if aiAvailability.isOn {
                        ImportWithAIMenuItem(kind: .nutrition, identifier: "nutrition.menu.import")
                    }
                    Button("Histórico", systemImage: "calendar") { showHistory = true }
                    Button("Favoritos", systemImage: "star") { showFavorites = true }
                } label: {
                    Label("Mais opções", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("nutrition.menu")
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
                AdjustMealSheet(meal: meal, existing: model.entries(for: meal), onFillWithPhoto: {
                    openMealLog(camera: true, prefill: meal.name.isEmpty ? "" : "\(meal.name): ")
                }) { drafts in
                    model.saveAdjusted(meal, drafts: drafts)
                }
            case .mealLog:
                if let mealSession {
                    MealLogSheet(session: mealSession, startWithCamera: mealStartsWithCamera,
                                 onChangeDay: changeMealLogDay, onApplied: mealLogApplied,
                                 onDiscard: { self.mealSession = nil })
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
        .onReceive(NotificationCenter.default.publisher(for: .fjImportWillUndo)) { _ in showPlans = false }
        .onChange(of: coachHandoff?.request) { _, request in if request != nil { sheet = nil } }
        .task { openImportedPlan() }
        #if DEBUG
        // Capturas/QA (`-fj.seedDemo YES -fj.demoMealLog sheet|review`): abre a folha do registro com IA.
        .task {
            guard StoreDemo.isEnabled, let mode = UserDefaults.standard.string(forKey: "fj.demoMealLog") else { return }
            try? await Task.sleep(for: .milliseconds(800))
            openMealLog(camera: false, prefill: mode == "review" ? String(localized: "Café: 2 ovos mexidos e 1 pão francês com manteiga, café com leite.\nÀ tarde tomei um açaí com granola.") : "")
            if mode == "review", let session = mealSession { try? await session.analyze() }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in model.dayChanged() }
    }

    // MARK: Registro com IA

    /// Barra "O que você comeu?" (só com IA; some em dia futuro) e o aviso de Desfazer, acima da tab bar.
    private var mealLogInset: some View {
        VStack(spacing: FJSpacing.s) {
            if let lastUndo {
                MealLogUndoBanner(message: MealLogPresentation.undoMessage(mealCount: lastUndo.mealCount), onUndo: undoMealLog)
                    .task(id: lastUndo.id) {
                        try? await Task.sleep(for: .seconds(12))
                        if self.lastUndo?.id == lastUndo.id { self.lastUndo = nil }
                    }
            }
            if model.phase != .future {
                MealLogComposerBar(draftSummary: draftSummary,
                                   onText: { openMealLog(camera: false) },
                                   onCamera: { openMealLog(camera: true) })
                    .visibleWhenAIAvailable()
            }
        }
    }

    private var draftSummary: String? {
        guard let mealSession, mealSession.day == Calendar.autoupdatingCurrent.startOfDay(for: model.registrationDate) else { return nil }
        if let review = mealSession.review, mealSession.phase.hasDraft {
            let count = review.includedMeals.count
            return count == 1 ? String(localized: "Continuar rascunho · 1 refeição")
                : String(localized: "Continuar rascunho · \(count) refeições")
        }
        return nil
    }

    private func openMealLog(camera: Bool, prefill: String = "") {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: model.registrationDate)
        if let existing = mealSession, existing.day == day {
            if existing.text.isEmpty { existing.text = prefill }
        } else {
            mealSession = MealLogSessionFactory.make(day: day, context: context, availability: aiAvailability,
                                                     network: importCoordinator?.network, text: prefill)
        }
        mealStartsWithCamera = camera
        sheet = .mealLog
    }

    /// Outro dia no seletor da folha: nova sessão com o mesmo texto e as mesmas fotos.
    private func changeMealLogDay(_ date: Date) {
        guard let old = mealSession else { return }
        let photos = old.photos
        let session = MealLogSessionFactory.make(day: date, context: context, availability: aiAvailability,
                                                 network: importCoordinator?.network, text: old.text)
        mealSession = session
        guard !photos.isEmpty else { return }
        Task {
            try? await session.addPhotos(photos.map { RawAttachment(filename: "foto.jpg", data: $0.jpegData, typeHint: "public.jpeg") })
        }
    }

    private func mealLogApplied(_ undo: MealLogUndo) {
        mealSession = nil
        lastUndo = undo
        if let day = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: undo.day)?.start, day != model.date { model.jump(to: day) }
    }

    private func undoMealLog() {
        guard let undo = lastUndo else { return }
        do {
            try MealLogApplier(context: context).undo(undo)
            lastUndo = nil
            model.reload()
            model.afterChange?()
        } catch {
            model.errorMessage = error.localizedDescription
        }
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
            // `FJCard` não empilha os filhos: sem o `VStack`, cada um virava um cartão próprio dentro do `LazyVStack`.
            FJCard {
                VStack(spacing: FJSpacing.m) {
                    FJEmptyState("Cadastre sua dieta", systemImage: "fork.knife",
                                 message: "Monte refeições e metas para marcar como feitas com 1 toque. Você pode registrar comidas avulsas mesmo sem plano.",
                                 actionTitle: "Criar dieta", area: .nutrition) { sheet = .newPlan }
                    if aiAvailability.isOn { ImportWithAIButton(kind: .nutrition, fillsWidth: false, identifier: "nutrition.empty.import") }
                }
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
