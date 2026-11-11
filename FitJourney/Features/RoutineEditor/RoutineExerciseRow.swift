import SwiftUI

/// Posição de uma linha dentro de um grupo (bi-set/tri-set/circuito).
enum GroupPosition: Hashable {
    case none, first, middle, last

    var isGrouped: Bool { self != .none }
}

/// Ações de uma linha de exercício (compartilhadas por menu, contexto e VoiceOver).
struct RowActions {
    var open: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var duplicate: () -> Void
    var transfer: () -> Void
    var showExercise: () -> Void
    var delete: () -> Void
    var ungroup: () -> Void
    var setGroupRest: (Int) -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool
}

/// Linha de exercício da ficha: nome, resumo da prescrição, etiquetas de série e menu de ações.
struct RoutineExerciseRow: View {
    let item: RoutineExercise
    let position: GroupPosition
    let groupCount: Int
    let groupRest: Int
    let isSelecting: Bool
    let isSelected: Bool
    let actions: RowActions

    private var summary: String { item.prescriptionSummary }
    private var isRemoved: Bool { item.exercise == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            if position == .first, let gid = item.groupID {
                HStack {
                    FJTag(LocalizedStringKey(GroupLabel.name(forCount: groupCount)), systemImage: "link", area: .training)
                    Spacer(minLength: 0)
                    Button("Desagrupar", systemImage: "link.badge.minus", action: actions.ungroup)
                        .font(FJFont.label)
                        .buttonStyle(.borderless)
                        .frame(minHeight: FJSize.minTap)
                        .id(gid)
                }
            }

            HStack(spacing: FJSpacing.s) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? FJColor.training : FJColor.textTertiary)
                        .accessibilityHidden(true)
                }
                Button(action: actions.open) {
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        Text(item.displayName.exerciseDisplayName)
                            .font(FJFont.cardTitle)
                            .foregroundStyle(isRemoved ? FJColor.textSecondary : FJColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        if summary.isEmpty {
                            Label("Definir séries", systemImage: FJTone.attention.systemImage)
                                .font(FJFont.label)
                                .foregroundStyle(FJColor.textPrimary)
                                .symbolRenderingMode(.multicolor)
                        } else {
                            Text(summary)
                                .font(FJFont.numberCaption)
                                .foregroundStyle(FJColor.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        let kinds = item.nonWorkingKinds
                        if isRemoved || !kinds.isEmpty {
                            HStack(spacing: FJSpacing.xs) {
                                if isRemoved {
                                    FJTag("Removido do catálogo", systemImage: FJTone.attention.systemImage, tone: .attention)
                                }
                                ForEach(kinds, id: \.self) { FJTag(LocalizedStringKey($0.localizedName)) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: FJSize.minTap, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityName))
                .accessibilityValue(Text(summary.isEmpty ? String(localized: "Sem séries definidas") : item.prescriptionSpoken))
                .accessibilityHint(Text(isSelecting ? (isSelected ? "Toque para desmarcar" : "Toque para marcar") : "Abre a prescrição"))
                .accessibilityAddTraits(isSelecting && isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: Text("Subir"), actions.moveUp)
                .accessibilityAction(named: Text("Descer"), actions.moveDown)
                .accessibilityAction(named: Text("Duplicar"), actions.duplicate)
                .accessibilityAction(named: Text("Mover ou copiar para outra ficha"), actions.transfer)
                .accessibilityAction(named: Text("Remover"), actions.delete)

                if !isSelecting {
                    Menu { RowMenu(actions: actions, hasExercise: !isRemoved) } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: FJSize.minTap, height: FJSize.minTap)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Ações de \(item.displayName.exerciseDisplayName)"))
                }
            }

            if position == .last {
                Menu {
                    ForEach(Array(Set([30, 45, 60, 90, 120, 180, groupRest])).sorted(), id: \.self) { n in
                        Button {
                            actions.setGroupRest(n)
                        } label: {
                            if n == groupRest { Label("\(n) s", systemImage: "checkmark") } else { Text("\(n) s") }
                        }
                    }
                } label: {
                    Label("Descanso ao fim da rodada: \(groupRest) s", systemImage: "timer")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textPrimary)
                        .frame(minHeight: FJSize.minTap, alignment: .leading)
                }
                .accessibilityLabel(Text("Descanso ao fim da rodada: \(FJFormat.spokenDuration(groupRest))"))
                .accessibilityHint(Text("Toque para alterar"))
            }
        }
        .padding(.leading, position.isGrouped ? FJSpacing.m : 0)
        .contextMenu { RowMenu(actions: actions, hasExercise: !isRemoved) }
    }

    private var accessibilityName: String {
        guard position.isGrouped else { return item.displayName.exerciseDisplayName }
        return "\(GroupLabel.name(forCount: groupCount)), \(item.displayName.exerciseDisplayName)"
    }
}

/// Itens de menu de uma linha (subir/descer são a alternativa acessível ao arrastar).
struct RowMenu: View {
    let actions: RowActions
    let hasExercise: Bool

    var body: some View {
        Button("Subir", systemImage: "arrow.up", action: actions.moveUp).disabled(!actions.canMoveUp)
        Button("Descer", systemImage: "arrow.down", action: actions.moveDown).disabled(!actions.canMoveDown)
        Divider()
        Button("Duplicar", systemImage: "plus.square.on.square", action: actions.duplicate)
        Button("Mover ou copiar para…", systemImage: "arrowshape.turn.up.right", action: actions.transfer)
        if hasExercise {
            Button("Ver exercício", systemImage: "info.circle", action: actions.showExercise)
        }
        Divider()
        Button("Remover", systemImage: "trash", role: .destructive, action: actions.delete)
    }
}

/// Fundo da linha com o trilho vertical laranja do grupo (contínuo entre as linhas).
struct GroupRailBackground: View {
    let position: GroupPosition

    var body: some View {
        ZStack(alignment: .leading) {
            FJColor.surface
            if position.isGrouped {
                Rectangle()
                    .fill(FJColor.training)
                    .frame(width: 4)
                    .padding(.leading, FJSpacing.xs)
                    .padding(.top, position == .first ? FJSpacing.m : 0)
                    .padding(.bottom, position == .last ? FJSpacing.m : 0)
                    .accessibilityHidden(true)
            }
        }
    }
}
