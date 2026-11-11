import Foundation

// Contrato `fitjourney-export-v1` (contracts/fitjourney-export-v1.schema.json, SPEC §8/§9).
//
// Estes tipos são o formato de fio — independentes dos modelos SwiftData (renomear um campo do
// modelo não muda o backup). Regras:
// - Datas ISO-8601 com fuso e milissegundos ("2026-11-11T09:30:00.000-03:00").
// - Decimais como número JSON; enums como `rawValue` estável (os mesmos gravados no banco).
// - Opcional ausente ou `null` = "não informado" (nunca zero).
// - Campos desconhecidos são ignorados na leitura (adições compatíveis dentro da v1); mudança
//   incompatível = `schemaVersion` 2.
// - Nunca contém segredos (chaves de API vivem só no Keychain e não passam por aqui).

enum BackupV1 {
    static let format = "fitjourney-export"
    static let schemaVersion = 1
    /// Nome do JSON dentro do pacote `.fitjourney` (zip) e da pasta de mídia.
    static let dataFileName = "data.json"
    static let mediaFolder = "media"
    static let packageExtension = "fitjourney"

    struct Document: Codable, Sendable, Equatable {
        var format: String = BackupV1.format
        var schemaVersion: Int = BackupV1.schemaVersion
        var exportedAt: Date
        var app: AppInfo
        var options: Options
        var exercises: [Exercise] = []
        var programs: [Program] = []
        var sessions: [Session] = []
        var nutritionPlans: [NutritionPlan] = []
        var foodEntries: [FoodEntry] = []
        var waterLogs: [WaterLog] = []
        /// Alimentos favoritos/recentes (`FoodItem`).
        var foods: [Food] = []
        /// `nil` quando a exportação não incluiu conversas (opção desligada).
        var coachConversations: [Conversation]?
        var coachProfile: CoachProfileInfo?
        var preferences: Preferences = Preferences()
        /// Arquivos de mídia referenciados pelos exercícios (manifesto; os bytes vão em `media/`).
        var media: [MediaFile] = []
    }

    struct AppInfo: Codable, Sendable, Equatable {
        var name: String
        var version: String
        var build: String
        var platform: String
        /// Identificador do fuso do aparelho no momento da exportação (ex.: "America/Sao_Paulo").
        var timeZone: String
        var locale: String
    }

    struct Options: Codable, Sendable, Equatable {
        var includesMedia: Bool
        var includesCoachConversations: Bool
    }

    // MARK: Valores compostos

    struct RepTargetValue: Codable, Sendable, Equatable {
        /// fixed | range | amrap
        var kind: String
        var reps: Int?
        var min: Int?
        var max: Int?
    }

    struct LoadValue: Codable, Sendable, Equatable {
        /// weight | bodyweight (value = lastro + / assistência −)
        var kind: String
        var value: Double
        var unit: String
    }

    struct EffortValue: Codable, Sendable, Equatable {
        /// rir | rpe
        var kind: String
        var value: Double
    }

    struct CardioValue: Codable, Sendable, Equatable {
        var durationSeconds: Int?
        var distanceMeters: Double?
        var level: Int?
        var speedKmh: Double?
        var inclinePercent: Double?
        var heartRateZone: Int?
    }

    struct MediaValue: Codable, Sendable, Equatable {
        /// image | localVideo | externalVideo
        var kind: String
        var fileName: String?
        var thumbnailFileName: String?
        var url: String?
        var provider: String?
        var videoID: String?
    }

