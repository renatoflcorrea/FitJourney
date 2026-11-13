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
                Text("Seus treinos, dieta e dados de saúde ficam neste iPhone. Nada é enviado a servidores do FitRoute. Só o Coach envia texto ao provedor de IA que você escolher, e apenas o que você permitir em Coach e IA.")
                    .font(FJFont.label)
            } header: {
                Text("Privacidade")
            }
        }
        .navigationTitle("Sobre")
        .navigationBarTitleDisplayMode(.inline)
    }
}
