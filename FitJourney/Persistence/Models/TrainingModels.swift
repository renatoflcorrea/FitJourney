import Foundation
import SwiftData

// Modelos de planejamento de treino (SPEC §3). Regras CloudKit (R4): sem `.unique`,
// toda propriedade com padrão ou opcional, relações opcionais com inverso e deleteRule explícito.
// Enums ficam em `…Raw: String`, tipos compostos em `…Data: Data?` (JSON), com acessores tipados.

@Model
final class TrainingProgram {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var goalRaw: String = ProgramGoal.hypertrophy.rawValue
    /// Objetivo em texto livre.
    var goalText: String = ""
    var scheduleModeRaw: String = ScheduleMode.sequential.rawValue
    var startDate: Date = Date()
    var endDate: Date?
    var notes: String = ""
    var isActive: Bool = false
    var isArchived: Bool = false
    var originRaw: String = ProgramOrigin.manual.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Routine.program)
    var routines: [Routine]? = []

    init(name: String, goal: ProgramGoal = .hypertrophy, scheduleMode: ScheduleMode = .sequential,
         startDate: Date = .now, origin: ProgramOrigin = .manual) {
        self.name = name
        self.goalRaw = goal.rawValue
        self.scheduleModeRaw = scheduleMode.rawValue
        self.startDate = startDate
        self.originRaw = origin.rawValue
    }

    var goal: ProgramGoal {
        get { ProgramGoal(rawValue: goalRaw) ?? .other }
        set { goalRaw = newValue.rawValue }
    }

    var scheduleMode: ScheduleMode {
        get { ScheduleMode(rawValue: scheduleModeRaw) ?? .free }
        set { scheduleModeRaw = newValue.rawValue }
    }

    var origin: ProgramOrigin {
        get { ProgramOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    /// Fichas ordenadas por `sortIndex`.
    var sortedRoutines: [Routine] { (routines ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// "Semana X de Y" (SPEC §3.1): `nil` sem data de fim.
    func weekProgress(on date: Date = .now, calendar: Calendar = .current) -> (week: Int, of: Int)? {
        guard let endDate else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let total = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                            to: calendar.startOfDay(for: endDate)).day ?? 0
        let totalWeeks = max(1, total / 7 + 1)
        return (min(max(1, days / 7 + 1), totalWeeks), totalWeeks)
    }
}

@Model
final class Routine {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    /// Letra ou SF Symbol curto exibido no avatar da ficha ("A", "B"…).
    var symbol: String = ""
    /// Nome de token de cor do DesignSystem (ex.: "blue"); vazio = padrão.
    var colorName: String = ""
    var weekdaysRaw: String = ""
    var sortIndex: Int = 0
    var notes: String = ""

    var program: TrainingProgram?

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.routine)
    var exercises: [RoutineExercise]? = []

    /// Sessões feitas desta ficha; ao apagar a ficha, as sessões ficam (routine = nil).
    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.routine)
    var sessions: [WorkoutSession]? = []

    init(name: String, symbol: String = "", sortIndex: Int = 0, weekdays: Set<Weekday> = []) {
        self.name = name
        self.symbol = symbol
        self.sortIndex = sortIndex
        self.weekdaysRaw = StorageCoding.encodeWeekdays(weekdays)
    }

    /// Dias da semana (modo semanal).
    var weekdays: Set<Weekday> {
        get { StorageCoding.decodeWeekdays(weekdaysRaw) }
        set { weekdaysRaw = StorageCoding.encodeWeekdays(newValue, preservingUnknownIn: weekdaysRaw) }
    }

    var sortedExercises: [RoutineExercise] { (exercises ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Duração estimada (SPEC §3.2), em segundos.
    /// Em bi-set/circuito o descanso só vale ao fim da rodada (último membro do grupo); os demais
    /// membros contam apenas a transição (`groupTransitionSeconds`).
    var estimatedDurationSeconds: Int {
        let ordered = sortedExercises
        let rests = ordered.enumerated().flatMap { index, re in
            let next = index + 1 < ordered.count ? ordered[index + 1] : nil
            let restsOnlyAtRoundEnd = re.groupID != nil && next?.groupID == re.groupID
            return re.sortedSets.map { set in
                restsOnlyAtRoundEnd
                    ? RoutineEstimate.groupTransitionSeconds
                    : (set.restSeconds ?? re.restSeconds ?? re.exercise?.defaultRestSeconds ?? 90)
            }
        }
        return RoutineEstimate.durationSeconds(restSeconds: rests)
    }
}

/// Exercício do catálogo (SPEC §3.3).
@Model
final class Exercise {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var name: String = ""
    var primaryMusclesRaw: String = ""
    var secondaryMusclesRaw: String = ""
    var equipmentRaw: String = Equipment.other.rawValue
    var lateralityRaw: String = Laterality.bilateral.rawValue
    var measurementKindRaw: String = MeasurementKind.repsAndLoad.rawValue
    var mediaData: Data?
    var isBuiltIn: Bool = false
    /// Chave estável do catálogo embutido (ex.: "bench-press"); `nil` para exercícios do usuário.
    var catalogKey: String?
    var notes: String = ""
    var defaultRestSeconds: Int = 90

    @Relationship(deleteRule: .nullify, inverse: \RoutineExercise.exercise)
    var routineExercises: [RoutineExercise]? = []

    init(name: String, primaryMuscles: [MuscleGroup] = [], secondaryMuscles: [MuscleGroup] = [],
         equipment: Equipment = .other, laterality: Laterality = .bilateral,
         measurementKind: MeasurementKind = .repsAndLoad, defaultRestSeconds: Int = 90,
         isBuiltIn: Bool = false, catalogKey: String? = nil) {
        self.name = name
        self.primaryMusclesRaw = StorageCoding.encodeList(primaryMuscles)
        self.secondaryMusclesRaw = StorageCoding.encodeList(secondaryMuscles)
        self.equipmentRaw = equipment.rawValue
        self.lateralityRaw = laterality.rawValue
        self.measurementKindRaw = measurementKind.rawValue
        self.defaultRestSeconds = defaultRestSeconds
        self.isBuiltIn = isBuiltIn
        self.catalogKey = catalogKey
    }

    var primaryMuscles: [MuscleGroup] {
        get { StorageCoding.decodeList(MuscleGroup.self, from: primaryMusclesRaw) }
        set { primaryMusclesRaw = StorageCoding.encodeList(newValue, preservingUnknownIn: primaryMusclesRaw) }
    }

    var secondaryMuscles: [MuscleGroup] {
        get { StorageCoding.decodeList(MuscleGroup.self, from: secondaryMusclesRaw) }
        set { secondaryMusclesRaw = StorageCoding.encodeList(newValue, preservingUnknownIn: secondaryMusclesRaw) }
    }

    var equipment: Equipment {
        get { Equipment(rawValue: equipmentRaw) ?? .other }
        set { equipmentRaw = newValue.rawValue }
    }

    var laterality: Laterality {
        get { Laterality(rawValue: lateralityRaw) ?? .bilateral }
        set { lateralityRaw = newValue.rawValue }
    }

    var measurementKind: MeasurementKind {
        get { MeasurementKind(rawValue: measurementKindRaw) ?? .repsAndLoad }
        set { measurementKindRaw = newValue.rawValue }
    }

    var media: [MediaRef] {
        get { StorageCoding.decodeList(MediaRef.self, from: mediaData) }
        set { mediaData = StorageCoding.encodeList(newValue, preservingUnknownIn: mediaData) }
    }
}

/// Exercício dentro de uma ficha, com a prescrição (SPEC §3.4).
@Model
final class RoutineExercise {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var sortIndex: Int = 0
    /// Mesmo `groupID` = bi-set/tri-set/circuito (descanso só ao fim da rodada).
    var groupID: UUID?
    var notes: String = ""
    /// Descanso padrão deste exercício na ficha (sobrescreve o do catálogo).
    var restSeconds: Int?

    var routine: Routine?
    var exercise: Exercise?

    @Relationship(deleteRule: .cascade, inverse: \SetPrescription.routineExercise)
    var sets: [SetPrescription]? = []

    init(sortIndex: Int = 0, groupID: UUID? = nil, restSeconds: Int? = nil, notes: String = "") {
        self.sortIndex = sortIndex
        self.groupID = groupID
        self.restSeconds = restSeconds
        self.notes = notes
    }

    var sortedSets: [SetPrescription] { (sets ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    /// Nome para exibição (o exercício do catálogo pode ter sido apagado).
    var displayName: String { exercise?.name ?? String(localized: "Exercício removido") }
}

/// Uma série prescrita (SPEC §3.4).
@Model
final class SetPrescription {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var sortIndex: Int = 0
    var kindRaw: String = SetKind.working.rawValue
    var repTargetData: Data?
    /// Sustentação alvo (isométricos), em segundos.
    var holdSeconds: Int?
    /// Carga prescrita ao criar/editar a ficha — a execução nunca altera (R-T2).
    var initialLoadData: Data?
    /// Carga atual — atualizada ao finalizar sessão, com confirmação (R-T2).
    var currentLoadData: Data?
    var restSeconds: Int?
    /// Cadência "3-1-1-0".
    var tempo: String?
    var effortData: Data?
    var cardioData: Data?
    var notes: String = ""

    var routineExercise: RoutineExercise?

    init(sortIndex: Int = 0, kind: SetKind = .working, repTarget: RepTarget? = .fixed(reps: 10),
         initialLoad: Load? = nil, restSeconds: Int? = nil) {
        self.sortIndex = sortIndex
        self.kindRaw = kind.rawValue
        self.repTargetData = StorageCoding.encode(repTarget)
        self.initialLoadData = StorageCoding.encode(initialLoad)
        self.restSeconds = restSeconds
    }

    var kind: SetKind {
        get { SetKind(rawValue: kindRaw) ?? .working }
        set { kindRaw = newValue.rawValue }
    }

    var repTarget: RepTarget? {
        get { StorageCoding.decode(RepTarget.self, from: repTargetData) }
        set { repTargetData = StorageCoding.encode(newValue) }
    }

    var initialLoad: Load? {
        get { StorageCoding.decode(Load.self, from: initialLoadData) }
        set { initialLoadData = StorageCoding.encode(newValue) }
    }

    var currentLoad: Load? {
        get { StorageCoding.decode(Load.self, from: currentLoadData) }
        set { currentLoadData = StorageCoding.encode(newValue) }
    }

    /// Carga que a próxima sessão pré-preenche: atual, senão inicial.
    var effectiveLoad: Load? { currentLoad ?? initialLoad }

    var effort: EffortTarget? {
        get { StorageCoding.decode(EffortTarget.self, from: effortData) }
        set { effortData = StorageCoding.encode(newValue) }
    }

    var cardio: CardioTarget? {
        get { StorageCoding.decode(CardioTarget.self, from: cardioData) }
        set { cardioData = StorageCoding.encode(newValue) }
    }
}
