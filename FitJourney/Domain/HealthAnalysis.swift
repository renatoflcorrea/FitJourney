import Foundation

// Regras puras de análise de saúde (SPEC §6.3). Só Foundation: nada de HealthKit, SwiftUI ou
// SwiftData. "Indisponível ≠ zero": ausência de dados é sempre `nil`/vazio, nunca 0.

// MARK: - Amostras

/// Amostra de frequência cardíaca (bpm) num instante.
struct HeartRateSample: Sendable, Hashable, Codable {
    var date: Date
    var bpm: Double

    init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// FC agregada num intervalo (ex.: 5 s na sessão, 5 min no dia).
struct HeartRateBucket: Sendable, Hashable {
    var interval: DateInterval
    var average: Double
    var minimum: Double
    var maximum: Double
}

/// Valor diário (FC em repouso, passos…).
struct HealthDailyValue: Sendable, Hashable {
    /// Início do dia.
    var day: Date
    var value: Double
}

/// Resultado de leitura do Saúde: distingue "sem dados" de "indisponível" — nunca vira zero.
/// A negação de leitura não é detectável pelo HealthKit: ela aparece como `.noData`, e a UI deve
/// oferecer "revisar permissões" nesse caso.
enum HealthReading<Value: Sendable>: Sendable {
    case available(Value)
    /// Consulta ok, mas sem amostras (pode ser falta de dados **ou** leitura negada).
    case noData
    /// Saúde indisponível (aparelho sem HealthKit, não conectado ou erro de consulta).
    case unavailable

    var value: Value? { if case .available(let value) = self { value } else { nil } }

    func map<T: Sendable>(_ transform: (Value) -> T) -> HealthReading<T> {
        switch self {
        case .available(let value): .available(transform(value))
        case .noData: .noData
        case .unavailable: .unavailable
        }
    }
}

extension HealthReading: Equatable where Value: Equatable {}

// MARK: - Zonas de FC

/// Zona de FC por % da FC máxima (modelo de 5 zonas): Z1 50–60 %, Z2 60–70 %, Z3 70–80 %,
/// Z4 80–90 %, Z5 ≥ 90 %. Abaixo de 50 % não há zona.
enum HeartRateZone: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
    case zone1 = 1, zone2, zone3, zone4, zone5

    /// Fração mínima da FC máxima (inclusiva).
    var lowerFraction: Double { Double(rawValue + 4) / 10 }
    /// Fração máxima (exclusiva); Z5 não tem teto.
    var upperFraction: Double? { self == .zone5 ? nil : Double(rawValue + 5) / 10 }

    var localizedName: String {
        switch self {
        case .zone1: String(localized: "Zona 1 · Muito leve")
        case .zone2: String(localized: "Zona 2 · Leve")
        case .zone3: String(localized: "Zona 3 · Moderada")
        case .zone4: String(localized: "Zona 4 · Intensa")
        case .zone5: String(localized: "Zona 5 · Máxima")
        }
    }

    static func < (lhs: HeartRateZone, rhs: HeartRateZone) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// De onde veio a FC máxima.
enum MaxHeartRateSource: String, Sendable, Hashable {
    /// Informada pelo usuário.
    case configured
    /// Estimada por 220 − idade.
    case ageEstimate
}

/// Resolução da FC máxima: configurada > 220 − idade > pedir ao usuário.
enum MaxHeartRateResolution: Sendable, Hashable {
    case resolved(bpm: Double, source: MaxHeartRateSource)
    /// Sem FC máxima configurada nem idade: a UI pede um dos dois (zonas ficam ocultas).
    case needsInput

    var zones: HeartRateZones? {
        if case .resolved(let bpm, _) = self { HeartRateZones(maxHeartRate: bpm) } else { nil }
    }
}

/// Limites das 5 zonas para uma FC máxima.
struct HeartRateZones: Sendable, Hashable {
    static let validMaxHeartRate: ClosedRange<Double> = 100...230
    static let validAge: ClosedRange<Int> = 10...100

    var maxHeartRate: Double

    init(maxHeartRate: Double) {
        self.maxHeartRate = maxHeartRate
    }

    /// FC máxima: a configurada (se válida), senão 220 − idade (se válida), senão `.needsInput`.
    static func resolve(configuredMax: Double?, age: Int?) -> MaxHeartRateResolution {
        if let configuredMax, validMaxHeartRate.contains(configuredMax) {
            return .resolved(bpm: configuredMax, source: .configured)
        }
        if let age, validAge.contains(age) {
            return .resolved(bpm: Double(220 - age), source: .ageEstimate)
        }
        return .needsInput
    }

    /// Idade completa em anos numa data.
    static func age(birthDate: Date, at date: Date, calendar: Calendar = .current) -> Int? {
        let years = calendar.dateComponents([.year], from: birthDate, to: date).year
        guard let years, years >= 0 else { return nil }
        return years
    }

