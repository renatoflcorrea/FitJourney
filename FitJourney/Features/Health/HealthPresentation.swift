import Foundation
import SwiftUI

// Apresentação pura da aba Saúde e do gráfico de FC (DESIGN_DIRECTION §4.11). Sem HealthKit, sem
// SwiftData: testável. Regra de ouro: sem dado não é zero — leitura vazia vira "—" com o motivo.

/// Como uma leitura do Saúde aparece numa célula.
struct HealthReadingDisplay: Equatable {
    /// `nil` = "—" (a célula mostra o traço).
    var value: String?
    /// Motivo em texto quando não há valor.
    var note: String?
    /// `noData` pode ser leitura negada: oferecer "Revisar permissões".
    var offersPermissionReview: Bool

    static let noDataNote = String(localized: "Sem dados")
    static let unavailableNote = String(localized: "Indisponível")
}

enum HealthPresentation {
    // MARK: Leituras

    static func display<Value: Sendable>(_ reading: HealthReading<Value>, format: (Value) -> String) -> HealthReadingDisplay {
        switch reading {
        case .available(let value):
            HealthReadingDisplay(value: format(value), note: nil, offersPermissionReview: false)
        case .noData:
            HealthReadingDisplay(value: nil, note: HealthReadingDisplay.noDataNote, offersPermissionReview: true)
        case .unavailable:
            HealthReadingDisplay(value: nil, note: HealthReadingDisplay.unavailableNote, offersPermissionReview: false)
        }
    }

    static func wholeNumber(_ value: Double) -> String { FJFormat.number(value, maxFractionDigits: 0) }

    static func bpm(_ value: Double) -> String { String(Int(value.rounded())) }

    /// "58–164" (ou "72" quando mínimo = máximo).
    static func bpmRange(_ stats: HeartRateStats) -> String {
        let low = Int(stats.minimum.rounded()), high = Int(stats.maximum.rounded())
        return low == high ? "\(low)" : "\(low)–\(high)"
    }

    /// "52 min" ou "1 h 05".
    static func minutes(_ value: Double) -> String {
        let total = Int(value.rounded())
        guard total >= 60 else { return String(localized: "\(total) min") }
        return String(localized: "\(total / 60) h \(String(format: "%02d", total % 60))")
    }

    static func minutes(seconds: TimeInterval) -> String { minutes(seconds / 60) }

    // MARK: Comparação com a semana (texto neutro)

    enum ComparisonUnit: Sendable {
        case kcal, bpm

        var short: String { self == .kcal ? "kcal" : "bpm" }
        var spoken: String { self == .kcal ? String(localized: "quilocalorias") : String(localized: "batimentos por minuto") }
    }

    struct Comparison: Equatable {
        enum Kind: Equatable { case above, below, onAverage, fewDays }
        var kind: Kind
        var text: String
        var spokenText: String
    }

    /// Valor de hoje contra a média dos 7 dias anteriores (hoje fora da média). Menos de 3 dias com
    /// dado: "Poucos dias para comparar". Diferença menor que 2 %: "na média". Sem "bom/ruim".
    static func compare(today: Double, previousDays: [Double], unit: ComparisonUnit, partialDay: Bool = false) -> Comparison {
        guard previousDays.count >= 3 else {
            let text = String(localized: "Poucos dias para comparar")
            return Comparison(kind: .fewDays, text: text, spokenText: text)
        }
        let mean = previousDays.reduce(0, +) / Double(previousDays.count)
        let delta = today - mean
        let suffix = partialDay ? String(localized: " (até agora)") : ""
        guard mean > 0, abs(delta) / mean >= 0.02 else {
            let text = String(localized: "na média") + suffix
            return Comparison(kind: .onAverage, text: text, spokenText: String(localized: "Na média dos 7 dias anteriores") + suffix)
        }
        let amount = Int(abs(delta).rounded())
        if delta > 0 {
            return Comparison(kind: .above, text: "↑ \(amount) \(unit.short) " + String(localized: "acima da sua média") + suffix,
                              spokenText: "\(amount) \(unit.spoken) " + String(localized: "acima da sua média de 7 dias") + suffix)
        }
        return Comparison(kind: .below, text: "↓ \(amount) \(unit.short) " + String(localized: "abaixo da sua média") + suffix,
                          spokenText: "\(amount) \(unit.spoken) " + String(localized: "abaixo da sua média de 7 dias") + suffix)
    }

