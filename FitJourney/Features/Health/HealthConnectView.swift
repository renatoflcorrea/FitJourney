import SwiftUI

/// Estado da conexão com o Saúde em texto (apresentação pura).
enum HealthConnectionState: Equatable {
    case unavailable
    case notConnected
    case connected(canWrite: Bool)

    @MainActor
    init(_ authorization: HealthAuthorization?) {
        guard let authorization else {
            self = .unavailable
            return
        }
        switch authorization.access {
        case .unavailable: self = .unavailable
        case .notDetermined: self = .notConnected
        case .requested(let canWrite):
            self = authorization.isConnectionEnabled ? .connected(canWrite: canWrite) : .notConnected
        }
    }

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// Conectar ao Saúde (SPEC §6.1): o que é lido e gravado, o botão, os estados e o atalho para revisar
/// permissões. Empurrável (Ajustes › Saúde) e usado como cartão na aba Saúde.
struct HealthConnectView: View {
    init() {}

    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?

    var body: some View {
        ScrollView {
            HealthConnectCard(showsTitle: false)
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.vertical, FJSpacing.s)
        }
        .fjScreenBackground()
        .navigationTitle("Saúde")
        .navigationBarTitleDisplayMode(.inline)
        .task { await authorization?.refresh() }
    }
}

/// Conteúdo de "Conectar ao Saúde" (cartão sólido).
struct HealthConnectCard: View {
    var showsTitle = true

    @Environment(HealthAuthorization.self) private var authorization: HealthAuthorization?
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false
    @State private var confirmsDisconnect = false

    private var state: HealthConnectionState { HealthConnectionState(authorization) }

    var body: some View {
        VStack(spacing: FJSpacing.cardGap) {
            switch state {
            case .unavailable:
                FJCard {
                    FJEmptyState("Saúde indisponível neste aparelho", systemImage: "heart.slash",
                                 message: "Este aparelho não tem o app Saúde. Seus treinos continuam sendo registrados no FitJourney.")
                }
            case .notConnected:
                intro
                FJPrimaryButton("Conectar ao Saúde", systemImage: "heart.fill", area: .health, isLoading: isRequesting) {
                    isRequesting = true
                    Task {
                        await authorization?.request()
                        isRequesting = false
                    }
                }
            case .connected(let canWrite):
                FJCard {
                    VStack(alignment: .leading, spacing: FJSpacing.m) {
                        Label("Conectado ao Saúde", systemImage: "checkmark.circle.fill")
                            .font(FJFont.cardTitle)
                            .foregroundStyle(FJColor.textPrimary)
                            .symbolRenderingMode(.hierarchical)
                        Text("O FitJourney lê frequência cardíaca, treinos, energia ativa, passos e peso, e grava seus treinos no Saúde.")
                            .font(FJFont.label)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                if !canWrite {
                    FJBanner("Sem acesso para gravar no Saúde",
                             message: "O treino fica só no FitJourney. Confira em Ajustes › Saúde › Acesso a Dados.",
                             tone: .attention, systemImage: "exclamationmark.triangle.fill",
                             actionTitle: "Abrir Ajustes") { HealthSettings.open(openURL) }
                }
                details
                FJCard {
                    VStack(alignment: .leading, spacing: FJSpacing.s) {
                        Button { HealthSettings.open(openURL) } label: {
                            Label("Revisar permissões", systemImage: "gearshape")
                                .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
                        }
                        Text("O Saúde não informa ao app quais leituras foram negadas. Se algum dado aparecer como \"—\", confira o acesso em Ajustes › Saúde › Acesso a Dados.")
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                        Divider()
                        Button(role: .destructive) { confirmsDisconnect = true } label: {
                            Label("Desconectar", systemImage: "heart.slash")
                                .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
                        }
                    }
                }
            }
            if state == .notConnected { details }
        }
        .confirmationDialog("Desconectar do Saúde?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Desconectar", role: .destructive) { authorization?.disconnect() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O FitJourney para de ler e gravar no Saúde. As permissões do sistema só mudam em Ajustes › Saúde.")
        }
    }

    private var intro: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                Image(systemName: "heart.text.square.fill")
                    .font(.largeTitle)
                    .foregroundStyle(FJColor.health)
                    .accessibilityHidden(true)
                if showsTitle {
                    Text("Conecte ao app Saúde").font(FJFont.sectionTitle).accessibilityAddTraits(.isHeader)
                }
                Text("Veja a frequência cardíaca em cada exercício e o seu dia de treino. Você escolhe o que compartilhar na folha do sistema.")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    private var details: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.l) {
                section("O que o FitJourney lê", rows: [
                    ("heart.fill", "Frequência cardíaca e FC em repouso"),
                    ("figure.run", "Treinos do Apple Watch e de outros apps"),
                    ("flame.fill", "Energia ativa e passos"),
                    ("scalemass", "Peso (para estimar a energia quando o relógio não mediu)"),
                ])
                section("O que o FitJourney grava", rows: [
                    ("dumbbell.fill", "Seus treinos, com início, fim e tipo"),
                    ("flame.fill", "Energia ativa do treino"),
                ])
            }
        }
    }

    private func section(_ title: LocalizedStringKey, rows: [(String, LocalizedStringKey)]) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text(title).font(FJFont.cardTitle).accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Label {
                    Text(row.1).font(FJFont.label)
                } icon: {
                    Image(systemName: row.0).foregroundStyle(FJColor.health).frame(width: 24)
                }
            }
        }
    }
}

#Preview("Conectar") {
    NavigationStack { HealthConnectView() }
        .environment(HealthPreviewFixtures.disconnectedAuthorization(suite: "preview-connect"))
        .tint(FJColor.health)
}
