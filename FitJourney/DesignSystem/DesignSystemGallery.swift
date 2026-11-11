import SwiftUI

/// Galeria de todos os tokens e componentes do DesignSystem. Só para previews e QA
/// (claro/escuro, Dynamic Type, Reduzir Transparência/Movimento).
struct DesignSystemGallery: View {
    @State private var load = 32.5
    @State private var reps: Int? = nil
    @State private var hold = 45.0
    @State private var rpe: Int? = 7
    @State private var checks: [FJCheckState] = [.done, .pending, .pending, .skipped]
    @State private var filters: Set<String> = ["Peito"]
    @State private var restEndsAt = Date.now.addingTimeInterval(75)
    @State private var restTotal: TimeInterval = 90

    private let sessionStart = Date.now.addingTimeInterval(-1934)
    private let groups = ["Peito", "Costas", "Pernas", "Ombros", "Braços"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.sectionGap) {
                    colors
                    typography
                    buttons
                    chips
                    metrics
                    progress
                    steppers
                    session
                    heartRate
                    states
                }
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.bottom, FJSpacing.xxl)
            }
            .fjScreenBackground()
            .navigationTitle("DesignSystem")
        }
        .tint(FJColor.training)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            FJSectionHeader(title)
            content()
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: FJSpacing.xs) {
            FJRadius.shape(FJRadius.field)
                .fill(color)
                .frame(height: 44)
            Text(verbatim: name)
                .font(.caption2)
                .foregroundStyle(FJColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var colors: some View {
        section("Cores") {
            FJCard {
                VStack(spacing: FJSpacing.m) {
                    HStack {
                        swatch("treino", FJColor.training)
                        swatch("dieta", FJColor.nutrition)
                        swatch("saúde", FJColor.health)
                        swatch("coach", FJColor.coach)
                        swatch("aeróbico", FJColor.aerobic)
                    }
                    HStack {
                        ForEach(FJHeartRateZone.allCases, id: \.self) { zone in
                            swatch(zone.shortLabel, zone.color)
                        }
                    }
                    HStack {
                        swatch("sucesso", FJColor.success)
                        swatch("atenção", FJColor.attention)
                        swatch("destrutivo", FJColor.destructive)
                        swatch("recorde", FJColor.record)
                    }
                }
            }
        }
    }

    private var typography: some View {
        section("Tipografia") {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    Text(verbatim: "52:18").font(FJFont.numberHero)
                    Text(verbatim: "32,5 kg × 10").font(FJFont.numberLarge)
                    Text(verbatim: "8.420 kg").font(FJFont.numberMedium)
                    Text(verbatim: "142 bpm").font(FJFont.numberBody)
                    Text("Título de seção").font(FJFont.sectionTitle)
                    Text("Título de cartão").font(FJFont.cardTitle)
                    Text("Rótulo secundário").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }

    private var buttons: some View {
        section("Botões") {
            VStack(spacing: FJSpacing.m) {
                FJPrimaryButton("Iniciar treino", systemImage: "play.fill") {}
                FJPrimaryButton("Marcar como feita", systemImage: "checkmark", area: .nutrition) {}
                GlassEffectContainer(spacing: FJSpacing.s) {
                    HStack(spacing: FJSpacing.s) {
                        FJSecondaryButton("Outra ficha", systemImage: "list.bullet") {}
                        FJSecondaryButton("Treino livre", systemImage: "plus") {}
                    }
                }
                HStack {
                    FJIconButton(systemImage: "chevron.down", label: "Minimizar treino") {}
                    FJIconButton(systemImage: "ellipsis", label: "Mais ações") {}
                }
            }
        }
    }

    private var chips: some View {
        section("Chips e etiquetas") {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: FJSpacing.s) {
                        HStack(spacing: FJSpacing.s) {
                            ForEach(groups, id: \.self) { group in
                                FJFilterChip(LocalizedStringKey(group), isSelected: filters.contains(group)) {
                                    if filters.contains(group) { filters.remove(group) } else { filters.insert(group) }
                                }
                            }
                        }
                    }
                }
                .scrollClipDisabled()
                FJCard {
                    VStack(alignment: .leading, spacing: FJSpacing.s) {
                        HStack {
                            FJTag("Aquecimento")
                            FJTag("Drop-set", area: .training)
                            FJTag("Recorde", systemImage: "trophy.fill", tone: .record)
                        }
                        HStack {
                            FJTag("Feita", systemImage: "checkmark.circle.fill", tone: .success)
                            FJTag("Ajustada", systemImage: "pencil.circle.fill", tone: .attention)
                            FJTag("Fora da dieta", systemImage: "plus.circle.fill")
                        }
                        HStack {
                            FJTag(.strength)
                            FJTag(.aerobic)
                        }
                    }
                }
            }
        }
    }

    private var metrics: some View {
        section("Métricas") {
            FJCard {
                FJMetricGrid {
                    FJMetricCell("Duração", value: "52:18", systemImage: "clock")
                    FJMetricCell("Volume", value: "8.420", unit: "kg", systemImage: "scalemass")
                    FJMetricCell("Séries", value: "18/20", systemImage: "checkmark.circle")
                    FJMetricCell("FC média", value: "128", unit: "bpm", systemImage: "heart.fill", tint: FJColor.health)
                    FJMetricCell("Energia ativa", value: nil, unit: "kcal", systemImage: "flame.fill", tint: FJColor.health)
                    FJMetricCell("Recordes", value: "2", systemImage: "trophy.fill", tint: FJColor.record)
                }
            }
        }
    }

    private var progress: some View {
        section("Metas") {
            FJCard {
                FJAdaptiveStack(spacing: FJSpacing.l) {
                    FJProgressRing(progress: 0.62, tint: FJColor.nutrition) {
                        Text(verbatim: "62%").font(FJFont.numberCaption)
                    }
                    .frame(width: FJSize.progressRing, height: FJSize.progressRing)
                    .accessibilityLabel(Text("Calorias"))
                    VStack(spacing: FJSpacing.m) {
                        FJGoalBar("Proteína", value: 96, goal: 150, unit: "g")
                        FJGoalBar("Fibra", value: 18, goal: nil, unit: "g")
                        FJGoalBar("Água", value: nil, goal: 3000, unit: "ml")
                    }
                }
            }
        }
    }

    private var steppers: some View {
        section("Carga e repetições") {
            FJCard {
                VStack(spacing: FJSpacing.l) {
                    NumberStepperField("Carga", value: $load, unit: "kg", step: 0.5, range: 0...500, fractionDigits: 2)
                    FJAdaptiveStack {
                        Text("alvo 8–12").font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                        Spacer(minLength: 0)
                        FJOptionalNumberField("Repetições realizadas", prompt: "+ reps", value: $reps, unit: "reps")
                    }
                    NumberStepperField("Sustentação", value: $hold, unit: "s", step: 5, range: 0...600)
                }
            }
        }
    }

    private var session: some View {
        section("Sessão") {
            VStack(spacing: FJSpacing.cardGap) {
                FJCard {
                    HStack(spacing: FJSpacing.m) {
                        ForEach(checks.indices, id: \.self) { index in
                            FJCheckButton(state: checks[index], accessibilityLabel: "Série \(index + 1) de \(checks.count)") {
                                checks[index] = checks[index] == .done ? .pending : .done
                            }
                        }
                    }
                }
                FJRestTimerView(
                    endsAt: restEndsAt,
                    total: restTotal,
                    nextUp: "Série 3 de 4 · 32,5 kg · alvo 8–12",
                    onAdjust: { delta in
                        restEndsAt = max(restEndsAt.addingTimeInterval(delta), .now)
                        restTotal = max(0, restTotal + delta)
                    },
                    onSkip: { restEndsAt = .now }
                )
                FJCard { FJRPEScale(value: $rpe) }
                FJSessionAccessory(
                    routineName: "A — Peito e tríceps",
                    startedAt: sessionStart,
                    detail: "Supino reto · série 2 de 4"
                )
                .fjGlass()
                FJSessionAccessory(
                    routineName: "A — Peito e tríceps",
                    startedAt: sessionStart,
                    pausedSeconds: 120,
                    pausedAt: sessionStart.addingTimeInterval(1500),
                    detail: "Supino reto · série 2 de 4"
                )
                .fjGlass()
            }
        }
    }

    private var heartRate: some View {
        section("Frequência cardíaca") {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    FJHeartRateBadge(bpm: 142, zone: .z3)
                    FJHeartRateBadge(bpm: nil)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: FJSpacing.xs) { zoneBadges }
                        VStack(alignment: .leading, spacing: FJSpacing.xs) { zoneBadges }
                    }
                }
            }
        }
    }

    private var zoneBadges: some View {
        ForEach(FJHeartRateZone.allCases, id: \.self) { zone in
            FJHeartRateZoneBadge(zone, showsName: false)
        }
    }

    private var states: some View {
        section("Estados") {
            VStack(spacing: FJSpacing.cardGap) {
                FJCard(padding: 0) {
                    FJEmptyState(
                        "Nenhum programa ainda",
                        systemImage: "dumbbell",
                        message: "Crie seu primeiro programa com as fichas da semana.",
                        actionTitle: "Criar programa"
                    ) {}
                    .padding(.vertical, FJSpacing.l)
                }
                FJCard { FJLoadingState("Lendo dados do Saúde…") }
                FJBanner(
                    "Saúde não conectado",
                    message: "Sem acesso ao app Saúde, a frequência cardíaca fica indisponível. Seus treinos continuam sendo registrados.",
                    tone: .attention,
                    systemImage: "heart.slash.fill",
                    actionTitle: "Abrir Ajustes"
                ) {}
                FJBanner("3 itens sem calorias", message: "O total do dia pode estar abaixo do real.")
                FJBanner("Não foi possível salvar", message: "Tente de novo. Nada foi perdido.", tone: .destructive, actionTitle: "Tentar de novo") {}
            }
        }
    }
}

#Preview("Galeria — claro") {
    DesignSystemGallery()
}

#Preview("Galeria — escuro") {
    DesignSystemGallery()
        .preferredColorScheme(.dark)
}

#Preview("Galeria — AX3") {
    DesignSystemGallery()
        .dynamicTypeSize(.accessibility3)
}
