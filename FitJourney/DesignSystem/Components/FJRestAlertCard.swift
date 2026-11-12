import SwiftUI

/// Cartão "Descanso concluído" do alerta insistente (DESIGN_DIRECTION §4.5): flutua sobre a doca da sessão
/// enquanto o iPhone vibra em laço. Anel laranja pulsando com o tempo desde o fim do descanso ("+0:12"), o que
/// vem a seguir e "Começar série". Vidro (flutua); com Reduzir Movimento não pulsa — o anel vira disco cheio e
/// o destaque vem só do contraste.
///
/// O tempo é calculado por datas (`endedAt`); quem apresenta trata o toque fora do botão (parar o alerta).
struct FJRestAlertCard: View {
    private let endedAt: Date
    private let exerciseName: String?
    private let nextUp: String?
    private let isRinging: Bool
    private let onStart: () -> Void
    private let onStop: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 104
    @State private var pulsing = false

    /// - Parameters:
    ///   - endedAt: instante em que o descanso terminou.
    ///   - exerciseName: exercício da próxima série.
    ///   - nextUp: a próxima série ("Série 3 de 4 · 26 kg · alvo 8–12").
    ///   - isRinging: a vibração em laço ainda toca (pulsa e mostra a dica de toque).
    ///   - onStop: parar o alerta sem começar a série — vira a ação "Parar vibração" do VoiceOver no cabeçalho
    ///     e na próxima série (os elementos em que o foco pousa).
    init(endedAt: Date, exerciseName: String? = nil, nextUp: String? = nil, isRinging: Bool,
         onStart: @escaping () -> Void, onStop: (() -> Void)? = nil) {
        self.endedAt = endedAt
        self.exerciseName = exerciseName
        self.nextUp = nextUp
        self.isRinging = isRinging
        self.onStart = onStart
        self.onStop = onStop
    }

    private var animates: Bool { isRinging && !reduceMotion }
    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    /// "+0:12": tempo desde o fim do descanso.
    static func overtime(since end: Date, at date: Date) -> String {
        "+" + FJFormat.clock(max(0, Int(date.timeIntervalSince(end))))
    }

    /// Anúncio do VoiceOver ao abrir.
    static func announcement(exerciseName: String?, nextUp: String?) -> String {
        let done = String(localized: "Descanso concluído")
        let next = [exerciseName, nextUp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return next.isEmpty ? done : String(localized: "\(done). Próxima: \(next).")
    }

    var body: some View {
        VStack(spacing: FJSpacing.m) {
            TimelineView(.periodic(from: endedAt, by: 1)) { context in
                header(at: context.date)
            }
            if exerciseName != nil || nextUp != nil {
                VStack(spacing: FJSpacing.xxs) {
                    if let exerciseName {
                        Text(verbatim: exerciseName)
                            .font(FJFont.cardTitle)
                            .foregroundStyle(FJColor.textPrimary)
                            .lineLimit(2)
                    }
                    if let nextUp {
                        Text(verbatim: nextUp)
                            .font(FJFont.label)
                            .foregroundStyle(FJColor.textSecondary)
                            .lineLimit(3)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .modifier(StopAction(onStop: onStop))
            }
            Button(action: onStart) {
                Text("Começar série")
            }
            .buttonStyle(.fjPrimary(.training))
            .accessibilityHint(Text(isRinging ? "Para a vibração e volta à série" : "Volta à série"))
            if isRinging {
                Text("Toque em qualquer lugar para parar")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
        }
        .padding(FJSpacing.l)
        .frame(maxWidth: .infinity)
        .fjGlass(in: FJRadius.shape(FJRadius.panel))
        .overlay {
            FJRadius.shape(FJRadius.panel)
                .strokeBorder(FJColor.training, lineWidth: 2)
                .opacity(animates ? (pulsing ? 1 : 0.35) : 1)
                .animation(animates ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulsing)
                .accessibilityHidden(true)
        }
        .onAppear { pulsing = true }
    }

    @ViewBuilder
    private func header(at date: Date) -> some View {
        let overtime = Self.overtime(since: endedAt, at: date)
        let seconds = max(0, Int(date.timeIntervalSince(endedAt)))
        Group {
            if isLargeText {
                // Texto grande: sem anel; título e tempo em linhas próprias.
                VStack(spacing: FJSpacing.xxs) {
                    title
                    Text(verbatim: overtime)
                        .font(FJFont.numberLarge)
                        .foregroundStyle(FJColor.textPrimary)
                }
            } else {
                VStack(spacing: FJSpacing.s) {
                    ring(overtime)
                    title
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Descanso concluído"))
        .accessibilityValue(Text("há \(FJFormat.spokenDuration(seconds))"))
        .accessibilityAddTraits([.isHeader, .updatesFrequently])
        .modifier(StopAction(onStop: onStop))
    }

    /// Ação "Parar vibração" no próprio elemento focável (ações em contêiner não aparecem no rotor).
    private struct StopAction: ViewModifier {
        let onStop: (() -> Void)?

        func body(content: Content) -> some View {
            if let onStop {
                content.accessibilityAction(named: Text("Parar vibração"), onStop)
            } else {
                content
            }
        }
    }

    private var title: some View {
        Text("Descanso concluído")
            .font(FJFont.sectionTitle)
            .foregroundStyle(FJColor.training)
            .multilineTextAlignment(.center)
    }

    private func ring(_ overtime: String) -> some View {
        let size = min(ringSize, 132)
        return ZStack {
            if animates {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(FJColor.training, lineWidth: 2)
                        .scaleEffect(pulsing ? 1.45 : 1)
                        .opacity(pulsing ? 0 : 0.6)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(index) * 0.9), value: pulsing)
                }
            }
            // Sem movimento o anel vira disco cheio: destaque por contraste, não por animação.
            Circle().fill(animates ? FJColor.training.opacity(0.16) : FJColor.trainingFill)
            Circle().strokeBorder(animates ? FJColor.training : FJColor.trainingFill, lineWidth: 5)
            Text(verbatim: overtime)
                .font(FJFont.timer(size: size * 0.3))
                .foregroundStyle(animates ? FJColor.textPrimary : FJColor.onFill)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, FJSpacing.s)
        }
        .frame(width: size, height: size)
        .padding(.vertical, FJSpacing.s)
    }
}

#Preview("Alerta de fim de descanso") {
    @Previewable @State var ringing = true

    return ZStack(alignment: .bottom) {
        FJColor.background.ignoresSafeArea()
        FJColor.scrim.ignoresSafeArea().onTapGesture { ringing = false }
        FJRestAlertCard(
            endedAt: .now.addingTimeInterval(-12),
            exerciseName: "Supino inclinado",
            nextUp: "Série 3 de 4 · 26 kg · alvo 8–12",
            isRinging: ringing,
            onStart: { ringing.toggle() }
        )
        .padding(FJSpacing.screenMargin)
    }
}
