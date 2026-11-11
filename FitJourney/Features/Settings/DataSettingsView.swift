import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Ajustes › Dados (§4.12): exportar, importar, espaço da mídia e apagar tudo.
struct DataSettingsView: View {
    /// Fecha o sheet de Ajustes (usado por "Ver treino").
    var onClose: () -> Void = {}

    @Environment(\.modelContext) private var context
    /// O App injeta um modelo de nível superior (sobrevive ao reset da árvore). Sem ele (previews), cria um local.
    @Environment(DataTransferModel.self) private var shared: DataTransferModel?
    @State private var local: DataTransferModel?

    var body: some View {
        Group {
            if let model = shared ?? local {
                DataSettingsContent(model: model, onClose: onClose)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if shared == nil, local == nil { local = DataTransferModel(container: context.container) }
        }
    }
}

struct DataSettingsContent: View {
    @Bindable var model: DataTransferModel
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(SessionCoordinator.self) private var coordinator: SessionCoordinator?

    @State private var format: BackupExportOptions.Format = .package
    @State private var includeConversations = false
    @State private var showsImporter = false
    @State private var mediaBytes: Int64?
    @State private var hasData = true

    private var sessionInProgress: Bool { coordinator?.engine.snapshot != nil }
    private var busy: Bool { model.activity.isBusy }

