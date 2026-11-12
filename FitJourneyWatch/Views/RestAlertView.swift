import SwiftUI

/// Textos da próxima série no alerta de fim de descanso (DESIGN §9.4).
enum WatchRestAlertText {
    /// "Supino inclinado · série 3 de 4" (`nil` = não há próxima série).
    static func title(_ display: SessionSnapshot?) -> String? {
        guard let exercise = display?.currentExercise else { return nil }
        guard let position = display?.currentSetPosition else { return exercise.name }
        return String(localized: "\(exercise.name) · série \(position.index) de \(position.of)")
    }

    /// "26 kg · alvo 8–12" (sem carga: só o alvo).
    static func detail(_ display: SessionSnapshot?) -> String? {
        guard let exercise = display?.currentExercise, let id = display?.currentSetID,
              let set = exercise.sets.first(where: { $0.id == id }) else { return nil }
        var parts: [String] = []
        if let load = effectiveLoad(of: set, in: exercise) { parts.append(WatchFormat.load(load, compact: true)) }
        if !set.targetText.isEmpty { parts.append(WatchFormat.target(text: set.targetText, effort: nil)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// VoiceOver: "Descanso concluído. Próxima: Supino inclinado, série 3 de 4, 26 quilos, alvo 8 a 12 repetições."
    static func announcement(_ display: SessionSnapshot?) -> String {
        let done = String(localized: "Descanso concluído")
        guard let exercise = display?.currentExercise, let id = display?.currentSetID,
              let set = exercise.sets.first(where: { $0.id == id }), let position = display?.currentSetPosition else { return done }
        var parts = [String(localized: "\(exercise.name), série \(position.index) de \(position.of)")]
        if let load = effectiveLoad(of: set, in: exercise) { parts.append(WatchFormat.spokenLoad(load)) }
        if !set.targetText.isEmpty { parts.append(WatchFormat.spokenTarget(text: set.targetText)) }
        return String(localized: "\(done). Próxima: \(parts.joined(separator: ", ")).")
    }

    /// "+0:12": tempo desde o fim do descanso.
    static func overtime(since end: Date, at date: Date) -> String {
        "+" + WatchFormat.clock(max(0, date.timeIntervalSince(end)))
    }
}

/// "Descanso concluído" em tela cheia (DESIGN §9.4): anel laranja pulsando com o tempo desde o fim, a próxima
/// série e "Começar série". Qualquer toque ou giro da Coroa para a vibração; "Começar série" (toque duplo)
/// para e volta à Série. Reduzir Movimento e tela sempre ligada: sem pulsar, anel cheio (só contraste).
struct RestAlertView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let alert: WatchRestAlert
    @State private var crown = 0.0
    @State private var pulsing = false

    private var isLargeText: Bool { typeSize >= .accessibility1 }
    private var animates: Bool { alert.isRinging && !reduceMotion && !isLuminanceReduced }
    private var ringSize: CGFloat { isLargeText ? 56 : (WatchLayout.isLargeCase ? 70 : 56) }

    var body: some View {
        Group {
            if isLargeText {
                // Texto grande: tudo rola; o botão fica fixo na base e a Coroa rola o conteúdo.
                ScrollView { VStack(spacing: 6) { ring; texts } .frame(maxWidth: .infinity) }
                    .safeAreaInset(edge: .bottom) { footer }
            } else {
                VStack(spacing: 3) {
                    ring
                    texts
                    Spacer(minLength: 0)
                    footer
                }
                .focusable()
                .digitalCrownRotation($crown)
                .onChange(of: crown) { _, _ in model.silenceRestAlert() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.silenceRestAlert() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.magicTap) { model.silenceRestAlert() }
        .onAppear {
            AccessibilityNotification.Announcement(WatchRestAlertText.announcement(model.display)).post()
            pulsing = true
        }
    }

    // MARK: Anel

    private var ring: some View {
        TimelineView(.periodic(from: alert.endedAt, by: 1)) { context in
            ZStack {
                if animates {
                    ForEach(0..<2, id: \.self) { index in
                        Circle()
                            .stroke(WF.training, lineWidth: 2)
                            .scaleEffect(pulsing ? 1.55 : 1)
                            .opacity(pulsing ? 0 : 0.7)
                            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(index) * 0.9), value: pulsing)
                    }
                }
                // Sem movimento o anel vira disco cheio: o destaque vem do contraste, não da animação.
                Circle().fill(animates ? WF.training.opacity(0.18) : WF.trainingFill)
                Circle().strokeBorder(WF.training, lineWidth: animates ? 4 : 3)
                Text(WatchRestAlertText.overtime(since: alert.endedAt, at: context.date))
                    .font(WF.number(ringSize * 0.3, weight: .bold))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: ringSize, height: ringSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Descanso concluído")
            .accessibilityValue(spokenOvertime(at: context.date))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: Text("Parar vibração")) { model.silenceRestAlert() }
            .accessibilitySortPriority(3)
        }
        .padding(.top, isLargeText ? 0 : 2)
    }

    private func spokenOvertime(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(alert.endedAt)))
        return seconds < 60 ? String(localized: "há \(seconds) segundos") : String(localized: "há \(seconds / 60) min")
    }

    // MARK: Textos e botão

    private var texts: some View {
        VStack(spacing: 1) {
            Text("Descanso concluído")
                .font(.headline).foregroundStyle(WF.training)
                .lineLimit(isLargeText ? 2 : 1).minimumScaleFactor(0.75)
                .accessibilityHidden(true)
            if let title = WatchRestAlertText.title(model.display) {
                Text(title).font(.footnote.weight(.semibold))
                    .lineLimit(isLargeText ? 4 : 1).minimumScaleFactor(0.75)
            }
            if let detail = WatchRestAlertText.detail(model.display) {
                Text(detail).font(.footnote).foregroundStyle(WF.textSecondary)
                    .lineLimit(isLargeText ? 3 : 1).minimumScaleFactor(0.75)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Parar vibração")) { model.silenceRestAlert() }
        .accessibilitySortPriority(2)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            WatchPrimaryButton(title: model.currentSet == nil ? "Continuar" : "Começar série",
                               accessibilityLabel: model.currentSet == nil ? "Continuar" : "Começar série") {
                model.startSetAfterRest()
            }
            .accessibilityHint(alert.isRinging ? Text("Para a vibração e volta à série") : Text("Volta à série"))
            .accessibilitySortPriority(1)
            if alert.isRinging {
                Text("Toque para parar")
                    .font(.caption2).foregroundStyle(WF.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
