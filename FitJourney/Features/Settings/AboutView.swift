import SwiftUI

/// Ajustes › Sobre: versão e privacidade.
struct AboutView: View {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Versão") {
                    Text(verbatim: Self.versionText).foregroundStyle(FJColor.textSecondary)
                }
            }
            Section {
                Text("Seus treinos, dieta e dados de saúde ficam neste iPhone. O Coach, a importação e o registro de refeições podem enviar dados ao provedor de IA que você escolher, somente depois de você permitir. Nada é enviado a servidores do FitJourney.")
                    .font(FJFont.label)
                Link("Política de privacidade", destination: AIConsentPresentation.appPolicyURL())
                    .frame(minHeight: FJSize.minTap, alignment: .leading)
                    .accessibilityIdentifier("about.privacyPolicy")
            } header: {
                Text("Privacidade")
            }
        }
        .navigationTitle("Sobre")
        .navigationBarTitleDisplayMode(.inline)
    }
}