    /// Zona de um bpm; `nil` abaixo de 50 % da FC máxima.
    func zone(for bpm: Double) -> HeartRateZone? {
        guard maxHeartRate > 0 else { return nil }
        let fraction = bpm / maxHeartRate
        return HeartRateZone.allCases.last { fraction >= $0.lowerFraction }
    }

    /// Faixa de bpm de uma zona (para desenhar as faixas no gráfico). Z5 vai até a FC máxima.
    func range(for zone: HeartRateZone) -> ClosedRange<Double> {
        let lower = zone.lowerFraction * maxHeartRate
        let upper = (zone.upperFraction ?? 1) * maxHeartRate
        return lower...upper
    }
}

/// Tempo em cada zona.
struct ZoneDurations: Sendable, Hashable {
    var byZone: [HeartRateZone: TimeInterval] = [:]
    /// Tempo abaixo da Z1 (< 50 %).
    var belowZones: TimeInterval = 0

    var total: TimeInterval { byZone.values.reduce(belowZones, +) }

    func duration(in zone: HeartRateZone) -> TimeInterval { byZone[zone] ?? 0 }

    /// Fração do tempo total numa zona (0 sem dados).
    func fraction(in zone: HeartRateZone) -> Double {
        total > 0 ? duration(in: zone) / total : 0
    }
}

/// FC média/mín/máx de um trecho.
struct HeartRateStats: Sendable, Hashable {
    var average: Double
    var minimum: Double
    var maximum: Double
    var sampleCount: Int
}

// MARK: - Agregações

enum HeartRateAnalysis {
    /// Uma amostra "vale" até a próxima, limitada a isto (buracos sem sinal não contam).
    static let maxSampleGap: TimeInterval = 60

    /// Amostras ordenadas dentro do intervalo (inclusivo nas pontas).
    static func samples(_ samples: [HeartRateSample], in interval: DateInterval) -> [HeartRateSample] {
        samples.filter { interval.contains($0.date) }.sorted { $0.date < $1.date }
    }

    /// Média simples, mínimo e máximo das amostras do intervalo; `nil` sem amostras (nunca zero).
    static func stats(_ samples: [HeartRateSample], in interval: DateInterval? = nil) -> HeartRateStats? {
        let inside = interval.map { HeartRateAnalysis.samples(samples, in: $0) } ?? samples
        guard !inside.isEmpty else { return nil }
        let values = inside.map(\.bpm)
        return HeartRateStats(average: values.reduce(0, +) / Double(values.count),
                              minimum: values.min() ?? 0, maximum: values.max() ?? 0,
                              sampleCount: values.count)
    }

    /// Tempo em zona: cada amostra vale até a seguinte (no máximo `maxGap`); a última vale até o fim
    /// do intervalo (se houver), também limitada a `maxGap`. Tudo recortado ao intervalo.
    static func timeInZones(_ samples: [HeartRateSample], zones: HeartRateZones, within interval: DateInterval? = nil,
                            maxGap: TimeInterval = maxSampleGap) -> ZoneDurations {
        let sorted = interval.map { HeartRateAnalysis.samples(samples, in: $0) } ?? samples.sorted { $0.date < $1.date }
        var result = ZoneDurations()
        for (index, sample) in sorted.enumerated() {
            let nextDate = index + 1 < sorted.count ? sorted[index + 1].date : interval?.end
            guard let nextDate else { continue }
            let duration = min(max(0, nextDate.timeIntervalSince(sample.date)), maxGap)
            guard duration > 0 else { continue }
            if let zone = zones.zone(for: sample.bpm) {
                result.byZone[zone, default: 0] += duration
            } else {
                result.belowZones += duration
            }
        }
        return result
    }

    /// Agrupa amostras em baldes de `width` segundos a partir de `interval.start` (baldes vazios omitidos).
    static func buckets(_ samples: [HeartRateSample], in interval: DateInterval, width: TimeInterval) -> [HeartRateBucket] {
        guard width > 0 else { return [] }
        var groups: [Int: [Double]] = [:]
        for sample in HeartRateAnalysis.samples(samples, in: interval) {
            let index = Int(sample.date.timeIntervalSince(interval.start) / width)
            groups[index, default: []].append(sample.bpm)
        }
        return groups.keys.sorted().compactMap { index in
            guard let values = groups[index], !values.isEmpty else { return nil }
            let start = interval.start.addingTimeInterval(Double(index) * width)
            let end = min(start.addingTimeInterval(width), interval.end)
            return HeartRateBucket(interval: DateInterval(start: start, end: max(start, end)),
                                   average: values.reduce(0, +) / Double(values.count),
                                   minimum: values.min() ?? 0, maximum: values.max() ?? 0)
        }
    }
}

// MARK: - Linha do tempo da sessão

/// Retrato da sessão para análise de FC e para os eventos do `HKWorkout` (sem SwiftData).
/// Montado a partir de `WorkoutSession` em `Services/Health`.
struct HealthSessionTimeline: Sendable, Hashable {
    struct SetMark: Sendable, Hashable {
        /// `SetLog.id`.
        var id: UUID
        /// Posição 1-based no exercício ("série 2").
        var number: Int
        var completedAt: Date
        var isWorking: Bool = true
    }

