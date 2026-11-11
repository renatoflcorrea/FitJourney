import Foundation

// Conversão entre os modelos SwiftData e o formato `BackupV1` (nos dois sentidos).
// Exportar: `BackupV1.X(model)`. Importar: `model.apply(dto)` grava todos os campos escalares
// (inclusive `id`, `createdAt` e `updatedAt`); relações ficam com o importador.

// MARK: - Valores compostos

extension BackupV1.RepTargetValue {
    init(_ value: RepTarget) {
        switch value {
        case .fixed(let reps): self.init(kind: "fixed", reps: reps)
        case .range(let min, let max): self.init(kind: "range", min: min, max: max)
        case .amrap: self.init(kind: "amrap")
        }
    }

    var domain: RepTarget? {
        switch kind {
        case "fixed": reps.map { .fixed(reps: $0) }
        case "range": min.flatMap { lo in max.map { .range(min: lo, max: $0) } }
        case "amrap": .amrap
        default: nil
        }
    }
}

extension BackupV1.LoadValue {
    init(_ value: Load) {
        switch value {
        case .weight(let value, let unit): self.init(kind: "weight", value: value, unit: unit.rawValue)
        case .bodyweight(let delta, let unit): self.init(kind: "bodyweight", value: delta, unit: unit.rawValue)
        }
    }

    var domain: Load? {
        guard let unit = WeightUnit(rawValue: unit) else { return nil }
        switch kind {
        case "weight": return .weight(value: value, unit: unit)
        case "bodyweight": return .bodyweight(delta: value, unit: unit)
        default: return nil
        }
    }
}

extension BackupV1.EffortValue {
    init(_ value: EffortTarget) {
        switch value {
        case .rir(let rir): self.init(kind: "rir", value: Double(rir))
        case .rpe(let rpe): self.init(kind: "rpe", value: rpe)
        }
    }

    var domain: EffortTarget? {
        switch kind {
        case "rir": .rir(Int(value.rounded()))
        case "rpe": .rpe(value)
        default: nil
        }
    }
}

extension BackupV1.CardioValue {
    init(_ value: CardioTarget) {
        self.init(durationSeconds: value.durationSeconds, distanceMeters: value.distanceMeters, level: value.level,
                  speedKmh: value.speedKmh, inclinePercent: value.inclinePercent, heartRateZone: value.heartRateZone)
    }

    var domain: CardioTarget {
        CardioTarget(durationSeconds: durationSeconds, distanceMeters: distanceMeters, level: level,
                     speedKmh: speedKmh, inclinePercent: inclinePercent, heartRateZone: heartRateZone)
    }
}

extension BackupV1.MediaValue {
    init(_ value: MediaRef) {
        switch value {
        case .image(let fileName):
            self.init(kind: "image", fileName: fileName)
        case .localVideo(let fileName, let thumbnail):
            self.init(kind: "localVideo", fileName: fileName, thumbnailFileName: thumbnail)
        case .externalVideo(let url, let provider, let videoID):
            self.init(kind: "externalVideo", url: url.absoluteString, provider: provider.rawValue, videoID: videoID)
        }
    }

    /// Para exportar: link externo com usuário/senha embutidos é descartado (nunca sai do aparelho).
    init?(exporting value: MediaRef) {
        if case .externalVideo(let url, _, _) = value, !Self.isSafeLink(url) { return nil }
        self.init(value)
    }

    /// http(s), com host e sem credenciais na URL.
    static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    /// `nil` se faltar campo obrigatório do tipo, o nome de arquivo for inseguro ou o link tiver credenciais.
    var domain: MediaRef? {
        switch kind {
        case "image":
            guard let fileName, MediaStore.isSafe(fileName: fileName) else { return nil }
            return .image(fileName: fileName)
        case "localVideo":
            guard let fileName, MediaStore.isSafe(fileName: fileName) else { return nil }
            let thumb = thumbnailFileName.flatMap { MediaStore.isSafe(fileName: $0) ? $0 : nil }
            return .localVideo(fileName: fileName, thumbnailFileName: thumb)
        case "externalVideo":
            guard let url = url.flatMap(URL.init(string:)), Self.isSafeLink(url) else { return nil }
            return .externalVideo(url: url, provider: provider.flatMap(VideoProvider.init(rawValue:)) ?? .other,
                                  videoID: videoID)
        default:
            return nil
        }
    }
}

