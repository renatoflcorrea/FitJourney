import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Etapa 1: escolher PDF, fotos, câmera ou texto (até 10), com aviso de privacidade e o botão "Analisar".
struct ImportFilesView: View {
    let session: ImportSession

    @Environment(ImportCoordinator.self) private var coordinator: ImportCoordinator?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var providerInfo: ImportProviderInfo?
    @State private var showFileImporter = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showPaste = false
    @State private var consent = AIConsentPromptState()
    @State private var showSettings = false
    @State private var cameraDenied = false
    @State private var preparing = 0
    @State private var errorMessage: String?

    private var isOnline: Bool { coordinator?.network.isOnline ?? true }
    private var needsSetup: Bool { providerInfo?.readiness == .needsSetup }
    private var providerReady: Bool { providerInfo?.readiness == .ready }
    private var maxFiles: Int { AttachmentPreparer.maxFiles }
    private var count: Int { session.attachments.count }
    private var isFull: Bool { count + preparing >= maxFiles }
    private var canAnalyze: Bool { count > 0 && preparing == 0 && isOnline && providerReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.l) {
                header
                if session.needsReattach {
                    FJBanner("Escolha os arquivos de novo", message: "Esta importação foi retomada, mas os arquivos não ficam guardados no app.",
                             tone: .attention, systemImage: "arrow.counterclockwise")
                }
                ForEach(session.warnings, id: \.self) { warning in
                    FJBanner(LocalizedStringKey(warning), tone: .attention)
                }
                if let errorMessage {
                    FJBanner("Não foi possível adicionar", message: LocalizedStringKey(errorMessage), tone: .destructive,
                             actionTitle: "Fechar") { self.errorMessage = nil }
                }
                sources
                attachmentsSection
                privacy
                if !isOnline {
                    FJBanner("Sem conexão", message: "Os arquivos ficam aqui; analise quando voltar.", tone: .neutral, systemImage: "wifi.slash")
                }
            }
            .padding(FJSpacing.screenMargin)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: true) { result in
            handleFiles(result)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: max(1, maxFiles - count), matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                add([RawAttachment(filename: String(localized: "Foto \(count + 1).jpg"), data: data, typeHint: UTType.jpeg.identifier)])
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPaste) {
            PasteTextSheet { text in
                do { try session.addPastedText(text) } catch { errorMessage = error.localizedDescription }
            }
        }
        .sheet(item: $consent.prompt) { prompt in
            AIConsentSheet(request: prompt.request, recipient: prompt.recipient, defaults: coordinator?.defaults ?? .standard,
                           onAllow: {
                               consent.allow()
                               analyze()
                           }, onDeny: { consent.deny() })
        }
        .navigationDestination(isPresented: $showSettings) {
            AISettingsView(secrets: coordinator?.secrets ?? KeychainSecretStore(), defaults: coordinator?.defaults ?? .standard)
        }
        .alert("Câmera sem acesso", isPresented: $cameraDenied) {
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Agora não", role: .cancel) {}
        } message: {
            Text("Libere a câmera em Ajustes para fotografar a ficha. As outras fontes continuam disponíveis.")
        }
        .onAppear { providerInfo = coordinator?.providerInfo() ?? ImportProviderInfo() }
    }

    static let fileTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .plainText]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }()

    // MARK: Partes

    private var header: some View {
        VStack(spacing: FJSpacing.s) {
            FJAIBadge(style: .hero)
            Text(session.kind == .program ? "Traga a ficha como ela está" : "Traga a dieta como ela está")
                .font(FJFont.sectionTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("PDF, foto ou texto. Eu leio, pergunto o que faltar e monto.")
                .font(FJFont.label)
                .foregroundStyle(FJColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var sources: some View {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: FJSpacing.s), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: FJSpacing.xs) {
            LazyVGrid(columns: columns, spacing: FJSpacing.s) {
                sourceButton("PDF ou arquivo", systemImage: "doc") { showFileImporter = true }
                    .accessibilityIdentifier("import.source.files")
                sourceButton("Fotos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    .accessibilityIdentifier("import.source.photos")
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    sourceButton("Câmera", systemImage: "camera", action: openCamera)
                        .accessibilityIdentifier("import.source.camera")
                }
                sourceButton("Colar texto", systemImage: "doc.on.clipboard") { showPaste = true }
                    .accessibilityIdentifier("import.source.paste")
            }
            .disabled(isFull)
            if count == 0, preparing == 0 {
                // Demonstração para quem não tem um arquivo à mão (App Review 2.1(a)).
                FJSecondaryButton("Experimentar com um exemplo", systemImage: "doc.text.image") { addSample() }
                    .accessibilityIdentifier("import.sample")
                    .padding(.top, FJSpacing.xs)
            }
            if isFull {
                Text("Limite de \(maxFiles) arquivos")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    private func sourceButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: FJSpacing.s) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(FJColor.coach)
                    .accessibilityHidden(true)
                Text(title)
                    .font(FJFont.label.weight(.semibold))
                    .foregroundStyle(FJColor.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: FJSize.primaryButton)
            .fjCard(padding: FJSpacing.m)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        if count > 0 || preparing > 0 {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                Text("\(count) de \(maxFiles) arquivos")
                    .font(FJFont.numberCaption)
                    .foregroundStyle(FJColor.textSecondary)
                FJFlowLayout(spacing: FJSpacing.m) {
                    ForEach(Array(session.attachments.enumerated()), id: \.element.id) { index, attachment in
                        FJAttachmentThumb(
                            name: attachment.filename, kind: Self.thumbKind(attachment.kind), detail: Self.detail(attachment),
                            pageCount: attachment.pageCount, onRemove: { session.remove(attachment.id) })
                            .accessibilityIdentifier("import.attachment.\(index)")
                    }
                    ForEach(0..<preparing, id: \.self) { index in
                        FJAttachmentThumb(name: String(localized: "Preparando…"), kind: .image, state: .preparing)
                            .id("preparing-\(index)")
                    }
                    if !isFull {
                        FJAttachmentAddTile { showFileImporter = true }
                    }
                }
                if hasSample {
                    Text("Ficha fictícia, criada para demonstração.")
                        .font(FJFont.caption)
                        .foregroundStyle(FJColor.textSecondary)
                    if session.kind == .program, count == 1, !isFull {
                        Button("Adicionar as outras 3 fichas do exemplo") {
                            add(ImportSamples.otherWorkouts.compactMap { ImportSamples.workout($0) })
                        }
                        .font(FJFont.label.weight(.semibold))
                        .foregroundStyle(FJColor.coach)
                        .frame(minHeight: FJSize.minTap, alignment: .leading)
                        .accessibilityIdentifier("import.sample.addMore")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var privacy: some View {
        if consent.denied {
            // Não permitir: nada foi enviado, os arquivos continuam aqui e "Analisar" pergunta de novo.
            let notice = AIConsentPresentation.importDenied(kind: session.kind)
            FJBanner(CoachMarkdown.literal(notice.title), message: CoachMarkdown.literal(notice.message),
                     tone: .neutral, systemImage: "hand.raised.fill")
                .accessibilityIdentifier("import.denied")
        } else if let recipient = providerInfo?.recipient, providerReady {
            let notice = AIConsentPresentation.importNotice(recipient)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                FJBanner(CoachMarkdown.literal(notice.title), message: CoachMarkdown.literal(notice.message),
                         tone: .neutral, systemImage: "lock.fill")
                Text("Localização e dados da câmera são removidos das fotos antes do envio.")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
                    .padding(.horizontal, FJSpacing.l)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.privacyNote")
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: FJSpacing.s) {
            if needsSetup {
                FJBanner("Falta configurar a IA", message: "Escolha o provedor e informe a chave. Os arquivos escolhidos ficam aqui.",
                         tone: .attention, actionTitle: "Configurar") { showSettings = true }
                    .accessibilityIdentifier("import.setup")
            } else {
                FJAIButton(count == 0 ? "Escolha um arquivo" : (count == 1 ? "Analisar 1 arquivo" : "Analisar \(count) arquivos")) {
                    analyze()
                }
                .disabled(!canAnalyze)
                .accessibilityIdentifier("import.analyze")
            }
        }
        .padding(.horizontal, FJSpacing.screenMargin)
        .padding(.vertical, FJSpacing.s)
        .background(FJColor.background)
    }

    // MARK: Ações

    private func analyze() {
        errorMessage = nil
        Task {
            do {
                try await session.analyze()
            } catch let ImportError.consentRequired(recipient) {
                consent.ask(.importFiles(kind: session.kind, fileCount: count), recipient: recipient)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var hasSample: Bool { session.attachments.contains { ImportSamples.sampleFilenames.contains($0.filename) } }

    private func addSample() {
        let sample = session.kind == .program ? ImportSamples.workout(ImportSamples.mainWorkout) : ImportSamples.mealPlanAttachment()
        guard let sample else { return }
        add([sample])
    }

    private func add(_ raws: [RawAttachment], priorError: String? = nil) {
        preparing += raws.count
        errorMessage = priorError
        Task {
            defer { preparing = max(0, preparing - raws.count) }
            do { try await session.add(raws) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func handleFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case let .failure(error):
            errorMessage = error.localizedDescription
        case let .success(urls):
            let room = max(0, maxFiles - count - preparing)
            var problems: [String] = []
            var accepted = urls
            if urls.count > room {
                problems.append(AttachmentError.tooManyFiles(max: maxFiles).localizedDescription)
                accepted = Array(urls.prefix(room))
            }
            guard !accepted.isEmpty else { errorMessage = problems.first; return }
            let urlsToRead = accepted
            preparing += urlsToRead.count
            errorMessage = nil
            Task {
                defer { preparing = max(0, preparing - urlsToRead.count) }
                // Lê fora da main; confere o tamanho antes de ler.
                let outcome = await Task.detached(priority: .userInitiated) { Self.read(urlsToRead) }.value
                problems.append(contentsOf: outcome.problems)
                if !outcome.raws.isEmpty {
                    do { try await session.add(outcome.raws) } catch { problems.append(error.localizedDescription) }
                }
                errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
            }
        }
    }

    nonisolated private static func read(_ urls: [URL]) -> (raws: [RawAttachment], problems: [String]) {
        var raws: [RawAttachment] = []
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > AttachmentPreparer.maxFileBytes {
                problems.append(AttachmentError.fileTooLarge(filename: name, maxMegabytes: AttachmentPreparer.maxFileBytes / 1_048_576).localizedDescription)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                problems.append(AttachmentError.unreadable(filename: name).localizedDescription)
                continue
            }
            raws.append(RawAttachment(filename: name, data: data, typeHint: UTType(filenameExtension: url.pathExtension)?.identifier))
        }
        return (raws, problems)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let base = count + preparing
        preparing += items.count
        photoItems = []
        errorMessage = nil
        Task {
            defer { preparing = max(0, preparing - items.count) }
            var raws: [RawAttachment] = []
            for (index, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    raws.append(RawAttachment(filename: String(localized: "Foto \(base + index + 1).jpg"), data: data,
                                              typeHint: item.supportedContentTypes.first?.identifier))
                } else {
                    errorMessage = String(localized: "Não foi possível ler uma das fotos.")
                }
            }
            guard !raws.isEmpty else { return }
            do { try await session.add(raws) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            cameraDenied = true
        default:
            showCamera = true
        }
    }

    // MARK: Apresentação

    static func thumbKind(_ kind: AttachmentKind) -> FJAttachmentKind {
        switch kind {
        case .pdf: .pdf
        case .image: .image
        case .text: .text
        }
    }

    static func detail(_ attachment: AttachmentMetadata) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
    }
}

// MARK: - Colar texto

private struct PasteTextSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                TextEditor(text: $text)
                    .focused($focused)
                    .padding(FJSpacing.s)
                    .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
                    .accessibilityLabel(Text("Texto da ficha"))
                HStack {
                    Button("Colar", systemImage: "doc.on.clipboard") {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                    }
                    Spacer()
                    Text("\(text.count) caracteres")
                        .font(FJFont.numberCaption)
                        .foregroundStyle(FJColor.textSecondary)
                }
            }
            .padding(FJSpacing.screenMargin)
            .fjScreenBackground()
            .navigationTitle("Colar texto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adicionar") {
                        onAdd(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Câmera

/// Câmera do sistema (uma foto por vez). A permissão é pedida pelo sistema ao abrir, só quando o usuário toca em "Câmera".
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
