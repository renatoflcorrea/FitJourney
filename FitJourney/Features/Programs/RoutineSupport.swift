import SwiftData
import SwiftUI

// Apresentação compartilhada de fichas e programas (Hoje e Treinos).

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
    /// Inicial para os círculos de dia (S T Q Q S S D), vinda do calendário do idioma atual.
    var initial: String {
        Calendar.current.veryShortStandaloneWeekdaySymbols[calendarWeekday - 1]
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
    var routineColor: FJRoutineColor { FJRoutineColor(name: colorName) }

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
        loadText(load, displayUnit: WeightUnitPreference.current)
    }

    static func loadText(_ load: Load, displayUnit: WeightUnit) -> String {
        switch LoadDisplay.load(load, in: displayUnit) {
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
    /// Fim no passado em relação a `date`.
    func isExpired(on date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let endDate else { return false }
        return calendar.startOfDay(for: endDate) < calendar.startOfDay(for: date)
    }

    func weekProgressText(on date: Date = .now) -> String? {
        guard let progress = weekProgress(on: date) else { return nil }
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
}

/// Sete círculos de dia (ordem da semana de Ajustes); os dias ativos ficam preenchidos.
struct WeekdayDots: View {
    @AppStorage(AppPreferenceKeys.weekStart) private var weekStartRaw = WeekStart.monday.rawValue
    let weekdays: Set<Weekday>
    var color: FJRoutineColor = .orange

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            ForEach(Weekday.ordered(startingOn: WeekStart(rawValue: weekStartRaw) ?? .monday), id: \.self) { day in
                let on = weekdays.contains(day)
                Text(verbatim: day.initial)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? color.onFill : FJColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(on ? color.fill : FJColor.fill, in: Circle())
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

/// Texto para mostrar ao usuário quando uma operação do `ProgramStore` falha.
func userMessage(for error: Error) -> String {
    if case ProgramStoreError.sessionInProgress(let name) = error {
        return String(localized: "Finalize ou descarte o treino em andamento (\(name)) antes de mudar de programa.")
    }
    return error.localizedDescription
}

/// Aviso do DESIGN §5.5: treino em andamento impede trocar/arquivar/excluir programa.
/// Com `addingTo`, a mensagem é a de "Adicionar ficha de outro programa" (§4.2.1).
struct SessionBlockBanner: View {
    var addingTo: String?
    @Environment(SessionCoordinator.self) private var sessionCoordinator: SessionCoordinator?

    var body: some View {
        if let addingTo {
            banner(message: "Finalize ou descarte o treino em andamento antes de adicionar fichas a \(addingTo).")
        } else {
            banner(message: "Finalize ou descarte o treino em andamento antes de trocar, arquivar ou excluir programas.")
        }
    }

    private func banner(message: LocalizedStringKey) -> some View {
        FJBanner("Há um treino em andamento", message: message,
                 tone: .attention, actionTitle: "Ver treino") {
            sessionCoordinator?.present()
        }
    }
}
