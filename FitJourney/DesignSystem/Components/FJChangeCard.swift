import SwiftUI

/// Uma linha do diff de um cartão de alteração: o que era → o que passa a ser.
/// `before == nil` é inclusão; `after == nil` é remoção. Os textos já vêm formatados e localizados
/// por quem monta o cartão ("32 kg", "Crucifixo com halteres", "30 g · 120 kcal").
struct FJChange: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case modified, added, removed
    }

    let id: String
    /// O que muda: "Supino reto · carga", "Lanche da tarde".
    let label: String
    let before: String?
    let after: String?
    /// Leitura do VoiceOver com unidades por extenso ("Supino reto, carga: de 32 quilos para
    /// 34 quilos"). Sem isso, o componente monta a frase com `label`, `before` e `after`.
    let accessibilityLabel: String?

    init(
        id: String = UUID().uuidString,
        label: String,
        before: String?,
        after: String?,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.label = label
        self.before = before
        self.after = after
        self.accessibilityLabel = accessibilityLabel
    }

    var kind: Kind {
        if before == nil { return .added }
        if after == nil { return .removed }
        return .modified
    }
}

/// Estado de um cartão de alteração (SPEC §7A.2).
enum FJChangeCardState: Equatable, Sendable {
    /// Esperando o usuário: Aplicar · Ajustar · Descartar.
    case proposed
    /// Gravando.
    case applying
    /// Gravado: "Aplicado" + Desfazer.
    case applied
    /// Desfeito pelo usuário: pode aplicar de novo.
    case undone
    /// Descartado: o cartão recolhe numa linha.
    case discarded
    /// Não dá para aplicar agora (ex.: treino em andamento). O texto diz o motivo e a saída.
    case conflict(String)
    /// A gravação falhou. O texto diz o que houve; "Tentar de novo" chama `onApply`.
    case failed(String)
}

/// Cartão de alteração do copiloto (DESIGN_DIRECTION §4.15.8): diff legível antes → depois, escopo
/// e as ações Aplicar / Ajustar / Descartar; depois de aplicado, "Aplicado" com Desfazer.
///
/// Sólido (é conteúdo da conversa). O contorno em gradiente de IA existe **enquanto a proposta espera
/// o usuário** e some quando ela é aplicada, desfeita ou descartada. "Aplicar" usa a cor da área que
/// vai ser alterada (laranja = ficha, verde = dieta): a cor diz onde a mudança será gravada.
struct FJChangeCard: View {
    private let title: String
    private let scope: String
    private let area: FJArea
    private let changes: [FJChange]
    private let state: FJChangeCardState
    private let note: String?
    private let applyTitle: LocalizedStringKey
    private let appliedTitle: LocalizedStringKey
    private let onApply: () -> Void
    private let onAdjust: (() -> Void)?
    private let onDiscard: () -> Void
    private let onUndo: () -> Void

    /// - Parameters:
    ///   - title: o que a alteração faz, em uma linha ("Subir a carga do supino").
    ///   - scope: onde ("Ficha A · Peito e tríceps", "Dieta · Lanche da tarde", "Hoje · 16:20").
    ///   - area: área alterada — define o símbolo do escopo e a cor do "Aplicar".
    ///   - note: observação da IA ou regra aplicada ("A carga inicial não muda.").
    ///   - applyTitle: rótulo da ação principal; "Registrar" no registro rápido de comida.
    ///   - appliedTitle: etiqueta depois de aplicado; "Registrado" no registro rápido de comida.
    ///   - onAdjust: leva o foco à composição para o usuário pedir outra coisa; `nil` esconde o botão.
    init(
        title: String,
        scope: String,
        area: FJArea = .training,
        changes: [FJChange],
        state: FJChangeCardState,
        note: String? = nil,
        applyTitle: LocalizedStringKey = "Aplicar",
        appliedTitle: LocalizedStringKey = "Aplicado",
        onApply: @escaping () -> Void,
        onAdjust: (() -> Void)? = nil,
        onDiscard: @escaping () -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.title = title
        self.scope = scope
        self.area = area
        self.changes = changes
        self.state = state
        self.note = note
        self.applyTitle = applyTitle
        self.appliedTitle = appliedTitle
        self.onApply = onApply
        self.onAdjust = onAdjust
        self.onDiscard = onDiscard
        self.onUndo = onUndo
    }

