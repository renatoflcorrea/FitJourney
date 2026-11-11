import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FitJourney

/// Arquivos sintéticos para os testes de anexos.
enum AttachmentFixtures {
    /// PDF com `pages` páginas (200×300 pt) desenhadas com CoreGraphics.
    static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in 0 ..< pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: CGFloat(page % 2), green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 260))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// JPEG `width`×`height` com EXIF (comentário), TIFF (fabricante) e GPS.
    static func jpegWithMetadata(width: Int = 3000, height: Int = 1500) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 23.55, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 46.63, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam", kCGImagePropertyTIFFModel: "X1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "segredo", kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

@Suite("Copiloto — anexos multimodais")
struct CopilotAttachmentTests {
    // MARK: Preparação

    @Test("foto: EXIF/GPS/TIFF removidos e lado maior ≤ 2048 px")
    func imageStripsMetadataAndResizes() throws {
        let original = AttachmentFixtures.jpegWithMetadata()
        let before = AttachmentFixtures.properties(of: original)
        #expect(before[kCGImagePropertyGPSDictionary] != nil) // a fixture tem GPS de verdade

        let prepared = try AttachmentPreparer().prepare(RawAttachment(filename: "../ficha.jpg", data: original))
        #expect(prepared.kind == .image)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.filename == "ficha.jpg")
        let after = AttachmentFixtures.properties(of: prepared.data)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let width = (after[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (after[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        #expect(max(width, height) == 2048)
        #expect(min(width, height) == 1024)
    }

    @Test("foto pequena não é ampliada")
    func smallImageKeepsSize() throws {
        let prepared = try AttachmentPreparer().prepare(RawAttachment(filename: "a.jpg",
                                                                      data: AttachmentFixtures.jpegWithMetadata(width: 400, height: 300)))
        let props = AttachmentFixtures.properties(of: prepared.data)
        #expect((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 400)
    }

    @Test("PDF conta páginas; texto é decodificado; formato desconhecido é recusado")
    func detectsKinds() throws {
        let preparer = AttachmentPreparer()
        let pdf = try preparer.prepare(RawAttachment(filename: "treino.pdf", data: AttachmentFixtures.pdf(pages: 3)))
        #expect(pdf.kind == .pdf)
        #expect(pdf.pageCount == 3)
        let text = try preparer.prepare(RawAttachment(filename: "dieta.md", data: Data("# Café\n2 ovos".utf8)))
        #expect(text.kind == .text)
        #expect(text.text == "# Café\n2 ovos")
        #expect(throws: AttachmentError.unsupportedType(filename: "x.bin")) {
            try preparer.prepare(RawAttachment(filename: "x.bin", data: Data([0, 1, 2, 0, 255])))
        }
        #expect(throws: AttachmentError.emptyFile(filename: "vazio.txt")) {
            try preparer.prepare(RawAttachment(filename: "vazio.txt", data: Data()))
        }
    }

    @Test("limite de 10 arquivos")
    func tooManyFiles() {
        let raws = (0 ..< 11).map { RawAttachment(filename: "\($0).txt", data: Data("a".utf8)) }
        #expect(throws: AttachmentError.tooManyFiles(max: 10)) { try AttachmentPreparer().prepare(raws) }
    }

    @Test("capacidades por provedor/modelo")
    func capabilities() {
        #expect(AttachmentCapabilities.resolve(provider: .anthropic, model: "claude-opus-5-5")
            == AttachmentCapabilities(supportsImages: true, supportsPDF: true))
        #expect(AttachmentCapabilities.resolve(provider: .openAI, model: "gpt-5-mini").supportsPDF)
        #expect(!AttachmentCapabilities.resolve(provider: .openAI, model: "gpt-3.5-turbo").supportsImages)
        #expect(!AttachmentCapabilities.resolve(provider: .chatGPT, model: "gpt-6").supportsPDF)
        #expect(!AttachmentCapabilities.resolve(provider: .custom, model: "llava").supportsPDF)
    }

    // MARK: Codificação

    @Test("PDF nativo quando o provedor aceita")
    func encodesNativePDF() throws {
        let pdf = try AttachmentPreparer().prepare(RawAttachment(filename: "t.pdf", data: AttachmentFixtures.pdf(pages: 2)))
        let output = try AttachmentEncoder.encode([pdf], capabilities: AttachmentCapabilities(supportsImages: true, supportsPDF: true))
        #expect(output.rasterizedPDFs == 0)
        #expect(output.parts.contains { if case .pdf("t.pdf", _) = $0 { true } else { false } })
    }

    @Test("sem PDF nativo: páginas viram JPEG (limite com aviso)")
    func rasterizesPDFWhenUnsupported() throws {
        let pdf = try AttachmentPreparer().prepare(RawAttachment(filename: "t.pdf", data: AttachmentFixtures.pdf(pages: 3)))
        let output = try AttachmentEncoder.encode([pdf], capabilities: AttachmentCapabilities(supportsImages: true, supportsPDF: false),
                                                  rasterizer: PDFRasterizer(maxPages: 2, maxPixels: 400))
        #expect(output.rasterizedPDFs == 1)
        let images = output.parts.compactMap { part -> Data? in
            if case let .image(mime, base64) = part, mime == "image/jpeg" { return Data(base64Encoded: base64) }
            return nil
        }
        #expect(images.count == 2)
        let props = AttachmentFixtures.properties(of: try #require(images.first))
        #expect((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 400)
        #expect(!output.parts.contains { if case .pdf = $0 { true } else { false } })
        #expect(output.warnings.count == 1)
        #expect(output.warnings.first?.contains("3") == true)
    }

    @Test("modelo sem imagens recusa foto e PDF rasterizado")
    func imagesNotSupported() throws {
        let image = try AttachmentPreparer().prepare(RawAttachment(filename: "a.jpg", data: AttachmentFixtures.jpegWithMetadata(width: 50, height: 50)))
        #expect(throws: AttachmentError.imagesNotSupported) {
            try AttachmentEncoder.encode([image], capabilities: AttachmentCapabilities(supportsImages: false, supportsPDF: false))
        }
    }

    // MARK: Fio por provedor

    private static let parts: [LLMContentPart] = [
        .text("[Arquivo: a.jpg (imagem)]"),
        .image(mimeType: "image/jpeg", base64: "QUJD"),
        .pdf(filename: "t.pdf", base64: "UERG"),
        .fileText(filename: "d.txt", text: "2 ovos"),
    ]

    @Test("OpenAI Chat Completions: image_url e file com data URL, texto por último")
    func openAIMapping() throws {
        let gateway = OpenAICompatibleChatGateway(configuration: EndpointConfiguration(
            provider: .openAI, baseURL: URL(string: "https://example.com/v1")!, auth: .bearer("k")))
        let request = ChatRequest(model: "gpt-5", messages: [.system("s"), .user("extraia", parts: Self.parts)])
        let urlRequest = try gateway.makeRequest(request, stream: false)
        let body = try JSONValue.parse(String(decoding: try #require(urlRequest.httpBody), as: UTF8.self))
        let content = try #require(body["messages"]?.arrayValue?[1]["content"]?.arrayValue)
        #expect(content.count == 5)
        #expect(content[1]["type"] == .string("image_url"))
        #expect(content[1]["image_url"]?["url"] == .string("data:image/jpeg;base64,QUJD"))
        #expect(content[2]["type"] == .string("file"))
        #expect(content[2]["file"]?["file_data"] == .string("data:application/pdf;base64,UERG"))
        #expect(content[2]["file"]?["filename"] == .string("t.pdf"))
        #expect(content[3]["text"]?.stringValue?.contains("2 ovos") == true)
        #expect(content[4] == .object(["type": .string("text"), "text": .string("extraia")]))
        // Mensagem sem anexos continua string simples.
        #expect(body["messages"]?.arrayValue?[0]["content"] == .string("s"))
    }

    @Test("Anthropic: blocos image/document base64 antes do texto")
    func anthropicMapping() throws {
        let wire = AnthropicMessagesGateway.wireMessages([.user("extraia", parts: Self.parts)])
        let blocks = try #require(wire.first?["content"]?.arrayValue)
        #expect(blocks.count == 5)
        #expect(blocks[1] == .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string("QUJD")])]))
        #expect(blocks[2]["type"] == .string("document"))
        #expect(blocks[2]["source"]?["media_type"] == .string("application/pdf"))
        #expect(blocks[2]["source"]?["data"] == .string("UERG"))
        #expect(blocks[2]["title"] == .string("t.pdf"))
        #expect(blocks[4] == .object(["type": .string("text"), "text": .string("extraia")]))
    }

    @Test("ChatGPT Responses: input_image/input_file/input_text")
    func chatGPTMapping() throws {
        let body = try ChatGPTResponsesGateway.body(for: ChatRequest(model: "gpt-6", messages: [.system("s"), .user("extraia", parts: Self.parts)]))
        let content = try #require(body["input"]?.arrayValue?.first?["content"]?.arrayValue)
        #expect(content[1] == .object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64,QUJD")]))
        #expect(content[2] == .object(["type": .string("input_file"), "filename": .string("t.pdf"),
                                       "file_data": .string("data:application/pdf;base64,UERG")]))
        #expect(content.last == .object(["type": .string("input_text"), "text": .string("extraia")]))
    }

    @Test("anexos nunca entram no Codable da mensagem (nem histórico, nem backup)")
    func partsAreNotEncoded() throws {
        let message = LLMMessage.user("oi", parts: Self.parts)
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(!json.contains("QUJD"))
        #expect(!json.contains("parts"))
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: Data(json.utf8))
        #expect(decoded.parts.isEmpty)
        #expect(decoded.content == "oi")
    }
}