extension BackupV1.Nutrients {
    init(_ value: NutrientValues) {
        self.init(kcal: value.kcal, protein: value.protein, carbs: value.carbs, fat: value.fat, fiber: value.fiber)
    }

    var domain: NutrientValues { NutrientValues(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber) }
}

enum BackupOpaqueJSON {
    static func value(from data: Data?) -> JSONValue? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue.convert(object)
    }

    static func data(from value: JSONValue?) -> Data? {
        guard let value, value != .null else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }
}

private func sortedWeekdays(_ set: Set<Weekday>) -> [String] { set.sorted().map(\.rawValue) }
private func backupWeekdays(from list: [String]) -> Set<Weekday> { Set(list.compactMap(Weekday.init(rawValue:))) }

// MARK: - Treino

extension BackupV1.Exercise {
    init(_ m: Exercise) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name,
                  primaryMuscles: m.primaryMuscles.map(\.rawValue), secondaryMuscles: m.secondaryMuscles.map(\.rawValue),
                  equipment: m.equipment.rawValue, laterality: m.laterality.rawValue,
                  measurementKind: m.measurementKind.rawValue, media: m.media.compactMap(BackupV1.MediaValue.init(exporting:)),
                  isBuiltIn: m.isBuiltIn, catalogKey: m.catalogKey, notes: m.notes,
                  defaultRestSeconds: m.defaultRestSeconds)
    }
}

extension Exercise {
    /// Campos escalares (a mídia é resolvida pelo importador). `keepID` mantém o `id` local
    /// (embutido casado por `catalogKey`).
    func apply(_ d: BackupV1.Exercise, media: [MediaRef], keepID: Bool = false) {
        if !keepID { id = d.id }
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        primaryMusclesRaw = StorageCoding.encodeList(d.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)))
        secondaryMusclesRaw = StorageCoding.encodeList(d.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)))
        equipment = Equipment(rawValue: d.equipment) ?? .other
        laterality = Laterality(rawValue: d.laterality) ?? .bilateral
        measurementKind = MeasurementKind(rawValue: d.measurementKind) ?? .repsAndLoad
        mediaData = StorageCoding.encodeList(media, preservingUnknownIn: nil)
        isBuiltIn = d.isBuiltIn
        catalogKey = d.catalogKey
        notes = d.notes
        defaultRestSeconds = d.defaultRestSeconds
    }
}

extension BackupV1.Program {
    init(_ m: TrainingProgram) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name, goal: m.goal.rawValue,
                  goalText: m.goalText, scheduleMode: m.scheduleMode.rawValue, startDate: m.startDate,
                  endDate: m.endDate, notes: m.notes, isActive: m.isActive, isArchived: m.isArchived,
                  origin: m.origin.rawValue, routines: m.sortedRoutines.map(BackupV1.Routine.init))
    }

    /// Instante mais recente do agregado (raiz e descendentes) — base do "mais recente vence".
    var latestUpdate: Date {
        routines.flatMap { r in
            [r.updatedAt] + r.exercises.flatMap { e in [e.updatedAt] + e.sets.map(\.updatedAt) }
        }.reduce(updatedAt, max)
    }
}

extension TrainingProgram {
    func apply(_ d: BackupV1.Program) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        goal = ProgramGoal(rawValue: d.goal) ?? .other
        goalText = d.goalText
        scheduleMode = ScheduleMode(rawValue: d.scheduleMode) ?? .free
        startDate = d.startDate
        endDate = d.endDate
        notes = d.notes
        isActive = d.isActive
        isArchived = d.isArchived
        origin = ProgramOrigin(rawValue: d.origin) ?? .imported
    }

    var latestUpdate: Date {
        (routines ?? []).flatMap { r in
            [r.updatedAt] + (r.exercises ?? []).flatMap { e in [e.updatedAt] + (e.sets ?? []).map(\.updatedAt) }
        }.reduce(updatedAt, max)
    }
}

extension BackupV1.Routine {
    init(_ m: Routine) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name, symbol: m.symbol,
                  colorName: m.colorName, weekdays: sortedWeekdays(m.weekdays), sortIndex: m.sortIndex, notes: m.notes,
                  exercises: m.sortedExercises.map(BackupV1.RoutineExercise.init))
    }
}

