import SwiftUI

/// Análise em andamento (mockup 05): orbe, tempo decorrido (a partir de `analysisStartedAt`) e "Cancelar".
struct MealLogAnalyzingView: View {
    let session: MealLogSession
    let providerName: String

    var body: some View {
        ScrollView {
            VStack {
                Spacer(minLength: FJSpacing.xxl)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = MealLogPresentation.elapsed(since: session.analysisStartedAt, now: context.date)
                    FJAnalysisProgress(
                        title: String(localized: "Analisando o que você comeu…"),
                        subtitle: String(localized: "Enviado para \(providerName) · \(elapsed)"),
                        steps: steps,
                        onCancel: { session.cancel() })
                }
                Spacer(minLength: FJSpacing.xxl)
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .frame(maxWidth: .infinity)
        }
    }

    private var steps: [FJAnalysisStep] {
        let photos = session.photos.count
        let reading = photos > 0
            ? (photos == 1 ? String(localized: "Lendo a foto e o texto") : String(localized: "Lendo \(photos) fotos e o texto"))
            : String(localized: "Lendo o texto")
        return [
            FJAnalysisStep(id: "sent", title: String(localized: "Enviado para \(providerName)"), state: .done),
            FJAnalysisStep(id: "reading", title: reading, state: .active),
        ]
    }
}

/// Fases sem rascunho: sem internet, nada de comida, ilegível, tempo esgotado, erro do provedor.
struct MealLogStateView: View {
    let phase: MealLogSession.Phase
    let onRetry: () -> Void
    let onBack: () -> Void
    let onRetake: () -> Void
    let onDescribe: () -> Void

    var body: some View {
        let copy = MealLogPresentation.stateCopy(for: phase)
        ScrollView {
            VStack(spacing: FJSpacing.l) {
                Spacer(minLength: FJSpacing.xl)
                Image(systemName: copy?.symbol ?? "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(FJColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(spacing: FJSpacing.s) {
                    Text(verbatim: copy?.title ?? "")
                        .font(FJFont.sectionTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: copy?.message ?? "")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: FJSpacing.s) {
                    if copy?.offersRetake == true {
                        FJAIButton("Tirar outra", systemImage: "camera", prominence: .subtle, action: onRetake)
                        FJSecondaryButton("Descrever por texto", systemImage: "text.cursor", action: onDescribe)
                    } else {
                        FJAIButton("Tentar de novo", systemImage: "arrow.clockwise", prominence: .prominent, action: onRetry)
                        FJSecondaryButton("Voltar ao texto", systemImage: "chevron.backward", action: onBack)
                    }
                }
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .frame(maxWidth: .infinity)
        }
    }
}

/// "Corrigir por texto": "o arroz era integral, sem feijão" refaz só o rascunho.
struct MealLogCorrectionSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Text("Diga o que está errado. A IA refaz só o rascunho, sem enviar as fotos de novo.")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(FJSpacing.s)
                    .frame(minHeight: 120)
                    .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
                    .accessibilityLabel(Text("Correção"))
                Text("Por exemplo: o arroz era integral, sem feijão.")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textTertiary)
                Spacer(minLength: 0)
                FJAIButton("Corrigir") {
                    onSubmit(text)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(FJSpacing.screenMargin)
            .fjScreenBackground()
            .navigationTitle("Corrigir por texto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
