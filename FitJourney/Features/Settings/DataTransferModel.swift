import Foundation
import Observation
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Postada depois de "Substituir tudo" ou "Apagar tudo": o `AppRoot` recria as abas (modelos antigos
    /// já não existem) e volta à raiz.
    static let fjDataDidReset = Notification.Name("fj.dataDidReset")
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

    struct ExportedFile: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    // MARK: Exportar

    func export(options: BackupExportOptions) {
        guard !activity.isBusy else { return }
        activity = .exporting(BackupProgress(phase: .reading, fraction: 0))
        let exporter = BackupExporter(modelContainer: container)
        let handler: BackupProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .exporting = self.activity else { return }
                self.activity = .exporting(progress)
            }
        }
        task = Task {
            do {
                let result = try await exporter.export(options: options, progress: handler)
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
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
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
        activity = .importing(BackupProgress(phase: .extracting, fraction: 0))
        let importer = BackupImporter(modelContainer: container)
        let options = BackupImportOptions(mode: pending.mode, includeCoachConversations: includeCoachConversations)
        let handler: BackupProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .importing = self.activity else { return }
                self.activity = .importing(progress)
            }
        }
        task = Task {
            do {
                let report = try await importer.importBackup(from: pending.url, options: options, progress: handler)
                self.report = report
                if pending.mode == .replace { NotificationCenter.default.post(name: .fjDataDidReset, object: nil) }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            releaseScope()
            activity = .idle
        }
    }

    // MARK: Apagar

    func eraseAll(options: DataEraseOptions) {
        guard !activity.isBusy else { return }
        activity = .erasing
        let eraser = DataEraser(modelContainer: container)
        task = Task {
            do {
                try await eraser.eraseAll(options: options)
                NotificationCenter.default.post(name: .fjDataDidReset, object: nil)
            } catch {
                errorMessage = error.localizedDescription
            }
            activity = .idle
        }
    }

    // MARK: Comum

    func cancel() { task?.cancel() }
    func dismissReport() { report = nil }

    private func releaseScope() {
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
