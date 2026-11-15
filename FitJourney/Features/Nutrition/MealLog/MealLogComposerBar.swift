import SwiftUI

/// Barra "O que você comeu?" da aba Dieta (mockup 01): vidro com contorno e `sparkles` em gradiente + botão de câmera.
/// Flutua acima da tab bar (`safeAreaInset`). O chamador a esconde sem IA com `.visibleWhenAIAvailable()`; a câmera
/// some sozinha quando o modelo não lê fotos.
struct MealLogComposerBar: View {
    /// "Continuar rascunho · 4 refeições" quando há rascunho guardado.
    var draftSummary: String?
    let onText: () -> Void
    let onCamera: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 52

    var body: some View {
        GlassEffectContainer(spacing: FJSpacing.s) {
            HStack(spacing: FJSpacing.s) {
                Button(action: onText) {
                    HStack(spacing: FJSpacing.s) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(FJAI.gradient)
                            .accessibilityHidden(true)
                        Text(draftSummary ?? String(localized: "O que você comeu?"))
                            .font(.body)
                            .foregroundStyle(draftSummary == nil ? FJColor.textSecondary : FJColor.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, FJSpacing.l)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .contentShape(Capsule())
                    // O contorno é conteúdo: vai antes do vidro (dentro de um `GlassEffectContainer` ele some depois).
                    .fjAIBorder(in: Capsule())
                    .fjGlass(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(draftSummary ?? String(localized: "Registrar com IA")))
                .accessibilityHint(Text("Abre a folha para descrever o que você comeu"))

                Button(action: onCamera) {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .foregroundStyle(FJColor.textPrimary)
                        .frame(width: height, height: height)
                        .contentShape(Circle())
                        .fjGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Foto do prato"))
                .accessibilityHint(Text("Abre a câmera para estimar a refeição"))
                .visibleWhenAIAvailable(requiringImages: true)
            }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.bottom, FJSpacing.s)
        .padding(.top, FJSpacing.xs)
    }
}

/// Aviso "4 refeições registradas · Desfazer" depois de registrar (mockup 08). Sólido: não flutua em vidro.
struct MealLogUndoBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: FJSpacing.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(FJColor.success)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FJColor.textPrimary)
            Spacer(minLength: FJSpacing.s)
            Button("Desfazer", action: onUndo)
                .buttonStyle(.fjSecondary(fillsWidth: false))
        }
        .padding(FJSpacing.m)
        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        .overlay(FJRadius.shape(FJRadius.card).strokeBorder(FJColor.separator, lineWidth: 0.5))
        .padding(.horizontal, FJSpacing.screenMargin)
        .accessibilityElement(children: .contain)
    }
}