    private var awaitsUser: Bool {
        switch state {
        case .proposed, .applying, .conflict, .failed: true
        case .applied, .undone, .discarded: false
        }
    }

    var body: some View {
        Group {
            if state == .discarded {
                discardedRow
            } else {
                card
            }
        }
        .fjAnimation(FJMotion.structure, value: state)
        .fjHaptic(.changeApplied, trigger: state) { _, new in new == .applied }
        .fjHaptic(.error, trigger: state) { _, new in
            if case .failed = new { true } else { false }
        }
        .onChange(of: state) { _, new in announce(new) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    if index > 0 {
                        Divider().padding(.vertical, FJSpacing.s)
                    }
                    FJChangeRow(change: change, isStruck: state == .undone)
                }
            }
            if let note {
                Text(verbatim: note)
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
            switch state {
            case let .conflict(message):
                FJBanner(LocalizedStringKey(message), tone: .attention)
            case let .failed(message):
                FJBanner("Não foi possível aplicar", message: LocalizedStringKey(message), tone: .destructive)
            default:
                EmptyView()
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .fjAIBorder(isVisible: awaitsUser)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Alteração proposta: \(title)"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            FJAdaptiveStack(spacing: FJSpacing.s) {
                HStack(spacing: FJSpacing.xs) {
                    Image(systemName: area.systemImage)
                        .foregroundStyle(area.color)
                        .accessibilityHidden(true)
                    Text(verbatim: scope)
                        .foregroundStyle(FJColor.textSecondary)
                }
                .font(FJFont.overline)
                Spacer(minLength: 0)
                stateTag
            }
            Text(verbatim: title)
                .font(FJFont.cardTitle)
                .foregroundStyle(FJColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var stateTag: some View {
        switch state {
        case .applied:
            FJTag(appliedTitle, systemImage: "checkmark.circle.fill", tone: .success)
        case .undone:
            FJTag("Desfeito", systemImage: "arrow.uturn.backward.circle.fill", tone: .neutral)
        case .conflict:
            FJTag("Não aplicado", systemImage: "exclamationmark.triangle.fill", tone: .attention)
        case .proposed, .applying, .failed:
            FJAIBadge("Sugestão da IA")
        case .discarded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        GlassEffectContainer(spacing: FJSpacing.s) {
            switch state {
            case .proposed, .applying:
                VStack(spacing: FJSpacing.s) {
                    FJPrimaryButton(applyTitle, systemImage: "checkmark", area: area,
                                    isLoading: state == .applying, action: onApply)
                    secondaryActions
                }
            case .failed:
                VStack(spacing: FJSpacing.s) {
                    FJPrimaryButton("Tentar de novo", systemImage: "arrow.clockwise", area: area, action: onApply)
                    secondaryActions
                }
            case .conflict:
                secondaryActions
            case .applied:
                FJSecondaryButton("Desfazer", systemImage: "arrow.uturn.backward", action: onUndo)
            case .undone:
                FJSecondaryButton("Aplicar de novo", systemImage: "arrow.clockwise", action: onApply)
            case .discarded:
                EmptyView()
            }
        }
    }

    private var secondaryActions: some View {
        FJAdaptiveStack(spacing: FJSpacing.s) {
            if let onAdjust {
                FJSecondaryButton("Ajustar", systemImage: "text.bubble", action: onAdjust)
            }
            FJSecondaryButton("Descartar", systemImage: "xmark", action: onDiscard)
        }
        .disabled(state == .applying)
    }

    private var discardedRow: some View {
        HStack(spacing: FJSpacing.s) {
            Image(systemName: "xmark.circle")
                .accessibilityHidden(true)
            Text("Sugestão descartada · \(title)")
                .lineLimit(2)
        }
        .font(FJFont.caption)
        .foregroundStyle(FJColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FJSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func announce(_ state: FJChangeCardState) {
        let message: String? = switch state {
        case .applied: String(localized: "Alteração aplicada")
        case .undone: String(localized: "Alteração desfeita")
        case .discarded: String(localized: "Sugestão descartada")
        case .failed: String(localized: "Não foi possível aplicar")
        case .proposed, .applying, .conflict: nil
        }
        if let message {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// Linha do diff. A diferença nunca depende só de cor: o valor antigo vem riscado e em tom
/// secundário, uma seta separa do novo (em destaque), e inclusão/remoção têm símbolo próprio.
private struct FJChangeRow: View {
    let change: FJChange
    /// Alteração desfeita: o "depois" também fica em tom secundário.
    let isStruck: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xxs) {
            Text(verbatim: change.label)
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
            switch change.kind {
            case .modified:
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                        beforeText
                        arrow
                        afterText
                    }
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        beforeText
                        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                            arrow
                            afterText
                        }
                    }
                }
            case .added:
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(isStruck ? FJColor.textSecondary : FJColor.success)
                    afterText
                }
            case .removed:
                HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(FJColor.textSecondary)
                    beforeText
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var beforeText: some View {
        Text(verbatim: change.before ?? "")
            .font(FJFont.numberBody)
            .strikethrough(true, color: FJColor.textSecondary)
            .foregroundStyle(FJColor.textSecondary)
    }

    private var afterText: some View {
        Text(verbatim: change.after ?? "")
            .font(FJFont.numberBody.weight(.semibold))
            .foregroundStyle(isStruck ? FJColor.textSecondary : FJColor.textPrimary)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(FJColor.textSecondary)
    }

    private var spokenLabel: Text {
        if let custom = change.accessibilityLabel {
            return Text(verbatim: custom)
        }
        switch change.kind {
        case .modified:
            return Text("\(change.label): de \(change.before ?? "") para \(change.after ?? "")")
        case .added:
            return Text("Adicionar \(change.label): \(change.after ?? "")")
        case .removed:
            return Text("Remover \(change.label): \(change.before ?? "")")
        }
    }
}

#Preview("Cartão de alteração") {
    @Previewable @State var state: FJChangeCardState = .proposed

    ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJChangeCard(
                title: "Subir a carga do supino",
                scope: "Ficha A · Peito e tríceps",
                changes: [
                    FJChange(label: "Supino reto · carga atual", before: "32 kg", after: "34 kg",
                             accessibilityLabel: "Supino reto, carga atual: de 32 quilos para 34 quilos"),
                    FJChange(label: "Exercício", before: "Crucifixo com halteres", after: "Voador"),
                    FJChange(label: "Tríceps corda", before: nil, after: "3 × 12–15 · 60 s"),
                    FJChange(label: "Mergulho no banco", before: "3 × máx.", after: nil),
                ],
                state: state,
                note: "A carga inicial não muda.",
                onApply: { state = .applied },
                onAdjust: {},
                onDiscard: { state = .discarded },
                onUndo: { state = .undone }
            )
            FJChangeCard(
                title: "Registrar açaí",
                scope: "Hoje · 16:20 · fora da dieta",
                area: .nutrition,
                changes: [FJChange(label: "Açaí", before: nil, after: "300 ml · 210 kcal (estimado)")],
                state: .applied,
                applyTitle: "Registrar",
                appliedTitle: "Registrado",
                onApply: {}, onDiscard: {}, onUndo: {}
            )
            FJChangeCard(
                title: "Trocar o agachamento",
                scope: "Ficha C · Pernas",
                changes: [FJChange(label: "Exercício", before: "Agachamento livre", after: "Leg press 45°")],
                state: .conflict("Você está treinando esta ficha agora. Aplique depois de finalizar o treino."),
                onApply: {}, onAdjust: {}, onDiscard: {}, onUndo: {}
            )
            FJChangeCard(
                title: "Adicionar whey no lanche",
                scope: "Dieta · Lanche da tarde",
                area: .nutrition,
                changes: [FJChange(label: "Whey protein", before: nil, after: "30 g · 120 kcal")],
                state: .failed("Tente de novo. Nada foi alterado."),
                onApply: {}, onAdjust: {}, onDiscard: {}, onUndo: {}
            )
        }
        .padding(FJSpacing.screenMargin)
    }
    .tint(FJColor.coach)
    .fjScreenBackground()
}
