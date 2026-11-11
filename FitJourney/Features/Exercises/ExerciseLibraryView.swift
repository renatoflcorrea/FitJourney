import SwiftData
import SwiftUI

// MARK: - Linha

struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        let media = exercise.media
        HStack(spacing: FJSpacing.m) {
            thumbnail(first: media.first)
                .frame(width: 56, height: 56)
                .clipShape(FJRadius.shape(FJRadius.chip))
            VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                Text(exercise.name)
                    .font(FJFont.cardTitle)
                    .foregroundStyle(FJColor.textPrimary)
                Text(exercise.summaryLine)
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(mediaCount: media.count))
    }

    @ViewBuilder
    private func thumbnail(first: MediaRef?) -> some View {
        if let first {
            MediaThumbnailView(media: first, maxPixel: 200, showsPlayBadge: false)
        } else {
            ZStack {
                FJColor.fill
                Image(systemName: exercise.equipment.systemImage)
                    .font(.title3)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    private func accessibilityText(mediaCount count: Int) -> String {
        let media = count > 0 ? ", " + String(localized: "\(count) mídias") : ""
        return "\(exercise.name), \(exercise.summaryLine)\(media)"
    }
}

// MARK: - Navegador (biblioteca e seletor)

/// Lista com busca, filtros e seções. `selection == nil` = modo biblioteca (toque abre o detalhe);
/// com `selection`, o toque marca/desmarca (modo seletor).
struct ExerciseBrowser: View {
    enum Mode {
        case browse
        case pick(allowsMultiple: Bool)
    }

    let mode: Mode
    @Binding var selection: [PersistentIdentifier]
    var onSingleTap: ((Exercise) -> Void)?

    @Environment(\.modelContext) private var context
    @Query private var allExercises: [Exercise]

    @State private var filter = ExerciseFilter()
    @State private var creating: CreationRequest?
    @State private var blockedDelete: Exercise?
    @State private var pendingDelete: Exercise?

    struct CreationRequest: Identifiable {
        let id = UUID()
        let name: String
    }

    private var results: [Exercise] {
        let matcher = filter.prepared()
        return allExercises
            .filter(matcher.matches)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let results = results
        let mine = results.filter { !$0.isBuiltIn }
        let catalog = results.filter(\.isBuiltIn)

        List {
            if !mine.isEmpty {
                Section("Meus exercícios") { rows(mine) }
            }
            if !catalog.isEmpty {
                Section("Catálogo") { rows(catalog) }
            }
            if results.isEmpty {
                emptyResult
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .fjScreenBackground()
        .searchable(text: $filter.query, prompt: "Buscar exercício")
        .safeAreaInset(edge: .top, spacing: 0) { FilterChips(filter: $filter) }
        .sheet(item: $creating) { request in
            ExerciseEditorView(initialName: request.name) { created in
                if case .pick(let multiple) = mode {
                    if multiple { selection.append(created.persistentModelID) } else { onSingleTap?(created) }
                }
            }
        }
        .alert("Exercício em uso", isPresented: Binding(get: { blockedDelete != nil }, set: { if !$0 { blockedDelete = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Este exercício está em fichas. Remova-o das fichas antes de excluir.")
        }
        .confirmationDialog("Excluir exercício?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { exercise in
            Button("Excluir \(exercise.name)", role: .destructive) { delete(exercise) }
        } message: { _ in
            Text("A mídia salva deste exercício também será apagada. O histórico de treinos continua.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Novo exercício", systemImage: "plus") { creating = CreationRequest(name: "") }
            }
        }
    }

    // MARK: Linhas

    @ViewBuilder
    private func rows(_ items: [Exercise]) -> some View {
        ForEach(items) { exercise in
            switch mode {
            case .browse:
                NavigationLink {
                    ExerciseDetailView(exercise: exercise)
                } label: {
                    ExerciseRow(exercise: exercise)
                }
                .swipeActions(edge: .trailing) {
                    if !exercise.isBuiltIn {
                        Button("Excluir", systemImage: "trash", role: .destructive) { requestDelete(exercise) }
                    }
                }
            case .pick(let multiple):
                let isSelected = selection.contains(exercise.persistentModelID)
                Button {
                    if multiple {
                        if isSelected { selection.removeAll { $0 == exercise.persistentModelID } } else { selection.append(exercise.persistentModelID) }
                    } else {
                        onSingleTap?(exercise)
                    }
                } label: {
                    HStack {
                        ExerciseRow(exercise: exercise)
                        if multiple {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? FJColor.training : FJColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .fjHaptic(.selection, trigger: isSelected)
            }
        }
    }

    @ViewBuilder
    private var emptyResult: some View {
        let text = filter.query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            FJEmptyState("Nenhum exercício com esses filtros", systemImage: "line.3.horizontal.decrease.circle",
                         message: "Remova um filtro para ver mais exercícios.",
                         actionTitle: "Limpar filtros") { filter = ExerciseFilter() }
        } else {
            ContentUnavailableView {
                Label("Sem resultados para \"\(text)\"", systemImage: "magnifyingglass")
            } description: {
                Text("Confira a ortografia ou crie o exercício.")
            } actions: {
                Button("Criar exercício \"\(text)\"") { creating = CreationRequest(name: text) }
                    .buttonStyle(.fjPrimary(.training, fillsWidth: false))
            }
        }
    }

    // MARK: Excluir

    private func requestDelete(_ exercise: Exercise) {
        if (exercise.routineExercises ?? []).isEmpty { pendingDelete = exercise } else { blockedDelete = exercise }
    }

    private func delete(_ exercise: Exercise) {
        let media = exercise.media
        context.delete(exercise)
        do {
            try context.save()
            MediaStore.shared.deleteUnreferenced(media, in: context)
        } catch {
            context.rollback()
        }
    }
}

// MARK: - Chips de filtro

private struct FilterChips: View {
    @Binding var filter: ExerciseFilter

    var body: some View {
        VStack(spacing: FJSpacing.xs) {
            chipRow(label: "Grupo muscular") {
                ForEach(MuscleGroup.allCases, id: \.self) { group in
                    FJFilterChip(LocalizedStringKey(group.localizedName), isSelected: filter.muscles.contains(group)) {
                        toggle(group, in: &filter.muscles)
                    }
                }
            }
            chipRow(label: "Equipamento") {
                ForEach(Equipment.allCases, id: \.self) { item in
                    FJFilterChip(LocalizedStringKey(item.localizedName), isSelected: filter.equipment.contains(item)) {
                        toggle(item, in: &filter.equipment)
                    }
                }
            }
        }
        .padding(.vertical, FJSpacing.s)
        .background(FJColor.background)
    }

    private func chipRow<Content: View>(label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: FJSpacing.s) {
                HStack(spacing: FJSpacing.s) { content() }
                    .padding(.horizontal, FJSpacing.screenMargin)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - Biblioteca

/// Biblioteca de exercícios (embutidos + do usuário). Empurre dentro de uma `NavigationStack`
/// (ex.: atalho "Biblioteca" da aba Treinos).
struct ExerciseLibraryView: View {
    @State private var selection: [PersistentIdentifier] = []

    var body: some View {
        ExerciseBrowser(mode: .browse, selection: $selection)
            .navigationTitle("Exercícios")
            .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Seletor (API pública para outros pacotes)

/// Sheet de seleção de exercícios (mesma busca e filtros da biblioteca).
/// Com `allowsMultiple`, mostra o contador e "Adicionar (n)"; sem, o toque numa linha escolhe e fecha.
/// `onPick` é chamado uma vez, na ordem em que o usuário marcou, e a sheet se fecha sozinha.
struct ExercisePicker: View {
    let allowsMultiple: Bool
    let onPick: ([Exercise]) -> Void

    init(allowsMultiple: Bool = true, onPick: @escaping ([Exercise]) -> Void) {
        self.allowsMultiple = allowsMultiple
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selection: [PersistentIdentifier] = []
    @State private var didFinish = false

    var body: some View {
        NavigationStack {
            ExerciseBrowser(mode: .pick(allowsMultiple: allowsMultiple), selection: $selection) { exercise in
                finish([exercise])
            }
            .navigationTitle(allowsMultiple ? "Adicionar exercícios" : "Escolher exercício")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if allowsMultiple {
                    Button("Adicionar (\(selection.count))") { finish(chosen()) }
                        .buttonStyle(.fjPrimary(.training))
                        .disabled(selection.isEmpty)
                        .padding(.horizontal, FJSpacing.screenMargin)
                        .padding(.vertical, FJSpacing.s)
                        .accessibilityHint(selection.isEmpty ? "Marque ao menos um exercício" : "")
                }
            }
        }
        .tint(FJColor.training)
    }

    private func chosen() -> [Exercise] {
        selection.compactMap { context.model(for: $0) as? Exercise }
    }

    private func finish(_ exercises: [Exercise]) {
        guard !exercises.isEmpty, !didFinish else { return }
        didFinish = true
        onPick(exercises)
        dismiss()
    }
}

#Preview("Biblioteca") {
    NavigationStack { ExerciseLibraryView() }
        .modelContainer(PersistenceController.preview)
        .tint(FJColor.training)
}

#Preview("Seletor") {
    Color.clear.sheet(isPresented: .constant(true)) {
        ExercisePicker { _ in }
    }
    .modelContainer(PersistenceController.preview)
}
