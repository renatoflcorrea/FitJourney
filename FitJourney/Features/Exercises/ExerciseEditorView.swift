import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Editor de exercício (criar ou editar), apresentado em sheet.
///
/// Decisão para exercício embutido (catálogo): nome e classificação (grupos, equipamento, lateralidade,
/// tipo de medida) ficam somente leitura, porque o catálogo é versionado e outras telas dependem da
/// identidade (`catalogKey`). Mídia, observações e descanso padrão são editáveis no próprio registro.
/// Quem quer mudar a classificação usa "Duplicar para editar" (no detalhe), que cria um exercício do usuário.
struct ExerciseEditorView: View {
    private let exercise: Exercise?
    private let initialName: String
    private let onSave: ((Exercise) -> Void)?

    init(exercise: Exercise? = nil, initialName: String = "", onSave: ((Exercise) -> Void)? = nil) {
        self.exercise = exercise
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: exercise?.name ?? initialName)
        _primary = State(initialValue: exercise?.primaryMuscles ?? [])
        _secondary = State(initialValue: exercise?.secondaryMuscles ?? [])
        _equipment = State(initialValue: exercise?.equipment ?? .other)
        _laterality = State(initialValue: exercise?.laterality ?? .bilateral)
        _kind = State(initialValue: exercise?.measurementKind ?? .repsAndLoad)
        _notes = State(initialValue: exercise?.notes ?? "")
        _rest = State(initialValue: Double(exercise?.defaultRestSeconds ?? 90))
        _items = State(initialValue: (exercise?.media ?? []).map(MediaItem.init))
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var name: String
    @State private var primary: [MuscleGroup]
    @State private var secondary: [MuscleGroup]
    @State private var equipment: Equipment
    @State private var laterality: Laterality
    @State private var kind: MeasurementKind
    @State private var notes: String
    @State private var rest: Double
    /// Mídias com identidade estável (reordenar/remover não reaproveita a linha errada).
    @State private var items: [MediaItem]

    /// Mídias criadas nesta edição (apagadas do disco se o usuário cancelar).
    @State private var added: [MediaRef] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var importing: LocalizedStringKey?
    @State private var errorMessage: String?
    @State private var showCamera = false
    @State private var cameraDenied = false
    @State private var linkText = ""
    @State private var showLinkField = false
    @State private var confirmDiscard = false
    @State private var saveError: String?

    private var media: [MediaRef] { items.map(\.ref) }
    private var isBuiltIn: Bool { exercise?.isBuiltIn ?? false }
    private var isNew: Bool { exercise == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && importing == nil }

    private var hasChanges: Bool {
        guard let exercise else {
            return !trimmedName.isEmpty && trimmedName != initialName || !media.isEmpty || !notes.isEmpty || !primary.isEmpty
        }
        return name != exercise.name || primary != exercise.primaryMuscles || secondary != exercise.secondaryMuscles
            || equipment != exercise.equipment || laterality != exercise.laterality || kind != exercise.measurementKind
            || notes != exercise.notes || Int(rest) != exercise.defaultRestSeconds || media != exercise.media
    }

