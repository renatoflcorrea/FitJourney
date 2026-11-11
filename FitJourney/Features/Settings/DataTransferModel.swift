import Foundation
import Observation
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Postada **antes** de "Substituir tudo" ou "Apagar tudo": o `AppRoot` troca a árvore por um estado
    /// neutro bloqueante (fecha sheets e editores, sessão minimizada) e o Coach cancela suas tarefas.
    static let fjDataWillReset = Notification.Name("fj.dataWillReset")
    /// Postada **depois** (também se a operação falhar): o `AppRoot` recria as abas e relê a sessão.
    static let fjDataDidReset = Notification.Name("fj.dataDidReset")
}

/// Mensagem mostrada pelo `AppRoot` depois de um reset (a tela de Dados já não existe nesse momento).
struct DataAnnouncement: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Resumo de um backup lido por `inspect`, antes de qualquer mudança.
struct PendingImport: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var exportedAt: Date
    var schemaVersion: Int
    var counts: BackupCounts
    var includesCoachConversations: Bool
    var includesMedia: Bool
    var mode: BackupImportMode = .merge
}

/// Orquestra exportar/importar/apagar para a tela de Dados. Tudo roda nos atores do backup; o progresso
/// chega fora da main e é trazido de volta aqui.
@MainActor
@Observable
final class DataTransferModel {
    enum Activity: Equatable {
        case idle
        case exporting(BackupProgress)
        case importing(BackupProgress)
        case erasing

        var isBusy: Bool { self != .idle }
    }

    private(set) var activity: Activity = .idle
    /// Arquivo pronto: a UI abre a folha de compartilhamento.
    var exported: ExportedFile?
    var pendingImport: PendingImport?
    private(set) var report: BackupImportReport?
    var errorMessage: String?
    /// Resultado de uma operação que reiniciou a árvore (substituir/apagar): o `AppRoot` mostra um alerta.
    var announcement: DataAnnouncement?

    struct ExportedFile: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var exportedURL: URL?
    /// Cada operação tem uma geração: progresso atrasado de uma anterior é ignorado e nunca regride.
    @ObservationIgnored private var generation = 0

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    // MARK: Exportar

    func export(options: BackupExportOptions) {
        guard !activity.isBusy else { return }
        generation += 1
        let gen = generation
        activity = .exporting(BackupProgress(phase: .reading, fraction: 0))
        let exporter = BackupExporter(modelContainer: container)
        let handler: BackupProgressHandler = { [weak self] progress in
            Task { @MainActor in self?.report(progress, generation: gen, exporting: true) }
        }
        task = Task {
            do {
                let result = try await exporter.export(options: options, progress: handler)
                Self.protect(result.fileURL)
                exportedURL = result.fileURL
                exported = ExportedFile(url: result.fileURL)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            activity = .idle
        }
    }

    // MARK: Importar

    /// Lê e valida o arquivo escolhido (acesso de segurança mantido até concluir ou cancelar).
    func inspect(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            guard !activity.isBusy else { return }
            releaseScope()
            if url.startAccessingSecurityScopedResource() {
                scopedURL = url
            } else if !FileManager.default.isReadableFile(atPath: url.path) {
                errorMessage = String(localized: "Não foi possível acessar o arquivo escolhido.")
                return
            }
            activity = .importing(BackupProgress(phase: .validating, fraction: 0))
            let importer = BackupImporter(modelContainer: container)
            task = Task {
                do {
                    let (document, counts) = try await importer.inspect(fileAt: url)
                    pendingImport = PendingImport(
                        url: url, exportedAt: document.exportedAt, schemaVersion: document.schemaVersion,
                        counts: counts, includesCoachConversations: document.coachConversations != nil,
                        includesMedia: document.options.includesMedia)
                } catch {
                    releaseScope()
                    errorMessage = error.localizedDescription
                }
                activity = .idle
            }
        }
    }

    func cancelPendingImport() {
        pendingImport = nil
        releaseScope()
    }

