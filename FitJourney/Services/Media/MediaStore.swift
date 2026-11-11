import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Limites de mídia (SPEC §3.3: vídeo padrão 60 s / 200 MB; configurável).
struct MediaLimits: Sendable, Equatable {
    var maxVideoDuration: TimeInterval = 60
    var maxVideoBytes: Int64 = 200 * 1024 * 1024
    /// Maior lado da imagem salva, em pixels.
    var maxImageDimension: Int = 2048
    var imageQuality: Double = 0.8

    static let standard = MediaLimits()
}

enum MediaStoreError: LocalizedError, Equatable {
    case unreadableImage
    case unreadableVideo
    case videoTooLong(limit: Int)
    case videoTooLarge(limitMB: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            String(localized: "Não foi possível ler essa imagem.")
        case .unreadableVideo:
            String(localized: "Não foi possível ler esse vídeo.")
        case .videoTooLong(let limit):
            String(localized: "Vídeo maior que o limite (\(limit) s). Corte no Fotos e tente de novo.")
        case .videoTooLarge(let limitMB):
            String(localized: "Vídeo maior que o limite (\(limitMB) MB). Corte ou comprima no Fotos e tente de novo.")
        }
    }
}

/// Resultado de salvar um vídeo da galeria.
struct StoredVideo: Sendable, Equatable {
    var fileName: String
    var thumbnailFileName: String?

    var mediaRef: MediaRef { .localVideo(fileName: fileName, thumbnailFileName: thumbnailFileName) }
}

/// Armazenamento de mídia dos exercícios em `Application Support/Media/`.
///
/// Só nomes de arquivo relativos vão para o `MediaRef` (o container do app muda de caminho entre
/// instalações). Métodos `async` não herdam ator: o trabalho pesado (decodificar, comprimir, copiar,
/// gerar miniatura) roda fora da main actor.
struct MediaStore: Sendable {
    let root: URL
    var limits: MediaLimits

    /// Pasta padrão: `Application Support/Media`.
    static let shared = MediaStore(root: defaultRoot, limits: .standard)

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Media", directoryHint: .isDirectory)
    }

    init(root: URL, limits: MediaLimits = .standard) {
        self.root = root
        self.limits = limits
    }

    // MARK: Nomes e caminhos

    /// Nome novo e único (`<uuid>.<ext>`); a extensão é restrita a letras/números.
    static func makeFileName(ext: String) -> String {
        let clean = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return clean.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(clean)"
    }

    /// Aceita só nomes simples (sem `/`, `..` ou arquivo oculto) — barra path traversal vindo de dado persistido.
    static func isSafe(fileName: String) -> Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.hasPrefix(".")
    }

    /// Arquivos locais usados por uma mídia (vazio para link externo).
    static func fileNames(of media: MediaRef) -> [String] {
        switch media {
        case .image(let fileName): [fileName]
        case .localVideo(let fileName, let thumb): [fileName] + (thumb.map { [$0] } ?? [])
        case .externalVideo: []
        }
    }

    /// Valida um vídeo contra os limites; `nil` = dentro do limite.
    static func violation(duration: TimeInterval, bytes: Int64, limits: MediaLimits) -> MediaStoreError? {
        if bytes > limits.maxVideoBytes { return .videoTooLarge(limitMB: Int(limits.maxVideoBytes / 1_048_576)) }
        if duration > limits.maxVideoDuration + 0.5 { return .videoTooLong(limit: Int(limits.maxVideoDuration)) }
        return nil
    }

    func url(for fileName: String) -> URL? {
        Self.isSafe(fileName: fileName) ? root.appending(path: fileName, directoryHint: .notDirectory) : nil
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Salvar

    /// Reduz a imagem a no máximo `maxImageDimension` px (respeitando a orientação EXIF), comprime em
    /// JPEG (~0,8) e grava. Devolve o nome do arquivo.
    func saveImage(data: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw MediaStoreError.unreadableImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maxImageDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaStoreError.unreadableImage
        }
        let encoded = try Self.encodeJPEG(image, quality: limits.imageQuality, error: .unreadableImage)
        try ensureRoot()
        let name = Self.makeFileName(ext: "jpg")
        try encoded.write(to: root.appending(path: name), options: .atomic)
        return name
    }

    /// Valida limites, copia o vídeo (arquivo temporário da galeria) para a pasta de mídia e gera a miniatura.
    /// O arquivo de origem não é apagado aqui (é temporário do sistema/seletor).
    func saveVideo(from source: URL) async throws -> StoredVideo {
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            throw MediaStoreError.unreadableVideo
        }
        if let violation = Self.violation(duration: duration, bytes: bytes, limits: limits) { throw violation }

        try ensureRoot()
        try Task.checkCancellation()
        let name = Self.makeFileName(ext: source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        let destination = root.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try Task.checkCancellation()
            let thumb = try? await makeThumbnail(forVideoAt: destination)
            return StoredVideo(fileName: name, thumbnailFileName: thumb)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Miniatura (JPEG, ≤ 640 px) do primeiro segundo do vídeo.
    private func makeThumbnail(forVideoAt url: URL) async throws -> String {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let encoded = try Self.encodeJPEG(cgImage, quality: 0.7, error: .unreadableVideo)
        let name = Self.makeFileName(ext: "jpg")
        try encoded.write(to: root.appending(path: name), options: .atomic)
        return name
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double, error: MediaStoreError) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw error
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw error }
        return output as Data
    }

    /// Copia os arquivos de uma mídia local para nomes novos (duplicar exercício sem compartilhar arquivos,
    /// para que apagar um não quebre o outro). Links externos voltam iguais.
    func duplicate(_ media: MediaRef) async throws -> MediaRef {
        switch media {
        case .externalVideo:
            return media
        case .image(let fileName):
            return .image(fileName: try copyFile(fileName))
        case .localVideo(let fileName, let thumb):
            return .localVideo(fileName: try copyFile(fileName), thumbnailFileName: try thumb.map(copyFile))
        }
    }

    private func copyFile(_ fileName: String) throws -> String {
        guard let source = url(for: fileName) else { throw CocoaError(.fileReadInvalidFileName) }
        try ensureRoot()
        let name = Self.makeFileName(ext: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: root.appending(path: name))
        return name
    }

    // MARK: Remover

    /// Apaga os arquivos de uma mídia (chamar quando ela é removida do exercício ou o exercício é apagado).
    func delete(_ media: MediaRef) {
        for name in Self.fileNames(of: media) { deleteFile(named: name) }
    }

    func delete(_ medias: [MediaRef]) { medias.forEach(delete) }

    func deleteFile(named fileName: String) {
        guard let url = url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Apaga qualquer arquivo da pasta que nenhuma mídia referencie (ex.: app fechado no meio de uma edição).
    /// `referenced` = todos os nomes usados por todos os exercícios. Devolve quantos apagou.
    @discardableResult
    func purgeOrphans(keeping referenced: Set<String>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path()) else { return 0 }
        var removed = 0
        for name in names where !referenced.contains(name) && Self.isSafe(fileName: name) {
            if (try? FileManager.default.removeItem(at: root.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// Carrega e guarda em cache imagens locais (miniaturas e fotos), decodificadas fora da main actor.
actor MediaImageLoader {
    static let shared = MediaImageLoader()

    private let cache = NSCache<NSString, CGImageBox>()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// `maxPixel` limita o maior lado decodificado (listas usam ~200; tela cheia ~2048).
    func image(for fileName: String, store: MediaStore = .shared, maxPixel: Int) -> CGImage? {
        let key = "\(fileName)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let url = store.url(for: fileName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }
}
