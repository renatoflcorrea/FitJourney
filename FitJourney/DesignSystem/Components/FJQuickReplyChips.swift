import SwiftUI

/// Resposta rápida a uma pergunta do copiloto. O título já vem localizado ("3 séries de 12",
/// "Peso corporal", "Não sei").
struct FJQuickReply: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String?

    init(_ title: String, id: String? = nil, systemImage: String? = nil) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
    }
}

/// Respostas rápidas da entrevista (DESIGN_DIRECTION §4.15.5): chips de vidro que quebram linha,
/// com 44 pt de altura mínima. Tocar responde; a última opção ("Outra resposta") leva ao texto livre.
///
/// Escolha única: o chip tocado fica marcado (`selected`) e a entrevista avança. Escolha múltipla:
/// passe todos os marcados em `selected` e ofereça um botão "Continuar" fora do componente.
/// Selecionado = check + contorno (nunca só cor).
struct FJQuickReplyChips: View {
    private let replies: [FJQuickReply]
    private let selected: Set<String>
    private let freeTextTitle: LocalizedStringKey
    private let onFreeText: (() -> Void)?
    private let onSelect: (FJQuickReply) -> Void

    /// - Parameters:
    ///   - selected: ids marcados.
    ///   - freeTextTitle: rótulo do chip de texto livre.
    ///   - onFreeText: foca o campo de resposta; `nil` esconde o chip de texto livre.
    init(
        _ replies: [FJQuickReply],
        selected: Set<String> = [],
        freeTextTitle: LocalizedStringKey = "Outra resposta",
        onFreeText: (() -> Void)? = nil,
        onSelect: @escaping (FJQuickReply) -> Void
    ) {
        self.replies = replies
        self.selected = selected
        self.freeTextTitle = freeTextTitle
        self.onFreeText = onFreeText
        self.onSelect = onSelect
    }

    var body: some View {
        GlassEffectContainer(spacing: FJSpacing.s) {
            FJFlowLayout(spacing: FJSpacing.s) {
                ForEach(replies) { reply in
                    let isSelected = selected.contains(reply.id)
                    Button {
                        onSelect(reply)
                    } label: {
                        chipLabel(isSelected: isSelected, systemImage: reply.systemImage) {
                            Text(verbatim: reply.title)
                        }
                    }
                    .buttonStyle(.plain)
                    .fjGlass(interactive: true)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                if let onFreeText {
                    Button(action: onFreeText) {
                        chipLabel(isSelected: false, systemImage: "keyboard") {
                            Text(freeTextTitle)
                        }
                    }
                    .buttonStyle(.plain)
                    .fjGlass(interactive: true)
                }
            }
        }
        .fjHaptic(.selection, trigger: selected)
    }

    private func chipLabel(
        isSelected: Bool,
        systemImage: String?,
        @ViewBuilder title: () -> some View
    ) -> some View {
        HStack(spacing: FJSpacing.xs) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FJColor.coach)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(FJColor.textSecondary)
            }
            title()
                .multilineTextAlignment(.leading)
        }
        .font(.subheadline.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(FJColor.textPrimary)
        .padding(.horizontal, FJSpacing.m)
        .padding(.vertical, FJSpacing.s)
        .frame(minHeight: FJSize.minTap)
        .contentShape(Capsule())
        // Contorno no conteúdo (antes do vidro), para não sumir dentro do GlassEffectContainer.
        .overlay {
            if isSelected {
                Capsule().strokeBorder(FJColor.coach, lineWidth: 1.5)
            }
        }
    }
}

/// Progresso da entrevista: "3 de 5 dúvidas" com um segmento por pergunta.
/// Respondidas = cheias; atual = cheia e mais alta; pendentes = trilho. O texto diz o mesmo.
struct FJQuestionProgress: View {
    private let current: Int
    private let total: Int

    /// - Parameters:
    ///   - current: pergunta atual, começando em 1.
    ///   - total: total de dúvidas (pode crescer: a IA pode perguntar algo novo depois de uma resposta).
    init(current: Int, total: Int) {
        self.total = max(total, 1)
        self.current = current.fjClamped(to: 1...max(total, 1))
    }

    var body: some View {
        HStack(spacing: FJSpacing.m) {
            HStack(spacing: FJSpacing.xs) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? AnyShapeStyle(FJAI.gradient) : AnyShapeStyle(FJColor.fillStrong))
                        .frame(height: index == current ? 6 : 4)
                        .frame(maxWidth: 28)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text("\(current) de \(total) dúvidas")
                .font(FJFont.numberCaption)
                .foregroundStyle(FJColor.textSecondary)
                .fjNumericTransition()
                .layoutPriority(1)
        }
        .fjAnimation(value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dúvida \(current) de \(total)"))
    }
}

#Preview("Respostas rápidas") {
    @Previewable @State var selected: Set<String> = []

    ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(alignment: .leading, spacing: FJSpacing.l) {
            FJQuestionProgress(current: 3, total: 5)
            Text("No supino está “3x12”. Como devo ler?")
                .font(FJFont.body)
            FJQuickReplyChips(
                [
                    FJQuickReply("3 séries de 12"),
                    FJQuickReply("3 séries de 8 a 12"),
                    FJQuickReply("12 séries de 3"),
                    FJQuickReply("Não sei", systemImage: "questionmark"),
                ],
                selected: selected,
                onFreeText: {}
            ) { reply in
                selected = [reply.id]
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .tint(FJColor.coach)
}
