import Foundation

/// Provedor único de calendário do app: o do sistema (`autoupdatingCurrent`) com o início da semana
/// escolhido em Ajustes (`fj.weekStart`, segunda por padrão — SPEC §11 Q2). Faixa da Dieta, aderência
/// semanal, Saúde e Hoje usam este calendário; os dias gravados nas fichas (`Weekday`) não mudam.
enum AppCalendar {
    /// Relido a cada acesso: mudar a preferência vale na hora, sem reabrir o app.
    static var current: Calendar { make(weekStart: .current) }

    static func make(base: Calendar = .autoupdatingCurrent, weekStart: WeekStart) -> Calendar {
        var calendar = base
        calendar.firstWeekday = weekStart.firstWeekday
        return calendar
    }
}

extension WeekStart {
    /// Valor de `Calendar.firstWeekday` (1 = domingo, 2 = segunda).
    var firstWeekday: Int { self == .sunday ? 1 : 2 }

    var firstDay: Weekday { self == .sunday ? .sunday : .monday }
}

extension Weekday {
    /// Os sete dias começando em `start`: só a ordem de exibição (seletores, pontos).
    static func ordered(startingOn start: WeekStart) -> [Weekday] {
        let all = Weekday.allCases
        let offset = start.firstDay.index
        return (0..<7).map { all[($0 + offset) % 7] }
    }

    /// Ordem de exibição segundo a preferência atual.
    static var displayOrder: [Weekday] { ordered(startingOn: .current) }
}
