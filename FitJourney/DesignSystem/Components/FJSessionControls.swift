import SwiftUI

/// Estado visual do check de uma série ou refeição.
enum FJCheckState: Sendable {
    case pending, done, skipped
}

/// Check grande (52 pt): um toque conclui com os valores exibidos. Concluído = preenchido na cor da área.
/// Quem usa fornece o rótulo completo do VoiceOver ("Série 2 de 4, 32,5 quilos, 10 repetições").
struct FJCheckButton: View {
    private let state: FJCheckState
    private let area: FJArea
    private let accessibilityLabel: String
    private let action: () -> Void

    init(state: FJCheckState, area: FJArea = .training, accessibilityLabel: String, action: @escaping () -> Void) {
        self.state = state
        self.area = area
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(state == .done ? area.fill : FJColor.fill)
                if state == .pending {
                    Circle().strokeBorder(FJColor.textTertiary, lineWidth: 1.5)
                }
                Image(systemName: state == .skipped ? "forward.fill" : "checkmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(foreground)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: FJSize.setCheck, height: FJSize.setCheck)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fjAnimation(value: state)
        .fjHaptic(.setCompleted, trigger: state == .done)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(valueText)
        .accessibilityHint(state == .done ? Text("Toque duas vezes para desfazer") : Text("Toque duas vezes para concluir"))
    }

    private var foreground: Color {
        switch state {
        case .pending: FJColor.textTertiary
        case .done: FJColor.onFill
        case .skipped: FJColor.textSecondary
        }
    }

    private var valueText: Text {
        switch state {
        case .pending: Text("Pendente")
        case .done: Text("Concluída")
        case .skipped: Text("Pulada")
        }
    }
}

/// Escala de intensidade percebida da sessão (RPE 1–10, Borg CR-10). Resposta opcional: `value == nil`.
struct FJRPEScale: View {
    @Binding private var value: Int?

    init(value: Binding<Int?>) {
        self._value = value
    }

    static func label(for value: Int) -> LocalizedStringKey {
        switch value {
        case ...1: "Muito leve"
        case 2: "Leve"
        case 3: "Moderado"
        case 4: "Um pouco difícil"
        case 5, 6: "Difícil"
        case 7, 8: "Muito difícil"
        case 9: "Quase máximo"
        default: "Máximo"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: FJSpacing.s) {
                Text(verbatim: value.map(String.init) ?? "—")
                    .font(FJFont.numberHero)
                    .contentTransition(.numericText())
                Text(value.map(Self.label(for:)) ?? "Toque para avaliar")
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
            }
            .fjAnimation(value: value)
            .accessibilityHidden(true)

            Grid(horizontalSpacing: FJSpacing.s, verticalSpacing: FJSpacing.s) {
                GridRow { ForEach(1...5, id: \.self) { cell($0) } }
                GridRow { ForEach(6...10, id: \.self) { cell($0) } }
            }
        }
        .fjHaptic(.selection, trigger: value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Intensidade percebida da sessão"))
    }

    private func cell(_ number: Int) -> some View {
        let isSelected = value == number
        return Button {
            value = isSelected ? nil : number
        } label: {
            Text(verbatim: "\(number)")
                .font(FJFont.numberMedium)
                .foregroundStyle(isSelected ? FJColor.onFill : FJColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: FJSize.setCheck)
                .background(isSelected ? FJColor.trainingFill : FJColor.fill, in: FJRadius.shape(FJRadius.field))
                .overlay {
                    if isSelected {
                        FJRadius.shape(FJRadius.field).strokeBorder(FJColor.textPrimary.opacity(0.35), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(number), \(Text(Self.label(for: number)))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Conteúdo do acessório da tab bar (`tabViewBottomAccessory`) com a sessão em andamento.
/// O vidro é do sistema. Tempo calculado por datas; durante o descanso mostra a contagem regressiva.
struct FJSessionAccessory: View {
    private let routineName: String
    private let startedAt: Date
    private let detail: String?
    private let restEndsAt: Date?

    init(routineName: String, startedAt: Date, detail: String? = nil, restEndsAt: Date? = nil) {
        self.routineName = routineName
        self.startedAt = startedAt
        self.detail = detail
        self.restEndsAt = restEndsAt
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let rest = restEndsAt.map { Int($0.timeIntervalSince(now).rounded(.up)) }.flatMap { $0 > 0 ? $0 : nil }
        let elapsed = Int(now.timeIntervalSince(startedAt))

        return HStack(spacing: FJSpacing.m) {
            Image(systemName: rest == nil ? "figure.strengthtraining.traditional" : "timer")
                .font(.body.weight(.semibold))
                .foregroundStyle(FJColor.training)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: routineName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(FJColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: FJSpacing.s)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: FJFormat.clock(rest ?? elapsed))
                    .font(FJFont.numberBody.weight(.semibold))
                    .contentTransition(.numericText(countsDown: rest != nil))
                if rest != nil {
                    Text("descanso")
                        .font(.caption2)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, FJSpacing.l)
        .frame(minHeight: FJSize.minTap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Treino em andamento: \(routineName)"))
        .accessibilityValue(
            rest.map { Text("Descanso, \(FJFormat.spokenDuration($0)) restantes") }
                ?? Text("\(FJFormat.spokenDuration(elapsed / 60 * 60)) de treino")
        )
        .accessibilityHint(Text("Abre a sessão"))
        .accessibilityAddTraits([.isButton, .updatesFrequently])
    }
}

#Preview("Check, RPE e acessório") {
    @Previewable @State var states: [FJCheckState] = [.done, .pending, .skipped]
    @Previewable @State var rpe: Int? = 7

    return ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                HStack(spacing: FJSpacing.l) {
                    ForEach(states.indices, id: \.self) { index in
                        FJCheckButton(state: states[index], accessibilityLabel: "Série \(index + 1) de 3") {
                            states[index] = states[index] == .done ? .pending : .done
                        }
                    }
                    FJCheckButton(state: .done, area: .nutrition, accessibilityLabel: "Café da manhã") {}
                }
            }
            FJCard { FJRPEScale(value: $rpe) }
            FJSessionAccessory(
                routineName: "A — Peito e tríceps",
                startedAt: .now.addingTimeInterval(-1934),
                detail: "Supino reto · série 2 de 4"
            )
            .fjGlass()
            FJSessionAccessory(
                routineName: "A — Peito e tríceps",
                startedAt: .now.addingTimeInterval(-1934),
                detail: "Supino reto · série 3 de 4",
                restEndsAt: .now.addingTimeInterval(48)
            )
            .fjGlass()
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}
