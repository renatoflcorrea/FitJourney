import SwiftUI

/// Uma etapa da análise dos arquivos. Os textos já vêm localizados e dizem algo concreto:
/// "Enviado à OpenAI", "Lendo Treino João.pdf", "Encontrei 4 fichas".
struct FJAnalysisStep: Identifiable, Equatable, Sendable {
    enum State: Sendable {
        case pending, active, done, failed
    }

    let id: String
    let title: String
    /// Segunda linha opcional ("página 2 de 4", "Peito e tríceps · Ombro · Perna · Costas e bíceps").
    let detail: String?
    let state: State
    /// Achado da IA ("Encontrei 4 fichas"): ganha o `sparkles` em gradiente e é anunciado ao VoiceOver.
    let isFinding: Bool

    init(id: String, title: String, detail: String? = nil, state: State, isFinding: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.isFinding = isFinding
    }
}

/// Estado de análise do copiloto (DESIGN_DIRECTION §4.15.4): orbe da IA, frase do que está
/// acontecendo, barra (quando há fração conhecida) e a lista de etapas com os achados.
/// Substitui o spinner genérico: sempre diz **o que** está sendo lido e **o que já foi encontrado**.
///
/// Sem fundo próprio: coloque direto na folha ou dentro de um `FJCard`.
struct FJAnalysisProgress: View {
    private let title: String
    private let subtitle: String?
    private let steps: [FJAnalysisStep]
    private let progress: Double?
    private let isActive: Bool
    private let cancelTitle: LocalizedStringKey
    private let onCancel: (() -> Void)?

    /// - Parameters:
    ///   - title: frase principal ("Lendo 3 arquivos…", "Montando as fichas…", "Leitura concluída").
    ///   - subtitle: para onde foi / quanto falta ("Enviados à OpenAI · costuma levar menos de 1 min").
    ///   - progress: 0…1 quando há fração real (arquivos enviados, páginas convertidas); `nil` esconde a barra.
    ///   - isActive: `false` para o orbe (concluído, pausado, erro).
    ///   - onCancel: `nil` esconde o botão.
    init(
        title: String,
        subtitle: String? = nil,
        steps: [FJAnalysisStep],
        progress: Double? = nil,
        isActive: Bool = true,
        cancelTitle: LocalizedStringKey = "Cancelar",
        onCancel: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.steps = steps
        self.progress = progress.map { $0.fjClamped(to: 0...1) }
        self.isActive = isActive
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    private var findings: [String] {
        steps.filter { $0.isFinding && $0.state == .done }.map(\.title)
    }

    var body: some View {
        VStack(spacing: FJSpacing.l) {
            VStack(spacing: FJSpacing.m) {
                FJAIOrb(size: 88, isActive: isActive)
                VStack(spacing: FJSpacing.xs) {
                    Text(verbatim: title)
                        .font(FJFont.sectionTitle)
                        .foregroundStyle(FJColor.textPrimary)
                        .multilineTextAlignment(.center)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(FJFont.label)
                            .foregroundStyle(FJColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                if let progress {
                    FJAIProgressBar(value: progress)
                        .frame(maxWidth: 220)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [title, subtitle].compactMap { $0 }.joined(separator: ". ")))
            .accessibilityValue(progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(.updatesFrequently)

            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    ForEach(steps) { step in
                        FJAnalysisStepRow(step: step, animates: isActive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fjAnimation(FJMotion.structure, value: steps)
            }

            if let onCancel {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(.fjSecondary(fillsWidth: false))
            }
        }
        .onChange(of: findings) { old, new in
            guard new.count > old.count, let latest = new.last else { return }
            AccessibilityNotification.Announcement(latest).post()
        }
    }
}

/// Barra de progresso no gradiente de IA.
private struct FJAIProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FJColor.fillStrong)
                Capsule()
                    .fill(FJAI.gradient)
                    .frame(width: max(proxy.size.height, proxy.size.width * value))
            }
        }
        .frame(height: 6)
        .fjAnimation(value: value)
        .accessibilityHidden(true)
    }
}

private struct FJAnalysisStepRow: View {
    let step: FJAnalysisStep
    let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FJSpacing.m) {
            icon
                .font(.body.weight(.semibold))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(verbatim: step.title)
                    .font(step.state == .active || step.isFinding ? FJFont.label.weight(.semibold) : FJFont.label)
                    .foregroundStyle(step.state == .pending ? FJColor.textSecondary : FJColor.textPrimary)
                if let detail = step.detail {
                    Text(verbatim: detail)
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [step.title, step.detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(stateText)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(FJColor.textTertiary)
        case .active:
            Image(systemName: "ellipsis")
                .foregroundStyle(FJAI.gradient)
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: animates && !reduceMotion)
        case .done:
            if step.isFinding {
                Image(systemName: "sparkles")
                    .foregroundStyle(FJAI.gradient)
            } else {
                Image(systemName: "checkmark")
                    .foregroundStyle(FJColor.textSecondary)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FJColor.attention)
        }
    }

    private var stateText: Text {
        switch step.state {
        case .pending: Text("Aguardando")
        case .active: Text("Em andamento")
        case .done: Text("Concluído")
        case .failed: Text("Falhou")
        }
    }
}

#Preview("Análise") {
    ScrollView {
        VStack(spacing: FJSpacing.sectionGap) {
            FJAnalysisProgress(
                title: "Lendo 3 arquivos…",
                subtitle: "Enviados à OpenAI · costuma levar menos de 1 minuto",
                steps: [
                    FJAnalysisStep(id: "send", title: "3 arquivos enviados", detail: "2 PDFs · 1 foto", state: .done),
                    FJAnalysisStep(id: "found", title: "Encontrei 4 fichas",
                                   detail: "Peito e tríceps · Ombro · Perna · Costas e bíceps", state: .done, isFinding: true),
                    FJAnalysisStep(id: "ex", title: "Lendo exercícios e séries", detail: "Ficha 2 de 4", state: .active),
                    FJAnalysisStep(id: "match", title: "Casar com a sua biblioteca", state: .pending),
                ],
                progress: 0.45
            ) {}
            FJCard {
                FJAnalysisProgress(
                    title: "Leitura concluída",
                    steps: [
                        FJAnalysisStep(id: "found", title: "Encontrei 1 dieta com 6 refeições", state: .done, isFinding: true),
                        FJAnalysisStep(id: "bad", title: "Foto 2 está ilegível", detail: "Vou perguntar o que faltou.", state: .failed),
                    ],
                    isActive: false
                )
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
