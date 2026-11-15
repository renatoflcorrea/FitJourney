import Foundation
import Photos

/// Acesso mínimo à biblioteca de Fotos para **adicionar** (nunca ler). Protocolo para testes.
protocol PhotoLibraryAdding: Sendable {
    func addOnlyAuthorizationStatus() -> PHAuthorizationStatus
    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus
    func addPhoto(_ data: Data) async throws
}

/// Biblioteca do sistema com o nível `.addOnly` (`NSPhotoLibraryAddUsageDescription`).
struct SystemPhotoLibrary: PhotoLibraryAdding {
    func addOnlyAuthorizationStatus() -> PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .addOnly) }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    func addPhoto(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

/// Salva em Fotos a foto tirada pela câmera do app (SPEC §7.x), pedindo só a permissão de adicionar. A foto
/// enviada à IA é outra (reduzida, sem EXIF/GPS) e nunca fica no registro.
struct PhotoLibrarySaver: Sendable {
    enum Outcome: Sendable, Hashable {
        case saved
        /// Sem permissão (negada ou restrita): a análise segue; a tela pode sugerir Ajustes, sem insistir.
        case notAuthorized
    }

    let library: any PhotoLibraryAdding

    init(library: any PhotoLibraryAdding = SystemPhotoLibrary()) { self.library = library }

    /// Pede a permissão de adicionar se ainda não foi decidida e grava. Lança só falha da gravação.
    @discardableResult
    func save(imageData: Data) async throws -> Outcome {
        var status = library.addOnlyAuthorizationStatus()
        if status == .notDetermined { status = await library.requestAddOnlyAuthorization() }
        guard status == .authorized || status == .limited else { return .notAuthorized }
        try await library.addPhoto(imageData)
        return .saved
    }
}