    // MARK: Zonas

    static func designZone(_ zone: HeartRateZone) -> FJHeartRateZone {
        FJHeartRateZone(rawValue: zone.rawValue) ?? .z1
    }

    /// FC máxima guardada (`fj.maxHeartRate`); 0/ausente = não definida.
    static let maxHeartRateKey = "fj.maxHeartRate"

    static func resolveZones(storedMax: Double, age: Int? = nil) -> MaxHeartRateResolution {
        HeartRateZones.resolve(configuredMax: storedMax > 0 ? storedMax : nil, age: age)
    }

    // MARK: Tipo de treino

    static func kind(_ category: HealthWorkoutCategory) -> FJWorkoutKind? {
        switch category {
        case .strength: .strength
        case .aerobic: .aerobic
        case .mixed, .mobility, .other: nil
        }
    }

    // MARK: Faixas por exercício

    struct ExerciseBand: Equatable, Identifiable {
        var id: UUID
        /// Posição do exercício na ficha (1-based): o número do selo e da lista.
        var number: Int
        var name: String
        var interval: DateInterval
    }

    /// Faixas do gráfico: da 1ª à última série concluída. Exercício sem série concluída não tem faixa.
    static func bands(_ timeline: HealthSessionTimeline) -> [ExerciseBand] {
        timeline.exercises.enumerated().compactMap { offset, exercise in
            guard let band = exercise.band else { return nil }
            return ExerciseBand(id: exercise.id, number: offset + 1, name: exercise.name, interval: band)
        }
    }

    /// Faixa mais estreita que 16 pt: o número sai do gráfico e fica só na lista.
    static let minimumBandLabelWidth: CGFloat = 16

    static func showsBandLabel(band: DateInterval, total: DateInterval, plotWidth: CGFloat, visibleSeconds: TimeInterval? = nil) -> Bool {
        let span = visibleSeconds ?? total.duration
        guard span > 0, plotWidth > 0 else { return false }
        return CGFloat(band.duration / span) * plotWidth >= minimumBandLabelWidth
    }

    /// Cabeçalho do cartão do gráfico: "2 · Supino inclinado — série 3 · média 131 · máx 142 bpm".
    static func selectionTitle(number: Int?, exercise: String, setNumber: Int?, stats: HeartRateStats?) -> String {
        var parts: [String] = []
        var name = number.map { "\($0) · \(exercise)" } ?? exercise
        if let setNumber { name += " — " + String(localized: "série \(setNumber)") }
        parts.append(name)
        if let stats {
            parts.append(String(localized: "média \(bpm(stats.average))"))
            parts.append(String(localized: "máx \(bpm(stats.maximum)) bpm"))
        }
        return parts.joined(separator: " · ")
    }

    /// Linhas de zona a desenhar: limites inferiores de Z2…Z5 (Z1 começa em 50 %).
    static func zoneLines(_ zones: HeartRateZones) -> [(zone: HeartRateZone, bpm: Double)] {
        HeartRateZone.allCases.dropFirst().map { ($0, zones.range(for: $0).lowerBound) }
    }

