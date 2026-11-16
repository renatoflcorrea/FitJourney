import SwiftUI

/// Raiz do app do relógio (DESIGN §9.3): Treinos enquanto não há sessão; a Sessão a substitui enquanto houver.
struct WatchRootView: View {
    @Environment(WatchSessionModel.self) private var model
    /// Página inicial da sessão (0 Controles · 1 Série · 2 Métricas · 3 Ficha) — o harness muda isto.
    var initialPage = 1

    var body: some View {
        ZStack(alignment: .top) {
            content
            if let notice = model.notice {
                Text(notice.text)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { AccessibilityNotification.Announcement(notice.text).post() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        .preferredColorScheme(.dark)
        .tint(WF.training)
    }

    @ViewBuilder private var content: some View {
        if let summary = model.summary {
            SummaryView(summary: summary)
        } else if model.isSavingSession {
            SavingView()
        } else if model.hasActiveSession {
            if let since = model.staleSessionSince {
                StaleSessionView(since: since)
            } else if let alert = model.restAlert {
                // Tela cheia por cima de qualquer página da sessão; ao fechar, a sessão reabre na Série.
                RestAlertView(alert: alert)
            } else {
                SessionView(initialPage: initialPage)
            }
        } else {
            NavigationStack { RoutineListView() }
        }
    }
}

/// Selo `iphone.slash` na toolbar (iPhone fora de alcance). Sem alerta, sem modal.
struct PhoneUnreachableBadge: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        if model.connection == .phoneUnreachable {
            Image(systemName: "iphone.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WF.textSecondary)
                .accessibilityLabel("iPhone fora de alcance")
        }
    }
}

/// Estado vazio com símbolo e mensagem (sem botões mortos).
struct WatchEmptyState: View {
    let symbol: String
    let title: LocalizedStringResource
    var message: LocalizedStringResource?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(WF.training)
                    .accessibilityHidden(true)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(WF.textSecondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sessão aberta há mais de 4 h: Continuar · Finalizar · Descartar (mesma regra do iPhone).
struct StaleSessionView: View {
    @Environment(WatchSessionModel.self) private var model
    let since: Date

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Treino em aberto desde \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.headline).multilineTextAlignment(.center)
                WatchPrimaryButton(title: "Continuar") { model.keepStaleSessionGoing() }
                Button("Finalizar") { model.finish(rpe: nil) }.buttonStyle(WatchButtonStyle())
                Button("Descartar", role: .destructive) { model.discard() }.buttonStyle(WatchButtonStyle(kind: .destructive))
            }
        }
    }
}

/// Fim da sessão enviado, ainda sem confirmação do iPhone.
struct SavingView: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if model.connection == .phoneUnreachable {
                Image(systemName: "iphone.slash").font(.system(size: 30)).foregroundStyle(WF.textSecondary).accessibilityHidden(true)
                Text("Salvo no relógio").font(.headline)
                Text("Será enviado ao iPhone quando conectar.").font(.footnote).foregroundStyle(WF.textSecondary).multilineTextAlignment(.center)
                Button("OK") { model.dismissSaving() }.buttonStyle(WatchButtonStyle())
            } else if model.isSavingTimedOut {
                // iPhone alcançável mas sem confirmar no prazo: o relógio já encerrou e gravou.
                Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(WF.textSecondary).accessibilityHidden(true)
                Text("Salvo no relógio. O iPhone vai atualizar o histórico.").font(.footnote).multilineTextAlignment(.center)
                Button("OK") { model.dismissSaving() }.buttonStyle(WatchButtonStyle())
            } else {
                ProgressView()
                Text("Salvando…").font(.headline)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: model.isSavingTimedOut) { _, timedOut in
            guard timedOut else { return }
            AccessibilityNotification.Announcement(
                String(localized: "Salvo no relógio. O iPhone vai atualizar o histórico.")).post()
        }
    }
}