    struct Exercise: Sendable, Hashable {
        /// `SessionExercise.id`.
        var id: UUID
        var catalogExerciseID: UUID?
        var name: String
        var measurementKind: MeasurementKind
        var primaryMuscles: [MuscleGroup] = []
        var equipment: Equipment?
        /// Séries concluídas, em ordem de conclusão.
        var sets: [SetMark]

        /// Faixa do exercício no gráfico: 1ª → última série concluída (SPEC §6.3).
        var band: DateInterval? {
            let dates = sets.map(\.completedAt).sorted()
            guard let first = dates.first, let last = dates.last else { return nil }
            return DateInterval(start: first, end: last)
        }

        var typeInput: HealthWorkoutTypeInput {
            HealthWorkoutTypeInput(measurementKind: measurementKind, primaryMuscles: primaryMuscles,
                                   equipment: equipment, name: name)
        }
    }

    var sessionID: UUID
    var routineName: String
    var startedAt: Date
    var endedAt: Date?
    /// Tempo ativo (sem pausas), quando conhecido.
    var activeDuration: TimeInterval?
    /// Na ordem da ficha.
    var exercises: [Exercise]

    var workoutType: HealthWorkoutType { HealthWorkoutType.derive(from: exercises.map(\.typeInput)) }

    /// Intervalo total (até o fim, ou até `now` se em andamento).
    func interval(now: Date = Date()) -> DateInterval {
        DateInterval(start: startedAt, end: max(startedAt, endedAt ?? now))
    }
}

/// Janela de análise de uma série: a série acontece antes de ser marcada como concluída e o pico de
/// FC costuma vir logo depois. Padrão: 60 s antes (sem invadir a série anterior do mesmo exercício)
/// até 15 s depois.
struct SetHeartRateWindow: Sendable, Hashable {
    var lookBack: TimeInterval = 60
    var lookAhead: TimeInterval = 15

    static let standard = SetHeartRateWindow()
}

/// FC de uma série.
struct SetHeartRate: Sendable, Hashable, Identifiable {
    var setID: UUID
    var number: Int
    var completedAt: Date
    var window: DateInterval
    var stats: HeartRateStats?

    var id: UUID { setID }
}

/// FC de um exercício (faixa colorida no gráfico).
struct ExerciseHeartRate: Sendable, Hashable, Identifiable {
    var exerciseID: UUID
    var name: String
    /// Faixa exibida: 1ª → última série concluída.
    var band: DateInterval
    /// Trecho analisado: da janela da 1ª série ao fim da janela da última.
    var analysisInterval: DateInterval
    var stats: HeartRateStats?
    var sets: [SetHeartRate]

    var id: UUID { exerciseID }
}

/// Análise de FC da sessão para o detalhe (gráfico com faixas e marcadores).
struct SessionHeartRateAnalysis: Sendable, Hashable {
    var interval: DateInterval
    var overall: HeartRateStats?
    /// `nil` quando a FC máxima não é conhecida (`MaxHeartRateResolution.needsInput`).
    var zones: HeartRateZones?
    var timeInZones: ZoneDurations?
    var exercises: [ExerciseHeartRate]

    var hasHeartRate: Bool { overall != nil }