    /// Quebra a série em trechos nas lacunas (> `maxGap`), para a linha não atravessar buracos.
    static func segments(_ samples: [HeartRateSample], maxGap: TimeInterval = HeartRateAnalysis.maxSampleGap * 2) -> [[HeartRateSample]] {
        var result: [[HeartRateSample]] = []
        var current: [HeartRateSample] = []
        for sample in HeartRateAnalysis.valid(samples) {
            if let last = current.last, sample.date.timeIntervalSince(last.date) > maxGap {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Reduz a série a no máximo `limit` pontos (média por balde de tempo) — para o descritor de acessibilidade.
    static func downsample(_ samples: [HeartRateSample], to limit: Int) -> [HeartRateSample] {
        let valid = HeartRateAnalysis.valid(samples)
        guard valid.count > limit, limit > 0, let first = valid.first, let last = valid.last else { return valid }
        let width = max(1, last.date.timeIntervalSince(first.date) / Double(limit))
        let buckets = HeartRateAnalysis.buckets(valid, in: DateInterval(start: first.date, end: last.date.addingTimeInterval(1)), width: width)
        return buckets.map { HeartRateSample(date: $0.interval.start, bpm: $0.average) }
    }

    // MARK: Dia: linhas de treino

    struct WorkoutRow: Equatable, Identifiable {
        enum Origin: Equatable { case app, appAndWatch, external(String) }
        var id: UUID
        var title: String
        var category: HealthWorkoutCategory
        var interval: DateInterval
        var origin: Origin
        var averageHeartRate: Double?
        var energyKcal: Double?
        /// Sugestão de confiança alta já vinculada (mostra "Desfazer").
        var linkedSuggestion: HealthDayEntry.LinkSuggestion?
        /// Sugestão incerta pendente (treino externo que talvez seja uma sessão do app).
        var pendingSuggestion: HealthDayEntry.LinkSuggestion?
        var sessionID: UUID?
        var workoutRecord: HealthWorkoutRecord?
    }

    /// Decisões "Não é o mesmo" guardadas localmente: chave `sessionID|workoutID`.
    static func pairKey(sessionID: UUID, workoutID: UUID) -> String { "\(sessionID.uuidString)|\(workoutID.uuidString)" }

    /// Linhas do dia: uma por sessão do app (com o treino do Watch vinculado), uma por treino externo.
    /// Sugestões descartadas ("não é o mesmo") separam os dois treinos.
    static func rows(_ summary: HealthDaySummary, dismissedPairs: Set<String>) -> [WorkoutRow] {
        var rows: [WorkoutRow] = []
        for entry in summary.entries {
            switch entry {
            case .session(let window, let own, let suggestions):
                let kept = suggestions.filter { !dismissedPairs.contains(pairKey(sessionID: $0.sessionID, workoutID: $0.workout.id)) }
                let separated = suggestions.filter { dismissedPairs.contains(pairKey(sessionID: $0.sessionID, workoutID: $0.workout.id)) }
                let linkedWatch = (own.map { !$0.isFromThisApp } ?? false) || !kept.isEmpty
                let title = window.routineName.isEmpty ? String(localized: "Treino livre") : window.routineName
                let energy = own?.activeEnergyKcal ?? kept.first?.workout.activeEnergyKcal
                rows.append(WorkoutRow(
                    id: window.sessionID, title: title, category: window.category, interval: window.interval,
                    origin: linkedWatch ? .appAndWatch : .app,
                    averageHeartRate: summary.averageHeartRateByEntry[entry.id], energyKcal: energy,
                    linkedSuggestion: own == nil ? kept.first : nil, pendingSuggestion: nil,
                    sessionID: window.sessionID, workoutRecord: own ?? kept.first?.workout))
                for suggestion in separated {
                    rows.append(externalRow(suggestion.workout, suggestion: nil, summary: summary))
                }
            case .external(let record, let suggestion):
                let pending = suggestion.flatMap { dismissedPairs.contains(pairKey(sessionID: $0.sessionID, workoutID: record.id)) ? nil : $0 }
                rows.append(externalRow(record, suggestion: pending, summary: summary))
            }
        }
        return rows.sorted { $0.interval.start < $1.interval.start }
    }

    private static func externalRow(_ record: HealthWorkoutRecord, suggestion: HealthDayEntry.LinkSuggestion?,
                                    summary: HealthDaySummary) -> WorkoutRow {
        let title = record.workoutType?.localizedName ?? record.routineName ?? record.category.localizedName
        return WorkoutRow(id: record.id, title: title, category: record.category, interval: record.interval,
                          origin: .external(record.sourceName),
                          averageHeartRate: record.averageHeartRate ?? summary.averageHeartRateByEntry[record.id],
                          energyKcal: record.activeEnergyKcal, linkedSuggestion: nil, pendingSuggestion: suggestion,
                          sessionID: nil, workoutRecord: record)
    }

    /// "18:05 · 52 min · FC média 128 · 318 kcal" — só o que existe (nunca zero).
    static func rowDetail(_ row: WorkoutRow) -> String {
        var parts = [row.interval.start.formatted(.dateTime.hour().minute()), minutes(seconds: row.interval.duration)]
        if let hr = row.averageHeartRate { parts.append(String(localized: "FC média \(bpm(hr))")) }
        if let kcal = row.energyKcal { parts.append("\(wholeNumber(kcal)) kcal") }
        return parts.joined(separator: " · ")
    }

    static func originText(_ origin: WorkoutRow.Origin) -> String {
        switch origin {
        case .app: String(localized: "FitJourney")
        case .appAndWatch: String(localized: "FitJourney + Apple Watch")
        case .external(let name): name
        }
    }

    // MARK: Semana e tendências

    typealias CategorizedInterval = (category: HealthWorkoutCategory, interval: DateInterval)

    /// Minutos por tipo e por dia (união dentro de cada tipo); `days` = início de cada dia.
    static func dailyMinutes(_ intervals: [CategorizedInterval], days: [Date],
                             calendar: Calendar = .current) -> [[FJWorkoutKind: Double]] {
        days.map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let clip = DateInterval(start: day, end: end)
            var result: [FJWorkoutKind: Double] = [:]
            for kind in FJWorkoutKind.allCases {
                let ofKind = intervals.filter { Self.kind($0.category) == kind }.map(\.interval)
                let minutes = DateIntervalMath.unionDuration(ofKind, clippedTo: clip) / 60
                if minutes > 0 { result[kind] = minutes }
            }
            return result
        }
    }

    /// Minutos por semana (início de cada semana) e tipo.
    static func weeklyMinutes(_ intervals: [CategorizedInterval], weekStarts: [Date],
                              calendar: Calendar = .current) -> [[FJWorkoutKind: Double]] {
        weekStarts.map { start in
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            var total: [FJWorkoutKind: Double] = [:]
            for day in dailyMinutes(intervals, days: days, calendar: calendar) {
                for (kind, value) in day { total[kind, default: 0] += value }
            }
            return total
        }
    }

    static func trendText(_ direction: HealthTrendDirection?) -> String {
        switch direction {
        case .up?: String(localized: "↑ acima dos 7 dias anteriores")
        case .down?: String(localized: "↓ abaixo dos 7 dias anteriores")
        case .stable?: String(localized: "estável em relação aos 7 dias anteriores")
        case nil: String(localized: "Continue registrando para ver a tendência")
        }
    }

    /// Média móvel de `window` valores (só dias com dado).
    static func movingAverage(_ values: [HealthDailyValue], window: Int = 7) -> [HealthDailyValue] {
        let sorted = values.sorted { $0.day < $1.day }
        return sorted.indices.map { index in
            let slice = sorted[max(0, index - window + 1)...index]
            return HealthDailyValue(day: sorted[index].day, value: slice.map(\.value).reduce(0, +) / Double(slice.count))
        }
    }
}

// MARK: - Preferências locais

/// "Não é o mesmo": guardado localmente (UserDefaults) até o núcleo ter campo.
enum HealthDismissedLinks {
    static let key = "fj.health.dismissedLinks"

    static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func add(sessionID: UUID, workoutID: UUID, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        all.insert(HealthPresentation.pairKey(sessionID: sessionID, workoutID: workoutID))
        defaults.set(Array(all), forKey: key)
    }
}

// MARK: - Ambiente

private struct HealthReaderKey: EnvironmentKey {
    static let defaultValue: (any HealthDataReading)? = nil
}

extension EnvironmentValues {
    /// Leitor do Saúde das telas. `nil` = usa `HealthQueries.live` (previews e testes injetam fakes).
    var healthReader: (any HealthDataReading)? {
        get { self[HealthReaderKey.self] }
        set { self[HealthReaderKey.self] = newValue }
    }
}

extension View {
    func healthReader(_ reader: any HealthDataReading) -> some View { environment(\.healthReader, reader) }
}

@MainActor
enum HealthSettings {
    /// Ajustes do app no sistema (Saúde › Acesso a Dados fica a dois toques dali).
    static func open(_ openURL: OpenURLAction) {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
