import SwiftUI

// Peças da tela "Dieta — dia". Só compõe componentes do DesignSystem.

// MARK: Totais

struct NutritionTotalsCard: View {
    let totals: DayNutritionTotals
    let targets: NutritionTargets
    let estimatedCount: Int

    private var kcalProgress: Double? {
        guard let goal = targets.kcal, goal > 0 else { return nil }
        return totals.kcal / goal
    }

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJAdaptiveStack(spacing: FJSpacing.l) {
                    FJProgressRing(progress: kcalProgress, tint: FJColor.nutrition, lineWidth: 8) {
                        VStack(spacing: 0) {
                            Text(FJFormat.number(totals.kcal, maxFractionDigits: 0))
                                .font(FJFont.numberMedium)
                                .minimumScaleFactor(0.6)
                            Text("kcal").font(.caption2).foregroundStyle(FJColor.textSecondary)
                        }
                        .padding(FJSpacing.xs)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .frame(width: FJSize.progressRing, height: FJSize.progressRing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(kcalSpoken)

                    VStack(spacing: FJSpacing.s) {
                        FJGoalBar("Proteína", value: totals.protein, goal: targets.protein, unit: "g")
                        FJGoalBar("Carboidrato", value: totals.carbs, goal: targets.carbs, unit: "g")
                        FJGoalBar("Gordura", value: totals.fat, goal: targets.fat, unit: "g")
                    }
                }
                if let goal = targets.kcal, goal > 0 {
                    Text("de \(FJFormat.number(goal, maxFractionDigits: 0)) kcal")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
                if let fiber = targets.fiber, fiber > 0 {
                    FJGoalBar("Fibra", value: totals.fiber, goal: fiber, unit: "g")
                }
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if totals.itemsWithoutKcal > 0 || estimatedCount > 0 {
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                if totals.itemsWithoutKcal > 0 {
                    Label(NutritionFormat.itemsWithoutKcal(totals.itemsWithoutKcal), systemImage: "info.circle")
                }
                if estimatedCount > 0 {
                    Label(estimatedCount == 1 ? "inclui 1 estimado" : "inclui \(estimatedCount) estimados",
                          systemImage: "scalemass")
                }
            }
            .font(FJFont.caption)
            .foregroundStyle(FJColor.textSecondary)
        }
    }

    private var kcalSpoken: String {
        let consumed = FJFormat.number(totals.kcal, maxFractionDigits: 0)
        guard let goal = targets.kcal, goal > 0 else { return String(localized: "\(consumed) quilocalorias consumidas") }
        return String(localized: "\(consumed) de \(FJFormat.number(goal, maxFractionDigits: 0)) quilocalorias")
    }
}

// MARK: Água

struct WaterCard: View {
    let total: Double
    let goal: Double?
    let isEditable: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    private var cups: (filled: Int, capacity: Int) { WaterCups.layout(total: total, goal: goal) }

    private var litersText: String {
        let current = FJFormat.number(total / 1_000, maxFractionDigits: 1)
        guard let goal, goal > 0 else { return "\(current) L" }
        return "\(current) / \(FJFormat.number(goal / 1_000, maxFractionDigits: 1)) L"
    }

    var body: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                FJAdaptiveStack(spacing: FJSpacing.xs) {
                    Label("Água", systemImage: "drop.fill")
                        .font(FJFont.cardTitle)
                        .foregroundStyle(FJColor.textPrimary)
                    Spacer(minLength: FJSpacing.s)
                    Text(litersText).font(FJFont.numberBody)
                    if isEditable {
                        HStack(spacing: 0) {
                            Button(action: onRemove) {
                                Image(systemName: "minus.circle")
                                    .font(.title2)
                                    .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
                            }
                            .disabled(total <= 0)
                            .accessibilityLabel("Remover um copo")
                            Button(action: onAdd) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(FJColor.nutrition)
                                    .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
                            }
                            .accessibilityLabel("Adicionar um copo, \(Int(WaterCups.cupMilliliters)) mililitros")
                        }
                    }
                }
                HStack(alignment: .center, spacing: FJSpacing.s) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(0..<cups.capacity, id: \.self) { index in
                            Image(systemName: index < cups.filled ? "drop.fill" : "drop")
                                .foregroundStyle(index < cups.filled ? FJColor.nutrition : FJColor.textTertiary)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .contextMenu {
                if isEditable {
                    Button("Adicionar copo", systemImage: "plus", action: onAdd)
                    Button("Remover último copo", systemImage: "minus", role: .destructive, action: onRemove)
                        .disabled(total <= 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            guard isEditable else { return }
            switch direction {
            case .increment: onAdd()
            case .decrement: onRemove()
            @unknown default: break
            }
        }
    }
}

// MARK: Linha do tempo

/// Hora + trilho + conteúdo. Em tamanhos de acessibilidade a hora vai acima do cartão.
struct TimelineRow<Content: View>: View {
    let item: TimelineItem
    let hasPlan: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isOverdue: Bool {
        if case .meal(let row) = item { return row.display == .overdue }
        return false
    }

    private var timeText: some View {
        HStack(spacing: FJSpacing.xxs) {
            if isOverdue {
                Image(systemName: "clock").foregroundStyle(FJColor.attention).accessibilityHidden(true)
            }
            Text(NutritionFormat.clock(item.time))
        }
        .font(FJFont.numberBody)
        .foregroundStyle(isOverdue ? FJColor.attention : FJColor.textSecondary)
    }

    var body: some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                timeText.padding(.horizontal, FJSpacing.xs)
                content()
            }
            .padding(.bottom, FJSpacing.cardGap)
        } else {
            HStack(alignment: .top, spacing: FJSpacing.s) {
                timeText
                    .frame(minWidth: 54, alignment: .trailing)
                    .fixedSize()
                    .padding(.top, FJSpacing.m)
                Rectangle()
                    .fill(FJColor.separator)
                    .frame(width: 2)
                    .accessibilityHidden(true)
                content()
                    .padding(.bottom, FJSpacing.cardGap)
            }
        }
    }
}

