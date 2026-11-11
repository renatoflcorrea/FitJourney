import Foundation
import SwiftData
import UserNotifications

struct DataEraseOptions: Sendable, Equatable {
    /// Semeia de novo o catálogo embutido depois de apagar (padrão). `false` = catálogo vazio e o seed
    /// do lançamento não o recria (a versão do catálogo fica registrada).
    var keepBuiltInCatalog = true
    /// Também apaga as chaves de API do Keychain (padrão: não).
    var includingSecrets = false

    init(keepBuiltInCatalog: Bool = true, includingSecrets: Bool = false) {
        self.keepBuiltInCatalog = keepBuiltInCatalog
        self.includingSecrets = includingSecrets
    }
}

struct DataEraseResult: Sendable, Equatable {
    var mediaFilesDeleted: Int
    var builtInExercisesSeeded: Int
    var secretsDeleted: Bool
}

/// "Apagar tudo" (SPEC §9): todos os modelos, a pasta de mídia, as preferências do app e os tombstones
/// de sessões descartadas. Chaves de API só com `includingSecrets`.
///
/// O banco é apagado num único `save` (falhou → nada muda). Depois do `save`: mídia, cache de imagens,
/// temporários de backup (`FJExports`, `FJImport-*`), notificações pendentes e entregues e UserDefaults.
///
/// **Antes de chamar** (UI): pare o motor da sessão e volte à raiz. Com treino em andamento a operação
/// é recusada (`BackupError.activeSessionInProgress`), conferido no início e logo antes do `save`.
actor DataEraser: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private let mediaStore: MediaStore
    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    private let clearNotifications: @Sendable () -> Void
    private let temporaryDirectory: URL

    init(modelContainer: ModelContainer, mediaStore: MediaStore = .shared, defaults: UserDefaults = .standard,
         secretStore: any SecretStore = KeychainSecretStore(),
         clearNotifications: @escaping @Sendable () -> Void = DataEraser.clearAllNotifications,
         temporaryDirectory: URL = URL.temporaryDirectory) {
        self.clearNotifications = clearNotifications
        self.temporaryDirectory = temporaryDirectory
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
        self.mediaStore = mediaStore
        self.defaults = defaults
        self.secretStore = secretStore
    }

    @discardableResult
    func eraseAll(options: DataEraseOptions = .init(), progress: BackupProgressHandler? = nil) throws -> DataEraseResult {
        progress?(BackupProgress(phase: .erasing, fraction: 0))
        let context = modelContext
        var seeded = 0
        do {
            if try BackupWipe.hasSessionInProgress(in: context) { throw BackupError.activeSessionInProgress }
            try BackupWipe.deleteAllModels(in: context)
            if options.keepBuiltInCatalog { seeded = try BackupCatalog.insertMissingBuiltIns(in: context) }
            progress?(BackupProgress(phase: .saving, fraction: 0.6))
            // Um treino pode ter começado na main durante a exclusão.
            if try BackupWipe.hasSessionInProgress(in: context) { throw BackupError.activeSessionInProgress }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        let mediaDeleted = mediaStore.deleteAllFiles()
        MediaImageLoader.shared.removeAll()
        BackupMaintenance.removeAll(temporaryDirectory: temporaryDirectory)
        clearNotifications()

        for key in BackupPreferenceKeys.erasable { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys
        where BackupPreferenceKeys.erasablePrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        // Com ou sem catálogo, a versão fica registrada: o seed do lançamento não traz de volta.
        defaults.set(ExerciseCatalog.version, forKey: BackupPreferenceKeys.seededCatalogVersion)

        var secretsDeleted = false
        if options.includingSecrets {
            for provider in AIProviderID.allCases { try secretStore.set(nil, for: .apiKey(provider)) }
            secretsDeleted = true
        }
        progress?(BackupProgress(phase: .finished, fraction: 1))
        return DataEraseResult(mediaFilesDeleted: mediaDeleted, builtInExercisesSeeded: seeded, secretsDeleted: secretsDeleted)
    }

    /// Lembretes de refeição, descanso etc.: pendentes e já entregues.
    static let clearAllNotifications: @Sendable () -> Void = {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
