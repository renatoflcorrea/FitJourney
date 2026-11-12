import SwiftData
import SwiftUI

/// Etapa 2: o que está sendo lido e o que já foi encontrado (DESIGN §4.15.4). Sem spinner genérico nem barra por tempo.
struct ImportAnalysisView: View {
    let session: ImportSession

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?
    @State private var providerName = ""
    @State private var slow = false

    var body: some View {
        let output = ImportAnalysisPresentation.make(
            kind: session.kind, attachments: session.attachments, providerName: providerName,
            programImport: session.programImport, nutritionImport: session.nutritionImport, slow: slow)
        ScrollView {
            VStack(spacing: FJSpacing.l) {
                FJAnalysisProgress(title: output.title, subtitle: output.subtitle, steps: output.steps, isActive: true,
                                   onCancel: { session.cancel() })
                if !(coordinator?.network.isOnline ?? true) {
                    FJBanner("Sem conexão", message: "Continuo quando ela voltar.", tone: .neutral, systemImage: "wifi.slash")
                }
                ForEach(session.warnings, id: \.self) { warning in
                    FJBanner(LocalizedStringKey(warning), tone: .attention)
                }
            }
            .padding(FJSpacing.screenMargin)
        }
        .task {
            providerName = (coordinator?.providerInfo() ?? ImportProviderInfo()).name
            try? await Task.sleep(for: .seconds(60))
            slow = true
        }
    }
}

// MARK: - Fichas / variações encontradas

/// "Encontrei 4 fichas": marcar, renomear e escolher letra/cor (DESIGN §4.15.6). Vem antes das perguntas, que só valem
/// para as fichas escolhidas.
struct ImportGroupsView: View {
    let session: ImportSession
    let ui: ImportUIState

    @Environment(\.modelContext) private var context
    @State private var editing: ImportGroupCardModel?
    @State private var expanded: Set<Int> = []

    private var cards: [ImportGroupCardModel] {
        if let program = session.programImport {
            return ImportReviewPresentation.routineCards(program, selected: session.selected, overrides: ui.routines, colorOffset: colorOffset)
        }
        if let nutrition = session.nutritionImport {
            return ImportReviewPresentation.dayCards(nutrition, selected: session.selected)
        }
        return []
    }

    private var colorOffset: Int { ImportOverrides.colorOffset(target: ui.target, context: context) }

    private var selectedCount: Int { session.selected.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                VStack(alignment: .leading, spacing: FJSpacing.xs) {
                    Text(session.kind == .program ? "Encontrei \(session.detectedGroupCount) fichas" : "Encontrei \(session.detectedGroupCount) variações")
                        .font(FJFont.screenTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(session.kind == .program ? "Escolha as que quer importar." : "Escolha as variações de dieta que quer importar.")
                        .font(FJFont.label)
                        .foregroundStyle(FJColor.textSecondary)
                    if case .existingProgram = ui.target {
                        Text("Serão adicionadas ao programa que você escolheu.")
                            .font(FJFont.caption)
                            .foregroundStyle(FJColor.textSecondary)
                    }
                }
                ForEach(cards) { card in
                    groupCard(card)
                }
            }
            .padding(FJSpacing.screenMargin)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FJPrimaryButton(continueTitle, systemImage: "arrow.right", area: .coach) { ui.groupsConfirmed = true }
                .disabled(selectedCount == 0)
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.vertical, FJSpacing.s)
                .background(FJColor.background)
        }
        .sheet(item: $editing) { card in
            GroupEditSheet(card: card, isProgram: session.kind == .program) { name, symbol, color in
                ui.routines[card.id] = ImportUIState.RoutineOverride(name: name, symbol: symbol, colorName: color)
            }
        }
    }

    private var continueTitle: LocalizedStringKey {
        switch (session.kind, selectedCount) {
        case (.program, 1): "Continuar com 1 ficha"
        case (.program, _): "Continuar com \(selectedCount) fichas"
        case (.nutrition, 1): "Continuar com 1 variação"
        case (.nutrition, _): "Continuar com \(selectedCount) variações"
        }
    }

    private func groupCard(_ card: ImportGroupCardModel) -> some View {
        let isExpanded = expanded.contains(card.id)
        return VStack(alignment: .leading, spacing: FJSpacing.s) {
            HStack(alignment: .top, spacing: FJSpacing.m) {
                Button { session.setSelected(card.id, included: !card.isSelected) } label: {
                    HStack(alignment: .top, spacing: FJSpacing.m) {
                        Image(systemName: card.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(card.isSelected ? FJColor.coach : FJColor.textTertiary)
                            .frame(width: FJSize.minTap, height: FJSize.minTap)
                            .accessibilityHidden(true)
                        if session.kind == .program {
                            FJRoutineBadge(symbol: card.symbol, name: card.name, colorName: card.colorName)
                        }
                        VStack(alignment: .leading, spacing: FJSpacing.xs) {
                            Text(verbatim: card.name).font(FJFont.cardTitle).foregroundStyle(FJColor.textPrimary)
                            Text(verbatim: card.detail).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
                            if let source = card.source { FJSourceLabel(file: source.file, page: source.page) }
                            FJConfidenceBadge(card.confidence, style: .full)
                            if card.attentionCount > 0 {
                                Text(card.attentionCount == 1 ? "1 item para conferir" : "\(card.attentionCount) itens para conferir")
                                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(card.isSelected ? .isSelected : [])
                .accessibilityHint(Text("Marca ou desmarca para importar"))
                Button { editing = card } label: {
                    Image(systemName: "pencil")
                        .frame(width: FJSize.minTap, height: FJSize.minTap)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Renomear \(card.name)"))
            }
            if session.kind == .program || !card.items.isEmpty {
                Button { toggle(card.id) } label: {
                    Label(isExpanded ? "Ocultar lista" : "Ver lista", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(FJFont.caption.weight(.semibold))
                        .frame(minHeight: FJSize.minTap, alignment: .leading)
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                            Text(verbatim: item).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fjCard()
        .opacity(card.isSelected ? 1 : 0.6)
        .fjAnimation(FJMotion.structure, value: isExpanded)
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// Renomear e escolher letra/cor (mesmos campos do editor de ficha).
private struct GroupEditSheet: View {
    let card: ImportGroupCardModel
    let isProgram: Bool
    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var colorName: String

    init(card: ImportGroupCardModel, isProgram: Bool, onSave: @escaping (String, String, String) -> Void) {
        self.card = card
        self.isProgram = isProgram
        self.onSave = onSave
        _name = State(initialValue: card.name)
        _symbol = State(initialValue: card.symbol)
        _colorName = State(initialValue: card.colorName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Nome", text: $name)
                }
                if isProgram {
                    Section("Letra ou símbolo") {
                        TextField("Letra", text: $symbol)
                            .textInputAutocapitalization(.characters)
                            .onChange(of: symbol) { _, value in symbol = String(value.prefix(2)) }
                    }
                    Section("Cor") {
                        FJRoutineColorPicker(colorName: $colorName)
                    }
                }
            }
            .navigationTitle("Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), symbol.uppercased(), colorName)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
