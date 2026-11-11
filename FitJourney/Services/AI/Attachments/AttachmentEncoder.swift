import Foundation

/// Converte anexos preparados em partes de mensagem conforme o que o provedor/modelo aceita.
/// - Imagem → `.image`; texto → `.fileText`.
/// - PDF → `.pdf` quando `supportsPDF`; senão páginas rasterizadas (`PDFRasterizer`) como imagens, com aviso
///   se passou do limite de páginas.
/// - Cada anexo vai precedido de um rótulo `[Arquivo: nome …]` para o modelo citar `source.file`/`page`.
enum AttachmentEncoder {
    /// PDFs acima disso avisam custo (SPEC §7A.1).
    static let costWarningPages = 30

    struct Output: Sendable, Hashable {
        var parts: [LLMContentPart]
        /// Avisos para a UI (páginas cortadas, custo). Sem conteúdo dos arquivos.
        var warnings: [String]
        /// O PDF foi convertido em imagens (provedor sem PDF nativo).
        var rasterizedPDFs: Int
    }

    static func encode(_ attachments: [PreparedAttachment], capabilities: AttachmentCapabilities,
                       rasterizer: PDFRasterizer = PDFRasterizer()) throws -> Output {
        var parts: [LLMContentPart] = []
        var warnings: [String] = []
        var rasterized = 0
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                guard capabilities.supportsImages else { throw AttachmentError.imagesNotSupported }
                parts.append(.text("[Arquivo: \(attachment.filename) (imagem)]"))
                parts.append(.image(mimeType: attachment.mimeType, base64: attachment.data.base64EncodedString()))
            case .text:
                parts.append(.fileText(filename: attachment.filename, text: attachment.text ?? ""))
            case .pdf:
                let pages = attachment.pageCount ?? 0
                if capabilities.supportsPDF {
                    if pages > costWarningPages {
                        warnings.append(String(localized: "\(attachment.filename) tem \(pages) páginas: a análise pode custar mais."))
                    }
                    parts.append(.text("[Arquivo: \(attachment.filename) (PDF, \(pages) páginas)]"))
                    parts.append(.pdf(filename: attachment.filename, base64: attachment.data.base64EncodedString()))
                } else {
                    guard capabilities.supportsImages else { throw AttachmentError.imagesNotSupported }
                    let result = try rasterizer.rasterize(attachment.data, filename: attachment.filename)
                    rasterized += 1
                    if result.truncated {
                        warnings.append(String(localized: "\(attachment.filename) tem \(result.totalPages) páginas; só as primeiras \(result.pages.count) foram enviadas."))
                    }
                    for page in result.pages {
                        parts.append(.text("[Arquivo: \(attachment.filename) — página \(page.number) de \(result.totalPages), convertida em imagem]"))
                        parts.append(.image(mimeType: "image/jpeg", base64: page.jpeg.base64EncodedString()))
                    }
                }
            }
        }
        return Output(parts: parts, warnings: warnings, rasterizedPDFs: rasterized)
    }
}
