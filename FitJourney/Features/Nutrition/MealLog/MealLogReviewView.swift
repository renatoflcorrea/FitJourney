import SwiftUI

/// Revisão do rascunho (mockups 06 e 07): total com faixa, "Registrar como", refeições e itens editáveis, perguntas
/// pendentes. Edita `session.review` no lugar; as regras (pendências, totais, vínculo) vêm de `MealLogReview`.
struct MealLogReviewView: View {
    @Bindable var session: MealLogSession
    @Binding var errorMessage: String?
    let onApply: () -> Void

    @Environment(AIAvailability.self) private var availability: AIAvailability?
    @State private var expandedItem: UUID?
    @State private var answers: [UUID: String] = [:]
    @State private var offerDietSharing = false

    var body: some View {
        if let review = session.review {
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.cardGap) {
                    if let errorMessage {
                        FJBanner("Não foi possível continuar", message: LocalizedStringKey(errorMessage), tone: .attention,
                                 actionTitle: "Fechar") { self.errorMessage = nil }
                    }
                    if review.isLowConfidence {
                        let warning = MealLogPresentation.lowConfidenceWarning()
                        FJBanner(LocalizedStringKey(warning.title), message: LocalizedStringKey(warning.message),
                                 tone: .attention, systemImage: "exclamationmark.triangle")
                    }
                    if offerDietSharing { dietOffer }
                    header(review)
                    if review.meals.count == 1, let meal = review.meals.first {
                        registerAsCard(meal, review: review)
                        itemsCard(meal, review: review)
                    } else {
                        ForEach(review.meals) { meal in mealCard(meal, review: review) }
                    }
                    openQuestions(review)
                    notSeen(review)
                    Text("Valores estimados pela IA. Não é orientação nutricional. As fotos não ficam guardadas no registro.")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .padding(.horizontal, FJSpacing.xs)
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.top, FJSpacing.s)
                .padding(.bottom, FJSpacing.xl)
            }
            .safeAreaInset(edge: .bottom) { footer(review) }
            .task(id: review.hasPlan) {
                let prefs = MealLogPreferences()
                guard !offerDietSharing, prefs.shouldOfferDietSharing(hasPlan: review.hasPlan) else { return }
                offerDietSharing = true
                prefs.markDietSharingOffered()
            }
        }
    }

    // MARK: Edição

    private func mutate(_ change: (inout MealLogReview) -> Void) {
        guard var review = session.review else { return }
        change(&review)
        session.review = review
    }

    private func updateMeal(_ id: UUID, _ change: @escaping (inout MealLogReviewMeal) -> Void) {
        mutate { review in
            guard let index = review.meals.firstIndex(where: { $0.id == id }) else { return }
            change(&review.meals[index])
        }
    }

    private func updateItem(meal mealID: UUID, item itemID: UUID, _ change: @escaping (inout MealLogReviewItem) -> Void) {
        updateMeal(mealID) { meal in
            guard let index = meal.items.firstIndex(where: { $0.id == itemID }) else { return }
            change(&meal.items[index])
        }
    }

    // MARK: Cabeçalho (total com incerteza)

    private func header(_ review: MealLogReview) -> some View {
        let single = review.meals.count == 1
        let totals = review.totals
        let informed = informedKcal(review)
        return VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                FJTag(single ? "Estimativa da IA" : "Rascunho da IA", systemImage: "sparkles", tone: .neutral)
                Spacer()
            }
            FJAdaptiveStack(spacing: FJSpacing.m, verticalAlignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: FJSpacing.xs) {
                        Text(MealLogPresentation.approxNumber(totals.kcal))
                            .font(FJFont.numberHero)
                        Text("kcal").font(FJFont.unit).foregroundStyle(FJColor.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(totals.kcal.map {
                        String(localized: "cerca de \(FJFormat.number($0, maxFractionDigits: 0)) quilocalorias")
                    } ?? String(localized: "calorias desconhecidas")))
                    if !single {
                        Text("\(NutritionFormat.dayTitle(review.day, now: .now)) · \(countText(meals: review.includedMeals.count, items: review.includedMeals.reduce(0) { $0 + $1.items.count }))")
                            .font(FJFont.label)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if !single, informed > 0 {
                    VStack(alignment: .trailing, spacing: FJSpacing.xxs) {
                        Text("\(FJFormat.number(informed, maxFractionDigits: 0)) informadas")
                        if let kcal = totals.kcal, kcal - informed >= 1 {
                            Text("≈ \(FJFormat.number(kcal - informed, maxFractionDigits: 0)) estimadas")
                        }
                    }
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                }
            }
            if single, let range = review.kcalRange, let text = MealLogPresentation.rangeText(range), let kcal = totals.kcal {
                MealLogRangeBar(value: kcal, range: range, text: text)
            }
            if single { macros(totals) }
        }
    }

    private func macros(_ totals: NutrientValues) -> some View {
        FJCard {
            FJAdaptiveStack(spacing: FJSpacing.m, verticalAlignment: .top) {
                macro("Proteína", totals.protein)
                macro("Carboidrato", totals.carbs)
                macro("Gordura", totals.fat)
            }
        }
    }

    private func macro(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            Text(title).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(MealLogPresentation.approxNumber(value)).font(FJFont.numberMedium)
                if value != nil { Text("g").font(FJFont.unit).foregroundStyle(FJColor.textSecondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// kcal que vêm do plano ("Feita"): valem como informadas.
    private func informedKcal(_ review: MealLogReview) -> Double {
        review.includedMeals.filter { $0.decision == .done }.reduce(0) { sum, meal in
            sum + (MealLogPresentation.selectedPlannedMeal(meal, in: review)?.items.compactMap(\.values.kcal).reduce(0, +) ?? 0)
        }
    }

    private func countText(meals: Int, items: Int) -> String {
        let mealText = meals == 1 ? String(localized: "1 refeição") : String(localized: "\(meals) refeições")
        let itemText = items == 1 ? String(localized: "1 item") : String(localized: "\(items) itens")
        return "\(mealText) · \(itemText)"
    }

    // MARK: Foto: "Registrar como"

    private func registerAsCard(_ meal: MealLogReviewMeal, review: MealLogReview) -> some View {
        let planned = MealLogPresentation.selectedPlannedMeal(meal, in: review)
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        Text("Registrar como").font(FJFont.overline).foregroundStyle(FJColor.textSecondary).textCase(.uppercase)
                        Text(mealHeadline(meal, planned: planned)).font(FJFont.cardTitle)
                    }
                    Spacer(minLength: FJSpacing.s)
                    if review.hasPlan { changeMenu(meal, review: review, title: "Trocar") }
                }
                if review.hasPlan {
                    Picker("Registrar como", selection: decisionBinding(meal)) {
                        ForEach(MealLogDecision.allCases, id: \.self) { Text(MealLogPresentation.decisionTitle($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Text(MealLogPresentation.decisionExplanation(meal.decision, planned: planned))
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                if meal.alreadyLogged { replaceToggle(meal) }
            }
        }
    }

    private func mealHeadline(_ meal: MealLogReviewMeal, planned: MealLogPlannedMeal?) -> String {
        let title = MealLogPresentation.mealTitle(meal, planned: planned)
        guard let time = MealLogPresentation.mealTime(meal, planned: planned) else { return title }
        return "\(title) · \(time)"
    }

    private func decisionBinding(_ meal: MealLogReviewMeal) -> Binding<MealLogDecision> {
        Binding(get: { session.review?.meals.first { $0.id == meal.id }?.decision ?? meal.decision },
                set: { value in updateMeal(meal.id) { $0.decision = value } })
    }

    private func replaceToggle(_ meal: MealLogReviewMeal) -> some View {
        Toggle("Substituir o registro", isOn: Binding(
            get: { session.review?.meals.first { $0.id == meal.id }?.isIncluded ?? meal.isIncluded },
            set: { value in updateMeal(meal.id) { $0.isIncluded = value } }))
            .font(FJFont.label)
    }

    /// "Trocar"/"Mudar": estado e refeição do plano.
    private func changeMenu(_ meal: MealLogReviewMeal, review: MealLogReview, title: LocalizedStringKey) -> some View {
        Menu {
            Picker("Registrar como", selection: decisionBinding(meal)) {
                ForEach(MealLogDecision.allCases, id: \.self) { Text(MealLogPresentation.decisionTitle($0)).tag($0) }
            }
            if review.hasPlan {
                Picker("Refeição do plano", selection: Binding<UUID?>(
                    get: { session.review?.meals.first { $0.id == meal.id }?.plannedMealID },
                    set: { value in mutate { $0.relink(mealID: meal.id, to: value) } })) {
                    Text("Nenhuma").tag(UUID?.none)
                    ForEach(review.planned) { planned in
                        Text(plannedLabel(planned)).tag(Optional(planned.id))
                    }
                }
            }
            if review.meals.count > 1 {
                Button("Tirar do registro", systemImage: "minus.circle", role: .destructive) {
                    mutate { $0.meals.removeAll { $0.id == meal.id } }
                }
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FJColor.nutrition)
                .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
        }
    }

    private func plannedLabel(_ planned: MealLogPlannedMeal) -> String {
        let base = "\(planned.name) · \(NutritionFormat.clock(minutes: planned.minutesFromMidnight))"
        return planned.isLogged ? "\(base) · \(String(localized: "já registrada"))" : base
    }

    // MARK: Dia: um cartão por refeição

    private func mealCard(_ meal: MealLogReviewMeal, review: MealLogReview) -> some View {
        let planned = MealLogPresentation.selectedPlannedMeal(meal, in: review)
        let estimated = meal.decision != .done
        let kcal = estimated ? meal.estimatedTotals.kcal : planned?.items.compactMap(\.values.kcal).reduce(0, +)
        return FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                    if let time = MealLogPresentation.mealTime(meal, planned: planned) {
                        Text(time).font(FJFont.numberBody).foregroundStyle(FJColor.textSecondary)
                    }
                    Text(MealLogPresentation.mealTitle(meal, planned: planned)).font(FJFont.cardTitle)
                    Spacer(minLength: FJSpacing.s)
                    if meal.isIncluded {
                        Text(estimated ? MealLogPresentation.approxKcal(kcal)
                             : (NutritionFormat.kcal(kcal) ?? "—"))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                }
                FJAdaptiveStack(spacing: FJSpacing.s) {
                    FJTag(MealLogPresentation.decisionTitle(meal.decision),
                          systemImage: MealLogPresentation.decisionSymbol(meal.decision),
                          tone: meal.decision == .done ? .success : (meal.decision == .adjusted ? .attention : .neutral))
                    Text(stateCaption(meal, planned: planned))
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                    Spacer(minLength: 0)
                    changeMenu(meal, review: review, title: "Mudar")
                }
                if meal.alreadyLogged { replaceToggle(meal) }
                if meal.isIncluded && meal.decision != .done {
                    VStack(spacing: 0) {
                        ForEach(meal.items) { item in
                            Divider()
                            itemRow(item, mealID: meal.id)
                        }
                    }
                }
                ForEach(review.questions.filter { $0.mealID == meal.id }) { question in
                    questionView(question, mealID: meal.id)
                }
            }
        }
        .opacity(meal.isIncluded ? 1 : 0.7)
    }

    private func stateCaption(_ meal: MealLogReviewMeal, planned: MealLogPlannedMeal?) -> String {
        switch meal.decision {
        case .done:
            let count = planned?.items.count ?? 0
            return String(localized: "como no plano · \(count) itens")
        case .adjusted:
            guard let planned, !planned.items.isEmpty else { return String(localized: "no lugar dos itens do plano") }
            return String(localized: "no lugar de \(planned.items.prefix(3).map(\.name).joined(separator: ", "))")
        case .offPlan:
            return meal.alreadyLogged ? String(localized: "já tinha registro") : String(localized: "sem refeição do plano")
        }
    }

    // MARK: Itens

    private func itemsCard(_ meal: MealLogReviewMeal, review: MealLogReview) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Itens · toque para editar")
                    .font(FJFont.overline)
                    .foregroundStyle(FJColor.textSecondary)
                    .textCase(.uppercase)
                    .padding(.bottom, FJSpacing.s)
                ForEach(meal.items) { item in
                    Divider()
                    itemRow(item, mealID: meal.id)
                }
                ForEach(review.questions.filter { $0.mealID == meal.id }) { question in
                    questionView(question, mealID: meal.id).padding(.top, FJSpacing.m)
                }
            }
        }
    }

    private func itemRow(_ item: MealLogReviewItem, mealID: UUID) -> some View {
        let isExpanded = expandedItem == item.id || !item.hasQuantity
        return VStack(alignment: .leading, spacing: FJSpacing.s) {
            Button {
                expandedItem = expandedItem == item.id ? nil : item.id
            } label: {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    FJAdaptiveStack(spacing: FJSpacing.s, verticalAlignment: .firstTextBaseline) {
                        Text(item.name).font(FJFont.body).foregroundStyle(FJColor.textPrimary)
                        Spacer(minLength: FJSpacing.s)
                        Text("\(item.hasQuantity ? "≈ " : "")\(MealLogPresentation.quantity(item.quantity, unit: item.unit)) · \(MealLogPresentation.approxKcal(item.values.kcal))")
                            .font(FJFont.numberCaption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                    if item.confidence != .high || !item.hasQuantity { confidenceLine(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, FJSpacing.s)
                .frame(minHeight: FJSize.minTap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(MealLogPresentation.itemAccessibilityLabel(item)))
            .accessibilityHint(Text("Toque para editar a quantidade"))
            if isExpanded {
                NumberStepperField("Quantidade de \(item.name)", value: quantityBinding(mealID: mealID, itemID: item.id, fallback: item),
                                   unit: item.unit.symbol, step: MealLogPresentation.step(for: item.unit), range: 0 ... 9_999,
                                   fractionDigits: item.unit == .cup || item.unit == .serving ? 1 : 0)
                Button("Remover item", systemImage: "trash", role: .destructive) {
                    updateMeal(mealID) { meal in meal.items.removeAll { $0.id == item.id } }
                }
                .font(FJFont.label)
                .frame(minHeight: FJSize.minTap)
            }
        }
    }

    private func quantityBinding(mealID: UUID, itemID: UUID, fallback: MealLogReviewItem) -> Binding<Double> {
        Binding(
            get: {
                session.review?.meals.first { $0.id == mealID }?.items.first { $0.id == itemID }?.quantity ?? 0
            },
            set: { value in updateItem(meal: mealID, item: itemID) { $0.setQuantity(value) } })
    }

    @ViewBuilder private func confidenceLine(_ item: MealLogReviewItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
            if item.confidence != .high { FJConfidenceBadge(item.confidence.fjValue, style: .compact) }
            if !item.hasQuantity {
                Text("quantidade não informada").font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            } else if let note = item.note, !note.isEmpty {
                Text(note).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            } else if let text = MealLogPresentation.rangeText(item.kcalRange) {
                Text(text).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    // MARK: Perguntas e avisos

    /// Perguntas que não estão presas a uma refeição.
    @ViewBuilder private func openQuestions(_ review: MealLogReview) -> some View {
        let loose = review.questions.filter { question in !review.meals.contains { $0.id == question.mealID } }
        if !loose.isEmpty {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    ForEach(loose) { questionView($0, mealID: nil) }
                }
            }
        }
    }

    private func questionView(_ question: MealLogQuestion, mealID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Label(question.text, systemImage: "questionmark.bubble")
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
            if !question.options.isEmpty {
                FJQuickReplyChips(question.options.map { FJQuickReply($0) },
                                  selected: answers[question.id].map { [$0] } ?? [],
                                  freeTextTitle: "Outro",
                                  onFreeText: question.itemID == nil ? nil : { expandedItem = question.itemID },
                                  onSelect: { reply in answer(question, mealID: mealID, reply: reply.title) })
            }
        }
    }

    /// "300 ml" → quantidade 300 do item da pergunta (e a unidade, se o texto traz uma).
    private func answer(_ question: MealLogQuestion, mealID: UUID?, reply: String) {
        answers[question.id] = reply
        guard let mealID, let itemID = question.itemID, let parsed = MealLogAnswer.parse(reply) else { return }
        updateItem(meal: mealID, item: itemID) { item in
            item.applyAnswer(quantity: parsed.quantity, unit: parsed.unit)
        }
    }

    @ViewBuilder private func notSeen(_ review: MealLogReview) -> some View {
        if !review.notSeen.isEmpty {
            Label("Não aparecem na foto: \(review.notSeen.joined(separator: ", "))", systemImage: "eye.slash")
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
                .padding(.horizontal, FJSpacing.xs)
        }
    }

    private var dietOffer: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            FJBanner("A IA não vê o seu plano",
                     message: "Ligamos o registro às refeições no aparelho, por horário e nome. Permitir que a IA compare com o plano melhora as próximas análises.",
                     tone: .neutral, systemImage: "doc.text.magnifyingglass",
                     actionTitle: "Permitir comparar com o plano") {
                MealLogPreferences().enableDietSharing()
                offerDietSharing = false
            }
            Button("Agora não") { offerDietSharing = false }
                .font(FJFont.label)
                .frame(minHeight: FJSize.minTap)
                .padding(.horizontal, FJSpacing.l)
        }
    }

    // MARK: Rodapé

    private func footer(_ review: MealLogReview) -> some View {
        let issues = Array(NSOrderedSet(array: review.issues.map(MealLogPresentation.issueMessage))) as? [String] ?? []
        return VStack(spacing: FJSpacing.s) {
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    ForEach(issues.prefix(2), id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            FJPrimaryButton(MealLogPresentation.registerTitle(mealCount: review.includedMeals.count), area: .nutrition,
                            action: onApply)
                .disabled(!review.canApply)
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.bottom, FJSpacing.s)
        .padding(.top, FJSpacing.s)
        // O rodapé cobre o que rola por baixo (as pendências e o botão não podem se misturar com os itens).
        .background(FJColor.background)
    }
}

/// Resposta rápida "300 ml" / "2 un" / "1,5 xícara" → quantidade (e unidade, se reconhecida).
enum MealLogAnswer {
    static func parse(_ text: String) -> (quantity: Double, unit: FoodUnit?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "," || $0 == "." }
        guard !numberPart.isEmpty, let quantity = Double(numberPart.replacingOccurrences(of: ",", with: ".")), quantity > 0 else {
            return nil
        }
        let rest = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).lowercased()
        let unit = FoodUnit.allCases.first { $0.symbol.lowercased() == rest }
        return (quantity, unit)
    }
}

/// Faixa estimada: trilho, segmento entre o mínimo e o máximo e marca no valor (nunca só cor: tem o texto).
private struct MealLogRangeBar: View {
    let value: Double
    let range: MealLogRange
    let text: String

    var body: some View {
        let span = max(range.max - range.min, 1)
        let lower = max(0, range.min - span * 0.6)
        let total = (range.max + span * 0.6) - lower
        VStack(spacing: FJSpacing.xs) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let start = width * (range.min - lower) / total
                let end = width * (range.max - lower) / total
                let mark = width * (value - lower) / total
                ZStack(alignment: .leading) {
                    Capsule().fill(FJColor.fillStrong)
                    Capsule().fill(FJColor.nutrition.opacity(0.35)).frame(width: max(6, end - start)).offset(x: start)
                    Capsule().fill(FJColor.nutrition).frame(width: 3, height: 14).offset(x: min(max(0, mark - 1.5), width - 3))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack {
                Text(FJFormat.number(range.min, maxFractionDigits: 0))
                Spacer()
                Text(text)
                Spacer()
                Text(FJFormat.number(range.max, maxFractionDigits: 0))
            }
            .font(FJFont.caption)
            .foregroundStyle(FJColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}