extension Routine {
    func apply(_ d: BackupV1.Routine) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        symbol = d.symbol
        colorName = d.colorName
        weekdaysRaw = StorageCoding.encodeWeekdays(backupWeekdays(from: d.weekdays))
        sortIndex = d.sortIndex
        notes = d.notes
    }
}

extension BackupV1.RoutineExercise {
    init(_ m: RoutineExercise) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, exerciseID: m.exercise?.id,
                  sortIndex: m.sortIndex, groupID: m.groupID, notes: m.notes, restSeconds: m.restSeconds,
                  sets: m.sortedSets.map(BackupV1.SetPrescription.init))
    }
}

extension RoutineExercise {
    func apply(_ d: BackupV1.RoutineExercise) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        sortIndex = d.sortIndex
        groupID = d.groupID
        notes = d.notes
        restSeconds = d.restSeconds
    }
}

extension BackupV1.SetPrescription {
    init(_ m: SetPrescription) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, sortIndex: m.sortIndex,
                  kind: m.kind.rawValue, repTarget: m.repTarget.map(BackupV1.RepTargetValue.init),
                  holdSeconds: m.holdSeconds, initialLoad: m.initialLoad.map(BackupV1.LoadValue.init),
                  currentLoad: m.currentLoad.map(BackupV1.LoadValue.init), restSeconds: m.restSeconds, tempo: m.tempo,
                  effort: m.effort.map(BackupV1.EffortValue.init), cardio: m.cardio.map(BackupV1.CardioValue.init),
                  notes: m.notes)
    }
}

extension SetPrescription {
    func apply(_ d: BackupV1.SetPrescription) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        sortIndex = d.sortIndex
        kind = SetKind(rawValue: d.kind) ?? .working
        repTarget = d.repTarget?.domain
        holdSeconds = d.holdSeconds
        initialLoad = d.initialLoad?.domain
        currentLoad = d.currentLoad?.domain
        restSeconds = d.restSeconds
        tempo = d.tempo
        effort = d.effort?.domain
        cardio = d.cardio?.domain
        notes = d.notes
    }
}

// MARK: - Sessões

extension BackupV1.Session {
    init(_ m: WorkoutSession) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, routineID: m.routineID ?? m.routine?.id,
                  programID: m.programID, routineName: m.routineName, startedAt: m.startedAt, endedAt: m.endedAt,
                  status: m.status.rawValue, sessionRPE: m.sessionRPE, mood: m.mood, notes: m.notes,
                  healthKitWorkoutID: m.healthKitWorkoutID, pausedAt: m.pausedAt,
                  accumulatedPauseSeconds: m.accumulatedPauseSeconds, restEndsAt: m.restEndsAt,
                  lastActivityAt: m.lastActivityAt, exercises: m.sortedExercises.map(BackupV1.SessionExercise.init))
    }

    var latestUpdate: Date {
        exercises.flatMap { e in [e.updatedAt] + e.sets.map(\.updatedAt) }.reduce(updatedAt, max)
    }
}

extension WorkoutSession {
    func apply(_ d: BackupV1.Session) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        routineID = d.routineID
        programID = d.programID
        routineName = d.routineName
        startedAt = d.startedAt
        endedAt = d.endedAt
        status = SessionStatus(rawValue: d.status) ?? .completed
        sessionRPE = d.sessionRPE
        mood = d.mood
        notes = d.notes
        healthKitWorkoutID = d.healthKitWorkoutID
        pausedAt = d.pausedAt
        accumulatedPauseSeconds = d.accumulatedPauseSeconds
        restEndsAt = d.restEndsAt
        lastActivityAt = d.lastActivityAt
        // Estado transitório do motor não viaja no backup.
        revision = 0
        appliedCommandIDsData = nil
        focusedExerciseID = nil
        holdSetID = nil
        holdStartedAt = nil
    }

    var latestUpdate: Date {
        (exercises ?? []).flatMap { e in [e.updatedAt] + (e.sets ?? []).map(\.updatedAt) }.reduce(updatedAt, max)
    }
}

