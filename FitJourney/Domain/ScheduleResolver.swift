import Foundation

/// O que a aba Hoje deve sugerir (SPEC §3.1, R-T1).
enum ScheduleSuggestion: Sendable, Hashable {
    /// Uma ficha sugerida (livre: a menos recente; sequencial: a próxima do rodízio).
    case routine(UUID)
    /// Modo semanal: a(s) ficha(s) do dia, em ordem.
    case routines([UUID])
    /// Modo semanal sem ficha no dia.
    case rest
    /// Programa sem fichas.
    case noRoutines

    /// IDs sugeridos, em ordem (vazio em descanso/sem fichas).
    var routineIDs: [UUID] {
        switch self {
        case .routine(let id): [id]
        case .routines(let ids): ids
        case .rest, .noRoutines: []
        }
    }
}

/// Regra pura da agenda do programa.
enum ScheduleResolver {
    struct RoutineInfo: Sendable, Hashable {
        var id: UUID
        var sortIndex: Int
        var weekdays: Set<Weekday>
        /// Fim (ou início) da última sessão concluída desta ficha; `nil` = nunca feita.
        var lastCompletedAt: Date?

        init(id: UUID, sortIndex: Int, weekdays: Set<Weekday> = [], lastCompletedAt: Date? = nil) {
            self.id = id
            self.sortIndex = sortIndex
            self.weekdays = weekdays
            self.lastCompletedAt = lastCompletedAt
        }
    }

    static func suggestion(mode: ScheduleMode, routines: [RoutineInfo],
                           today: Date, calendar: Calendar = .current) -> ScheduleSuggestion {
        let ordered = routines.sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        guard !ordered.isEmpty else { return .noRoutines }

        switch mode {
        case .free:
            // Nunca feita conta como a menos recente; empate → ordem da ficha.
            let leastRecent = ordered.min { lhs, rhs in
                switch (lhs.lastCompletedAt, rhs.lastCompletedAt) {
                case (nil, nil): false // `min` é estável: mantém a primeira na ordem
                case (nil, _): true
                case (_, nil): false
                case let (l?, r?): l < r
                }
            }!
            return .routine(leastRecent.id)

        case .sequential:
            // Próxima após a concluída mais recentemente (circular); nenhuma feita → a primeira.
            let lastDone = ordered.enumerated()
                .filter { $0.element.lastCompletedAt != nil }
                .max { $0.element.lastCompletedAt! < $1.element.lastCompletedAt! }
            guard let lastDone else { return .routine(ordered[0].id) }
            return .routine(ordered[(lastDone.offset + 1) % ordered.count].id)

        case .weekly:
            let weekday = Weekday(date: today, calendar: calendar)
            let ofTheDay = ordered.filter { $0.weekdays.contains(weekday) }.map(\.id)
            return ofTheDay.isEmpty ? .rest : .routines(ofTheDay)
        }
    }
}