    var body: some View {
        Form {
            if let report = model.report { reportSection(report) }
            if sessionInProgress { sessionBlockSection }
            exportSection
            importSection
            storageSection
            Section {
                NavigationLink {
                    EraseAllView(model: model, sessionInProgress: sessionInProgress)
                } label: {
                    Label("Apagar todos os dados", systemImage: "trash")
                        .foregroundStyle(FJColor.destructive)
                }
                .disabled(busy)
            }
        }
        .navigationTitle("Dados")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadStats() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.importTypes) { model.inspect($0) }
        .sheet(item: $model.exported, onDismiss: { model.cleanupExport() }) { file in
            ShareSheet(items: [file.url]) { model.cleanupExport() }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $model.pendingImport, onDismiss: {
            // Confirmar já deixou a importação em curso (ela libera o arquivo ao terminar).
            if !model.activity.isBusy { model.releaseScope() }
        }) { pending in
            ImportSummarySheet(pending: pending, sessionInProgress: sessionInProgress,
                               onCancel: { model.cancelPendingImport() },
                               onConfirm: { mode, includeCoach in
                                   var confirmed = pending
                                   confirmed.mode = mode
                                   model.performImport(confirmed, includeCoachConversations: includeCoach)
                               })
                .presentationDetents([.medium, .large])
        }
        .alert("Não foi possível concluir", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: (model.errorMessage ?? "") + "\n" + String(localized: "Nada foi alterado."))
        }
        .task {
            #if DEBUG
            // QA/evidências: `-fj.debugImportPreview YES` abre o resumo de importação com dados de exemplo.
            if UserDefaults.standard.bool(forKey: "fj.debugImportPreview") {
                model.pendingImport = PendingImport(
                    url: URL.temporaryDirectory, exportedAt: .now, schemaVersion: 1,
                    counts: BackupCounts([.programs: 3, .sessions: 142, .nutritionPlans: 2, .foodEntries: 1204]),
                    includesCoachConversations: true, includesMedia: true)
            }
            #endif
        }
        .onChange(of: model.activity) { _, new in
            if new == .idle { Task { await loadStats() } }
        }
    }

    /// `.fitjourney` (zip) e `data.json`; `.data` cobre extensões sem tipo registrado.
    static var importTypes: [UTType] {
        [UTType(filenameExtension: BackupV1.packageExtension), .json, .zip, .data].compactMap { $0 }
    }

    // MARK: Seções

    private var sessionBlockSection: some View {
        Section {
            FJBanner("Há um treino em andamento",
                     message: "Finalize o treino em andamento primeiro. Exportar continua disponível.",
                     tone: .attention, systemImage: "figure.strengthtraining.traditional", actionTitle: "Ver treino") {
                coordinator?.present()
                onClose()
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var exportSection: some View {
        Section {
            Picker("Formato", selection: $format) {
                Text("Pacote com mídia").tag(BackupExportOptions.Format.package)
                Text("Só JSON").tag(BackupExportOptions.Format.json)
            }
            .disabled(busy)
            Toggle("Incluir conversas do Coach", isOn: $includeConversations)
                .disabled(busy)
            if case .exporting(let progress) = model.activity {
                progressRow(progress)
            } else {
                Button {
                    model.export(options: BackupExportOptions(format: format, includeCoachConversations: includeConversations))
                } label: {
                    Label("Exportar tudo", systemImage: "square.and.arrow.up")
                }
                .disabled(busy || !hasData)
            }
        } header: {
            Text("Exportar")
        } footer: {
            VStack(alignment: .leading, spacing: FJSpacing.xs) {
                if !hasData { Text("Ainda não há dados.") }
                Text("Inclui programas, treinos, dieta, registros e ajustes. Chaves de IA nunca entram no arquivo. As conversas do Coach podem ter dados pessoais de saúde. O pacote leva as mídias dos exercícios; o JSON não.")
            }
        }
    }

    private var importSection: some View {
        Section {
            if case .importing(let progress) = model.activity {
                progressRow(progress)
            } else {
                Button {
                    showsImporter = true
                } label: {
                    Label("Importar backup", systemImage: "square.and.arrow.down")
                }
                .disabled(busy)
            }
        } header: {
            Text("Importar")
        } footer: {
            Text("Mostramos um resumo antes de mudar qualquer coisa. Se algo falhar no meio, nada é aplicado.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Mídia dos exercícios") {
                if let mediaBytes {
                    Text(verbatim: SettingsPresentation.byteText(mediaBytes)).foregroundStyle(FJColor.textSecondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Armazenamento")
        }
    }

    private func progressRow(_ progress: BackupProgress) -> some View {
        VStack(alignment: .leading, spacing: FJSpacing.s) {
            HStack {
                Text(verbatim: progress.label).monospacedDigit()
                Spacer()
                Button("Cancelar", role: .cancel) { model.cancel() }
                    .buttonStyle(.borderless)
            }
            ProgressView(value: min(max(progress.fraction, 0), 1))
        }
        .accessibilityElement(children: .combine)
    }

    private func reportSection(_ report: BackupImportReport) -> some View {
        Section {
            FJBanner("Backup importado", message: CoachMarkdown.literal(SettingsPresentation.importSummary(report)),
                     tone: .success, actionTitle: "Fechar") { model.dismissReport() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if report.keptLocal.total > 0 {
                Text("\(report.keptLocal.total) itens do aparelho eram mais recentes e foram mantidos.")
                    .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
            }
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(FJFont.caption)
                    .foregroundStyle(FJColor.textPrimary)
            }
        }
    }

    // MARK: Dados

    private func loadStats() async {
        mediaBytes = await Task.detached { SettingsPresentation.mediaByteCount() }.value
        hasData = Self.hasAnythingToExport(in: context)
    }

    /// Algo além do catálogo embutido: programas, treinos, dietas, registros de comida ou água.
    static func hasAnythingToExport(in context: ModelContext) -> Bool {
        func count<T: PersistentModel>(_: T.Type) -> Int {
            var descriptor = FetchDescriptor<T>()
            descriptor.fetchLimit = 1
            return (try? context.fetchCount(descriptor)) ?? 0
        }
        return count(TrainingProgram.self) + count(WorkoutSession.self) + count(NutritionPlan.self)
            + count(FoodEntry.self) + count(WaterLog.self) + count(ChatConversation.self) > 0
    }
}

/// Resumo do backup antes de importar: contagens, modo e confirmação em dois passos para substituir.
struct ImportSummarySheet: View {
    let pending: PendingImport
    let sessionInProgress: Bool
    let onCancel: () -> Void
    let onConfirm: (BackupImportMode, Bool) -> Void

    @State private var mode: BackupImportMode = .merge
    @State private var includeCoach = true
    @State private var confirmsReplace = false
    @State private var finalReplace = false

    private var replaceBlocked: Bool { mode == .replace && sessionInProgress }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Backup de \(pending.exportedAt.formatted(date: .long, time: .omitted)) · formato v\(pending.schemaVersion)")
                        .font(FJFont.cardTitle)
                    let lines = SettingsPresentation.countsLines(pending.counts)
                    if lines.isEmpty {
                        Text("Este backup está vazio.").foregroundStyle(FJColor.textSecondary)
                    } else {
                        ForEach(lines, id: \.self) { Text(verbatim: $0) }
                    }
                    if !pending.includesMedia {
                        Text("Sem mídia: as fotos e vídeos dos exercícios não estão neste arquivo.")
                            .font(FJFont.caption).foregroundStyle(FJColor.textSecondary)
                    }
                } header: {
                    Text("Resumo")
                }

                Section {
                    Picker("Modo", selection: $mode) {
                        Text("Juntar com o que já existe").tag(BackupImportMode.merge)
                        Text("Substituir tudo").tag(BackupImportMode.replace)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if pending.includesCoachConversations {
                        Toggle("Importar conversas do Coach", isOn: $includeCoach)
                    }
                } header: {
                    Text("Como importar")
                } footer: {
                    if mode == .merge {
                        Text(verbatim: BackupImportReport.mergeSemantics)
                    } else if replaceBlocked {
                        Text("Finalize o treino em andamento primeiro.")
                    } else {
                        Text("Apaga os dados deste aparelho e coloca os do backup no lugar. Não dá para desfazer.")
                    }
                }
            }
            .navigationTitle("Importar backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar") {
                        if mode == .replace { confirmsReplace = true } else { onConfirm(mode, includeCoach) }
                    }
                    .disabled(replaceBlocked)
                }
            }
            .confirmationDialog("Substituir todos os dados deste aparelho?", isPresented: $confirmsReplace,
                                titleVisibility: .visible) {
                Button("Continuar…", role: .destructive) { finalReplace = true }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Programas, treinos, dieta e registros atuais serão apagados e trocados pelos do backup.")
            }
            .alert("Isso não pode ser desfeito.", isPresented: $finalReplace) {
                Button("Substituir definitivamente", role: .destructive) { onConfirm(mode, includeCoach) }
                Button("Cancelar", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(false)
    }
}

/// Tela "Apagar todos os dados": o que some, atalho para exportar antes e confirmação em dois passos.
struct EraseAllView: View {
    @Bindable var model: DataTransferModel
    let sessionInProgress: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var keepCatalog = true
    @State private var eraseKeys = false
    @State private var confirms = false
    @State private var finalConfirm = false

    private static let erased: [LocalizedStringKey] = [
        "Programas e fichas", "Treinos", "Dieta e registros", "Mídia dos exercícios",
        "Conversas do Coach", "Perfil", "Ajustes",
    ]

    var body: some View {
        Form {
            if sessionInProgress {
                Section {
                    FJBanner("Há um treino em andamento",
                             message: "Finalize o treino em andamento primeiro.",
                             tone: .attention, systemImage: "figure.strengthtraining.traditional")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(Self.erased.indices, id: \.self) { index in
                    Label(Self.erased[index], systemImage: "minus.circle")
                        .foregroundStyle(FJColor.textPrimary)
                }
            } header: {
                Text("O que será apagado")
            } footer: {
                Text("Treinos já gravados no app Saúde continuam lá.")
            }
            Section {
                Toggle("Manter o catálogo de exercícios", isOn: $keepCatalog)
                Toggle("Apagar também as chaves de IA", isOn: $eraseKeys)
            } footer: {
                Text("O catálogo embutido volta pronto para usar. As chaves de IA ficam no Chaveiro e, por padrão, são mantidas.")
            }
            Section {
                Button {
                    dismiss()
                    model.export(options: BackupExportOptions())
                } label: {
                    Label("Exportar antes", systemImage: "square.and.arrow.up")
                }
                .disabled(model.activity.isBusy)
            }
            Section {
                if model.activity == .erasing {
                    HStack { ProgressView(); Text("Apagando…").padding(.leading, FJSpacing.s) }
                } else {
                    Button("Apagar tudo…", role: .destructive) { confirms = true }
                        .disabled(sessionInProgress || model.activity.isBusy)
                }
            }
        }
        .navigationTitle("Apagar todos os dados")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Apagar todos os dados do FitJourney?", isPresented: $confirms, titleVisibility: .visible) {
            Button("Continuar…", role: .destructive) { finalConfirm = true }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Isso não pode ser desfeito.", isPresented: $finalConfirm) {
            Button("Apagar definitivamente", role: .destructive) {
                model.eraseAll(options: DataEraseOptions(keepBuiltInCatalog: keepCatalog, includingSecrets: eraseKeys))
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O app volta ao primeiro uso.")
        }
    }
}

/// Folha de compartilhamento do sistema para o arquivo exportado.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Chamado ao fim do compartilhamento ou do cancelamento.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