extension BackupV1.SessionExercise {
    init(_ m: SessionExercise) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, exerciseID: m.exerciseID,
                  routineExerciseID: m.routineExerciseID, name: m.name, measurementKind: m.measurementKind.rawValue,
                  laterality: m.laterality.rawValue, sortIndex: m.sortIndex, groupID: m.groupID,
                  restSeconds: m.restSeconds, status: m.status.rawValue, skipReason: m.skipReason?.rawValue,
                  skipReasonText: m.skipReasonText, substitutedFromExerciseID: m.substitutedFromExerciseID,
                  substitutedFromName: m.substitutedFromName, notes: m.notes, painLocation: m.painLocation,
                  painLevel: m.painLevel, sets: m.sortedSets.map(BackupV1.PerformedSet.init))
    }
}

extension SessionExercise {
    func apply(_ d: BackupV1.SessionExercise) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        exerciseID = d.exerciseID
        routineExerciseID = d.routineExerciseID
        name = d.name
        measurementKind = MeasurementKind(rawValue: d.measurementKind) ?? .repsAndLoad
        laterality = Laterality(rawValue: d.laterality) ?? .bilateral
        sortIndex = d.sortIndex
        groupID = d.groupID
        restSeconds = d.restSeconds
        status = SessionExerciseStatus(rawValue: d.status) ?? .pending
        skipReason = d.skipReason.flatMap(SkipReason.init(rawValue:))
        skipReasonText = d.skipReasonText
        substitutedFromExerciseID = d.substitutedFromExerciseID
        substitutedFromName = d.substitutedFromName
        notes = d.notes
        painLocation = d.painLocation
        painLevel = d.painLevel
    }
}

extension BackupV1.PerformedSet {
    init(_ m: SetLog) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, sortIndex: m.sortIndex,
                  prescriptionID: m.prescriptionID, kind: m.kind.rawValue,
                  repTarget: m.repTarget.map(BackupV1.RepTargetValue.init),
                  plannedLoad: m.plannedLoad.map(BackupV1.LoadValue.init), targetHoldSeconds: m.targetHoldSeconds,
                  restSeconds: m.restSeconds, cardioTarget: m.cardioTarget.map(BackupV1.CardioValue.init),
                  reps: m.reps, load: m.load.map(BackupV1.LoadValue.init), durationSeconds: m.durationSeconds,
                  distanceMeters: m.distanceMeters, isCompleted: m.isCompleted, completedAt: m.completedAt,
                  edited: m.edited)
    }
}

extension SetLog {
    func apply(_ d: BackupV1.PerformedSet) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        sortIndex = d.sortIndex
        prescriptionID = d.prescriptionID
        kind = SetKind(rawValue: d.kind) ?? .working
        repTarget = d.repTarget?.domain
        plannedLoad = d.plannedLoad?.domain
        targetHoldSeconds = d.targetHoldSeconds
        restSeconds = d.restSeconds
        cardioTarget = d.cardioTarget?.domain
        reps = d.reps
        load = d.load?.domain
        durationSeconds = d.durationSeconds
        distanceMeters = d.distanceMeters
        isCompleted = d.isCompleted
        completedAt = d.completedAt
        edited = d.edited
        lastCommandAt = nil
    }
}

// MARK: - Dieta

extension BackupV1.NutritionPlan {
    init(_ m: NutritionPlan) {
        let t = m.targets
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name, goal: m.goal,
                  startDate: m.startDate, endDate: m.endDate, author: m.author.rawValue, isActive: m.isActive,
                  isArchived: m.isArchived, notes: m.notes,
                  targets: .init(kcal: t.kcal, protein: t.protein, carbs: t.carbs, fat: t.fat, fiber: t.fiber,
                                 waterMilliliters: t.waterMilliliters),
                  days: m.sortedDays.map(BackupV1.NutritionDay.init))
    }

    var latestUpdate: Date {
        days.flatMap { d in
            [d.updatedAt] + d.meals.flatMap { m in [m.updatedAt] + m.items.map(\.updatedAt) }
        }.reduce(updatedAt, max)
    }
}

extension NutritionPlan {
    func apply(_ d: BackupV1.NutritionPlan) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        goal = d.goal
        startDate = d.startDate
        endDate = d.endDate
        author = NutritionPlanAuthor(rawValue: d.author) ?? .me
        isActive = d.isActive
        isArchived = d.isArchived
        notes = d.notes
        targets = NutritionTargets(kcal: d.targets.kcal, protein: d.targets.protein, carbs: d.targets.carbs,
                                   fat: d.targets.fat, fiber: d.targets.fiber, waterMilliliters: d.targets.waterMilliliters)
    }

    var latestUpdate: Date {
        (days ?? []).flatMap { d in
            [d.updatedAt] + (d.meals ?? []).flatMap { m in [m.updatedAt] + (m.items ?? []).map(\.updatedAt) }
        }.reduce(updatedAt, max)
    }
}