    /// O que mostrar ao tocar no gráfico num instante: exercício cuja janela contém a data e, se
    /// houver, a série cuja janela contém a data.
    func lookup(at date: Date) -> (exercise: ExerciseHeartRate, set: SetHeartRate?)? {
        guard let exercise = exercises.first(where: { $0.analysisInterval.contains(date) }) else { return nil }
        return (exercise, exercise.sets.first { $0.window.contains(date) })
    }
}

enum SessionHeartRateAnalyzer {
    static func analyze(_ timeline: HealthSessionTimeline, samples: [HeartRateSample], zones: HeartRateZones?,
                        window: SetHeartRateWindow = .standard, now: Date = Date()) -> SessionHeartRateAnalysis {
        let interval = timeline.interval(now: now)
        let inside = HeartRateAnalysis.samples(samples, in: interval)
        let exercises: [ExerciseHeartRate] = timeline.exercises.compactMap { exercise in
            guard let band = exercise.band else { return nil }
            let ordered = exercise.sets.sorted { $0.completedAt < $1.completedAt }
            var previous: Date?
            let sets: [SetHeartRate] = ordered.map { mark in
                var start = mark.completedAt.addingTimeInterval(-window.lookBack)
                if let previous { start = max(start, previous) }
                start = max(start, interval.start)
                let end = min(mark.completedAt.addingTimeInterval(window.lookAhead), interval.end)
                let setWindow = DateInterval(start: min(start, end), end: max(start, end))
                previous = mark.completedAt
                return SetHeartRate(setID: mark.id, number: mark.number, completedAt: mark.completedAt,
                                    window: setWindow, stats: HeartRateAnalysis.stats(inside, in: setWindow))
            }
            let analysisStart = sets.map(\.window.start).min() ?? band.start
            let analysisEnd = sets.map(\.window.end).max() ?? band.end
            let analysis = DateInterval(start: analysisStart, end: max(analysisStart, analysisEnd))
            return ExerciseHeartRate(exerciseID: exercise.id, name: exercise.name, band: band,
                                     analysisInterval: analysis, stats: HeartRateAnalysis.stats(inside, in: analysis),
                                     sets: sets)
        }
        let overall = HeartRateAnalysis.stats(inside)
        let timeInZones = zones.flatMap { zones in
            overall == nil ? nil : HeartRateAnalysis.timeInZones(inside, zones: zones, within: interval)
        }
        return SessionHeartRateAnalysis(interval: interval, overall: overall, zones: zones,
                                        timeInZones: timeInZones, exercises: exercises)
    }
}

// MARK: - Eventos do HKWorkout

/// Eventos que acompanham o `HKWorkout` da sessão (SPEC §6.2): um segmento por exercício e um
/// marcador por série concluída. Tudo recortado ao intervalo do treino.
struct HealthWorkoutEventPlan: Sendable, Hashable {
    struct Segment: Sendable, Hashable {
        var exerciseID: UUID
        var exerciseName: String
        /// Ordem na ficha (1-based).
        var index: Int
        var interval: DateInterval
    }

    struct Marker: Sendable, Hashable {
        var setID: UUID
        var exerciseID: UUID
        var exerciseName: String
        var setNumber: Int
        var date: Date
    }

    /// Segmento de exercício com uma só série (1ª = última) ganha esta duração para trás.
    static let minimumSegment: TimeInterval = 30

    var segments: [Segment]
    var markers: [Marker]

    static func make(_ timeline: HealthSessionTimeline, workout: DateInterval) -> HealthWorkoutEventPlan {
        var segments: [Segment] = []
        var markers: [Marker] = []
        for (offset, exercise) in timeline.exercises.enumerated() {
            for mark in exercise.sets where workout.contains(mark.completedAt) {
                markers.append(Marker(setID: mark.id, exerciseID: exercise.id, exerciseName: exercise.name,
                                      setNumber: mark.number, date: mark.completedAt))
            }
            guard let band = exercise.band else { continue }
            var start = max(band.start, workout.start)
            let end = min(band.end, workout.end)
            guard end >= start else { continue }
            if end.timeIntervalSince(start) < minimumSegment {
                start = max(workout.start, end.addingTimeInterval(-minimumSegment))
            }
            guard end > start else { continue }
            segments.append(Segment(exerciseID: exercise.id, exerciseName: exercise.name, index: offset + 1,
                                    interval: DateInterval(start: start, end: end)))
        }
        markers.sort { $0.date < $1.date }
        return HealthWorkoutEventPlan(segments: segments, markers: markers)
    }
}

// MARK: - Energia estimada

/// Estimativa de energia ativa quando o Saúde não mediu (sem Watch/sensor): MET do tipo de treino
/// (Compendium of Physical Activities) × massa × horas, descontando o basal (MET − 1).
/// Sem massa corporal → `nil` (nunca chuta zero nem um peso padrão).
enum HealthEnergyEstimate {
    static func met(for type: HealthWorkoutType) -> Double {
        switch type {
        case .traditionalStrength: 3.5
        case .functionalStrength: 4.3
        case .hiit: 8.0
        case .core: 3.8
        case .flexibility: 2.5
        case .running: 9.8
        case .cycling: 7.0
        case .elliptical: 5.0
        case .rowing: 7.0
        case .stairClimbing: 9.0
        case .walking: 3.5
        case .mixedCardio: 6.0
        }
    }

    static func activeKilocalories(type: HealthWorkoutType, activeDuration: TimeInterval, bodyMassKg: Double?) -> Double? {
        guard let bodyMassKg, bodyMassKg > 0, activeDuration > 0 else { return nil }
        return (met(for: type) - 1) * bodyMassKg * activeDuration / 3_600
    }
}
