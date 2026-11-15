import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Folha "Registrar com IA" (proposta `ai-meal-log.md`): Compor → Analisar → Revisar → fecha e a Dieta mostra o aviso
/// com Desfazer. Uma folha só, guiada por `session.phase`. Nada é gravado antes de "Registrar".
///
/// O dono da sessão é a Dieta (`NutritionDayView`): "Continuar depois" mantém a sessão; "Descartar" a larga.
struct MealLogSheet: View {
    @Bindable var session: MealLogSession
    /// Abre a câmera ao aparecer (botão de câmera da barra, "Preencher com foto").
    var startWithCamera = false
    /// Muda o dia do registro (a Dieta cria outra sessão com o mesmo texto).
    let onChangeDay: (Date) -> Void
    /// Registrado: a Dieta guarda o Desfazer e larga a sessão.
    let onApplied: (MealLogUndo) -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AIAvailability.self) private var availability: AIAvailability?
    @Environment(ImportCoordinator.self) private var importCoordinator: ImportCoordinator?

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var cameraDenied = false
    @State private var showConsent = false
    @State private var showCloseDialog = false
    @State private var showCorrection = false
    @State private var showAISettings = false
    @State private var preparing = 0
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var plannedNames: [String] = []
    @FocusState private var textFocused: Bool

    private var isOnline: Bool { importCoordinator?.network.isOnline ?? true }
    private var providerName: String { availability?.providerName ?? "" }
    private var hasContent: Bool {
        !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.photos.isEmpty || session.review != nil
    }
    private var remainingPhotos: Int { max(0, MealLogSession.maxPhotos - session.photos.count - preparing) }

    var body: some View {
        NavigationStack {
            content
                .fjScreenBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !session.isAnalyzing {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancelar", action: close) }
                    }
                    if session.phase.hasDraft {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Corrigir por texto", systemImage: "text.bubble") { showCorrection = true }
                                Button("Descartar rascunho", systemImage: "trash", role: .destructive, action: discardAndClose)
                            } label: {
                                Label("Mais opções", systemImage: "ellipsis")
                            }
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasContent)
        .fullScreenCover(isPresented: $showCamera) {
            MealCameraPicker { captured($0) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: max(1, remainingPhotos),
                      matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .sheet(isPresented: $showConsent) {
            MealLogConsentSheet(providerName: providerName) {
                MealLogPreferences().grantConsent()
                analyze()
            }
        }
        .sheet(isPresented: $showCorrection) {
            MealLogCorrectionSheet { instruction in correct(instruction) }
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { showAISettings = false } } }
            }
        }
        .alert("Câmera sem acesso", isPresented: $cameraDenied) {
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Permita a câmera nos Ajustes para fotografar o prato. A galeria e o texto continuam funcionando.")
        }
        .confirmationDialog("Fechar o registro?", isPresented: $showCloseDialog, titleVisibility: .visible) {
            Button("Continuar depois") { dismiss() }
            Button("Descartar", role: .destructive, action: discardAndClose)
        } message: {
            Text("O texto e o rascunho ficam guardados. As fotos não.")
        }
        .task(id: session.day) { loadPlannedNames() }
        .task {
            guard startWithCamera, MealCamera.isAvailable, availability.canReadImages else { return }
            try? await Task.sleep(for: .milliseconds(450))
            openCamera()
        }
    }

    // MARK: Fases

    private var title: LocalizedStringKey {
        switch session.phase {
        case .analyzing: "Analisando"
        case .ready, .lowConfidence: "Revisar registro"
        default: "Registrar com IA"
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .composing:
            compose
        case .analyzing:
            MealLogAnalyzingView(session: session, providerName: providerName)
        case .ready, .lowConfidence:
            MealLogReviewView(session: session, errorMessage: $errorMessage, onApply: apply)
        case .noFood, .unreadable, .offline, .timedOut, .providerError:
            MealLogStateView(phase: session.phase, onRetry: retryAnalysis, onBack: { session.retry() },
                             onRetake: retake, onDescribe: { session.retry() })
        }
    }

    // MARK: Compor (mockup 02)

    private var compose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FJSpacing.l) {
                dayRow
                textCard
                planChips
                photosSection
                privacyNotice
                banners
            }
            .padding(.horizontal, FJSpacing.screenMargin)
            .padding(.top, FJSpacing.s)
            .padding(.bottom, FJSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            FJAIButton("Analisar", prominence: .prominent, action: analyze)
                .disabled(!session.canAnalyze || !isOnline)
                .padding(.horizontal, FJSpacing.screenMargin)
                .padding(.vertical, FJSpacing.s)
                .background(FJColor.background)
        }
    }

    private var dayRow: some View {
        FJAdaptiveStack(spacing: FJSpacing.s) {
            DatePicker("Dia do registro", selection: Binding(get: { session.day }, set: { onChangeDay($0) }),
                       in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .accessibilityLabel(Text("Dia do registro"))
            Text("Os registros entram neste dia")
                .font(FJFont.caption)
                .foregroundStyle(FJColor.textSecondary)
        }
    }

    private var textCard: some View {
        VStack(alignment: .trailing, spacing: FJSpacing.xs) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.text)
                    .focused($textFocused)
                    .font(FJFont.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .accessibilityLabel(Text("O que você comeu"))
                if session.text.isEmpty {
                    Text(session.photos.isEmpty ? "O que você comeu?" : "Algo que a foto não mostra? (opcional)")
                        .font(FJFont.body)
                        .foregroundStyle(FJColor.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Text("\(session.text.count.formatted()) / \(MealLogSession.maxTextLength.formatted())")
                .font(FJFont.numberCaption)
                .foregroundStyle(FJColor.textSecondary)
        }
        .padding(FJSpacing.m)
        .background(FJColor.surface, in: FJRadius.shape(FJRadius.card))
        .onChange(of: session.text) { _, value in
            if value.count > MealLogSession.maxTextLength { session.text = String(value.prefix(MealLogSession.maxTextLength)) }
        }
    }

    @ViewBuilder private var planChips: some View {
        if !plannedNames.isEmpty {
            VStack(alignment: .leading, spacing: FJSpacing.s) {
                Text("Inserir refeição do plano")
                    .font(FJFont.overline)
                    .foregroundStyle(FJColor.textSecondary)
                FJQuickReplyChips(plannedNames.map { FJQuickReply($0) }) { reply in
                    session.text += (session.text.isEmpty || session.text.hasSuffix("\n") ? "" : "\n") + "\(reply.title): "
                    textFocused = true
                }
            }
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            Text("Fotos (opcional, até \(MealLogSession.maxPhotos))")
                .font(FJFont.overline)
                .foregroundStyle(FJColor.textSecondary)
            if !session.photos.isEmpty || preparing > 0 {
                FJFlowLayout(spacing: FJSpacing.m) {
                    ForEach(Array(session.photos.enumerated()), id: \.element.id) { index, photo in
                        FJAttachmentThumb(name: String(localized: "Foto \(index + 1)"), kind: .image,
                                          preview: UIImage(data: photo.jpegData).map(Image.init(uiImage:)),
                                          onRemove: { session.removePhoto(photo.id) })
                    }
                    ForEach(0 ..< preparing, id: \.self) { index in
                        FJAttachmentThumb(name: String(localized: "Preparando…"), kind: .image, state: .preparing)
                            .id("preparing-\(index)")
                    }
                }
            }
            if availability.canReadImages {
                let columns = dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: FJSpacing.s), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: FJSpacing.s) {
                    if MealCamera.isAvailable {
                        sourceButton("Câmera", systemImage: "camera", action: openCamera)
                    }
                    sourceButton("Galeria", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                }
                .disabled(remainingPhotos == 0)
            } else {
                FJBanner("O modelo \(availability?.model ?? "") não lê fotos",
                         message: "Descreva a refeição por texto ou troque o modelo nos Ajustes de IA.",
                         tone: .attention, systemImage: "eye.slash", actionTitle: "Trocar modelo") { showAISettings = true }
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
    }

    private func sourceButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FJSpacing.s) {
                Image(systemName: systemImage)
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

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: FJSpacing.m) {
            Image(systemName: "lock.fill")
                .foregroundStyle(FJColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                Text("O texto e as fotos vão para \(providerName)")
                    .font(.subheadline.weight(.semibold))
                Text("As fotos saem reduzidas e sem localização. Seu histórico não é enviado.")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FJSpacing.m)
        .background(FJColor.fill, in: FJRadius.shape(FJRadius.card))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var banners: some View {
        if !isOnline {
            FJBanner("Sem internet", message: "O texto fica guardado. Analise quando a conexão voltar ou registre à mão.",
                     systemImage: "wifi.slash")
        }
        if let errorMessage {
            FJBanner("Não foi possível continuar", message: LocalizedStringKey(errorMessage), tone: .attention,
                     actionTitle: "Fechar") { self.errorMessage = nil }
        }
    }

    // MARK: Ações

    private func close() {
        if hasContent { showCloseDialog = true } else { onDiscard(); dismiss() }
    }

    private func discardAndClose() {
        session.discard()
        onDiscard()
        dismiss()
    }

    private func loadPlannedNames() {
        let states = (try? NutritionStore(context: context).plannedMeals(on: session.day)) ?? []
        plannedNames = states.map(\.meal.name).filter { !$0.isEmpty }
    }

    private func analyze() {
        errorMessage = nil
        textFocused = false
        Task {
            do {
                try await session.analyze()
            } catch MealLogError.consentRequired {
                showConsent = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retryAnalysis() {
        session.retry()
        analyze()
    }

    private func correct(_ instruction: String) {
        errorMessage = nil
        Task {
            do { try await session.correct(instruction) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        guard let review = session.review else { return }
        do {
            let undo = try MealLogApplier(context: context).apply(review)
            session.discard()
            onApplied(undo)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Tirar outra": volta à composição sem as fotos e abre a câmera (ou a galeria, sem câmera).
    private func retake() {
        session.retry()
        for photo in session.photos { session.removePhoto(photo.id) }
        if MealCamera.isAvailable { openCamera() } else { showPhotoPicker = true }
    }

    private func openCamera() {
        if MealCamera.isDenied { cameraDenied = true } else { showCamera = true }
    }

    /// Foto tirada pela câmera do app: vai para Fotos (sem erro se faltar permissão) e para a análise.
    private func captured(_ data: Data) {
        notice = nil
        Task {
            let outcome = try? await PhotoLibrarySaver().save(imageData: data)
            if outcome != .saved {
                notice = String(localized: "A foto não foi salva em Fotos (sem permissão). A análise segue normalmente.")
            }
        }
        ingest(count: 1) { [RawAttachment(filename: "foto.jpg", data: data, typeHint: "public.jpeg")] }
    }

    /// Fotos escolhidas na galeria: só vão para a análise (não são salvas de novo).
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        ingest(count: items.count) {
            var raws: [RawAttachment] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    raws.append(RawAttachment(filename: "foto.jpg", data: data, typeHint: item.supportedContentTypes.first?.identifier))
                }
            }
            return raws
        }
    }

    private func ingest(count: Int, load: @escaping () async -> [RawAttachment]) {
        errorMessage = nil
        preparing += count
        Task {
            defer { preparing = max(0, preparing - count) }
            let raws = await load()
            if raws.count < count { errorMessage = String(localized: "Não foi possível ler uma das fotos.") }
            guard !raws.isEmpty else { return }
            do { try await session.addPhotos(raws) } catch { errorMessage = error.localizedDescription }
        }
    }
}

#if DEBUG
#Preview("Registrar com IA — compor") {
    let container = PersistenceController.preview
    let session = MealLogSession(day: .now, context: container.mainContext, resolveChat: { throw MealLogError.aiUnavailable },
                                 isAIAvailable: { true })
    return MealLogSheet(session: session, onChangeDay: { _ in }, onApplied: { _ in }, onDiscard: {})
        .modelContainer(container)
}
#endif
