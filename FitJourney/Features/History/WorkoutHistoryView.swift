import SwiftData
import SwiftUI

/// Histórico de sessões concluídas (SPEC §4.4): lista por mês ou calendário. Empurrável.
struct WorkoutHistoryView: View {
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw == "completed" },
           sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]

    private enum Mode: String, CaseIterable, Identifiable {
        case list, calendar
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .list ? "Lista" : "Calendário" }
    }

    @State private var mode: Mode = .list
    @State private var month: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedDay: Date?

    init() {}

    // Estado derivado: recalculado quando a lista muda (e ao voltar de um detalhe), não a cada render.
    @State private var rows: [HistoryPresentation.Row] = []
    @State private var sections: [HistoryPresentation.MonthSection] = []
    @State private var trainedDays: Set<Date> = []
    @State private var sessionsByID: [UUID: WorkoutSession] = [:]
    @State private var deleteFailed = false
    @Environment(\.modelContext) private var context

    private func refresh() {
        rows = sessions.map(HistoryPresentation.row)
        sections = HistoryPresentation.sections(rows)
        trainedDays = HistoryPresentation.trainedDays(rows)
        sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func delete(_ session: WorkoutSession) {
        do {
            context.delete(session)
            try context.save()
            deleteFailed = false
        } catch {
            context.rollback()
            deleteFailed = true
        }
        refresh()
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                FJEmptyState("Seus treinos aparecem aqui", systemImage: "calendar",
                             message: "Quando você finalizar um treino, ele entra no histórico com séries, intensidade e notas.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FJSpacing.cardGap, pinnedViews: []) {
                        if deleteFailed {
                            FJBanner("Não foi possível excluir", message: "A sessão continua no histórico. Tente de novo.", tone: .destructive)
                        }
                        Picker("Visualização", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, FJSpacing.xs)
                        switch mode {
                        case .list: listContent
                        case .calendar: calendarContent
                        }
                    }
                    .padding(.horizontal, FJSpacing.screenMargin)
                    .padding(.vertical, FJSpacing.s)
                }
            }
        }
        .fjScreenBackground()
        .navigationTitle("Histórico")
        .navigationBarTitleDisplayMode(.large)
        .task(id: sessions.count) { refresh() }
        .onAppear { refresh() }
    }

    // MARK: Lista

    @ViewBuilder
    private var listContent: some View {
        ForEach(sections, id: \.monthStart) { section in
            FJSectionHeader(LocalizedStringKey(section.monthStart.formatted(.dateTime.month(.wide).year()).capitalized))
                .padding(.top, FJSpacing.s)
            ForEach(section.rows) { row in
                sessionLink(row)
            }
        }
    }

    @ViewBuilder
    private func sessionLink(_ row: HistoryPresentation.Row) -> some View {
        if let session = sessionsByID[row.id] {
            NavigationLink {
                WorkoutDetailView(session: session, onDelete: delete)
            } label: {
                HistoryRowView(row: row)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Calendário

    @ViewBuilder
    private var calendarContent: some View {
        let calendar = Calendar.current
        let trained = trainedDays
        FJCard {
            VStack(spacing: FJSpacing.m) {
                HStack {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: FJSize.minTap, height: FJSize.minTap) }
                        .accessibilityLabel(Text("Mês anterior"))
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year()).capitalized)
                        .font(FJFont.cardTitle)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: FJSize.minTap, height: FJSize.minTap) }
                        .accessibilityLabel(Text("Próximo mês"))
                }
                weekdayHeader(calendar)
                ForEach(Array(HistoryPresentation.calendarWeeks(month: month).enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            dayCell(week[column], trained: trained, calendar: calendar)
                        }
                    }
                }
            }
        }
        if let selectedDay {
            let dayRows = rows.filter { calendar.isDate($0.startedAt, inSameDayAs: selectedDay) }
            FJSectionHeader(LocalizedStringKey(selectedDay.formatted(date: .complete, time: .omitted)))
            if dayRows.isEmpty {
                Text("Nenhum treino neste dia.")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .padding(.horizontal, FJSpacing.xs)
            }
            ForEach(dayRows) { sessionLink($0) }
        }
    }

    private func weekdayHeader(_ calendar: Calendar) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(FJFont.overline)
                    .foregroundStyle(FJColor.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, trained: Set<Date>, calendar: Calendar) -> some View {
        if let day {
            let isTrained = trained.contains(calendar.startOfDay(for: day))
            let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
            Button {
                selectedDay = isSelected ? nil : day
            } label: {
                VStack(spacing: FJSpacing.xxs) {
                    Text(verbatim: "\(calendar.component(.day, from: day))")
                        .font(FJFont.numberBody)
                        .foregroundStyle(FJColor.textPrimary)
                    Circle()
                        .fill(isTrained ? FJColor.training : Color.clear)
                        .frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                .background(isSelected ? FJColor.fillStrong : Color.clear, in: FJRadius.shape(FJRadius.chip))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(day.formatted(date: .complete, time: .omitted)))
            .accessibilityValue(Text(isTrained ? "Treinou" : "Sem treino"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: FJSize.minTap)
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: month) {
            month = Calendar.current.dateInterval(of: .month, for: next)?.start ?? next
            selectedDay = nil
        }
    }
}

// MARK: - Linha

struct HistoryRowView: View {
    let row: HistoryPresentation.Row

    var body: some View {
        FJCard {
            HStack(spacing: FJSpacing.m) {
                VStack(spacing: 0) {
                    Text(row.startedAt.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(FJFont.overline)
                        .foregroundStyle(FJColor.textSecondary)
                    Text(verbatim: "\(Calendar.current.component(.day, from: row.startedAt))")
                        .font(FJFont.numberLarge)
                }
                .frame(width: 48)
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(row.routineName).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary)
                    Text(HistoryPresentation.summaryLine(row)).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                    HStack(spacing: FJSpacing.s) {
                        if let rpe = row.rpe { FJTag("RPE \(rpe)", tone: .neutral) }
                        if row.isEdited { FJTag("editado", systemImage: "pencil", tone: .attention) }
                    }
                }
                Spacer(minLength: FJSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FJColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Histórico") {
    NavigationStack { WorkoutHistoryView() }
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}
