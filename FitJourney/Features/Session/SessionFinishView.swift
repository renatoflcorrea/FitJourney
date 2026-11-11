import SwiftUI

/// Encerramento (SPEC §4.3, DESIGN_DIRECTION §4.6): resumo, recordes, RPE e cargas atuais.
/// Empurrada dentro da sessão; "Voltar ao treino" é o voltar da navegação.
struct SessionFinishView: View {
    let coordinator: SessionCoordinator

    @State private var summary: SessionSummary?
    @State private var loadFailed = false
    @State private var rpe: Int?
    @State private var applied: Set<UUID> = []
    @State private var knownProposals: Set<UUID> = []
    @State private var isSaving = false
    @State private var confirmsDiscard = false

    private var engine: SessionEngine { coordinator.engine }

    var body: some View {
        ScrollView {
            VStack(spacing: FJSpacing.cardGap) {
                if let summary {
                    if summary.completedSets == 0 {
                        emptyState
                    } else {
                        header(summary)
                        recordsCard(summary)
                        skippedCard(summary)
                        rpeCard
                        proposalsCard(summary)
                    }
                } else if loadFailed {
                    FJBanner("Não foi possível montar o resumo", message: "Você ainda pode finalizar ou voltar ao treino.", tone: .attention)
                } else {
                    FJLoadingState("Montando resumo…")
                }
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.top, FJSpacing.s)
            .padding(.bottom, FJSpacing.l)
        }
        .fjScreenBackground()
        .navigationTitle("Finalizar treino")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmsDiscard = true } label: {
                        Label("Descartar treino", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("Mais ações"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if summary?.completedSets ?? 1 > 0 {
                FJPrimaryButton("Salvar treino", systemImage: "checkmark", isLoading: isSaving, action: save)
                    .padding(.horizontal, FJSpacing.screenMargin)
                    .padding(.vertical, FJSpacing.s)
                    .disabled(summary == nil && !loadFailed)
            }
        }
        .confirmationDialog("Descartar este treino?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Descartar treino", role: .destructive) { coordinator.send(.discard) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Nada será salvo no histórico.")
        }
        .task(id: engine.snapshot?.revision) { load() }
    }

    // MARK: Seções

    private func header(_ summary: SessionSummary) -> some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text(engine.snapshot.map(SessionPresentation.routineTitle) ?? String(localized: "Treino"))
                        .font(FJFont.sectionTitle)
                    Text(Date.now.formatted(date: .complete, time: .omitted))
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
                FJMetricGrid {
                    FJMetricCell("Duração", value: FJFormat.clock(Int(summary.durationSeconds)), systemImage: "clock")
                    FJMetricCell(summary.hasEstimatedVolume ? "Volume (estimado)" : "Volume",
                                 value: LoadDisplay.kgNumber(summary.volumeKg, maxFractionDigits: 0), unit: LoadDisplay.symbol(), systemImage: "scalemass")
                    FJMetricCell("Séries", value: "\(summary.completedSets)/\(summary.totalSets)", systemImage: "checkmark.circle")
                    FJMetricCell("Exercícios",
                                 value: "\(engine.snapshot?.metrics.exercisesDone ?? 0)/\(engine.snapshot?.metrics.exercisesTotal ?? 0)",
                                 systemImage: "dumbbell")
                    FJMetricCell("FC média", value: nil, unit: "bpm", systemImage: "heart.fill", tint: FJColor.health)
                    FJMetricCell("Energia ativa", value: nil, unit: "kcal", systemImage: "flame.fill", tint: FJColor.health)
                }
                if summary.hasEstimatedVolume {
                    Text("Séries sem repetições informadas entram no volume pelo piso do alvo.")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func recordsCard(_ summary: SessionSummary) -> some View {
        if !summary.personalRecords.isEmpty {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    FJSectionHeader("Recordes")
                    ForEach(Array(summary.personalRecords.enumerated()), id: \.offset) { _, record in
                        Label {
                            Text(recordText(record))
                        } icon: {
                            Image(systemName: "trophy.fill").foregroundStyle(FJColor.record)
                        }
                        .font(FJFont.body)
                    }
                }
            }
        }
    }

