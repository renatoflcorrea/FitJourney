import SwiftUI

/// Identidade visual da IA (DESIGN_DIRECTION §4.15.1): gradiente "aurora" azul → violeta → rosa.
///
/// Regras: o gradiente marca **onde a IA entra e o que ela propõe** (símbolo `sparkles`, botão
/// "Importar com IA", contorno de cartão ainda não aplicado, progresso da análise). Nunca significa
/// estado (sucesso/erro), nunca é cor de texto corrido e nunca aparece sem símbolo ou rótulo.
enum FJAI {
    /// Texto curto, símbolo, contorno e barra de progresso.
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [FJColor.aiBlue, FJColor.aiViolet, FJColor.aiPink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Preenchimento com texto branco (botão de IA em destaque).
    static var fillGradient: LinearGradient {
        LinearGradient(
            colors: [FJColor.aiBlueFill, FJColor.aiVioletFill, FJColor.aiPinkFill],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Fundo suave (14%) de etiqueta e do orbe.
    static var softGradient: LinearGradient {
        LinearGradient(
            colors: [FJColor.aiBlue.opacity(0.14), FJColor.aiViolet.opacity(0.14), FJColor.aiPink.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Anel do orbe: o gradiente fecha em si mesmo para girar sem emenda.
    static var ringGradient: AngularGradient {
        AngularGradient(
            colors: [FJColor.aiBlue, FJColor.aiViolet, FJColor.aiPink, FJColor.aiViolet, FJColor.aiBlue],
            center: .center
        )
    }
}

private struct FJAIBorderModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let lineWidth: CGFloat
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isVisible {
                shape
                    .strokeBorder(FJAI.gradient, lineWidth: lineWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Brilho que atravessa a superfície **uma vez** ao aparecer (e de novo quando `trigger` muda).
/// Nunca em laço. Com Reduzir Movimento não existe.
private struct FJAISheenModifier<S: Shape, T: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shape: S
    let trigger: T
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.38), .white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: phase * proxy.size.width)
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: trigger) {
                guard !reduceMotion else { return }
                phase = -0.6
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.9)) { phase = 1.2 }
            }
    }
}

extension View {
    /// Contorno em gradiente de IA: marca um cartão que a IA propôs e que ainda espera o usuário.
    func fjAIBorder(
        in shape: some InsettableShape = FJRadius.shape(FJRadius.card),
        lineWidth: CGFloat = 1.5,
        isVisible: Bool = true
    ) -> some View {
        modifier(FJAIBorderModifier(shape: shape, lineWidth: lineWidth, isVisible: isVisible))
    }

    /// Brilho único ao aparecer (repete quando `trigger` muda). Sem efeito com Reduzir Movimento.
    func fjAISheen<T: Equatable>(in shape: some Shape = Capsule(), trigger: T) -> some View {
        modifier(FJAISheenModifier(shape: shape, trigger: trigger))
    }

    /// Brilho único ao aparecer. Sem efeito com Reduzir Movimento.
    func fjAISheen(in shape: some Shape = Capsule()) -> some View {
        modifier(FJAISheenModifier(shape: shape, trigger: 0))
    }
}

/// Orbe da IA: `sparkles` em gradiente dentro de um anel. É a "cara" do copiloto em folhas, estados
/// vazios e na análise. `isActive` gira o anel devagar **só enquanto a IA trabalha** (equivale a um
/// indicador de atividade); parado com Reduzir Movimento e quando `isActive` é falso.
struct FJAIOrb: View {
    private let baseSize: CGFloat
    private let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    init(size: CGFloat = 72, isActive: Bool = false) {
        self.baseSize = size
        self.isActive = isActive
    }

    var body: some View {
        let side = baseSize * min(max(scale, 1), 1.3)
        let spins = isActive && !reduceMotion
        ZStack {
            Circle().fill(FJAI.softGradient)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spins)) { context in
                let turn = spins
                    ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
                    : 0.08
                Circle()
                    .strokeBorder(FJAI.ringGradient, lineWidth: max(2, side * 0.045))
                    .rotationEffect(.degrees(turn * 360))
            }
            Image(systemName: "sparkles")
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(FJAI.gradient)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: spins)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

#Preview("IA — gradiente e orbe") {
    ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(spacing: FJSpacing.xl) {
            HStack(spacing: FJSpacing.xl) {
                FJAIOrb()
                FJAIOrb(size: 96, isActive: true)
            }
            FJCard {
                Text("Cartão proposto pela IA").font(FJFont.cardTitle)
            }
            .fjAIBorder()
            Text("Brilho único")
                .font(.headline)
                .foregroundStyle(FJColor.onFill)
                .padding(.horizontal, FJSpacing.xl)
                .frame(minHeight: FJSize.primaryButton)
                .background(FJAI.fillGradient, in: Capsule())
                .fjAISheen()
        }
        .padding(FJSpacing.screenMargin)
    }
}
