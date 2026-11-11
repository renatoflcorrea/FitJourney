import CoreGraphics
import Foundation
import PDFKit

/// Converte páginas de PDF em JPEG **só para enviar** a provedores sem PDF nativo (SPEC §7A.3). Não é OCR:
/// a leitura continua sendo do modelo multimodal. Limite de páginas com aviso; nada é guardado.
struct PDFRasterizer: Sendable {
    static let defaultMaxPages = 20

    var maxPages: Int
    /// Lado maior da página renderizada, em pixels.
    var maxPixels: Int
    var quality: Double

    init(maxPages: Int = PDFRasterizer.defaultMaxPages, maxPixels: Int = 1600, quality: Double = 0.75) {
        self.maxPages = maxPages
        self.maxPixels = maxPixels
        self.quality = quality
    }

    struct Page: Sendable, Hashable {
        /// 1-based.
        var number: Int
        var jpeg: Data
    }

    struct Result: Sendable, Hashable {
        var pages: [Page]
        var totalPages: Int
        var truncated: Bool { pages.count < totalPages }
    }

    func rasterize(_ data: Data, filename: String = "arquivo.pdf") throws -> Result {
        guard let document = PDFDocument(data: data) else { throw AttachmentError.unreadable(filename: filename) }
        guard !document.isLocked else { throw AttachmentError.protectedPDF(filename: filename) }
        let total = document.pageCount
        var pages: [Page] = []
        for index in 0 ..< min(total, max(0, maxPages)) {
            guard let page = document.page(at: index), let cgPage = page.pageRef,
                  let jpeg = render(cgPage, bounds: page.bounds(for: .mediaBox), rotation: page.rotation) else {
                throw AttachmentError.unreadable(filename: filename)
            }
            pages.append(Page(number: index + 1, jpeg: jpeg))
        }
        return Result(pages: pages, totalPages: total)
    }

    private func render(_ page: CGPDFPage, bounds: CGRect, rotation: Int) -> Data? {
        let rotated = rotation % 180 != 0
        let pageWidth = rotated ? bounds.height : bounds.width
        let pageHeight = rotated ? bounds.width : bounds.height
        guard pageWidth > 0, pageHeight > 0 else { return nil }
        let scale = CGFloat(maxPixels) / max(pageWidth, pageHeight)
        let width = max(1, Int((pageWidth * scale).rounded()))
        let height = max(1, Int((pageHeight * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        if rotated || rotation % 360 != 0 {
            // Gira em torno do centro da página para respeitar `/Rotate`.
            context.translateBy(x: pageWidth / 2, y: pageHeight / 2)
            context.rotate(by: -CGFloat(rotation) * .pi / 180)
            context.translateBy(x: -bounds.width / 2, y: -bounds.height / 2)
        }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return AttachmentPreparer.jpegData(image, quality: quality)
    }
}