    private func recordText(_ record: PersonalRecord) -> String {
        let name = engine.snapshot?.exercises.first { $0.exerciseID == record.exerciseID }?.name ?? String(localized: "Exercício")
        let value = LoadDisplay.kgText(record.valueKg, maxFractionDigits: 2)
        switch record.kind {
        case .heaviestLoad: return String(localized: "\(name) — maior carga: \(value)")
        case .bestVolume: return String(localized: "\(name) — maior volume: \(value)")
        case .estimated1RM: return String(localized: "\(name) — 1RM estimado: \(value)")
        }
    }

    @ViewBuilder
    private func skippedCard(_ summary: SessionSummary) -> some View {
        let partial = engine.snapshot?.exercises.filter { $0.status == .partial }.map(\.name) ?? []
        if !summary.skippedExercises.isEmpty || !partial.isEmpty {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    FJSectionHeader("Pulados e parciais")
                    ForEach(summary.skippedExercises, id: \.self) { name in
                        Label(name, systemImage: "forward.fill").foregroundStyle(FJColor.textPrimary)
                    }
                    ForEach(partial, id: \.self) { name in
                        Label("\(name) — parcial", systemImage: "circle.lefthalf.filled").foregroundStyle(FJColor.textPrimary)
                    }
                }
                .font(FJFont.label)
            }
        }
    }

    private var rpeCard: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                FJSectionHeader("Como foi o treino?", subtitle: "Opcional · toque de novo para desmarcar")
                FJRPEScale(value: $rpe)
            }
        }
    }

    @ViewBuilder
    private func proposalsCard(_ summary: SessionSummary) -> some View {
        if !summary.loadProposals.isEmpty {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    FJSectionHeader("Atualizar carga atual",
                                    subtitle: "Usa a carga das séries concluídas como ponto de partida do próximo treino")
                    ForEach(summary.loadProposals) { proposal in
                        Toggle(isOn: binding(for: proposal.id)) {
                            Text(proposalText(proposal)).font(FJFont.body)
                        }
                        .frame(minHeight: FJSize.minTap)
                    }
                }
            }
        }
    }

    private func proposalText(_ proposal: LoadUpdateProposal) -> String {
        let to = SessionPresentation.loadText(WatchLoad(proposal.to)) ?? ""
        guard let from = proposal.from, let fromText = SessionPresentation.loadText(WatchLoad(from)) else {
            return "\(proposal.exerciseName): \(to)"
        }
        return "\(proposal.exerciseName): \(fromText) → \(to)"
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { applied.contains(id) },
            set: { if $0 { applied.insert(id) } else { applied.remove(id) } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: FJSpacing.l) {
            FJEmptyState("Nenhuma série registrada", systemImage: "tray",
                         message: "Este treino ainda não tem séries concluídas. Volte e registre, ou descarte.")
            Button("Descartar treino", role: .destructive) { confirmsDiscard = true }
                .buttonStyle(.fjPrimary(.training))
        }
    }

    // MARK: Ações

    /// Recalcula o resumo a cada revisão do snapshot (comando do relógio, edição). Preserva as escolhas
    /// do usuário nos toggles; propostas novas entram ligadas (padrão do motor).
    private func load() {
        do {
            let loaded = try engine.currentSummary()
            let ids = Set(loaded?.loadProposals.map(\.id) ?? [])
            let isFirst = summary == nil
            applied = isFirst ? ids : applied.intersection(ids).union(ids.subtracting(knownProposals))
            knownProposals = ids
            summary = loaded
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func save() {
        isSaving = true
        // Preserva a ordem do resumo para um comando determinístico.
        let ids = (summary?.loadProposals ?? []).map(\.id).filter(applied.contains)
        if !coordinator.send(.finish(rpe: rpe, applyLoadProposalIDs: ids)) { isSaving = false }
    }
}
