import SwiftData
import SwiftUI

// Apresentação compartilhada de fichas e programas (Hoje e Treinos).

/// Cores disponíveis para fichas (`Routine.colorName`), todas vindas de tokens do DesignSystem.
enum RoutineColor: String, CaseIterable, Identifiable {
    case orange, blue, green, teal, pink, magenta, gray

    var id: String { rawValue }

    init(name: String) { self = RoutineColor(rawValue: name) ?? .orange }

    var color: Color {
        switch self {
        case .orange: FJColor.training
        case .blue: FJColor.coach
        case .green: FJColor.nutrition
        case .teal: FJColor.aerobic
        case .pink: FJColor.health
        case .magenta: FJColor.zone5
        case .gray: FJColor.zone1
        }
    }

    var localizedName: LocalizedStringKey {
        switch self {
        case .orange: "Laranja"
        case .blue: "Azul"
        case .green: "Verde"
        case .teal: "Turquesa"
        case .pink: "Rosa"
        case .magenta: "Magenta"
        case .gray: "Cinza"
        }
    }
}

extension ScheduleMode {
    var systemImage: String {
        switch self {
        case .free: "shuffle"
        case .sequential: "arrow.triangle.2.circlepath"
        case .weekly: "calendar"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .free: "Escolho a ficha no dia. O app destaca a que está há mais tempo sem treinar."
        case .sequential: "A → B → C → A… O app sugere a próxima da sequência."
        case .weekly: "Cada ficha tem seus dias da semana."
        }
    }
}

extension Weekday {
    /// Inicial para os círculos de dia (S T Q Q S S D).
    var initial: String {
        switch self {
        case .monday: String(localized: "S", comment: "Inicial de segunda-feira")
        case .tuesday: String(localized: "T", comment: "Inicial de terça-feira")
        case .wednesday: String(localized: "Q", comment: "Inicial de quarta-feira")
        case .thursday: String(localized: "Q", comment: "Inicial de quinta-feira")
        case .friday: String(localized: "S", comment: "Inicial de sexta-feira")
        case .saturday: String(localized: "S", comment: "Inicial de sábado")
        case .sunday: String(localized: "D", comment: "Inicial de domingo")
        }
    }

    var fullName: String {
        switch self {
        case .monday: String(localized: "segunda")
        case .tuesday: String(localized: "terça")
        case .wednesday: String(localized: "quarta")
        case .thursday: String(localized: "quinta")
        case .friday: String(localized: "sexta")
        case .saturday: String(localized: "sábado")
        case .sunday: String(localized: "domingo")
        }
    }
}

extension Routine {
    var routineColor: RoutineColor { RoutineColor(name: colorName) }

    /// Letra do selo: `symbol`, senão a inicial do nome.
    var badgeLetter: String {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return String(trimmed.prefix(2)) }
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    var exerciseCount: Int { (exercises ?? []).count }

    /// "~55 min" (arredondado a 5 min); `nil` sem exercícios.
    var estimatedMinutesText: String? {
        guard exerciseCount > 0 else { return nil }
        let minutes = max(5, Int((Double(estimatedDurationSeconds) / 60 / 5).rounded()) * 5)
        return String(localized: "~\(minutes) min")
    }

    var exerciseCountText: String {
        String(localized: "\(exerciseCount) exercícios")
    }

    /// "6 exercícios · ~55 min" ou "Sem exercícios".
    var summaryText: String {
        guard exerciseCount > 0 else { return String(localized: "Sem exercícios") }
        return [exerciseCountText, estimatedMinutesText].compactMap { $0 }.joined(separator: " · ")
    }
}

