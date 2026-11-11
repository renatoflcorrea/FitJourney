import SwiftUI

/// Anel de progresso de meta (kcal, progresso da sessão). `progress == nil` = sem meta: só o trilho.
struct FJProgressRing<Label: View>: View {
    private let progress: Double?
    private let tint: Color
    private let lineWidth: CGFloat
    private let label: Label

    init(
        progress: Double?,
        tint: Color = FJColor.training,
        lineWidth: CGFloat = 8,
        @ViewBuilder label: () -> Label
    ) {
        self.progress = progress
        self.tint = tint
        self.lineWidth = lineWidth
        self.label = label()
    }

    private var clamped: Double { (progress ?? 0).fjClamped(to: 0...1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(FJColor.fill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .fjAnimation(value: clamped)
            label
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("Sem meta"))
    }
}

extension FJProgressRing where Label == EmptyView {
    init(progress: Double?, tint: Color = FJColor.training, lineWidth: CGFloat = 8) {
        self.init(progress: progress, tint: tint, lineWidth: lineWidth) { EmptyView() }
    }
}

/// Barra de meta: rótulo, "valor / meta unidade" e trilho. Sem meta mostra só o valor;
/// valor indisponível mostra "—" (nunca zero).
struct FJGoalBar: View {
    private let label: LocalizedStringKey
    private let value: Double?
    private let goal: Double?
    private let unit: String
    private let tint: Color

    init(_ label: LocalizedStringKey, value: Double?, goal: Double?, unit: String, tint: Color = FJColor.nutrition) {
        self.label = label
        self.value = value
        self.goal = goal
        self.unit = unit
        self.tint = tint
    }

    private var fraction: Double? {
        guard let value, let goal, goal > 0 else { return nil }
        return (value / goal).fjClamped(to: 0...1)
    }

    private var valueText: String {
        guard let value else { return "—" }
        let current = FJFormat.number(value, maxFractionDigits: 0)
        guard let goal else { return "\(current) \(unit)" }
        return "\(current) / \(FJFormat.number(goal, maxFractionDigits: 0)) \(unit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    labelText
                    Spacer(minLength: FJSpacing.s)
                    valueLabel
                }
                VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                    labelText
                    valueLabel
                }
            }
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FJColor.fill)
                        Capsule().fill(tint)
                            .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                            .fjAnimation(value: fraction)
                    }
                }
                .frame(height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value == nil ? Text("Indisponível") : Text(verbatim: valueText))
    }

    private var labelText: some View {
        Text(label)
            .font(FJFont.label)
            .foregroundStyle(FJColor.textSecondary)
    }

    private var valueLabel: some View {
        Text(verbatim: valueText)
            .font(FJFont.numberCaption)
            .foregroundStyle(FJColor.textPrimary)
    }
}

#Preview("Progresso") {
    ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                HStack(spacing: FJSpacing.l) {
                    FJProgressRing(progress: 0.62, tint: FJColor.nutrition) {
                        Text(verbatim: "62%").font(FJFont.numberCaption)
                    }
                    .frame(width: FJSize.progressRing, height: FJSize.progressRing)
                    FJProgressRing(progress: 0.5) {
                        Text(verbatim: "3/6").font(FJFont.numberCaption)
                    }
                    .frame(width: FJSize.progressRing, height: FJSize.progressRing)
                    FJProgressRing(progress: nil, tint: FJColor.health)
                        .frame(width: FJSize.progressRing, height: FJSize.progressRing)
                }
            }
            FJCard {
                VStack(spacing: FJSpacing.m) {
                    FJGoalBar("Proteína", value: 96, goal: 150, unit: "g")
                    FJGoalBar("Carboidrato", value: 180, goal: 220, unit: "g")
                    FJGoalBar("Fibra", value: 18, goal: nil, unit: "g")
                    FJGoalBar("Água", value: nil, goal: 3000, unit: "ml")
                }
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