    struct Nutrients: Codable, Sendable, Equatable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
    }

    // MARK: Treino — planejamento

    struct Exercise: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
        var equipment: String
        var laterality: String
        var measurementKind: String
        var media: [MediaValue]
        /// Embutido: casado pelo `catalogKey` na importação (os IDs mudam entre instalações).
        var isBuiltIn: Bool
        var catalogKey: String?
        var notes: String
        var defaultRestSeconds: Int
    }

    struct Program: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var goal: String
        var goalText: String
        var scheduleMode: String
        var startDate: Date
        var endDate: Date?
        var notes: String
        var isActive: Bool
        var isArchived: Bool
        var origin: String
        var routines: [Routine]
    }

    struct Routine: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var symbol: String
        var colorName: String
        var weekdays: [String]
        var sortIndex: Int
        var notes: String
        var exercises: [RoutineExercise]
    }

    struct RoutineExercise: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        /// `Exercise.id` deste backup; `nil` = exercício removido do catálogo.
        var exerciseID: UUID?
        var sortIndex: Int
        var groupID: UUID?
        var notes: String
        var restSeconds: Int?
        var sets: [SetPrescription]
    }

    struct SetPrescription: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var sortIndex: Int
        var kind: String
        var repTarget: RepTargetValue?
        var holdSeconds: Int?
        var initialLoad: LoadValue?
        var currentLoad: LoadValue?
        var restSeconds: Int?
        var tempo: String?
        var effort: EffortValue?
        var cardio: CardioValue?
        var notes: String
    }

    // MARK: Treino — execução

    struct Session: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var routineID: UUID?
        var programID: UUID?
        var routineName: String
        var startedAt: Date
        var endedAt: Date?
        /// inProgress | completed | discarded
        var status: String
        var sessionRPE: Int?
        var mood: Int?
        var notes: String
        var healthKitWorkoutID: UUID?
        var pausedAt: Date?
        var accumulatedPauseSeconds: Double
        var restEndsAt: Date?
        var lastActivityAt: Date?
        var exercises: [SessionExercise]
    }

    struct SessionExercise: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var exerciseID: UUID?
        var routineExerciseID: UUID?
        var name: String
        var measurementKind: String
        var laterality: String
        var sortIndex: Int
        var groupID: UUID?
        var restSeconds: Int?
        var status: String
        var skipReason: String?
        var skipReasonText: String?
        var substitutedFromExerciseID: UUID?
        var substitutedFromName: String?
        var notes: String
        var painLocation: String?
        var painLevel: Int?
        var sets: [PerformedSet]
    }

    struct PerformedSet: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var sortIndex: Int
        var prescriptionID: UUID?
        var kind: String
        var repTarget: RepTargetValue?
        var plannedLoad: LoadValue?
        var targetHoldSeconds: Int?
        var restSeconds: Int?
        var cardioTarget: CardioValue?
        var reps: Int?
        var load: LoadValue?
        var durationSeconds: Double?
        var distanceMeters: Double?
        var isCompleted: Bool
        var completedAt: Date?
        var edited: Bool
    }

    // MARK: Dieta

    struct NutritionTargetsValue: Codable, Sendable, Equatable {
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var fiber: Double?
        var waterMilliliters: Double?
    }

    struct NutritionPlan: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var goal: String
        var startDate: Date
        var endDate: Date?
        var author: String
        var isActive: Bool
        var isArchived: Bool
        var notes: String
        var targets: NutritionTargetsValue
        var days: [NutritionDay]
    }

    struct NutritionDay: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        /// Vazio = todos os dias.
        var weekdays: [String]
        var sortIndex: Int
        var meals: [Meal]
    }

    struct Meal: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var minutesFromMidnight: Int
        var reminderEnabled: Bool
        var sortIndex: Int
        var notes: String
        var items: [MealItem]
    }

    struct MealItem: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var quantity: Double
        var unit: String
        var nutrients: Nutrients
        var notes: String
        var sortIndex: Int
        var substitutions: [Substitution]
    }

    struct Substitution: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var quantity: Double
        var unit: String
        var nutrients: Nutrients
        var notes: String
    }

    struct Food: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var servingQuantity: Double
        var unit: String
        var nutrients: Nutrients
        var isFavorite: Bool
        var lastUsedAt: Date?
        var useCount: Int
        var estimation: String
    }

    struct FoodEntry: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var date: Date
        var mealID: UUID?
        var mealName: String?
        var name: String
        var quantity: Double
        var unit: String
        var nutrients: Nutrients
        var estimation: String
        var mealStatus: String?
        var notes: String
        var plannedItemID: UUID?
    }

    struct WaterLog: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var date: Date
        var milliliters: Double
    }

    // MARK: Coach

    struct Conversation: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var titleIsUserEdited: Bool
        var provider: String?
        var modelID: String?
        var isArchived: Bool
        var messages: [Message]
    }

    struct Message: Codable, Sendable, Equatable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var role: String
        var content: String
        var reasoning: String?
        var state: String
        var failureReason: String?
        var sortIndex: Int
        var modelID: String?
        var promptTokens: Int?
        var completionTokens: Int?
        /// JSON opaco do app (chamadas de ferramenta, blocos de raciocínio, proposta).
        var toolCalls: JSONValue?
        var reasoningBlocks: JSONValue?
        var toolCallID: String?
        var toolName: String?
        var toolResultIsError: Bool
        var proposal: JSONValue?
    }

    struct CoachProfileInfo: Codable, Sendable, Equatable {
        var age: Int?
        var sex: String?
        var heightCm: Double?
        var weightKg: Double?
        var level: String?
        var goal: String?
        var restrictions: String?
        var equipment: String?
        var daysPerWeek: Int?
        var minutesPerSession: Int?
        var foodPreferences: String?
        /// Informativo: a importação **nunca** concede compartilhamento com o provedor de IA.
        var sharing: Sharing
        var consentedAt: Date?

        struct Sharing: Codable, Sendable, Equatable {
            var profile: Bool
            var workouts: Bool
            var nutrition: Bool
            var health: Bool
        }
    }

    // MARK: Preferências (não secretas)

    struct Preferences: Codable, Sendable, Equatable {
        /// kg | lb
        var weightUnit: String?
        var coachProvider: CoachProvider?
    }

    struct CoachProvider: Codable, Sendable, Equatable {
        var provider: String
        /// Modelo escolhido por provedor (chave = provider).
        var models: [String: String]
        var customBaseURL: String?
        var customContextTokens: Int?
    }

    struct MediaFile: Codable, Sendable, Equatable {
        var fileName: String
        var byteCount: Int?
        /// O arquivo está em `media/` do pacote.
        var included: Bool
    }
}