extension RoutineExercise {
    /// "4 × 8–12 · 32,5 kg" (séries válidas; aquecimento e preparatória não contam).
    var prescriptionText: String {
        let working = sortedSets.filter { $0.kind.isWorking }
        guard let first = working.first ?? sortedSets.first else { return String(localized: "Sem séries") }
        let count = working.isEmpty ? sortedSets.count : working.count
        var parts: [String] = []
        if let cardio = first.cardio, let seconds = cardio.durationSeconds {
            parts.append(String(localized: "\(seconds / 60) min"))
        } else if let hold = first.holdSeconds {
            parts.append("\(count) × \(hold) s")
        } else if let target = first.repTarget {
            parts.append("\(count) × \(target.displayText)")
        } else {
            parts.append(String(localized: "\(count) séries"))
        }
        if let load = first.effectiveLoad { parts.append(Self.loadText(load)) }
        return parts.joined(separator: " · ")
    }

    static func loadText(_ load: Load) -> String {
        switch load {
        case .weight(let value, let unit):
            return "\(FJFormat.number(value, maxFractionDigits: 1)) \(unit.rawValue)"
        case .bodyweight(let delta, let unit):
            guard delta != 0 else { return String(localized: "peso corporal") }
            let sign = delta > 0 ? "+" : "−"
            return "\(sign)\(FJFormat.number(abs(delta), maxFractionDigits: 1)) \(unit.rawValue)"
        }
    }
}

extension TrainingProgram {
    var isExpired: Bool {
        guard let endDate else { return false }
        return Calendar.current.startOfDay(for: endDate) < Calendar.current.startOfDay(for: .now)
    }

    var weekProgressText: String? {
        guard let progress = weekProgress() else { return nil }
        return String(localized: "semana \(progress.week) de \(progress.of)")
    }

    /// "11 nov 2026 – 6 jan 2027" ou "desde 11 nov 2026".
    var periodText: String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        if let endDate {
            return "\(startDate.formatted(style)) – \(endDate.formatted(style))"
        }
        return String(localized: "desde \(startDate.formatted(style))")
    }

    var originText: String {
        switch origin {
        case .manual: String(localized: "Manual")
        case .ai: String(localized: "IA")
        case .imported: String(localized: "Importado")
        case .duplicated: String(localized: "Duplicado")
        }
    }

    /// Aderência da semana (modo semanal): treinos concluídos × treinos previstos, semana começando na segunda.
    func weeklyAdherence(sessions: [WorkoutSession], now: Date = .now) -> (done: Int, planned: Int)? {
        guard scheduleMode == .weekly else { return nil }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let planned = sortedRoutines.reduce(0) { $0 + $1.weekdays.count }
        guard planned > 0 else { return nil }
        let done = sessions.filter {
            $0.programID == id && $0.status == .completed && week.contains($0.endedAt ?? $0.startedAt)
        }.count
        return (done, planned)
    }
}

/// Selo quadrado com a letra da ficha, na cor dela.
struct RoutineBadge: View {
    let routine: Routine
    var size: CGFloat = 48

    var body: some View {
        Text(verbatim: routine.badgeLetter)
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(FJColor.onFill)
            .frame(width: size, height: size)
            .background(routine.routineColor.color.mix(with: .black, by: 0.12), in: FJRadius.shape(FJRadius.field))
            .accessibilityHidden(true)
    }
}

/// Sete círculos S T Q Q S S D; os dias ativos ficam preenchidos.
struct WeekdayDots: View {
    let weekdays: Set<Weekday>
    var tint: Color = FJColor.training

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = weekdays.contains(day)
                Text(verbatim: day.initial)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? FJColor.onFill : FJColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(on ? tint.mix(with: .black, by: 0.12) : FJColor.fill, in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dias da semana"))
        .accessibilityValue(Text(verbatim: weekdays.isEmpty
            ? String(localized: "nenhum")
            : weekdays.sorted().map(\.fullName).joined(separator: ", ")))
    }
}

/// Última execução da ficha: "última vez: ontem" / "ainda não feita".
func lastDoneText(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return String(localized: "ainda não feita") }
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case ..<1: return String(localized: "última vez: hoje")
    case 1: return String(localized: "última vez: ontem")
    case 2...6: return String(localized: "última vez: há \(days) dias")
    default:
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return String(localized: "última vez: \(day)")
    }
}