    var body: some View {
        NavigationStack {
            Form {
                if isBuiltIn { builtInNotice }
                identitySection
                if !isBuiltIn { classificationSections }
                restSection
                notesSection
                mediaSection
            }
            .scrollContentBackground(.hidden)
            .fjScreenBackground()
            .navigationTitle(isNew ? "Novo exercício" : "Editar exercício")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { hasChanges || !added.isEmpty ? (confirmDiscard = true) : cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: save).disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(hasChanges || importing != nil)
            .onDisappear { importTask?.cancel() }
            .confirmationDialog("Descartar alterações?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar", role: .destructive, action: cancel)
                Button("Continuar editando", role: .cancel) {}
            }
            .alert("Não foi possível adicionar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("Não foi possível salvar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in
                    showCamera = false
                    if let data { importImage(data) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                startImport("Salvando foto…") {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw MediaStoreError.unreadableImage }
                    try Task.checkCancellation()
                    return .image(fileName: try await MediaStore.shared.saveImage(data: data))
                }
            }
            .onChange(of: videoItem) { _, item in
                guard let item else { return }
                videoItem = nil
                startImport("Copiando vídeo…") {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw MediaStoreError.unreadableVideo }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    try Task.checkCancellation()
                    return try await MediaStore.shared.saveVideo(from: movie.url).mediaRef
                }
            }
        }
        .tint(FJColor.training)
    }

    // MARK: Seções

    private var builtInNotice: some View {
        Section {
            FJBanner("Exercício do catálogo",
                     message: "Nome e classificação não podem ser editados. Mídia, observações e descanso sim. Para mudar a classificação, use Duplicar para editar.",
                     tone: .neutral, systemImage: "books.vertical")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var identitySection: some View {
        Section("Nome") {
            if isBuiltIn {
                Text(name)
            } else {
                TextField("Ex.: Supino reto com barra", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
            }
        }
    }

    @ViewBuilder
    private var classificationSections: some View {
        Section {
            MuscleChips(selection: $primary, excluded: secondary) { group in
                secondary.removeAll { $0 == group }
            }
        } header: { Text("Grupos primários") }

        Section {
            MuscleChips(selection: $secondary, excluded: primary) { group in
                primary.removeAll { $0 == group }
            }
        } header: { Text("Grupos secundários") }

        Section("Equipamento") {
            Picker("Equipamento", selection: $equipment) {
                ForEach(Equipment.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            Picker("Lateralidade", selection: $laterality) {
                ForEach(Laterality.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }

        Section {
            Picker("Tipo de medida", selection: $kind) {
                ForEach(MeasurementKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } footer: {
            Text(kind.example)
        }
    }

    private var restSection: some View {
        Section("Descanso") {
            NumberStepperField("Descanso padrão", value: $rest, unit: "s", step: 15, range: 0...600)
        }
    }

    private var notesSection: some View {
        Section("Observações") {
            TextField("Dicas de execução, regulagem da máquina…", text: $notes, axis: .vertical)
                .lineLimit(3...8)
        }
    }

    // MARK: Mídia

    private var mediaSection: some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                MediaEditorRow(media: item.ref, index: index, count: items.count,
                               move: { move(index, by: $0) }, remove: { remove(at: index) })
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Foto da galeria", systemImage: "photo")
            }
            .disabled(importing != nil)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { openCamera() } label: { Label("Tirar foto", systemImage: "camera") }
                    .disabled(importing != nil)
            }
            PhotosPicker(selection: $videoItem, matching: .videos) {
                Label("Vídeo da galeria", systemImage: "video")
            }
            .disabled(importing != nil)
            Button { withAnimation(FJMotion.value) { showLinkField.toggle() } } label: {
                Label("Link de vídeo (YouTube, Vimeo)", systemImage: "link")
            }
            if showLinkField { linkField }

            if cameraDenied {
                FJBanner("Câmera sem permissão",
                         message: "Ative a câmera em Ajustes para tirar fotos. Fotos da galeria e links continuam funcionando.",
                         tone: .attention, actionTitle: "Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if let importing {
                HStack(spacing: FJSpacing.m) {
                    ProgressView()
                    Text(importing)
                    Spacer()
                    Button("Cancelar") { importTask?.cancel() }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Mídia")
        } footer: {
            Text("Vídeos da galeria: até 60 s e 200 MB.")
        }
        .disabled(importing != nil && false)
    }

    @ViewBuilder
    private var linkField: some View {
        let parsed = VideoLinkParser.parse(linkText)
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            TextField("Cole o link do vídeo", text: $linkText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let parsed {
                HStack(spacing: FJSpacing.m) {
                    MediaThumbnailView(media: .externalVideo(url: parsed.url, provider: parsed.provider, videoID: parsed.videoID),
                                       maxPixel: 200, showsPlayBadge: false, allowsRemoteThumbnail: true)
                        .frame(width: 80, height: 45)
                        .clipShape(FJRadius.shape(FJRadius.chip))
                    VStack(alignment: .leading) {
                        Text(providerTitle(parsed.provider)).font(FJFont.label.weight(.semibold))
                        Text(parsed.provider == .other ? "Abre no Safari" : "Toca dentro do app")
                            .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if !linkText.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("Link inválido", systemImage: "exclamationmark.triangle.fill")
                    .font(FJFont.caption).foregroundStyle(FJColor.destructive)
            }
            Button("Adicionar link") {
                if let parsed {
                    append(.externalVideo(url: parsed.url, provider: parsed.provider, videoID: parsed.videoID))
                    linkText = ""
                    showLinkField = false
                }
            }
            .disabled(parsed == nil)
        }
    }

    private func providerTitle(_ provider: VideoProvider) -> String {
        switch provider {
        case .youtube: "YouTube"
        case .vimeo: "Vimeo"
        case .other: String(localized: "Outro site")
        }
    }

    // MARK: Ações de mídia

    private func append(_ item: MediaRef) {
        guard !media.contains(item) else { return }
        withAnimation(FJMotion.structure) {
            items.append(MediaItem(item))
            added.append(item)
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        withAnimation(FJMotion.structure) { items.swapAt(index, target) }
    }

    private func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items.remove(at: index).ref
        // Criada nesta edição: o arquivo some já. Antiga: só sai do disco ao salvar.
        if let addedIndex = added.firstIndex(of: item) {
            added.remove(at: addedIndex)
            MediaStore.shared.delete(item)
        }
    }

    private func openCamera() {
        guard importing == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: cameraDenied = true
        default: cameraDenied = false; showCamera = true
        }
    }

    private func importImage(_ data: Data) {
        startImport("Salvando foto…") { .image(fileName: try await MediaStore.shared.saveImage(data: data)) }
    }

    /// Uma importação por vez. Se for cancelada (ou a tela sumir) depois de gravar, o arquivo é apagado.
    private func startImport(_ label: LocalizedStringKey, _ work: @escaping @Sendable () async throws -> MediaRef) {
        guard importing == nil else { return }
        importing = label
        importTask = Task {
            defer { importing = nil; importTask = nil }
            do {
                let result = try await work()
                guard !Task.isCancelled else { MediaStore.shared.delete(result); return }
                append(result)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Salvar / cancelar

    private func cancel() {
        importTask?.cancel()
        MediaStore.shared.delete(added)
        dismiss()
    }

    private func save() {
        let target = exercise ?? Exercise(name: trimmedName)
        let original = exercise?.media ?? []
        if !isBuiltIn {
            target.name = trimmedName
            target.primaryMuscles = primary
            target.secondaryMuscles = secondary
            target.equipment = equipment
            target.laterality = laterality
            target.measurementKind = kind
        }
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.defaultRestSeconds = Int(rest)
        target.media = media
        target.updatedAt = .now
        if exercise == nil { context.insert(target) }
        do {
            try context.save()
        } catch {
            if exercise == nil { context.delete(target) }
            saveError = error.localizedDescription
            return
        }
        MediaStore.shared.deleteUnreferenced(original.filter { !media.contains($0) }, in: context)
        onSave?(target)
        dismiss()
    }
}

// MARK: - Subviews

private struct MediaItem: Identifiable {
    let id = UUID()
    let ref: MediaRef
    init(_ ref: MediaRef) { self.ref = ref }
}

private struct MuscleChips: View {
    @Binding var selection: [MuscleGroup]
    let excluded: [MuscleGroup]
    let didSelect: (MuscleGroup) -> Void

    var body: some View {
        GlassEffectContainer(spacing: FJSpacing.s) {
            FlowLayout(spacing: FJSpacing.s) {
                ForEach(MuscleGroup.allCases, id: \.self) { group in
                    let isOn = selection.contains(group)
                    FJFilterChip(LocalizedStringKey(group.localizedName), isSelected: isOn) {
                        if isOn {
                            selection.removeAll { $0 == group }
                        } else {
                            selection.append(group)
                            didSelect(group)
                        }
                    }
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: FJSpacing.s, leading: 0, bottom: FJSpacing.s, trailing: 0))
    }
}

private struct MediaEditorRow: View {
    let media: MediaRef
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: FJSpacing.m) {
            MediaThumbnailView(media: media, maxPixel: 200)
                .frame(width: 80, height: 45)
                .clipShape(FJRadius.shape(FJRadius.chip))
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(media.accessibilityLabel()).font(FJFont.body)
                if let name = media.providerName {
                    Text(name).font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if index > 0 { Button("Mover para cima", systemImage: "arrow.up") { move(-1) } }
                if index < count - 1 { Button("Mover para baixo", systemImage: "arrow.down") { move(1) } }
                Button("Remover", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: FJSize.minTap, minHeight: FJSize.minTap)
            }
            .accessibilityLabel("Ações da mídia")
        }
        .accessibilityElement(children: .contain)
        .swipeActions(edge: .trailing) {
            Button("Remover", systemImage: "trash", role: .destructive, action: remove)
        }
    }
}

/// Vídeo escolhido na galeria: o arquivo é copiado para um temporário que o `MediaStore` consome e apaga.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let directory = MediaMaintenance.pickedMoviesDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: "\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Câmera do sistema (foto). Devolve JPEG ou `nil` se cancelado.
private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}

#Preview("Novo") {
    ExerciseEditorView()
        .modelContainer(PersistenceController.preview)
}

#Preview("Embutido") {
    let container = PersistenceController.preview
    let exercise = (try? container.mainContext.fetch(FetchDescriptor<Exercise>()))?.first
    return ExerciseEditorView(exercise: exercise).modelContainer(container)
}
