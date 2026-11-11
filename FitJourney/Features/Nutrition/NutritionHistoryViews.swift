import SwiftData
import SwiftUI

// MARK: Faixa da semana

/// Faixa da semana com um símbolo por dia (aderência): forma + texto, não só cor (DESIGN §4.9).
struct WeekStrip: View {
    let cells: [WeekCell]
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(cells) { cell in
                Button { onSelect(cell.date) } label: {
                    VStack(spacing: FJSpacing.xs) {
                        Text(cell.date.formatted(.dateTime.weekday(.narrow)))
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                        Text(cell.date.formatted(.dateTime.day()))
                            .font(FJFont.numberBody)
                            .foregroundStyle(cell.isSelected ? FJColor.onFill : FJColor.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(cell.isSelected ? FJColor.nutritionFill : .clear))
                            .overlay(Circle().strokeBorder(cell.isToday && !cell.isSelected ? FJColor.nutrition : .clear, lineWidth: 1.5))
                        AdherenceMark(level: cell.adherence.level)
                    }
                    .frame(maxWidth: .infinity, minHeight: FJSize.minTap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(for: cell))
                .accessibilityAddTraits(cell.isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func label(for cell: WeekCell) -> String {
        let day = cell.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        switch cell.adherence.level {
        case .noPlan: return day
        case .upcoming: return "\(day), \(cell.adherence.planned == 1 ? String(localized: "1 refeição planejada") : String(localized: "\(cell.adherence.planned) refeições planejadas"))"
        default: return "\(day), \(cell.adherence.summary)"
        }
    }
}

/// Símbolo de aderência do dia.
struct AdherenceMark: View {
    let level: DayAdherence.Level

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .frame(height: 14)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch level {
        case .complete: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .none: "circle"
        case .upcoming: "circle.dotted"
        case .noPlan: "minus"
        }
    }

    private var color: Color {
        switch level {
        case .complete, .partial: FJColor.nutrition
        case .none, .upcoming, .noPlan: FJColor.textTertiary
        }
    }
}

// MARK: Histórico

/// Dieta → Histórico: dias com totais e aderência ao plano; tocar leva ao dia.
struct NutritionHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Date) -> Void

    @State private var days: [HistoryDay] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                FJBanner("Não foi possível carregar", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if loaded && days.isEmpty {
                FJEmptyState("Nada no histórico ainda", systemImage: "calendar",
                             message: "Os dias com refeições marcadas ou comidas registradas aparecem aqui, com totais e aderência ao plano.",
                             area: .nutrition)
                    .listRowBackground(Color.clear)
            }
            ForEach(days) { day in
                Button { onSelect(day.date); dismiss() } label: { HistoryRow(day: day) }
                    .buttonStyle(.plain)
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle("Histórico")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        do { days = try NutritionStore(context: context).history() } catch {
            errorMessage = String(localized: "Tente de novo.")
        }
        loaded = true
    }
}

private struct HistoryRow: View {
    let day: HistoryDay

    var body: some View {
        HStack(spacing: FJSpacing.m) {
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(FJFont.body)
                    .foregroundStyle(FJColor.textPrimary)
                Text(totalsText)
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
            Spacer()
            if day.adherence.planned > 0 {
                VStack(alignment: .trailing, spacing: FJSpacing.xxs) {
                    AdherenceMark(level: day.adherence.level)
                    Text(day.adherence.summary)
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            } else {
                Text("Sem plano")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textTertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(FJColor.textTertiary).accessibilityHidden(true)
        }
        .frame(minHeight: FJSize.minTap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Abre o dia")
    }

    private var totalsText: String {
        let kcal = FJFormat.number(day.totals.kcal, maxFractionDigits: 0)
        let protein = FJFormat.number(day.totals.protein, maxFractionDigits: 0)
        let goal = day.targetKcal.map { " / \(FJFormat.number($0, maxFractionDigits: 0))" } ?? ""
        return String(localized: "\(kcal)\(goal) kcal · \(protein) g proteína")
    }
}

// MARK: Favoritos

/// Dieta → Favoritos: marcar/desmarcar e registrar rápido (1 toque, porção salva, agora).
struct NutritionFavoritesView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<FoodItem> { $0.isFavorite }, sort: \FoodItem.name) private var favorites: [FoodItem]
    @Query(filter: #Predicate<FoodItem> { $0.lastUsedAt != nil }, sort: \FoodItem.lastUsedAt, order: .reverse)
    private var used: [FoodItem]

    let day: Date
    @State private var message: String?
    @State private var errorMessage: String?

    private var recents: [FoodItem] { Array(used.filter { !$0.isFavorite }.prefix(20)) }

    var body: some View {
        List {
            if let errorMessage {
                FJBanner("Não foi possível salvar", message: LocalizedStringKey(errorMessage), tone: .destructive,
                         actionTitle: "Fechar") { self.errorMessage = nil }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let message {
                FJBanner(LocalizedStringKey(message), tone: .success, systemImage: "checkmark.circle")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if favorites.isEmpty && recents.isEmpty {
                FJEmptyState("Sem favoritos ainda", systemImage: "star",
                             message: "O que você registra aparece em Recentes. Toque na estrela para fixar como favorito.",
                             area: .nutrition)
                    .listRowBackground(Color.clear)
            }
            if !favorites.isEmpty {
                Section("Favoritos") { ForEach(favorites) { row($0) } }
            }
            if !recents.isEmpty {
                Section("Recentes") { ForEach(recents) { row($0) } }
            }
        }
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .navigationTitle("Favoritos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ food: FoodItem) -> some View {
        HStack(spacing: FJSpacing.s) {
            Button { toggle(food) } label: {
                Image(systemName: food.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(food.isFavorite ? FJColor.attention : FJColor.textSecondary)
                    .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(food.isFavorite ? "Remover \(food.name) dos favoritos" : "Favoritar \(food.name)")
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(food.name).font(FJFont.body)
                Text([NutritionFormat.quantity(food.servingQuantity, food.unit), NutritionFormat.kcal(food.kcal)]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            Spacer()
            Button { log(food) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(FJColor.nutrition)
                    .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Registrar \(food.name)")
        }
    }

    private func toggle(_ food: FoodItem) {
        food.isFavorite.toggle()
        food.updatedAt = .now
        do { try context.save() } catch { errorMessage = String(localized: "Tente de novo. Nada foi perdido.") }
    }

    /// Registro rápido: a porção salva, agora (no dia exibido; dia passado usa meio-dia).
    private func log(_ food: FoodItem) {
        let calendar = Calendar.autoupdatingCurrent
        let when = calendar.isDate(day, inSameDayAs: .now) ? Date.now
            : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day)
        do {
            try NutritionStore(context: context).logFood(name: food.name, quantity: food.servingQuantity, unit: food.unit,
                                                         values: food.values, estimation: food.estimation, at: when)
            let text = String(localized: "\(food.name) registrado")
            message = text
            AccessibilityNotification.Announcement(text).post()
        } catch {
            errorMessage = String(localized: "Tente de novo. Nada foi perdido.")
        }
    }
}