extension BackupV1.NutritionDay {
    init(_ m: NutritionDay) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name,
                  weekdays: sortedWeekdays(m.weekdays), sortIndex: m.sortIndex,
                  meals: m.sortedMeals.map(BackupV1.Meal.init))
    }
}

extension NutritionDay {
    func apply(_ d: BackupV1.NutritionDay) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        weekdaysRaw = StorageCoding.encodeWeekdays(backupWeekdays(from: d.weekdays))
        sortIndex = d.sortIndex
    }
}

extension BackupV1.Meal {
    init(_ m: Meal) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name,
                  minutesFromMidnight: m.minutesFromMidnight, reminderEnabled: m.reminderEnabled,
                  sortIndex: m.sortIndex, notes: m.notes, items: m.sortedItems.map(BackupV1.MealItem.init))
    }
}

extension Meal {
    func apply(_ d: BackupV1.Meal) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        minutesFromMidnight = d.minutesFromMidnight
        reminderEnabled = d.reminderEnabled
        sortIndex = d.sortIndex
        notes = d.notes
    }
}

extension BackupV1.MealItem {
    init(_ m: MealItem) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name, quantity: m.quantity,
                  unit: m.unit.rawValue, nutrients: .init(m.values), notes: m.notes, sortIndex: m.sortIndex,
                  substitutions: m.substitutions.map(BackupV1.Substitution.init))
    }
}

extension MealItem {
    func apply(_ d: BackupV1.MealItem) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        quantity = d.quantity
        unit = FoodUnit(rawValue: d.unit) ?? .grams
        values = d.nutrients.domain
        notes = d.notes
        sortIndex = d.sortIndex
        substitutionsData = StorageCoding.encodeList(d.substitutions.map(\.domain), preservingUnknownIn: nil)
    }
}

extension BackupV1.Substitution {
    init(_ m: MealSubstitution) {
        self.init(id: m.id, name: m.name, quantity: m.quantity, unit: m.unit.rawValue, nutrients: .init(m.values),
                  notes: m.notes)
    }

    var domain: MealSubstitution {
        MealSubstitution(id: id, name: name, quantity: quantity, unit: FoodUnit(rawValue: unit) ?? .grams,
                         values: nutrients.domain, notes: notes)
    }
}

extension BackupV1.Food {
    init(_ m: FoodItem) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, name: m.name,
                  servingQuantity: m.servingQuantity, unit: m.unit.rawValue, nutrients: .init(m.values),
                  isFavorite: m.isFavorite, lastUsedAt: m.lastUsedAt, useCount: m.useCount,
                  estimation: m.estimation.rawValue)
    }
}

extension FoodItem {
    func apply(_ d: BackupV1.Food) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        name = d.name
        servingQuantity = d.servingQuantity
        unit = FoodUnit(rawValue: d.unit) ?? .grams
        values = d.nutrients.domain
        isFavorite = d.isFavorite
        lastUsedAt = d.lastUsedAt
        useCount = d.useCount
        estimation = EstimationSource(rawValue: d.estimation) ?? .informed
    }
}

extension BackupV1.FoodEntry {
    init(_ m: FoodEntry) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, date: m.date, mealID: m.mealID,
                  mealName: m.mealName, name: m.name, quantity: m.quantity, unit: m.unit.rawValue,
                  nutrients: .init(m.values), estimation: m.estimation.rawValue, mealStatus: m.mealStatus?.rawValue,
                  notes: m.notes, plannedItemID: m.plannedItemID)
    }
}

extension FoodEntry {
    func apply(_ d: BackupV1.FoodEntry) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        date = d.date
        mealID = d.mealID
        mealName = d.mealName
        name = d.name
        quantity = d.quantity
        unit = FoodUnit(rawValue: d.unit) ?? .grams
        values = d.nutrients.domain
        estimation = EstimationSource(rawValue: d.estimation) ?? .informed
        mealStatus = d.mealStatus.flatMap(MealStatus.init(rawValue:))
        notes = d.notes
        plannedItemID = d.plannedItemID
    }
}

