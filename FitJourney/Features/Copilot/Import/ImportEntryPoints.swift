import SwiftData
import SwiftUI

/// Botão "Importar com IA" dos pontos de entrada (DESIGN §4.15.2). Some em previews sem coordenador.
struct ImportWithAIButton: View {
    let kind: ImportSession.Kind
    var target: ImportSession.Target?
    var title: LocalizedStringKey = "Importar com IA"
    var prominence: FJAIButtonStyle.Prominence = .subtle
    var fillsWidth = true

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?

    var body: some View {
        if let coordinator {
            FJAIButton(title, prominence: prominence, fillsWidth: fillsWidth) {
                coordinator.start(kind: kind, target: target)
            }
        }
    }
}

/// Item de menu "Importar com IA" (toolbar e menus do sistema: `sparkles` nativo, sem gradiente).
struct ImportWithAIMenuItem: View {
    let kind: ImportSession.Kind
    var target: ImportSession.Target?
    var title: LocalizedStringKey = "Importar com IA"

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?

    var body: some View {
        if let coordinator {
            Button(title, systemImage: "sparkles") { coordinator.start(kind: kind, target: target) }
        }
    }
}

/// Cartão "Continuar importação" (DESIGN §4.15.9): importação interrompida ou terminada com a folha fechada.
struct ImportContinueCard: View {
    let kind: ImportSession.Kind

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let coordinator {
            let pending = coordinator.pending(kind: kind)
            Group {
                if let first = pending.first {
                    card(first, coordinator: coordinator)
                }
            }
            .onAppear { coordinator.refreshStored() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { coordinator.refreshStored() } }
        }
    }

    private func card(_ item: PendingCopilotImport, coordinator: ImportCoordinator) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                FJAIBadge(style: .symbol).font(.title3)
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    Text("Continuar importação").font(FJFont.cardTitle)
                    Text(verbatim: item.detail).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            FJAdaptiveStack(spacing: FJSpacing.s) {
                FJAIButton("Continuar", prominence: .subtle) { coordinator.resume(item.id) }
                FJSecondaryButton("Descartar", systemImage: "trash") { coordinator.discard(item.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .fjAIBorder(isVisible: true)
        .accessibilityElement(children: .contain)
    }
}

/// Aviso global depois de aplicar: "Programa criado" · Desfazer (até sair da tela). Fica no `AppRoot`.
struct ImportResultBanner: View {
    let completion: ImportCompletion
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        FJBanner(completion.kind == .program ? "Programa criado" : "Dieta criada",
                 message: LocalizedStringKey(completion.createdNew
                    ? String(localized: "\(completion.name) foi criado a partir dos seus arquivos.")
                    : String(localized: "As fichas foram adicionadas a \(completion.name).")),
                 tone: .success,
                 actionTitle: completion.createdNew ? "Desfazer" : "Fechar",
                 action: completion.createdNew ? onUndo : onDismiss)
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.top, FJSpacing.s)
            .task {
                try? await Task.sleep(for: .seconds(12))
                onDismiss()
            }
    }
}
