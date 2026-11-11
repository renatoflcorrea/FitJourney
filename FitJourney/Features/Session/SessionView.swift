import SwiftData
import SwiftUI

/// Tela da sessão de treino (SPEC §4.2, DESIGN_DIRECTION §4.5): barra superior só de leitura,
/// lista de exercícios (o atual expandido) e doca de ação na base. Toda escrita vai pelo
/// `SessionCoordinator` → `SessionEngine`.
struct SessionView: View {
    let coordinator: SessionCoordinator

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var restDismissedFor: Date?
    @State private var advanceTo: UUID?
    @State private var expandedExtra: Set<UUID> = []
    @State private var catalog: [UUID: SessionCatalogInfo] = [:]

    @State private var picker: PickerPurpose?
    @State private var media: MediaItem?
    @State private var skipping: UUID?
    @State private var editing: SessionSnapshot.ExerciseSet?
    @State private var progressExercise: UUID?
    @State private var showsReorder = false
    @State private var showsFinish = false
    @State private var confirmsDiscard = false
    @State private var bannerDismissed = false

    private var engine: SessionEngine { coordinator.engine }

    enum PickerPurpose: Identifiable {
        case add
        case substitute(UUID)
        var id: String {
            switch self {
            case .add: "add"
            case .substitute(let id): "sub-\(id)"
            }
        }
    }

