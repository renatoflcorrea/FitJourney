import Foundation

// Enums persistidos como `rawValue` String. NUNCA renomeie um rawValue existente:
// ele está gravado no banco, em backups JSON e (futuro) no CloudKit.

/// Modo de agenda do programa (SPEC §3.1, R-T1).
enum ScheduleMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Escolho a ficha no dia; destaca a menos recente.
    case free
    /// Rodízio A → B → C → A…
    case sequential
    /// Fichas atribuídas a dias da semana.
    case weekly

    var localizedName: String {
        switch self {
        case .free: String(localized: "Livre")
        case .sequential: String(localized: "Sequencial")
        case .weekly: String(localized: "Semanal")
        }
    }
}

/// Tag de objetivo do programa (SPEC §3.1). O texto livre fica em `TrainingProgram.goalText`.
enum ProgramGoal: String, Codable, Sendable, Hashable, CaseIterable {
    case hypertrophy, strength, endurance, fatLoss, conditioning, rehabilitation, other

    var localizedName: String {
        switch self {
        case .hypertrophy: String(localized: "Hipertrofia")
        case .strength: String(localized: "Força")
        case .endurance: String(localized: "Resistência")
        case .fatLoss: String(localized: "Emagrecimento")
        case .conditioning: String(localized: "Condicionamento")
        case .rehabilitation: String(localized: "Reabilitação")
        case .other: String(localized: "Outro")
        }
    }
}

/// De onde veio o programa (SPEC §3.1).
enum ProgramOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    case manual, ai, imported, duplicated
}

/// Dia da semana. A semana começa na segunda (SPEC §11 Q2): `allCases` está nessa ordem.
enum Weekday: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    /// Posição na semana começando na segunda (0…6).
    var index: Int { Weekday.allCases.firstIndex(of: self)! }

    /// Valor de `Calendar.component(.weekday)` (1 = domingo … 7 = sábado).
    var calendarWeekday: Int { self == .sunday ? 1 : index + 2 }

    init(calendarWeekday: Int) {
        let normalized = ((calendarWeekday - 1) % 7 + 7) % 7 // 0 = domingo
        self = normalized == 0 ? .sunday : Weekday.allCases[normalized - 1]
    }

    init(date: Date, calendar: Calendar = .current) {
        self.init(calendarWeekday: calendar.component(.weekday, from: date))
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.index < rhs.index }

    var shortName: String {
        switch self {
        case .monday: String(localized: "Seg")
        case .tuesday: String(localized: "Ter")
        case .wednesday: String(localized: "Qua")
        case .thursday: String(localized: "Qui")
        case .friday: String(localized: "Sex")
        case .saturday: String(localized: "Sáb")
        case .sunday: String(localized: "Dom")
        }
    }
}

/// Tipo de medida do exercício (SPEC §3.3).
enum MeasurementKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Repetições × carga (padrão).
    case repsAndLoad
    /// Peso corporal; carga opcional como lastro (+) ou assistência (−).
    case repsOnly
    /// Tempo de sustentação + carga opcional.
    case isometric
    /// Cardio: duração, distância, nível…
    case timeOrDistance
}

enum Equipment: String, Codable, Sendable, Hashable, CaseIterable {
    case barbell, dumbbell, machine, cable, bodyweight, band, kettlebell, cardio, other

    var localizedName: String {
        switch self {
        case .barbell: String(localized: "Barra")
        case .dumbbell: String(localized: "Halter")
        case .machine: String(localized: "Máquina")
        case .cable: String(localized: "Polia")
        case .bodyweight: String(localized: "Peso corporal")
        case .band: String(localized: "Elástico")
        case .kettlebell: String(localized: "Kettlebell")
        case .cardio: String(localized: "Cardio")
        case .other: String(localized: "Outro")
        }
    }
}

enum MuscleGroup: String, Codable, Sendable, Hashable, CaseIterable {
    case chest, back, lowerBack, traps, shoulders, biceps, triceps, forearms
    case abs, obliques, quads, hamstrings, glutes, calves, adductors, abductors
    case fullBody, cardio

    var localizedName: String {
        switch self {
        case .chest: String(localized: "Peito")
        case .back: String(localized: "Costas")
        case .lowerBack: String(localized: "Lombar")
        case .traps: String(localized: "Trapézio")
        case .shoulders: String(localized: "Ombros")
        case .biceps: String(localized: "Bíceps")
        case .triceps: String(localized: "Tríceps")
        case .forearms: String(localized: "Antebraço")
        case .abs: String(localized: "Abdômen")
        case .obliques: String(localized: "Oblíquos")
        case .quads: String(localized: "Quadríceps")
        case .hamstrings: String(localized: "Posteriores")
        case .glutes: String(localized: "Glúteos")
        case .calves: String(localized: "Panturrilha")
        case .adductors: String(localized: "Adutores")
        case .abductors: String(localized: "Abdutores")
        case .fullBody: String(localized: "Corpo inteiro")
        case .cardio: String(localized: "Cardio")
        }
    }
}

enum Laterality: String, Codable, Sendable, Hashable, CaseIterable {
    case bilateral
    /// Registrado "por lado".
    case unilateral
}

/// Tipo de série (SPEC §3.4).
enum SetKind: String, Codable, Sendable, Hashable, CaseIterable {
    case warmup, feeder, working, dropSet, restPause, toFailure, backOff

    /// Série "válida": conta para volume, recordes e carga atual.
    /// Aquecimento e preparatória (feeder) não contam.
    var isWorking: Bool {
        switch self {
        case .warmup, .feeder: false
        case .working, .dropSet, .restPause, .toFailure, .backOff: true
        }
    }

    var localizedName: String {
        switch self {
        case .warmup: String(localized: "Aquecimento")
        case .feeder: String(localized: "Preparatória")
        case .working: String(localized: "Válida")
        case .dropSet: String(localized: "Drop-set")
        case .restPause: String(localized: "Rest-pause")
        case .toFailure: String(localized: "Até a falha")
        case .backOff: String(localized: "Back-off")
        }
    }
}

/// Status da sessão de treino.
enum SessionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case inProgress, completed, discarded
}

/// Status de um exercício dentro da sessão (SPEC §4.2).
enum SessionExerciseStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending, inProgress, completed, partial, skipped
}

/// Motivo de pular exercício (SPEC §4.2). Texto livre também é aceito em `skipReasonText`.
enum SkipReason: String, Codable, Sendable, Hashable, CaseIterable {
    case equipmentBusy, pain, time, other
}