struct MealCard: View {
    let row: MealRowModel
    let phase: NutritionDayPhase
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDone: () -> Void
    let onAdjust: () -> Void
    let onSkip: () -> Void
    let onUndo: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isNext: Bool { row.display == .next }
    private var isEditable: Bool { phase != .future }
    private var isSkipped: Bool { row.status == .skipped }

    private var kcalText: String? { NutritionFormat.kcal(row.kcalSummary) }

    private var summary: String {
        let names = (row.status == .adjusted ? row.entries.map(\.name) : row.meal.sortedItems.map(\.name))
        return names.isEmpty ? String(localized: "Sem itens") : names.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            Button(action: onToggle) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint(isExpanded ? "Recolher" : "Expandir")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                itemList
                if isEditable { actions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .overlay {
            if isNext {
                FJRadius.shape(FJRadius.card).strokeBorder(FJColor.nutrition, lineWidth: 1.5)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            FJAdaptiveStack(spacing: FJSpacing.xs, verticalAlignment: .firstTextBaseline) {
                Text(row.meal.name.isEmpty ? String(localized: "Refeição") : row.meal.name)
                    .font(FJFont.cardTitle)
                    .foregroundStyle(FJColor.textPrimary)
                    .strikethrough(isSkipped)
                Spacer(minLength: FJSpacing.s)
                HStack(spacing: FJSpacing.s) {
                    if let kcalText {
                        Text(kcalText).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FJColor.textTertiary)
                        .rotationEffect(isExpanded ? .degrees(180) : .zero)
                }
            }
            if !isExpanded {
                Text(summary)
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .strikethrough(isSkipped)
            }
            statusTag
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusTag: some View {
        let time = row.loggedAt.map { NutritionFormat.clock($0) }
        switch row.display {
        case .pending: FJTag("Pendente", systemImage: "circle")
        case .next: FJTag(row.scheduledAt <= .now ? "Agora" : "Próxima", systemImage: "fork.knife", area: .nutrition)
        case .overdue: FJTag("Pendente", systemImage: "clock")
        case .noRecord: FJTag("Sem registro", systemImage: "minus.circle")
        case .planned: FJTag("Planejada", systemImage: "calendar")
        case .done:
            if let time { FJTag("Feita \(time)", systemImage: "checkmark.circle.fill", tone: .success) }
            else { FJTag("Feita", systemImage: "checkmark.circle.fill", tone: .success) }
        case .adjusted:
            if let time { FJTag("Ajustada \(time)", systemImage: "pencil", tone: .attention) }
            else { FJTag("Ajustada", systemImage: "pencil", tone: .attention) }
        case .skipped: FJTag("Pulada", systemImage: "forward.fill")
        }
    }

    private var stateSpoken: String {
        let time = row.loggedAt.map { NutritionFormat.clock($0) }
        return switch row.display {
        case .pending: String(localized: "pendente")
        case .next: String(localized: "próxima refeição")
        case .overdue: String(localized: "pendente, atrasada")
        case .noRecord: String(localized: "sem registro")
        case .planned: String(localized: "planejada")
        case .done: time.map { String(localized: "feita às \($0)") } ?? String(localized: "feita")
        case .adjusted: time.map { String(localized: "feita com alteração às \($0)") } ?? String(localized: "feita com alteração")
        case .skipped: String(localized: "pulada")
        }
    }

    private var spokenLabel: String {
        var parts = [row.meal.name, NutritionFormat.clock(row.scheduledAt), stateSpoken]
        if let kcalText { parts.append(kcalText) }
        parts.append(summary)
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var itemList: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            if row.status == .done || row.status == .adjusted {
                ForEach(row.entries) { entry in
                    itemLine(name: entry.name, quantity: entry.quantity, unit: entry.unit, kcal: entry.kcal, hasSubstitutions: false)
                }
            } else {
                ForEach(row.meal.sortedItems) { item in
                    itemLine(name: item.name, quantity: item.quantity, unit: item.unit, kcal: item.kcal,
                             hasSubstitutions: !item.substitutions.isEmpty)
                }
                if row.meal.sortedItems.isEmpty {
                    Text("Esta refeição ainda não tem itens. Use Ajustar para registrar o que você comeu.")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
            if let summary = row.kcalSummary, summary.isPartial {
                Label(NutritionFormat.itemsWithoutKcal(summary.itemsWithoutKcal), systemImage: "info.circle")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            let partial = row.entries.filter { $0.mealStatus == nil }
            if row.status == .pending, !partial.isEmpty {
                Text("Registrado nesta refeição").font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                ForEach(partial) { entry in
                    itemLine(name: entry.name, quantity: entry.quantity, unit: entry.unit, kcal: entry.kcal, hasSubstitutions: false)
                }
            }
        }
    }

    private func itemLine(name: String, quantity: Double, unit: FoodUnit, kcal: Double?, hasSubstitutions: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(FJFont.body).strikethrough(isSkipped)
                Text(NutritionFormat.quantity(quantity, unit)).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            if hasSubstitutions {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(FJColor.textSecondary)
                    .accessibilityLabel("Tem substituições")
            }
            Spacer(minLength: FJSpacing.s)
            if let text = NutritionFormat.kcal(kcal) {
                Text(text).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        switch row.status {
        case .pending:
            FJAdaptiveStack(spacing: FJSpacing.m) {
                HStack(spacing: FJSpacing.s) {
                    FJCheckButton(state: .pending, area: .nutrition,
                                  accessibilityLabel: String(localized: "Marcar \(row.meal.name) como feita"),
                                  action: onDone)
                        .disabled(!row.canMarkDone)
                        .opacity(row.canMarkDone ? 1 : 0.4)
                        .accessibilityHint(row.canMarkDone ? "" : String(localized: "Indisponível: a refeição não tem itens. Use Ajustar para registrar o que comeu."))
                    Text("Feita").font(FJFont.label.weight(.semibold))
                }
                FJSecondaryButton("Ajustar", systemImage: "pencil", fillsWidth: false, action: onAdjust)
                FJSecondaryButton("Pular", systemImage: "forward.fill", fillsWidth: false, action: onSkip)
            }
        case .done, .adjusted:
            FJAdaptiveStack(spacing: FJSpacing.m) {
                FJSecondaryButton("Ajustar", systemImage: "pencil", fillsWidth: false, action: onAdjust)
                FJSecondaryButton("Desfazer", systemImage: "arrow.uturn.backward", fillsWidth: false, action: onUndo)
            }
        case .skipped:
            FJAdaptiveStack(spacing: FJSpacing.m) {
                FJSecondaryButton("Ajustar", systemImage: "pencil", fillsWidth: false, action: onAdjust)
                FJSecondaryButton("Desfazer", systemImage: "arrow.uturn.backward", fillsWidth: false, action: onUndo)
            }
        }
    }
}

/// Registro avulso na linha do tempo (neutro: "Fora da dieta" não é alerta).
struct ExtraEntryCard: View {
    let entry: FoodEntry
    let showsOffPlanTag: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary)
                Spacer(minLength: FJSpacing.s)
                if let kcal = NutritionFormat.kcal(entry.kcal) {
                    Text(kcal).font(FJFont.numberCaption).foregroundStyle(FJColor.textSecondary)
                }
            }
            HStack(spacing: FJSpacing.s) {
                Text(NutritionFormat.quantity(entry.quantity, entry.unit))
                    .font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                if entry.estimation != .informed {
                    Text(entry.estimation == .ai ? "IA" : "estimado")
                        .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
            if entry.mealID == nil {
                if showsOffPlanTag { FJTag("Fora da dieta", systemImage: "fork.knife") }
            } else {
                if let name = entry.mealName, !name.isEmpty {
                    FJTag("\(name) · refeição removida", systemImage: "fork.knife")
                } else {
                    FJTag("Refeição removida", systemImage: "fork.knife")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Entrada de refeição que não está no plano do dia: usa o nome gravado, sem juízo.
    private var orphanLabel: String {
        let removed = String(localized: "refeição removida")
        guard let name = entry.mealName, !name.isEmpty else { return removed }
        return "\(name) · \(removed)"
    }

    private var spoken: String {
        var parts = [entry.name, NutritionFormat.quantity(entry.quantity, entry.unit), NutritionFormat.clock(entry.date)]
        if let kcal = NutritionFormat.kcal(entry.kcal) { parts.append(kcal) }
        if entry.mealID == nil {
            if showsOffPlanTag { parts.append(String(localized: "fora da dieta")) }
        } else {
            parts.append(orphanLabel)
        }
        return parts.joined(separator: ", ")
    }
}