    struct MediaItem: Identifiable {
        let media: MediaRef
        var id: MediaRef { media }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = engine.snapshot {
                    content(snapshot)
                } else {
                    FJLoadingState("Abrindo treino…")
                }
            }
            .fjScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(isPresented: $showsFinish) {
                SessionFinishView(coordinator: coordinator)
            }
        }
        .tint(FJColor.training)
        .sheet(item: $picker) { purpose in
            ExercisePicker(allowsMultiple: purpose.allowsMultiple) { picked in
                apply(picked, for: purpose)
            }
        }
        .sheet(item: $media) { ExerciseMediaViewer(media: $0.media) }
        .sheet(item: $editing) { set in
            if let snapshot = engine.snapshot, let exercise = snapshot.exercises.first(where: { $0.sets.contains { $0.id == set.id } }) {
                SessionSetEditSheet(coordinator: coordinator, exercise: exercise, set: set)
            }
        }
        .sheet(item: $progressExercise.identified) { item in
            NavigationStack {
                ExerciseProgressView(exerciseID: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fechar") { progressExercise = nil }
                        }
                    }
            }
            .tint(FJColor.training)
        }
        .sheet(isPresented: $showsReorder) {
            if let snapshot = engine.snapshot {
                SessionReorderSheet(coordinator: coordinator, exercises: snapshot.exercises)
            }
        }
        .confirmationDialog("Motivo", isPresented: skipDialogBinding, titleVisibility: .visible) {
            skipButtons
        } message: {
            Text("Por que pular este exercício? (opcional)")
        }
        .confirmationDialog("Descartar este treino?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Descartar treino", role: .destructive) { coordinator.send(.discard) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Nada será salvo no histórico.")
        }
        .alert("Avisar quando o descanso acabar?", isPresented: Bindable(coordinator).showsNotificationRationale) {
            Button("Agora não", role: .cancel) {}
            Button("Ativar avisos") { Task { await coordinator.confirmNotificationPermission() } }
        } message: {
            Text("Com o celular bloqueado ou o app em segundo plano, uma notificação avisa que o descanso terminou. Só usamos isso para o descanso entre séries.")
        }
        .task(id: engine.snapshot?.exercises.map { "\($0.id)\($0.exerciseID?.uuidString ?? "")" }.joined()) {
            loadCatalog()
        }
        .task(id: engine.snapshot?.restEndsAt) { await dismissFinishedRestLater() }
        .onChange(of: engine.snapshot?.currentExerciseID) { old, new in advanceIfFinished(from: old, to: new) }
        .task { await coordinator.refreshNotificationAuthorization() }
    }

    // MARK: Conteúdo

    @ViewBuilder
    private func content(_ snapshot: SessionSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: FJSpacing.cardGap) {
                    banners
                    if snapshot.exercises.isEmpty {
                        FJEmptyState(
                            "Adicione o primeiro exercício",
                            systemImage: "dumbbell",
                            message: "Treino livre: escolha os exercícios na hora e registre as séries.",
                            actionTitle: nil
                        )
                        .padding(.top, FJSpacing.xxl)
                    }
                    ForEach(snapshot.exercises) { exercise in
                        exerciseBlock(exercise, snapshot: snapshot)
                    }
                    if !snapshot.exercises.isEmpty {
                        Button { picker = .add } label: {
                            Label("Adicionar exercício", systemImage: "plus")
                        }
                        .buttonStyle(.fjSecondary())
                        .padding(.top, FJSpacing.s)
                    }
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.top, FJSpacing.s)
                .padding(.bottom, FJSpacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) { progressBar(snapshot) }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock(snapshot) }
            .onChange(of: snapshot.currentExerciseID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : FJMotion.structure) { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let id = snapshot.currentExerciseID { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if coordinator.notificationAuthorization == .denied, !bannerDismissed {
            FJBanner(
                "Avisos de descanso desativados",
                message: "Você ainda sente a vibração com o app aberto. Para ser avisado com a tela bloqueada, ative as notificações.",
                tone: .neutral,
                systemImage: "bell.slash",
                actionTitle: "Abrir Ajustes"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                bannerDismissed = true
            }
        }
        if engine.lastPersistenceError != nil || coordinator.lastRejection == .persistenceFailed {
            FJBanner("Não foi possível salvar", message: "Tente de novo. Nada foi perdido.", tone: .destructive)
        }
    }

    private func progressBar(_ snapshot: SessionSnapshot) -> some View {
        ProgressView(value: SessionPresentation.progressFraction(snapshot))
            .progressViewStyle(.linear)
            .tint(FJColor.training)
            .scaleEffect(x: 1, y: 0.5, anchor: .center)
            .padding(.horizontal, 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func exerciseBlock(_ exercise: SessionSnapshot.Exercise, snapshot: SessionSnapshot) -> some View {
        let isCurrent = exercise.id == snapshot.currentExerciseID
        let isOpen = exercise.status == .pending || exercise.status == .inProgress
        let isExpanded = (isCurrent && isOpen) || expandedExtra.contains(exercise.id)
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            if SessionPresentation.isFirstInGroup(exercise, in: snapshot.exercises),
               let label = SessionPresentation.groupLabel(for: exercise, in: snapshot.exercises) {
                Label(label, systemImage: "link")
                    .font(FJFont.overline)
                    .foregroundStyle(FJColor.training)
                    .padding(.horizontal, FJSpacing.xs)
            }
            SessionExerciseCard(
                coordinator: coordinator,
                exercise: exercise,
                snapshot: snapshot,
                info: catalog[exercise.id],
                isExpanded: isExpanded,
                isCurrent: isCurrent && isOpen,
                onHeaderTap: { headerTapped(exercise, isOpen: isOpen, isExpanded: isExpanded) },
                onMedia: { if let item = catalog[exercise.id]?.media { media = MediaItem(media: item) } },
                onSubstitute: { picker = .substitute(exercise.id) },
                onSkip: { skipping = exercise.id },
                onProgress: { progressExercise = exercise.exerciseID },
                onEditSet: { editing = $0 }
            )
        }
        .overlay(alignment: .leading) {
            if exercise.groupID != nil {
                Capsule().fill(FJColor.training).frame(width: 3).padding(.vertical, FJSpacing.s).offset(x: -FJSpacing.s)
                    .accessibilityHidden(true)
            }
        }
        .id(exercise.id)
    }

    private func headerTapped(_ exercise: SessionSnapshot.Exercise, isOpen: Bool, isExpanded: Bool) {
        if isOpen {
            coordinator.send(.focusExercise(exerciseID: exercise.id))
        } else if expandedExtra.contains(exercise.id) {
            expandedExtra.remove(exercise.id)
        } else {
            expandedExtra.insert(exercise.id)
        }
    }

    // MARK: Doca

    @ViewBuilder
    private func dock(_ snapshot: SessionSnapshot) -> some View {
        let mode = SessionPresentation.dockMode(
            snapshot: snapshot, now: .now, restDismissedFor: restDismissedFor, advanceTo: advanceTo)
        SessionDock(
            mode: mode,
            coordinator: coordinator,
            onAddExercise: { picker = .add },
            onContinueAfterRest: { restDismissedFor = snapshot.restEndsAt },
            onAdvance: { advanceTo = nil },
            onFinish: { showsFinish = true }
        )
        .fjAnimation(FJMotion.structure, value: mode)
    }

    private func dismissFinishedRestLater() async {
        guard let end = engine.snapshot?.restEndsAt else { return }
        let wait = end.addingTimeInterval(SessionPresentation.restFinishedLinger).timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        restDismissedFor = end
    }

    private func advanceIfFinished(from old: UUID?, to new: UUID?) {
        guard let old, let new, old != new, let snapshot = engine.snapshot,
              let previous = snapshot.exercises.first(where: { $0.id == old }),
              [.completed, .partial, .skipped].contains(previous.status) else { return }
        advanceTo = new
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { coordinator.minimize() } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel(Text("Minimizar treino"))
        }
        ToolbarItem(placement: .principal) {
            if let snapshot = engine.snapshot { SessionTopBarTitle(snapshot: snapshot) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            FJHeartRateBadge(bpm: coordinator.heartRate?.bpm, zone: coordinator.heartRate?.zone)
            Menu {
                sessionMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("Mais ações do treino"))
        }
    }

    @ViewBuilder
    private var sessionMenu: some View {
        if engine.snapshot?.status == .paused {
            Button { coordinator.send(.resume) } label: { Label("Retomar treino", systemImage: "play.fill") }
        } else {
            Button { coordinator.send(.pause) } label: { Label("Pausar treino", systemImage: "pause.fill") }
        }
        Button { picker = .add } label: { Label("Adicionar exercício", systemImage: "plus") }
        Button { showsReorder = true } label: { Label("Reordenar", systemImage: "arrow.up.arrow.down") }
        Button { showsFinish = true } label: { Label("Finalizar treino", systemImage: "flag.checkered") }
        Divider()
        Button(role: .destructive) { confirmsDiscard = true } label: { Label("Descartar treino", systemImage: "trash") }
    }

    // MARK: Pular

    private var skipDialogBinding: Binding<Bool> {
        Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } })
    }

    @ViewBuilder
    private var skipButtons: some View {
        if let id = skipping {
            Button("Equipamento ocupado") { skip(id, .equipmentBusy) }
            Button("Dor") { skip(id, .pain) }
            Button("Tempo") { skip(id, .time) }
            Button("Outro") { skip(id, .other) }
            Button("Sem motivo") { skip(id, nil) }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func skip(_ id: UUID, _ reason: WatchSkipReason?) {
        coordinator.send(.skipExercise(exerciseID: id, reason: reason))
        skipping = nil
    }

    // MARK: Adicionar / trocar

    private func apply(_ picked: [Exercise], for purpose: PickerPurpose) {
        switch purpose {
        case .add:
            for exercise in picked {
                coordinator.send(.addExercise(catalogExerciseID: exercise.id, afterExerciseID: nil))
            }
        case .substitute(let id):
            if let exercise = picked.first {
                coordinator.send(.substituteExercise(exerciseID: id, withCatalogExerciseID: exercise.id))
            }
        }
    }

    // MARK: Catálogo (somente leitura)

    private func loadCatalog() {
        guard let snapshot = engine.snapshot else { return }
        let store = SessionStore(context: context, autosave: false)
        var result: [UUID: SessionCatalogInfo] = [:]
        for exercise in snapshot.exercises {
            guard let catalogID = exercise.exerciseID else { continue }
            var descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == catalogID })
            descriptor.fetchLimit = 1
            let model = try? context.fetch(descriptor).first
            let last = (try? store.lastPerformance(exerciseID: catalogID)).flatMap {
                SessionPresentation.lastPerformanceText($0.performedSets)
            }
            result[exercise.id] = SessionCatalogInfo(media: model?.media.first, lastTime: last, existsInCatalog: model != nil)
        }
        catalog = result
    }
}

