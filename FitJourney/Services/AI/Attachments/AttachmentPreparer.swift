import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Prepara anexos para envio ao provedor (SPEC §7A.1):
/// - até `maxFiles` arquivos de até `maxFileBytes` cada; total preparado ≤ `maxTotalBytes`;
/// - imagens (HEIC/JPEG/PNG…) reencodadas em JPEG com lado maior ≤ `maxImagePixels`, desenhadas num contexto
///   novo — **EXIF, GPS e demais metadados não sobrevivem** — e orientação aplicada;
/// - PDF validado (abre, não protegido) com contagem de páginas;
/// - texto (.txt/.md/.csv) decodificado em UTF-8 e cortado em `maxTextCharacters`.
///
/// Puro e `Sendable`: pode rodar fora da main. Nunca loga nomes nem conteúdo.
struct AttachmentPreparer: Sendable {
    static let maxFiles = 10
    static let maxFileBytes = 20 * 1024 * 1024
    /// Depois da preparação. Com base64 (+33%) fica abaixo do limite de 32 MB por pedido da Anthropic.
    static let maxTotalBytes = 22 * 1024 * 1024
    static let maxImagePixels = 2048
    static let maxTextCharacters = 100_000
    static let jpegQuality = 0.82

    var maxImagePixels = AttachmentPreparer.maxImagePixels

    init(maxImagePixels: Int = AttachmentPreparer.maxImagePixels) {
        self.maxImagePixels = maxImagePixels
    }

    /// Prepara `raws` somando aos já preparados (`existing`). Lança no primeiro problema, sem preparar pela metade.
    func prepare(_ raws: [RawAttachment], existing: [PreparedAttachment] = []) throws -> [PreparedAttachment] {
        guard existing.count + raws.count <= Self.maxFiles else { throw AttachmentError.tooManyFiles(max: Self.maxFiles) }
        var result: [PreparedAttachment] = []
        var total = existing.reduce(0) { $0 + $1.data.count }
        for raw in raws {
            let prepared = try prepare(raw)
            total += prepared.data.count
            guard total <= Self.maxTotalBytes else {
                throw AttachmentError.totalTooLarge(maxMegabytes: Self.maxTotalBytes / 1_048_576)
            }
            result.append(prepared)
        }
        return result
    }

    func prepare(_ raw: RawAttachment) throws -> PreparedAttachment {
        let name = Self.cleanFilename(raw.filename)
        guard !raw.data.isEmpty else { throw AttachmentError.emptyFile(filename: name) }
        guard raw.data.count <= Self.maxFileBytes else {
            throw AttachmentError.fileTooLarge(filename: name, maxMegabytes: Self.maxFileBytes / 1_048_576)
        }
        switch Self.detectKind(data: raw.data, filename: name, hint: raw.typeHint) {
        case .pdf:
            guard let document = PDFDocument(data: raw.data) else { throw AttachmentError.unreadable(filename: name) }
            guard !document.isLocked, !document.isEncrypted || document.unlock(withPassword: "") else {
                throw AttachmentError.protectedPDF(filename: name)
            }
            guard document.pageCount > 0 else { throw AttachmentError.emptyFile(filename: name) }
            return PreparedAttachment(filename: name, kind: .pdf, mimeType: "application/pdf", data: raw.data,
                                      pageCount: document.pageCount)
        case .image:
            guard let jpeg = Self.reencodeImage(raw.data, maxPixels: maxImagePixels) else {
                throw AttachmentError.unreadable(filename: name)
            }
            return PreparedAttachment(filename: name, kind: .image, mimeType: "image/jpeg", data: jpeg)
        case .text:
            guard var text = String(data: raw.data, encoding: .utf8) ?? String(data: raw.data, encoding: .isoLatin1) else {
                throw AttachmentError.unreadable(filename: name)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AttachmentError.emptyFile(filename: name) }
            if text.count > Self.maxTextCharacters { text = String(text.prefix(Self.maxTextCharacters)) }
            return PreparedAttachment(filename: name, kind: .text, mimeType: "text/plain", data: Data(text.utf8))
        case nil:
            throw AttachmentError.unsupportedType(filename: name)
        }
    }

    /// Texto colado pelo usuário vira um anexo de texto.
    func preparePastedText(_ text: String, filename: String = "texto-colado.txt") throws -> PreparedAttachment {
        try prepare(RawAttachment(filename: filename, data: Data(text.utf8), typeHint: UTType.plainText.identifier))
    }

    // MARK: - Detecção

    /// Pelo conteúdo: `%PDF` → PDF; ImageIO reconhece → imagem; extensão/dica de texto ou UTF-8 sem NUL → texto.
    static func detectKind(data: Data, filename: String, hint: String?) -> AttachmentKind? {
        if data.starts(with: Array("%PDF".utf8)) { return .pdf }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
           CGImageSourceGetCount(source) > 0 {
            return .image
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "text"]
        let hintIsText = hint.map { hint in
            hint.hasPrefix("text/") || (UTType(hint)?.conforms(to: .plainText) ?? false)
                || (UTType(hint)?.conforms(to: .text) ?? false)
        } ?? false
        if textExtensions.contains(ext) || hintIsText { return .text }
        if !data.contains(0), String(data: data.prefix(4096), encoding: .utf8) != nil, ext.isEmpty { return .text }
        return nil
    }

    // MARK: - Imagem

    /// Reduz para lado maior ≤ `maxPixels` (nunca amplia), aplica a orientação e reencoda em JPEG desenhando
    /// num contexto sRGB sem alfa (fundo branco). Nenhuma propriedade da origem é copiada: sem EXIF/GPS/TIFF.
    static func reencodeImage(_ data: Data, maxPixels: Int = maxImagePixels, quality: Double = jpegQuality) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? maxPixels
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? maxPixels
        let longest = max(1, min(maxPixels, max(width, height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let flattened = flatten(thumbnail) else { return nil }
        return jpegData(flattened, quality: quality)
    }

    static func flatten(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Só o último componente, sem caracteres de controle, até 120 caracteres.
    static func cleanFilename(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "arquivo" : String(cleaned.prefix(120))
    }
}