    /// Importa o backup. `includeCoachConversations` só vale se o arquivo as tiver.
    func performImport(_ pending: PendingImport, includeCoachConversations: Bool) {
        guard !activity.isBusy else { return }
        pendingImport = nil
        generation += 1
        let gen = generation
        activity = .importing(BackupProgress(phase: .extracting, fraction: 0))
        let importer = BackupImporter(modelContainer: container)
        let options = BackupImportOptions(mode: pending.mode, includeCoachConversations: includeCoachConversations)
        let handler: BackupProgressHandler = { [weak self] progress in
            Task { @MainActor in self?.report(progress, generation: gen, exporting: false) }
        }
        let replaces = pending.mode == .replace
        task = Task {
            if replaces { await beginReset() }
            do {
                let report = try await importer.importBackup(from: pending.url, options: options, progress: handler)
                if replaces {
                    announcement = DataAnnouncement(
                        title: String(localized: "Backup importado"),
                        message: ([SettingsPresentation.importSummary(report)] + report.warnings.map(\.message))
                            .joined(separator: "\n"))
                } else {
                    self.report = report
                }
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription + "\n" + String(localized: "Nada foi alterado.")
                if replaces {
                    announcement = DataAnnouncement(title: String(localized: "Não foi possível concluir"), message: message)
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            releaseScope()
            if replaces { endReset() }
            activity = .idle
        }
    }

    // MARK: Apagar

    func eraseAll(options: DataEraseOptions) {
        guard !activity.isBusy else { return }
        generation += 1
        activity = .erasing
        let eraser = DataEraser(modelContainer: container)
        task = Task {
            await beginReset()
            do {
                try await eraser.eraseAll(options: options)
                announcement = DataAnnouncement(title: String(localized: "Dados apagados"),
                                                message: String(localized: "O app voltou ao primeiro uso."))
            } catch {
                announcement = DataAnnouncement(title: String(localized: "Não foi possível concluir"),
                                                message: error.localizedDescription + "\n" + String(localized: "Nada foi alterado."))
            }
            endReset()
            activity = .idle
        }
    }

    // MARK: Reset em duas fases

    /// Fase 1: a árvore vira um estado neutro bloqueante antes de qualquer escrita no banco.
    private func beginReset() async {
        NotificationCenter.default.post(name: .fjDataWillReset, object: nil)
        try? await Task.sleep(for: .milliseconds(350)) // deixa as views antigas saírem
    }

    /// Fase 2: recria as abas (também quando a operação falhou).
    private func endReset() {
        NotificationCenter.default.post(name: .fjDataDidReset, object: nil)
    }

    // MARK: Comum

    private func report(_ progress: BackupProgress, generation gen: Int, exporting: Bool) {
        guard gen == generation else { return }
        switch (activity, exporting) {
        case (.exporting(let current), true):
            activity = .exporting(BackupProgress(phase: progress.phase, fraction: max(current.fraction, progress.fraction)))
        case (.importing(let current), false):
            activity = .importing(BackupProgress(phase: progress.phase, fraction: max(current.fraction, progress.fraction)))
        default: break
        }
    }

    /// Exportação pode ter dados de saúde: protegida enquanto o aparelho está bloqueado e fora do backup do iCloud.
    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = url
        try? copy.setResourceValues(values)
    }

    /// Apaga o arquivo exportado (fim do compartilhamento, cancelamento ou fechamento da folha).
    func cleanupExport() {
        exported = nil
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        exportedURL = nil
    }

    func cancel() { task?.cancel() }
    func dismissReport() { report = nil }

    func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}

extension BackupProgress {
    /// "Preparando… 62%".
    var label: String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        let text: String
        switch phase {
        case .reading, .encoding, .copyingMedia: text = String(localized: "Preparando…")
        case .extracting, .validating: text = String(localized: "Lendo o arquivo…")
        case .importing, .saving: text = String(localized: "Importando…")
        case .erasing: text = String(localized: "Apagando…")
        case .finished: text = String(localized: "Concluído")
        }
        return "\(text) \(percent)%"
    }
}
