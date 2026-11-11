import SwiftData
import SwiftUI

/// Mídia aberta em tela cheia (wrapper local; `MediaRef` não é `Identifiable` globalmente).
private struct MediaSelection: Identifiable {
    let media: MediaRef
    var id: MediaRef { media }
}

/// Detalhe do exercício: mídia, classificação, observações e descanso padrão.
/// Empurre dentro de uma `NavigationStack`.
struct ExerciseDetailView: View {
    let exercise: Exercise

    @Environment(\.modelContext) private var context
    @State private var viewing: MediaSelection?
    @State private var duplicating = false
    @State private var editing = false
    @State private var duplicated: Exercise?
    @State private var duplicateError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.sectionGap) {
                mediaSection
                infoCard
                if !exercise.notes.isEmpty {
                    VStack(alignment: .leading, spacing: FJSpacing.s) {
                        FJSectionHeader("Observações")
                        FJCard { Text(exercise.notes).font(FJFont.body) }
                    }
                }
                // TODO(P2.4): resumo de evolução (melhor série, última vez, minigráfico) e "Ver evolução".
                // TODO(P2.4): "Usado em" — fichas que contêm o exercício.
            }
            .padding(FJSpacing.screenMargin)
        }
        .fjScreenBackground()
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Mais", systemImage: "ellipsis.circle") {
                    Button("Editar", systemImage: "pencil") { editing = true }
                    if exercise.isBuiltIn {
                        Button("Duplicar para editar", systemImage: "plus.square.on.square") { duplicate() }
                            .disabled(duplicating)
                    }
                }
            }
        }
        .fullScreenCover(item: $viewing) { ExerciseMediaViewer(media: $0.media) }
        .sheet(isPresented: $editing) { ExerciseEditorView(exercise: exercise) }
        .sheet(item: $duplicated) { ExerciseEditorView(exercise: $0) }
        .alert("Não foi possível duplicar", isPresented: Binding(get: { duplicateError != nil }, set: { if !$0 { duplicateError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(duplicateError ?? "") }
    }

    // MARK: Mídia

    @ViewBuilder
    private var mediaSection: some View {
        let media = exercise.media
        if media.isEmpty {
            Button { editing = true } label: {
                VStack(spacing: FJSpacing.s) {
                    Image(systemName: "photo.badge.plus").font(.title)
                    Text("Adicionar foto ou vídeo").font(FJFont.label)
                }
                .foregroundStyle(FJColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 140)
                .overlay {
                    FJRadius.shape(FJRadius.card)
                        .strokeBorder(FJColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adicionar foto ou vídeo")
        } else {
            TabView {
                ForEach(Array(media.enumerated()), id: \.element) { index, item in
                    Button { viewing = MediaSelection(media: item) } label: {
                        MediaThumbnailView(media: item, maxPixel: 1200, allowsRemoteThumbnail: true)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(FJRadius.shape(FJRadius.card))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.accessibilityLabel(index: index, of: media.count))
                    .accessibilityHint(item.isVideo ? "Toque duas vezes para reproduzir" : "Toque duas vezes para ver em tela cheia")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))
            .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    // MARK: Informações

    private var infoCard: some View {
        FJCard {
            VStack(alignment: .leading, spacing: FJSpacing.m) {
                if !exercise.primaryMuscles.isEmpty || !exercise.secondaryMuscles.isEmpty {
                    VStack(alignment: .leading, spacing: FJSpacing.xs) {
                        Text("Grupos musculares").font(FJFont.overline).foregroundStyle(FJColor.textSecondary)
                        FlowTags(primary: exercise.primaryMuscles, secondary: exercise.secondaryMuscles)
                    }
                    .accessibilityElement(children: .combine)
                }
                infoRow("Equipamento", exercise.equipment.localizedName)
                infoRow("Tipo de medida", exercise.measurementKind.displayName)
                infoRow("Lateralidade", exercise.laterality.displayName)
                infoRow("Descanso padrão", FJFormat.clock(exercise.defaultRestSeconds), spoken: FJFormat.spokenDuration(exercise.defaultRestSeconds))
                if exercise.isBuiltIn {
                    FJTag("Catálogo", systemImage: "books.vertical", tone: .neutral)
                }
            }
        }
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String, spoken: String? = nil) -> some View {
        FJAdaptiveStack(verticalAlignment: .firstTextBaseline) {
            Text(title).font(FJFont.label).foregroundStyle(FJColor.textSecondary)
            Spacer(minLength: FJSpacing.s)
            Text(value).font(FJFont.body).foregroundStyle(FJColor.textPrimary)
                .accessibilityLabel(spoken ?? value)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Duplicar

    private func duplicate() {
        guard !duplicating else { return }
        duplicating = true
        let copy = Exercise(name: exercise.name + " " + String(localized: "(cópia)"),
                            primaryMuscles: exercise.primaryMuscles, secondaryMuscles: exercise.secondaryMuscles,
                            equipment: exercise.equipment, laterality: exercise.laterality,
                            measurementKind: exercise.measurementKind, defaultRestSeconds: exercise.defaultRestSeconds)
        copy.notes = exercise.notes
        let source = exercise.media
        Task {
            defer { duplicating = false }
            var copied: [MediaRef] = []
            do {
                // `duplicate` apaga o que já copiou se falhar no meio.
                copied = try await MediaStore.shared.duplicate(source)
                copy.media = copied
                context.insert(copy)
                try context.save()
                duplicated = copy
            } catch {
                if copy.modelContext != nil { context.delete(copy); context.rollback() }
                MediaStore.shared.delete(copied)
                duplicateError = error.localizedDescription
            }
        }
    }
}

/// Etiquetas dos grupos (primários em destaque, secundários neutros), quebrando linha.
private struct FlowTags: View {
    let primary: [MuscleGroup]
    let secondary: [MuscleGroup]

    var body: some View {
        FJFlowLayout(spacing: FJSpacing.xs) {
            ForEach(primary, id: \.self) { FJTag(LocalizedStringKey($0.localizedName), area: .training) }
            ForEach(secondary, id: \.self) { FJTag(LocalizedStringKey($0.localizedName), tone: .neutral) }
        }
    }
}

#Preview("Detalhe") {
    let container = PersistenceController.preview
    let exercise = (try? container.mainContext.fetch(FetchDescriptor<Exercise>()))?.first
    return NavigationStack {
        if let exercise { ExerciseDetailView(exercise: exercise) }
    }
    .modelContainer(container)
    .tint(FJColor.training)
}
