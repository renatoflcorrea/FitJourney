import SwiftUI

/// Aviso do primeiro envio (proposta §7): o texto e as fotos vão ao provedor. Aceitar vale como o consentimento do
/// Coach com os quatro compartilhamentos desligados (`MealLogPreferences.grantConsent`).
struct MealLogConsentSheet: View {
    let providerName: String
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FJSpacing.l) {
                    FJAIBadge(style: .hero)
                        .frame(maxWidth: .infinity)
                    Text("Antes de analisar")
                        .font(FJFont.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    FJBanner("O texto e as fotos vão para \(providerName)",
                             message: "As fotos saem reduzidas e sem localização. Nada vai a servidor do FitJourney, e o seu histórico não é enviado.",
                             tone: .attention, systemImage: "lock.shield.fill")
                    Text("Aceitar vale como consentimento do Coach. Os compartilhamentos do Coach continuam desligados.")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                    VStack(spacing: FJSpacing.s) {
                        FJPrimaryButton("Concordar e analisar", systemImage: "checkmark", area: .coach) {
                            dismiss()
                            onAccept()
                        }
                        Button("Agora não") { dismiss() }
                            .frame(minHeight: FJSize.minTap)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(FJSpacing.screenMargin)
            }
            .fjScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