// MARK: - Codificação JSON

extension BackupV1 {
    private static let whole = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
    private static let wholeCompact = Date.ISO8601FormatStyle(timeZoneSeparator: .omitted)

    /// "2026-11-11T09:30:00.123-03:00" no fuso dado. Milissegundos por aritmética inteira (arredondados),
    /// para que formatar → ler → formatar devolva sempre o mesmo texto.
    static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = totalMs >= 0 ? totalMs / 1000 : -((-totalMs + 999) / 1000)
        let ms = Int(totalMs - seconds * 1000)
        var style = whole
        style.timeZone = timeZone
        let text = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(style)
        let cut = text.index(text.startIndex, offsetBy: min(19, text.count)) // "yyyy-MM-ddTHH:mm:ss"
        return String(text[..<cut]) + String(format: ".%03d", ms) + String(text[cut...])
    }

    /// Aceita com ou sem fração (qualquer número de dígitos), com "Z" ou deslocamento (±hh:mm ou ±hhmm).
    static func parseDate(_ string: String) -> Date? {
        var text = string
        var fraction = 0.0
        if text.count > 20, text[text.index(text.startIndex, offsetBy: 19)] == "." {
            let start = text.index(text.startIndex, offsetBy: 20)
            let digits = text[start...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            text = String(text[..<text.index(text.startIndex, offsetBy: 19)]) + String(text[digits.endIndex...])
        }
        for style in [whole, wholeCompact] {
            if let date = try? Date(text, strategy: style) {
                // Volta a milissegundos inteiros (mesma grade do `formatDate`).
                let ms = ((date.timeIntervalSince1970 + fraction) * 1000).rounded()
                return Date(timeIntervalSince1970: ms / 1000)
            }
        }
        return nil
    }

    static func makeEncoder(timeZone: TimeZone = .current, pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date, timeZone: timeZone))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Data ISO-8601 inválida: \(raw)")
            }
            return date
        }
        return decoder
    }
}