extension SessionView.PickerPurpose {
    var allowsMultiple: Bool {
        if case .add = self { true } else { false }
    }
}

/// Dados de catálogo de um exercício da sessão (só leitura).
struct SessionCatalogInfo: Equatable {
    var media: MediaRef?
    var lastTime: String?
    var existsInCatalog: Bool
}

// MARK: - Título da barra superior

/// Tempo decorrido (derivado do snapshot, 1 Hz) e "3/6" exercícios; "Pausado" quando parado.
struct SessionTopBarTitle: View {
    let snapshot: SessionSnapshot

    var body: some View {
        TimelineView(.periodic(from: snapshot.startedAt, by: 1)) { context in
            let elapsed = Int(snapshot.elapsed(at: context.date))
            VStack(spacing: 0) {
                HStack(spacing: FJSpacing.xs) {
                    Text(verbatim: FJFormat.clock(elapsed))
                        .font(FJFont.numberBody.weight(.semibold))
                        .fjNumericTransition()
                    Text(verbatim: "· \(snapshot.metrics.exercisesDone)/\(snapshot.metrics.exercisesTotal)")
                        .font(FJFont.numberBody)
                        .foregroundStyle(FJColor.textSecondary)
                }
                if snapshot.status == .paused {
                    Text("Pausado")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FJColor.attention)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Tempo de treino"))
            .accessibilityValue(Text("\(FJFormat.spokenDuration(elapsed)), \(snapshot.metrics.exercisesDone) de \(snapshot.metrics.exercisesTotal) exercícios\(snapshot.status == .paused ? ", pausado" : "")"))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Edição de série (qualquer série, antes ou depois de concluir)

struct SessionSetEditSheet: View {
    let coordinator: SessionCoordinator
    let exercise: SessionSnapshot.Exercise
    let set: SessionSnapshot.ExerciseSet

    @Environment(\.dismiss) private var dismiss
    @State private var load: Double
    @State private var reps: Int?
    @State private var seconds: Double
    @State private var distanceKm: Double

    init(coordinator: SessionCoordinator, exercise: SessionSnapshot.Exercise, set: SessionSnapshot.ExerciseSet) {
        self.coordinator = coordinator
        self.exercise = exercise
        self.set = set
        _load = State(initialValue: SessionPresentation.displayLoad(set)?.value ?? 0)
        _reps = State(initialValue: set.reps)
        _seconds = State(initialValue: set.durationSeconds ?? 0)
        _distanceKm = State(initialValue: (set.distanceMeters ?? 0) / 1_000)
    }

    private var index: Int { (exercise.sets.firstIndex { $0.id == set.id } ?? 0) + 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FJSpacing.cardGap) {
                    FJCard {
                        VStack(alignment: .leading, spacing: FJSpacing.m) {
                            Text(exercise.name).font(FJFont.cardTitle)
                            Text(SessionPresentation.spokenSet(index: index, of: exercise.sets.count, set: set))
                                .font(FJFont.label)
                                .foregroundStyle(FJColor.textSecondary)
                            if exercise.measurementKind != .timeOrDistance {
                                NumberStepperField(exercise.measurementKind == .repsOnly ? "Lastro" : "Carga", value: $load,
                                                   unit: "kg", step: 0.5,
                                                   range: exercise.measurementKind == .repsOnly ? -300...300 : 0...999,
                                                   fractionDigits: 2, showsSign: exercise.measurementKind == .repsOnly)
                            }
                            switch exercise.measurementKind {
                            case .repsAndLoad, .repsOnly:
                                FJOptionalNumberField("Repetições realizadas", prompt: "+ reps", value: $reps, unit: "reps")
                            case .isometric:
                                NumberStepperField("Sustentação", value: $seconds, unit: "s", step: 1, range: 0...3_600)
                            case .timeOrDistance:
                                NumberStepperField("Duração", value: $seconds, unit: "s", step: 10, range: 0...36_000)
                                NumberStepperField("Distância", value: $distanceKm, unit: "km", step: 0.1, range: 0...500, fractionDigits: 2)
                            case .unknown:
                                EmptyView()
                            }
                        }
                    }
                    if set.isCompleted {
                        Button("Desmarcar série") {
                            coordinator.send(.uncompleteSet(setID: set.id))
                            dismiss()
                        }
                        .buttonStyle(.fjSecondary())
                    }
                }
                .padding(FJSpacing.screenMargin)
            }
            .fjScreenBackground()
            .navigationTitle("Editar série")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let unit = SessionPresentation.displayLoad(set)?.unit ?? .kg
        let isBodyweight = exercise.measurementKind == .repsOnly
        let newLoad: WatchLoad? = exercise.measurementKind == .timeOrDistance ? nil
            : WatchLoad(value: load, unit: unit, isBodyweight: isBodyweight)
        let duration: Double? = switch exercise.measurementKind {
        case .isometric, .timeOrDistance: seconds > 0 ? seconds : nil
        default: set.durationSeconds
        }
        let distance: Double? = exercise.measurementKind == .timeOrDistance && distanceKm > 0 ? distanceKm * 1_000 : set.distanceMeters
        coordinator.send(.updateSet(setID: set.id, reps: reps, load: newLoad, durationSeconds: duration, distanceMeters: distance))
        dismiss()
    }
}

// MARK: - Reordenar

/// Modo "Reordenar": arrastar ou usar as ações de mover do VoiceOver (lista em modo de edição).
struct SessionReorderSheet: View {
    let coordinator: SessionCoordinator
    @State var exercises: [SessionSnapshot.Exercise]
    @Environment(\.dismiss) private var dismiss

    init(coordinator: SessionCoordinator, exercises: [SessionSnapshot.Exercise]) {
        self.coordinator = coordinator
        _exercises = State(initialValue: exercises)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(exercises) { exercise in
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text(exercise.name)
                        Text(SessionPresentation.exerciseSummary(exercise))
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    let moved = exercises[from]
                    exercises.move(fromOffsets: source, toOffset: destination)
                    if let to = exercises.firstIndex(where: { $0.id == moved.id }) {
                        coordinator.send(.reorderExercise(exerciseID: moved.id, toIndex: to))
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reordenar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
