import Foundation

// Anexos multimodais do copiloto (SPEC §7A.1/§7A.3). Os bytes só vivem em memória até o envio; o que é
// persistido (sessão de importação, conversa) são os metadados (`AttachmentMetadata`). Nunca logar conteúdo.

/// Arquivo escolhido pelo usuário, antes da preparação.
struct RawAttachment: Sendable {
    var filename: String
    var data: Data
    /// Dica de tipo (UTType identifier ou MIME), quando a origem informa. A detecção principal é pelo conteúdo.
    var typeHint: String?

    init(filename: String, data: Data, typeHint: String? = nil) {
        self.filename = filename
        self.data = data
        self.typeHint = typeHint
    }
}

enum AttachmentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case image, pdf, text
}

/// Metadados persistíveis de um anexo (nome, tipo, páginas, tamanho) — sem conteúdo.
struct AttachmentMetadata: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var filename: String
    var kind: AttachmentKind
    var mimeType: String
    /// Páginas (PDF); `nil` nos demais.
    var pageCount: Int?
    /// Tamanho já preparado (o que vai ao provedor, antes do base64).
    var byteCount: Int
}

/// Anexo pronto para envio: imagem redimensionada (≤ 2048 px) e sem metadados, PDF validado, texto decodificado.
struct PreparedAttachment: Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var filename: String
    var kind: AttachmentKind
    var mimeType: String
    /// Imagem: JPEG reencodado. PDF: o arquivo original. Texto: UTF-8.
    var data: Data
    var pageCount: Int?

    var metadata: AttachmentMetadata {
        AttachmentMetadata(id: id, filename: filename, kind: kind, mimeType: mimeType, pageCount: pageCount,
                           byteCount: data.count)
    }

    /// Texto decodificado (só `kind == .text`).
    var text: String? { kind == .text ? String(data: data, encoding: .utf8) : nil }
}

enum AttachmentError: Error, Sendable, Hashable {
    case tooManyFiles(max: Int)
    case fileTooLarge(filename: String, maxMegabytes: Int)
    case totalTooLarge(maxMegabytes: Int)
    case unsupportedType(filename: String)
    case unreadable(filename: String)
    case protectedPDF(filename: String)
    case emptyFile(filename: String)
    /// O provedor/modelo escolhido não aceita imagens (nem as páginas rasterizadas de um PDF).
    case imagesNotSupported
}

extension AttachmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .tooManyFiles(max): String(localized: "Escolha no máximo \(max) arquivos.")
        case let .fileTooLarge(name, mb): String(localized: "\(name) passa de \(mb) MB.")
        case let .totalTooLarge(mb): String(localized: "Os arquivos juntos passam de \(mb) MB. Remova algum.")
        case let .unsupportedType(name): String(localized: "\(name): formato não suportado (use PDF, foto ou texto).")
        case let .unreadable(name): String(localized: "Não foi possível ler \(name).")
        case let .protectedPDF(name): String(localized: "\(name) está protegido por senha.")
        case let .emptyFile(name): String(localized: "\(name) está vazio.")
        case .imagesNotSupported:
            String(localized: "O modelo escolhido não aceita imagens. Escolha outro modelo em Ajustes de IA.")
        }
    }
}

/// O que o provedor/modelo aceita como anexo. Sem PDF nativo → `PDFRasterizer` (páginas em JPEG, só para envio).
struct AttachmentCapabilities: Sendable, Hashable {
    var supportsImages: Bool
    var supportsPDF: Bool

    /// Tabela conservadora:
    /// - Anthropic: imagem e PDF (`image`/`document`) em todos os modelos atuais.
    /// - OpenAI: imagem nos modelos com visão; PDF (`file`) em gpt-4o/4.1/5 e séries o*.
    /// - OpenRouter: imagem e PDF (`file`, o OpenRouter converte quando o modelo não lê PDF).
    /// - Compatível (URL própria): imagem sim (o usuário escolheu o modelo), PDF não.
    /// - ChatGPT (login): imagem sim; PDF **não verificado** no endpoint não oficial → rasteriza.
    static func resolve(provider: AIProviderID, model: String) -> AttachmentCapabilities {
        let slug = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        switch provider {
        case .anthropic:
            return AttachmentCapabilities(supportsImages: true, supportsPDF: true)
        case .openAI:
            let vision = !slug.hasPrefix("gpt-3.5")
            let pdf = ["gpt-4o", "gpt-4.1", "gpt-5", "o1", "o3", "o4"].contains { slug.hasPrefix($0) }
            return AttachmentCapabilities(supportsImages: vision, supportsPDF: pdf)
        case .openRouter:
            return AttachmentCapabilities(supportsImages: true, supportsPDF: true)
        case .custom:
            return AttachmentCapabilities(supportsImages: true, supportsPDF: false)
        case .chatGPT:
            return AttachmentCapabilities(supportsImages: true, supportsPDF: false)
        }
    }
}