extension BackupV1.WaterLog {
    init(_ m: WaterLog) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, date: m.date, milliliters: m.milliliters)
    }
}

extension WaterLog {
    func apply(_ d: BackupV1.WaterLog) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        date = d.date
        milliliters = d.milliliters
    }
}

// MARK: - Coach

extension BackupV1.Conversation {
    init(_ m: ChatConversation) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, title: m.title,
                  titleIsUserEdited: m.titleIsUserEdited, provider: m.providerRaw, modelID: m.modelID,
                  isArchived: m.isArchived, messages: m.sortedMessages.map(BackupV1.Message.init))
    }

    var latestUpdate: Date { messages.map(\.updatedAt).reduce(updatedAt, max) }
}

extension ChatConversation {
    func apply(_ d: BackupV1.Conversation) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        title = d.title
        titleIsUserEdited = d.titleIsUserEdited
        providerRaw = d.provider
        modelID = d.modelID
        isArchived = d.isArchived
    }

    var latestUpdate: Date { (messages ?? []).map(\.updatedAt).reduce(updatedAt, max) }
}

extension BackupV1.Message {
    init(_ m: ChatMessage) {
        self.init(id: m.id, createdAt: m.createdAt, updatedAt: m.updatedAt, role: m.role.rawValue, content: m.content,
                  reasoning: m.reasoning, state: m.state.rawValue, failureReason: m.failureReason, sortIndex: m.sortIndex,
                  modelID: m.modelID, promptTokens: m.promptTokens, completionTokens: m.completionTokens,
                  toolCalls: BackupOpaqueJSON.value(from: m.toolCallsData),
                  reasoningBlocks: BackupOpaqueJSON.value(from: m.reasoningBlocksData), toolCallID: m.toolCallID,
                  toolName: m.toolName, toolResultIsError: m.toolResultIsError,
                  proposal: BackupOpaqueJSON.value(from: m.proposalData))
    }
}

extension ChatMessage {
    func apply(_ d: BackupV1.Message) {
        id = d.id
        createdAt = d.createdAt
        updatedAt = d.updatedAt
        role = LLMRole(rawValue: d.role) ?? .user
        content = d.content
        reasoning = d.reasoning
        // `streaming` é transitório: importado vira `stopped` (mesmo reparo do launch).
        let imported = ChatMessageState(rawValue: d.state) ?? .complete
        state = imported == .streaming ? .stopped : imported
        failureReason = d.failureReason
        sortIndex = d.sortIndex
        modelID = d.modelID
        promptTokens = d.promptTokens
        completionTokens = d.completionTokens
        toolCallsData = BackupOpaqueJSON.data(from: d.toolCalls)
        reasoningBlocksData = BackupOpaqueJSON.data(from: d.reasoningBlocks)
        toolCallID = d.toolCallID
        toolName = d.toolName
        toolResultIsError = d.toolResultIsError
        proposalData = BackupOpaqueJSON.data(from: d.proposal)
    }
}

extension BackupV1.CoachProfileInfo {
    init(_ p: CoachProfile, consentedAt: Date?) {
        self.init(age: p.age, sex: p.sex?.rawValue, heightCm: p.heightCm, weightKg: p.weightKg, level: p.level?.rawValue,
                  goal: p.goal, restrictions: p.restrictions, equipment: p.equipment, daysPerWeek: p.daysPerWeek,
                  minutesPerSession: p.minutesPerSession, foodPreferences: p.foodPreferences,
                  sharing: .init(profile: p.sharing.profile, workouts: p.sharing.workouts,
                                 nutrition: p.sharing.nutrition, health: p.sharing.health),
                  consentedAt: consentedAt)
    }

    /// Perfil sem o compartilhamento (que fica sempre com a decisão local do usuário).
    func profile(keepingSharing sharing: CoachProfile.Sharing) -> CoachProfile {
        var p = CoachProfile()
        p.age = age
        p.sex = sex.flatMap(CoachProfile.Sex.init(rawValue:))
        p.heightCm = heightCm
        p.weightKg = weightKg
        p.level = level.flatMap(CoachProfile.Level.init(rawValue:))
        p.goal = goal
        p.restrictions = restrictions
        p.equipment = equipment
        p.daysPerWeek = daysPerWeek
        p.minutesPerSession = minutesPerSession
        p.foodPreferences = foodPreferences
        p.sharing = sharing
        return p
    }
}
