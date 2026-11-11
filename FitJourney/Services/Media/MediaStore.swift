import AVFoundation
import Foundation
import ImageIO
import SwiftData
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
/// gerar miniatura) roda fora da main actor e respeita cancelamento (nada fica gravado ao cancelar).
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
        if let size = sizeViolation(bytes: bytes, limits: limits) { return size }
        if duration > limits.maxVideoDuration + 0.5 { return .videoTooLong(limit: Int(limits.maxVideoDuration)) }
        return nil
    }

    static func sizeViolation(bytes: Int64, limits: MediaLimits) -> MediaStoreError? {
        bytes > limits.maxVideoBytes ? .videoTooLarge(limitMB: Int(limits.maxVideoBytes / 1_048_576)) : nil
    }

    func url(for fileName: String) -> URL? {
        Self.isSafe(fileName: fileName) ? root.appending(path: fileName, directoryHint: .notDirectory) : nil
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Salvar

    /// Reduz a imagem a no máximo `maxImageDimension` px (respeitando a orientação EXIF), comprime em
    /// JPEG (~0,8) e grava. Devolve o nome do arquivo. Cancelado: não grava nada.
    func saveImage(data: Data) async throws -> String {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        try ensureRoot()
        let name = Self.makeFileName(ext: "jpg")
        try encoded.write(to: root.appending(path: name), options: .atomic)
        return name
    }

    /// Valida limites (tamanho primeiro, é barato), copia o vídeo (arquivo temporário da galeria) para a pasta
    /// de mídia e gera a miniatura. Cancelado ou com erro: o destino é apagado.
    /// O arquivo de origem não é apagado aqui (é temporário do sistema/seletor).
    func saveVideo(from source: URL) async throws -> StoredVideo {
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw MediaStoreError.unreadableVideo
        }
        if let violation = Self.sizeViolation(bytes: Int64(size), limits: limits) { throw violation }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            throw MediaStoreError.unreadableVideo
        }
        try Task.checkCancellation()
        if let violation = Self.violation(duration: duration, bytes: Int64(size), limits: limits) { throw violation }

        try ensureRoot()
        let name = Self.makeFileName(ext: source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        let destination = root.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try Task.checkCancellation()
            var thumbnailName: String?
            do {
                let encoded = try await makeThumbnail(forVideoAt: destination)
                try Task.checkCancellation()
                let name = Self.makeFileName(ext: "jpg")
                try encoded.write(to: root.appending(path: name), options: .atomic)
                thumbnailName = name
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                thumbnailName = nil // sem miniatura o vídeo continua utilizável
            }
            if Task.isCancelled {
                if let thumbnailName { deleteFile(named: thumbnailName) }
                throw CancellationError()
            }
            return StoredVideo(fileName: name, thumbnailFileName: thumbnailName)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Miniatura (JPEG, ≤ 640 px) do primeiro segundo do vídeo, já codificada.
    private func makeThumbnail(forVideoAt url: URL) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        return try Self.encodeJPEG(cgImage, quality: 0.7, error: .unreadableVideo)
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

    // MARK: Duplicar

    /// Copia os arquivos de uma lista de mídias para nomes novos (duplicar exercício sem compartilhar arquivos).
    /// Links externos voltam iguais. Se qualquer cópia falhar ou for cancelada, as já feitas são apagadas.
    func duplicate(_ medias: [MediaRef]) async throws -> [MediaRef] {
        var copies: [MediaRef] = []
        do {
            for media in medias {
                try Task.checkCancellation()
                copies.append(try copy(media))
            }
            return copies
        } catch {
            delete(copies)
            throw error
        }
    }

    func duplicate(_ media: MediaRef) async throws -> MediaRef {
        try await duplicate([media])[0]
    }

    private func copy(_ media: MediaRef) throws -> MediaRef {
        switch media {
        case .externalVideo:
            return media
        case .image(let fileName):
            return .image(fileName: try copyFile(fileName))
        case .localVideo(let fileName, let thumb):
            let video = try copyFile(fileName)
            do {
                return .localVideo(fileName: video, thumbnailFileName: try thumb.map(copyFile))
            } catch {
                deleteFile(named: video)
                throw error
            }
        }
    }

    private func copyFile(_ fileName: String) throws -> String {
        guard let source = url(for: fileName) else { throw CocoaError(.fileReadInvalidFileName) }
        try ensureRoot()
        let name = Self.makeFileName(ext: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: root.appending(path: name))
        return name
    }

    // MARK: Referências e remoção

    /// Todos os nomes de arquivo usados por qualquer exercício.
    static func referencedFileNames(in context: ModelContext) throws -> Set<String> {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        return Set(exercises.flatMap { $0.media.flatMap(fileNames(of:)) })
    }

    /// Apaga os arquivos de mídias que **nenhum** exercício referencia mais (chamar depois de salvar a remoção).
    /// Um arquivo ainda usado por outro exercício é preservado. Se não for possível consultar, não apaga nada.
    func deleteUnreferenced(_ medias: [MediaRef], in context: ModelContext) {
        guard let referenced = try? Self.referencedFileNames(in: context) else { return }
        for name in medias.flatMap(Self.fileNames(of:)) where !referenced.contains(name) { deleteFile(named: name) }
    }

    /// Apaga os arquivos de mídias recém-criadas e ainda não referenciadas por ninguém (cancelamento de edição).
    func delete(_ media: MediaRef) {
        for name in Self.fileNames(of: media) { deleteFile(named: name) }
    }

    func delete(_ medias: [MediaRef]) { medias.forEach(delete) }

    func deleteFile(named fileName: String) {
        guard let url = url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Apaga arquivos regulares da pasta que ninguém referencia (ex.: app fechado no meio de uma edição).
    /// `referenced` = todos os nomes usados por todos os exercícios. Devolve quantos apagou.
    @discardableResult
    func purgeOrphans(keeping referenced: Set<String>) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in urls {
            let name = url.lastPathComponent
            guard Self.isSafe(fileName: name), !referenced.contains(name),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Manutenção

/// Limpeza periódica de mídia. **Não está ligada ao App**: o integrador chama no lançamento.
enum MediaMaintenance {
    /// Pasta dos arquivos temporários de vídeos escolhidos na galeria (`PickedMovie`).
    static var pickedMoviesDirectory: URL {
        URL.temporaryDirectory.appending(path: "FJPickedMovies", directoryHint: .isDirectory)
    }

    /// Apaga arquivos de mídia órfãos (com base em todos os exercícios) e temporários com mais de `maxAge`.
    /// Se não conseguir ler os exercícios, não purga. Roda fora da main actor.
    @discardableResult
    static func runAtLaunch(container: ModelContainer, store: MediaStore = .shared,
                            temporaryDirectory: URL = pickedMoviesDirectory,
                            maxTemporaryAge: TimeInterval = 24 * 3600) async -> Int {
        let context = ModelContext(container)
        var removed = 0
        if let referenced = try? MediaStore.referencedFileNames(in: context) {
            removed += store.purgeOrphans(keeping: referenced)
        }
        removed += cleanTemporary(in: temporaryDirectory, olderThan: maxTemporaryAge)
        return removed
    }

    @discardableResult
    static func cleanTemporary(in directory: URL, olderThan maxAge: TimeInterval, now: Date = .now) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Carregador de imagens

/// Carrega imagens locais (e miniaturas remotas) com cache limitado por bytes. A decodificação roda no
/// executor global (não na main actor nem serializada num actor).
final class MediaImageLoader: @unchecked Sendable {
    static let shared = MediaImageLoader()

    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
        var cost: Int { image.bytesPerRow * image.height }
    }

    private func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

    private func store(_ image: CGImage, key: String) {
        let box = CGImageBox(image)
        cache.setObject(box, forKey: key as NSString, cost: box.cost)
    }

    /// `maxPixel` limita o maior lado decodificado (listas usam ~200; tela cheia ~2048).
    func image(for fileName: String, store mediaStore: MediaStore = .shared, maxPixel: Int) async -> CGImage? {
        let key = "\(mediaStore.root.path())/\(fileName)#\(maxPixel)"
        if let hit = cached(key) { return hit }
        guard let url = mediaStore.url(for: fileName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Self.thumbnail(from: source, maxPixel: maxPixel) else { return nil }
        store(image, key: key)
        return image
    }

    /// Miniatura remota (só YouTube), com cache em memória. Falha de rede = `nil` (a UI mostra o placeholder).
    func remoteImage(from url: URL, maxPixel: Int = 640) async -> CGImage? {
        let key = "remote:\(url.absoluteString)#\(maxPixel)"
        if let hit = cached(key) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = Self.thumbnail(from: source, maxPixel: maxPixel) else { return nil }
        store(image, key: key)
        return image
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
