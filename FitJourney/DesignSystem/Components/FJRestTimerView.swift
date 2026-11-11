import SwiftUI

/// Painel do cronômetro de descanso (vidro, flutua sobre a lista da sessão, na metade inferior).
/// O tempo é calculado por datas (`endsAt`), nunca por contador em memória: sobrevive a fechar o app.
struct FJRestTimerView: View {
    private let endsAt: Date
    private let total: TimeInterval
    private let nextUp: String?
    private let onAdjust: (TimeInterval) -> Void
    private let onSkip: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 60

    /// - Parameters:
    ///   - endsAt: instante em que o descanso termina.
    ///   - total: duração total atual do descanso (para a barra).
    ///   - nextUp: o que vem a seguir ("Série 3 de 4 · 32,5 kg × 10").
    ///   - onAdjust: recebe +15 ou −15 segundos.
    init(
        endsAt: Date,
        total: TimeInterval,
        nextUp: String? = nil,
        onAdjust: @escaping (TimeInterval) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.endsAt = endsAt
        self.total = total
        self.nextUp = nextUp
        self.onAdjust = onAdjust
        self.onSkip = onSkip
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            panel(now: context.date)
        }
    }

    private func panel(now: Date) -> some View {
        let remaining = Int(endsAt.timeIntervalSince(now).rounded(.up))
        let finished = remaining <= 0
        let fraction = total > 0 ? min(max(Double(remaining) / total, 0), 1) : 0

        return VStack(spacing: FJSpacing.m) {
            VStack(spacing: FJSpacing.xxs) {
                Label(finished ? "Descanso concluído" : "Descanso", systemImage: finished ? "checkmark.circle.fill" : "timer")
                    .font(FJFont.overline)
                    .foregroundStyle(finished ? FJColor.success : FJColor.textSecondary)
                if let nextUp {
                    Text(verbatim: nextUp)
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            Text(verbatim: finished ? "+\(FJFormat.clock(-remaining))" : FJFormat.clock(remaining))
                .font(FJFont.timer(size: min(timerSize, 96)))
                .foregroundStyle(FJColor.textPrimary)
                .contentTransition(.numericText(countsDown: !finished))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .fjAnimation(value: remaining)
                .accessibilityLabel(finished ? Text("Descanso concluído") : Text("Descanso restante"))
                .accessibilityValue(Text(verbatim: FJFormat.spokenDuration(abs(remaining))))
                .accessibilityAddTraits(.updatesFrequently)

            ProgressView(value: fraction)
                .tint(FJColor.training)
                .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: FJSpacing.s) { controls }
                VStack(spacing: FJSpacing.s) { controls }
            }
        }
        .padding(FJSpacing.l)
        .frame(maxWidth: .infinity)
        .fjGlass(in: FJRadius.shape(FJRadius.panel))
        .fjHaptic(.timerFinished, trigger: finished)
    }

    @ViewBuilder private var controls: some View {
        control("−15 s", accessibility: "Menos 15 segundos") { onAdjust(-15) }
        control(prominent: true, "Pular", accessibility: "Pular descanso", action: onSkip)
        control("+15 s", accessibility: "Mais 15 segundos") { onAdjust(15) }
    }

    /// Dentro do painel os controles são sólidos: vidro sobre vidro não.
    private func control(
        prominent: Bool = false,
        _ title: LocalizedStringKey,
        accessibility: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.monospacedDigit())
                .foregroundStyle(prominent ? FJColor.onFill : FJColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: FJSize.setCheck)
                .background(prominent ? FJColor.trainingFill : FJColor.fillStrong, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibility))
    }
}

#Preview("Timer de descanso") {
    @Previewable @State var endsAt = Date.now.addingTimeInterval(75)
    @Previewable @State var total: TimeInterval = 90

    return ZStack(alignment: .bottom) {
        FJColor.background.ignoresSafeArea()
        FJRestTimerView(
            endsAt: endsAt,
            total: total,
            nextUp: "Série 3 de 4 · 32,5 kg × 10",
            onAdjust: { delta in
                endsAt = endsAt.addingTimeInterval(delta)
                total = max(0, total + delta)
            },
            onSkip: { endsAt = .now }
        )
        .padding(FJSpacing.screenMargin)
    }
}
