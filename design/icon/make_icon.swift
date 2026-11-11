// Gera os PNGs do ícone do FitJourney (DESIGN_DIRECTION §2.6).
//
// Uso, a partir da raiz do repositório:
//   swift design/icon/make_icon.swift
//
// Motivo: "degraus" — um caminho que sobe em três degraus até um ponto (a meta). Jornada + progressão de carga.
// Saídas (1024 × 1024):
//   FitJourney/Assets.xcassets/AppIcon.appiconset/AppIcon.png          claro: branco sobre laranja
//   FitJourney/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png     escuro: laranja sobre quase-preto
//   FitJourney/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png   tinted: cinza sobre preto (o sistema tinge)
//   FitJourneyWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png     relógio: motivo reduzido para a máscara circular
//   design/icon/preview-*.png                                          cópias com máscara, só para conferência

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

struct Variant {
    let backgroundTop: UInt32
    let backgroundBottom: UInt32
    let glyphTop: UInt32
    let glyphBottom: UInt32
    /// Brilho suave no canto superior (só no claro e no relógio).
    let glow: Bool
    /// Escala do motivo em torno do centro (o relógio corta em círculo).
    let glyphScale: CGFloat
}

let light = Variant(backgroundTop: 0xFF8B2B, backgroundBottom: 0xDB430A, glyphTop: 0xFFFFFF, glyphBottom: 0xFFFFFF, glow: true, glyphScale: 1)
let dark = Variant(backgroundTop: 0x26262A, backgroundBottom: 0x0D0D0F, glyphTop: 0xFFA347, glyphBottom: 0xEE5A12, glow: false, glyphScale: 1)
let tinted = Variant(backgroundTop: 0x000000, backgroundBottom: 0x000000, glyphTop: 0xFFFFFF, glyphBottom: 0xB4B4B4, glow: false, glyphScale: 1)
let watch = Variant(backgroundTop: 0xFF8B2B, backgroundBottom: 0xDB430A, glyphTop: 0xFFFFFF, glyphBottom: 0xFFFFFF, glow: true, glyphScale: 0.8)

/// O motivo em coordenadas de tela (origem no canto superior esquerdo), como contorno preenchível.
func glyphPath() -> CGPath {
    let stroke: CGFloat = 92
    let steps = CGMutablePath()
    steps.move(to: CGPoint(x: 238, y: 770))
    steps.addLine(to: CGPoint(x: 420, y: 770))
    steps.addLine(to: CGPoint(x: 420, y: 600))
    steps.addLine(to: CGPoint(x: 602, y: 600))
    steps.addLine(to: CGPoint(x: 602, y: 430))
    steps.addLine(to: CGPoint(x: 786, y: 430))
    let outline = steps.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let path = CGMutablePath()
    path.addPath(outline)
    path.addEllipse(in: CGRect(x: 706 - 66, y: 284 - 66, width: 132, height: 132))
    return path
}

func render(_ v: Variant) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    // Coordenadas de tela: y cresce para baixo.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)

    let background = CGGradient(colorsSpace: space, colors: [rgb(v.backgroundTop), rgb(v.backgroundBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: 0, y: side), options: [])
    if v.glow {
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFD08A, 0.55), rgb(0xFFD08A, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 760, y: 150), startRadius: 0, endCenter: CGPoint(x: 760, y: 150), endRadius: 620, options: [])
    }

    ctx.saveGState()
    ctx.translateBy(x: side / 2, y: side / 2)
    ctx.scaleBy(x: v.glyphScale, y: v.glyphScale)
    ctx.translateBy(x: -side / 2, y: -side / 2)
    let path = glyphPath()
    if v.glow {
        // Sombra curta para destacar o branco do laranja claro do topo.
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0x7A1F00, 0.28))
        ctx.addPath(path)
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath(using: .winding)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
    ctx.addPath(path)
    ctx.clip(using: .winding)
    let fill = CGGradient(colorsSpace: space, colors: [rgb(v.glyphTop), rgb(v.glyphBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 218), end: CGPoint(x: 0, y: 816), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// Cópia com a máscara aproximada do sistema, para conferir margens (não vai para o catálogo).
func masked(_ image: CGImage, circle: Bool) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    ctx.addPath(circle ? CGPath(ellipseIn: rect, transform: nil) : CGPath(roundedRect: rect, cornerWidth: 230, cornerHeight: 230, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("não foi possível criar \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("não foi possível gravar \(path)") }
    print("gravado \(path)")
}

let ios = "FitJourney/Assets.xcassets/AppIcon.appiconset"
let watchOS = "FitJourneyWatch/Assets.xcassets/AppIcon.appiconset"
let lightImage = render(light), darkImage = render(dark), tintedImage = render(tinted), watchImage = render(watch)
write(lightImage, to: "\(ios)/AppIcon.png")
write(darkImage, to: "\(ios)/AppIcon-Dark.png")
write(tintedImage, to: "\(ios)/AppIcon-Tinted.png")
write(watchImage, to: "\(watchOS)/AppIcon.png")
write(masked(lightImage, circle: false), to: "design/icon/preview-light.png")
write(masked(darkImage, circle: false), to: "design/icon/preview-dark.png")
write(masked(tintedImage, circle: false), to: "design/icon/preview-tinted.png")
write(masked(watchImage, circle: true), to: "design/icon/preview-watch.png")
