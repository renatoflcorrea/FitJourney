// Gera a OPÇÃO "vidro" do ícone do FitJourney (alternativa ao ícone atual; não toca nos catálogos do app).
//
// Uso, de qualquer pasta (as saídas vão sempre para a pasta deste arquivo; leva uns 25 s):
//   swift -O design/icon/glass/make_icon_glass.swift
// Sem o `-O` também funciona, mas é um sombreador por pixel e leva minutos. O resultado é determinístico.
// Só lê o ícone atual (FitJourney/Assets.xcassets) para as prévias de comparação; não grava nada fora desta pasta.
//
// Motivo: os mesmos "degraus" do ícone atual (design/icon/make_icon.swift, DESIGN_DIRECTION §2.6), agora como uma
// peça de vidro leitoso grosso sobre o mesmo gradiente laranja. O vidro não é um branco com opacidade: é um
// sombreador por pixel em cima de um campo de distância (SDF) da forma:
//   1. SDF da forma → perfil de altura (quina arredondada + leve abaulado) → normais;
//   2. refração: cada pixel do vidro amostra o fundo (já com sombra e cáustica) deslocado pela inclinação da superfície;
//   3. parede de vidro limpo na borda (deixa ver e concentra o laranja) e miolo leitoso, mais ralo e dourado do lado
//      por onde a luz sai;
//   4. luz de cima à esquerda: especular na quina, fio de luz na borda, brilho de saída na parede oposta;
//   5. no fundo: sombra de contato, sombra ampla tingida de laranja queimado e a cáustica da luz que atravessa a peça.
//
// Saídas (em design/icon/glass/):
//   AppIcon-glass.png            1024, opaco, sem máscara — claro (padrão)
//   AppIcon-glass-dark.png       escuro: vidro laranja sobre quase-preto
//   AppIcon-glass-tinted.png     tinted: vidro em tons de cinza sobre preto (o sistema tinge)
//   AppIcon-glass-watch.png      relógio: motivo a 80% para a máscara circular
//   AppIcon-glass-alt.png        segunda direção: degraus como cápsulas de vidro sobrepostas
//   preview-*.png                conferência com máscara, comparação e tamanhos pequenos
//   layers/*.png, layers/*.svg   camadas separadas para montar o .icon no Icon Composer

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>

// MARK: - Base

let side = 1024
/// Superamostragem: tudo é calculado em 2048 × 2048 e reduzido no fim.
let ss = 2
let W = side * ss
let pixelCount = W * W
let center = V2(512, 512)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

final class Buffer<T> {
    let p: UnsafeMutablePointer<T>
    let count: Int
    init(_ count: Int, _ value: T) {
        self.count = count
        p = .allocate(capacity: count)
        p.initialize(repeating: value, count: count)
    }
    deinit { p.deallocate() }
    func copy() -> Buffer<T> {
        let other = Buffer(count, p[0])
        other.p.update(from: p, count: count)
        return other
    }
}

func hex(_ value: UInt32) -> V3 {
    V3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
}

func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func clamp01(_ x: Float) -> Float { max(0, min(1, x)) }
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}

// MARK: - Geometria (unidades de 1024, origem no canto superior esquerdo)

/// Traço mais grosso que o do ícone atual (108 contra 92): o vidro perde a faixa da borda para o chanfro.
let halfStroke: Float = 54
let stairPoints: [V2] = [V2(233, 773), V2(419, 773), V2(419, 599), V2(605, 599), V2(605, 425), V2(791, 425)]
let dotCenter = V2(712, 269)
let dotRadius: Float = 74
/// Raio do arredondamento dos cantos internos dos degraus (peça moldada, não recortada).
let filletRadius: Float = 20

func sdSegment(_ p: V2, _ a: V2, _ b: V2) -> Float {
    let pa = p - a, ba = b - a
    let h = clamp01(simd_dot(pa, ba) / simd_dot(ba, ba))
    return simd_length(pa - ba * h)
}

func sdBox(_ p: V2, _ half: V2) -> Float {
    let q = simd_abs(p) - half
    return simd_length(simd_max(q, V2(0, 0))) + min(max(q.x, q.y), 0)
}

/// Degraus inteiros: traço com pontas e cantos redondos, com os cantos internos arredondados.
/// É a distância exata por dentro e por fora (as curvas de nível contornam o canto sem vinco), o que o chanfro exige.
func sdStairs(_ p: V2) -> Float {
    var d = Float.greatestFiniteMagnitude
    for i in 0..<(stairPoints.count - 1) {
        d = min(d, sdSegment(p, stairPoints[i], stairPoints[i + 1]))
    }
    d -= halfStroke
    let reach = filletRadius + halfStroke
    for i in 1..<(stairPoints.count - 1) {
        let v = stairPoints[i]
        let a = simd_normalize(v - stairPoints[i - 1]), b = simd_normalize(stairPoints[i + 1] - v)
        let n = b - a // aponta para o lado côncavo; componentes ±1
        let arcCenter = v + n * reach
        // Coordenadas do canto: (0,0) no centro do arco, crescendo para dentro da peça até o vértice do traço.
        let q = (arcCenter - p) * n
        if q.x >= 0, q.y >= 0, q.x <= reach, q.y <= reach {
            d = max(filletRadius - simd_length(q), max(q.x, q.y) - reach - halfStroke)
        }
    }
    return d
}

func sdDot(_ p: V2) -> Float { simd_length(p - dotCenter) - dotRadius }

struct Piece {
    let name: String
    /// Distância com sinal em unidades do glifo (negativa dentro).
    let sdf: (V2) -> Float
    /// Largura da parede: a faixa de vidro limpo entre a borda e o miolo leitoso (é a espessura que se vê).
    let wall: Float
    /// Meia-largura da peça, para o abaulado do miolo.
    let halfWidth: Float
    /// Quanto do perfil é abaulado (0 = placa de topo plano, 1 = lente).
    let dome: Float
    /// Espessura: escala as inclinações (refração e luz).
    let thickness: Float
}

// MARK: - Estilo

struct Style {
    var backgroundTop: UInt32
    var backgroundBottom: UInt32
    var glow: Bool
    var glyphScale: Float = 1

    /// Direção da luz (x, y de tela; z para o observador). Vem de cima, um pouco da esquerda.
    var light = V3(-0.40, -0.78, 0.60)

    /// Miolo leitoso: cor e quantidade no lado da luz e no lado oposto do motivo.
    var milkTop: V3
    var milkBottom: V3
    var milkAmountTop: Float
    var milkAmountBottom: Float
    /// Fração do leitoso que resta na parede (0 = parede totalmente limpa).
    var milkWall: Float
    /// Do lado oposto à luz o miolo fica mais ralo e pega a cor do fundo: fração do leitoso que resta e a cor que ele toma.
    var milkFar: Float
    var milkFarColor: V3
    /// A parede vista de lado concentra a cor do fundo (multiplica).
    var wallTint: V3
    var wallTintAmount: Float

    /// Deslocamento máximo da amostra refratada, em unidades do glifo.
    var refraction: Float = 52
    /// Escurecimento da parede no lado da luz (vê-se o "chão" escuro através dela) e do miolo que dá as costas à luz.
    var wallShade: Float = 0.04
    /// Clareia a parede do lado da luz com a cor do brilho de saída (só no claro, para ela não virar contorno escuro).
    var wallLift: Float = 0
    var shadeAmount: Float = 0.10
    /// Clareamento do miolo voltado para a luz.
    var litColor = V3(1, 1, 1)
    var litAmount: Float = 0.6
    /// Especular largo (chanfro) e reflexo duro (ponto de luz).
    var specularPower: Float = 22
    var specularAmount: Float = 0.85
    var glintPower: Float = 140
    var glintAmount: Float = 1.0
    /// Fio de luz na borda de fora: largura e intensidades (base, lado da luz, lado oposto).
    var rimColor = V3(1, 1, 1)
    var rimWidth: Float = 2.6
    var rimBase: Float = 0.34
    var rimLight: Float = 0.80
    var rimBack: Float = 0.50
    /// Segundo fio, onde a parede encontra o topo (é ele que dá a leitura de placa grossa).
    var innerRim: Float = 0.22
    /// Brilho de saída: a luz que atravessa o vidro acende a parede do lado oposto com a cor do fundo.
    var exitGlowColor: V3
    var exitGlowAmount: Float

    /// Sombra sobre o fundo (multiplica) — contato e ampla.
    var shadowTint: V3
    var contactShadow: Float = 0.46
    var wideShadow: Float = 0.36
    /// Cáustica: luz concentrada que cai no fundo logo depois da borda oposta à luz.
    var causticColor = V3(0, 0, 0)
    var causticAmount: Float = 0
    /// Halo colorido em volta (só no escuro: o vidro laranja "acende" o fundo).
    var haloColor = V3(0, 0, 0)
    var haloAmount: Float = 0
}

var lightStyle: Style = {
    var s = Style(
        backgroundTop: 0xFF8B2B, backgroundBottom: 0xDB430A, glow: true,
        milkTop: hex(0xFFFFFF), milkBottom: hex(0xFFF3E6), milkAmountTop: 0.97, milkAmountBottom: 0.87, milkWall: 0.06,
        milkFar: 0.60, milkFarColor: hex(0xFFD08A),
        wallTint: hex(0xFFA04A), wallTintAmount: 0.42,
        exitGlowColor: hex(0xFFD79A), exitGlowAmount: 0.85,
        shadowTint: hex(0x8A2A04)
    )
    s.wallLift = 0.24
    s.causticColor = hex(0xFFC774)
    s.causticAmount = 0.42
    return s
}()

var darkStyle: Style = {
    var s = Style(
        backgroundTop: 0x26262A, backgroundBottom: 0x0D0D0F, glow: false,
        milkTop: hex(0xFFA347), milkBottom: hex(0xEE5A12), milkAmountTop: 0.97, milkAmountBottom: 0.93, milkWall: 0.62,
        milkFar: 0.82, milkFarColor: hex(0xC63A06),
        wallTint: hex(0xD14A0C), wallTintAmount: 0.40,
        exitGlowColor: hex(0xFFC27A), exitGlowAmount: 0.80,
        shadowTint: hex(0x000000)
    )
    s.litColor = hex(0xFFD9A8)
    s.litAmount = 0.7
    s.rimColor = hex(0xFFE9CF)
    s.specularAmount = 0.6
    s.contactShadow = 0.55
    s.wideShadow = 0.40
    s.causticColor = hex(0xFF6A14)
    s.causticAmount = 0.30
    s.haloColor = hex(0xFF6A14)
    s.haloAmount = 0.09
    return s
}()

var tintedStyle: Style = {
    var s = Style(
        backgroundTop: 0x000000, backgroundBottom: 0x000000, glow: false,
        milkTop: hex(0xFFFFFF), milkBottom: hex(0xD2D2D2), milkAmountTop: 1, milkAmountBottom: 1, milkWall: 0.45,
        milkFar: 0.94, milkFarColor: hex(0x9E9E9E),
        wallTint: hex(0x8C8C8C), wallTintAmount: 0.45,
        exitGlowColor: hex(0xFFFFFF), exitGlowAmount: 0.55,
        shadowTint: hex(0x000000)
    )
    s.contactShadow = 0
    s.wideShadow = 0
    return s
}()

var watchStyle: Style = {
    var s = lightStyle
    s.glyphScale = 0.8
    return s
}()

// MARK: - Fundo

func background(_ style: Style) -> Buffer<V3> {
    let out = Buffer<V3>(pixelCount, V3(0, 0, 0))
    let top = hex(style.backgroundTop), bottom = hex(style.backgroundBottom)
    let glowColor = hex(0xFFD08A), glowCenter = V2(760, 150)
    for j in 0..<W {
        let y = (Float(j) + 0.5) / Float(ss)
        for i in 0..<W {
            let x = (Float(i) + 0.5) / Float(ss)
            var c = mix(top, bottom, y / Float(side))
            if style.glow {
                let a = 0.55 * max(0, 1 - simd_length(V2(x, y) - glowCenter) / 620)
                c = mix(c, glowColor, a)
            }
            out.p[j * W + i] = c
        }
    }
    return out
}

// MARK: - Campos da peça

struct Field {
    /// Distância com sinal, em unidades do glifo.
    let distance: Buffer<Float>
    /// Altura normalizada 0…1, já suavizada.
    let height: Buffer<Float>
}

func gaussianBlur(_ buffer: Buffer<Float>, sigma: Float) {
    let radius = Int((sigma * 3).rounded(.up))
    guard radius > 0 else { return }
    var kernel = [Float](repeating: 0, count: 2 * radius + 1)
    var sum: Float = 0
    for k in -radius...radius {
        let w = exp(-Float(k * k) / (2 * sigma * sigma))
        kernel[k + radius] = w
        sum += w
    }
    for k in 0..<kernel.count { kernel[k] /= sum }
    let tmp = Buffer<Float>(pixelCount, 0)
    kernel.withUnsafeBufferPointer { kp in
        for j in 0..<W {
            for i in 0..<W {
                var acc: Float = 0
                for k in -radius...radius {
                    acc += buffer.p[j * W + min(W - 1, max(0, i + k))] * kp[k + radius]
                }
                tmp.p[j * W + i] = acc
            }
        }
        for j in 0..<W {
            for i in 0..<W {
                var acc: Float = 0
                for k in -radius...radius {
                    acc += tmp.p[min(W - 1, max(0, j + k)) * W + i] * kp[k + radius]
                }
                buffer.p[j * W + i] = acc
            }
        }
    }
}

func makeField(_ piece: Piece, scale: Float) -> Field {
    let distance = Buffer<Float>(pixelCount, 0)
    let height = Buffer<Float>(pixelCount, 0)
    for j in 0..<W {
        for i in 0..<W {
            let canvasPoint = V2((Float(i) + 0.5) / Float(ss), (Float(j) + 0.5) / Float(ss))
            let d = piece.sdf((canvasPoint - center) / scale + center)
            distance.p[j * W + i] = d
            let t = -d
            guard t > 0 else { continue }
            let e = 1 - clamp01(t / piece.wall)
            let rim = (1 - e * e).squareRoot() // quarto de círculo: quina arredondada da placa
            let lens = sin(clamp01(t / piece.halfWidth) * .pi / 2)
            height.p[j * W + i] = mix(rim, lens, piece.dome)
        }
    }
    // Suaviza o encontro da quina com o topo para a luz correr contínua pela peça.
    gaussianBlur(height, sigma: 2.2 * Float(ss) * scale)
    return Field(distance: distance, height: height)
}

// MARK: - Sombra

func applyShadow(_ canvas: Buffer<V3>, _ field: Field, _ style: Style) {
    let k = Float(ss) * style.glyphScale
    func shifted(_ i: Int, _ j: Int, _ dx: Float, _ dy: Float) -> Float {
        field.distance.p[min(W - 1, max(0, j - Int((dy * k).rounded()))) * W + min(W - 1, max(0, i - Int((dx * k).rounded())))]
    }
    for j in 0..<W {
        for i in 0..<W {
            let idx = j * W + i
            var c = canvas.p[idx]
            // Ampla e macia, para baixo e um pouco à direita (a luz vem de cima à esquerda).
            let wide = (1 - smoothstep(-26, 78, shifted(i, j, 9, 34))) * style.wideShadow
            if wide > 0 { c = mix(c, c * style.shadowTint, wide) }
            // Cáustica: a luz atravessa a peça e cai concentrada perto da borda oposta, dentro da sombra.
            if style.causticAmount > 0 {
                let caustic = (1 - smoothstep(-16, 5, shifted(i, j, 5, 15))) * style.causticAmount
                c = c + (V3(1, 1, 1) - c) * style.causticColor * caustic
            }
            // Contato: linha curta e escura que assenta a peça no fundo.
            let contact = (1 - smoothstep(-3, 9, shifted(i, j, 1.5, 4))) * style.contactShadow
            if contact > 0 { c = mix(c, c * style.shadowTint, contact) }
            if style.haloAmount > 0 {
                let halo = style.haloAmount * exp(-max(field.distance.p[idx], 0) / 60)
                c = c + (V3(1, 1, 1) - c) * style.haloColor * halo
            }
            canvas.p[idx] = c
        }
    }
}

// MARK: - Vidro

func sample(_ buffer: Buffer<V3>, _ x: Float, _ y: Float) -> V3 {
    let fx = min(Float(W - 1), max(0, x * Float(ss) - 0.5)), fy = min(Float(W - 1), max(0, y * Float(ss) - 0.5))
    let x0 = Int(fx), y0 = Int(fy)
    let x1 = min(W - 1, x0 + 1), y1 = min(W - 1, y0 + 1)
    let tx = fx - Float(x0), ty = fy - Float(y0)
    let top = mix(buffer.p[y0 * W + x0], buffer.p[y0 * W + x1], tx)
    let bottom = mix(buffer.p[y1 * W + x0], buffer.p[y1 * W + x1], tx)
    return mix(top, bottom, ty)
}

/// Camadas separadas (pré-multiplicadas), para exportar.
final class Layers {
    let glass = Buffer<V4>(pixelCount, V4(0, 0, 0, 0))
    let highlights = Buffer<V4>(pixelCount, V4(0, 0, 0, 0))
}

func shadeGlass(_ canvas: Buffer<V3>, _ field: Field, _ piece: Piece, _ style: Style, _ layers: Layers?) {
    let behind = canvas.copy()
    let scale = style.glyphScale
    let unit = 1 / (Float(ss) * scale) // unidades do glifo por pixel superamostrado
    let light = simd_normalize(style.light)
    let light2 = simd_normalize(V2(style.light.x, style.light.y))
    let halfVector = simd_normalize(light + V3(0, 0, 1))
    let white = V3(1, 1, 1)

    for j in 1..<(W - 1) {
        for i in 1..<(W - 1) {
            let idx = j * W + i
            let d = field.distance.p[idx]
            let coverage = clamp01(0.5 - d / unit)
            if coverage <= 0 { continue }

            let hx = (field.height.p[idx + 1] - field.height.p[idx - 1]) / (2 * unit)
            let hy = (field.height.p[idx + W] - field.height.p[idx - W]) / (2 * unit)
            let slope = V2(-hx, -hy) * piece.thickness // aponta para fora da peça
            let normal = simd_normalize(V3(slope.x, slope.y, 1))
            var outward = V2(field.distance.p[idx + 1] - field.distance.p[idx - 1], field.distance.p[idx + W] - field.distance.p[idx - W])
            let outwardLength = simd_length(outward)
            outward = outwardLength > 1e-6 ? outward / outwardLength : V2(0, 0)

            let canvasPoint = V2((Float(i) + 0.5) / Float(ss), (Float(j) + 0.5) / Float(ss))
            let glyphPoint = (canvasPoint - center) / scale + center
            // 0 no lado da luz, 1 no lado oposto, ao longo do motivo inteiro.
            let along = clamp01(0.5 - simd_dot(glyphPoint - center, light2) / 640)
            let t = -d
            // 0 na parede limpa, 1 no miolo leitoso.
            let core = smoothstep(piece.wall * 0.35, piece.wall * 1.35, t)
            // +1 na borda voltada para a luz, −1 na borda oposta.
            let facing = simd_dot(outward, light2)
            // Posição através da peça: 1 no lado por onde a luz entra, 0 no lado por onde sai.
            let lit = smoothstep(-0.92, 0.05, facing * (1 - clamp01(t / piece.halfWidth)))

            // Refração: a superfície inclinada para fora dobra o raio para dentro da peça.
            var displacement = -slope * style.refraction
            let displacementLength = simd_length(displacement)
            if displacementLength > style.refraction { displacement *= style.refraction / displacementLength }
            displacement *= scale
            var color = sample(behind, canvasPoint.x + displacement.x, canvasPoint.y + displacement.y)

            // Parede vista de lado: concentra a cor do fundo; no lado da luz deixa ver o chão sombreado.
            color = color * mix(white, style.wallTint * 1.3, (1 - core) * style.wallTintAmount)
            color = color * (1 - style.wallShade * (1 - core) * max(facing, 0))
            color = color + (white - color) * style.exitGlowColor * (style.wallLift * (1 - core) * max(facing, 0))
            // Miolo leitoso.
            let milk = mix(style.milkAmountTop, style.milkAmountBottom, along) * mix(style.milkWall, 1, core) * mix(style.milkFar, 1, lit)
            // Na parede e do lado por onde a luz sai, o leitoso toma a cor "de longe" (mais densa).
            color = mix(color, mix(style.milkFarColor, mix(style.milkTop, style.milkBottom, along), lit * mix(0.25, 1, core)), milk)
            // O abaulado do miolo dá as costas para a luz na metade de baixo: sombra interna suave.
            let lambert = simd_dot(normal, light) - light.z
            if lambert < 0 { color = color * max(0, 1 + style.shadeAmount * lambert * core) }

            // Realces, acumulados como uma camada própria (pré-multiplicada).
            var hc = V3(0, 0, 0)
            var ha: Float = 0
            if lambert > 0 {
                let a = clamp01(lambert * style.litAmount * core)
                hc = hc * (1 - a) + style.litColor * a
                ha = ha * (1 - a) + a
            }
            do { // luz que sai pela parede oposta
                let band = smoothstep(0, piece.wall * 0.35, t) * (1 - smoothstep(piece.wall * 0.6, piece.wall * 1.25, t))
                let a = clamp01(style.exitGlowAmount * band * pow(max(-facing, 0), 1.2))
                hc = hc * (1 - a) + style.exitGlowColor * a
                ha = ha * (1 - a) + a
            }
            do { // especular largo na quina voltada para a luz
                let a = clamp01(pow(max(simd_dot(normal, halfVector), 0), style.specularPower) * style.specularAmount * (1 - core * 0.7))
                hc = hc * (1 - a) + white * a
                ha = ha * (1 - a) + a
            }
            do { // reflexo duro
                let a = clamp01(pow(max(simd_dot(normal, halfVector), 0), style.glintPower) * style.glintAmount)
                hc = hc * (1 - a) + white * a
                ha = ha * (1 - a) + a
            }
            do { // fio de luz onde a parede encontra o topo
                let x = (t - piece.wall * 0.92) / 2.4
                let a = clamp01(exp(-x * x) * style.innerRim * (0.35 + 0.65 * max(facing, 0)))
                hc = hc * (1 - a) + style.rimColor * a
                ha = ha * (1 - a) + a
            }
            do { // fio de luz na borda de fora
                let line = exp(-(t / style.rimWidth) * (t / style.rimWidth))
                let strength = style.rimBase + style.rimLight * pow(max(facing, 0), 1.3) + style.rimBack * pow(max(-facing, 0), 2.2)
                let a = clamp01(line * strength)
                hc = hc * (1 - a) + style.rimColor * a
                ha = ha * (1 - a) + a
            }

            let final = color * (1 - ha) + hc
            canvas.p[idx] = mix(behind.p[idx], final, coverage)

            if let layers {
                let g = layers.glass.p[idx]
                layers.glass.p[idx] = g * (1 - coverage) + V4(color.x, color.y, color.z, 1) * coverage
                let k = layers.highlights.p[idx], a = ha * coverage
                layers.highlights.p[idx] = k * (1 - a) + V4(hc.x, hc.y, hc.z, ha) * coverage
            }
        }
    }
}

// MARK: - Direções

/// Principal: uma peça só para os degraus (cantos internos moldados) e uma conta de vidro para a meta.
let monolith: [Piece] = [
    Piece(name: "degraus", sdf: sdStairs, wall: 16, halfWidth: halfStroke, dome: 0.20, thickness: 30),
    Piece(name: "meta", sdf: sdDot, wall: 18, halfWidth: dotRadius, dome: 0.55, thickness: 46),
]

/// Alternativa: cada lance é uma cápsula de vidro; onde se sobrepõem o leitoso se soma (como as pétalas do Fotos).
let capsules: [Piece] = (0..<(stairPoints.count - 1)).map { i in
    let a = stairPoints[i], b = stairPoints[i + 1]
    return Piece(name: "lance-\(i + 1)", sdf: { sdSegment($0, a, b) - halfStroke }, wall: 15, halfWidth: halfStroke, dome: 0.20, thickness: 28)
} + [Piece(name: "meta", sdf: sdDot, wall: 18, halfWidth: dotRadius, dome: 0.55, thickness: 46)]

struct Rendered {
    let canvas: Buffer<V3>
    let background: Buffer<V3>
    let shadowed: Buffer<V3>?
    let layers: Layers?
}

/// `stacked`: cada peça projeta sombra nas de baixo (direção das cápsulas). Senão, todas as sombras vão no fundo.
func render(_ style: Style, _ pieces: [Piece], stacked: Bool, wantLayers: Bool = false) -> Rendered {
    let canvas = background(style)
    let bg = canvas.copy()
    let layers = wantLayers ? Layers() : nil
    var shadowed: Buffer<V3>?
    if stacked {
        var stackedStyle = style
        // Cada lâmina sozinha é mais rala; onde duas se sobrepõem o leitoso se soma.
        stackedStyle.milkAmountTop = 0.80
        stackedStyle.milkAmountBottom = 0.80
        stackedStyle.milkFar = 0.72
        stackedStyle.refraction = 26 // menos desvio: a borda da lâmina de baixo não ondula vista pela de cima
        stackedStyle.wideShadow *= 0.55
        stackedStyle.contactShadow *= 0.6
        stackedStyle.causticAmount *= 0.5
        for piece in pieces {
            let field = makeField(piece, scale: style.glyphScale)
            applyShadow(canvas, field, stackedStyle)
            shadeGlass(canvas, field, piece, stackedStyle, layers)
        }
    } else {
        let fields = pieces.map { makeField($0, scale: style.glyphScale) }
        for field in fields { applyShadow(canvas, field, style) }
        shadowed = canvas.copy()
        for (piece, field) in zip(pieces, fields) { shadeGlass(canvas, field, piece, style, layers) }
    }
    return Rendered(canvas: canvas, background: bg, shadowed: shadowed, layers: layers)
}

// MARK: - Saída

/// Ruído determinístico de ±0,5 nível, para o gradiente não fazer faixas em 8 bits.
func dither(_ x: Int, _ y: Int, _ c: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ c &* 83_492_791)
    h ^= h >> 13
    h = h &* 0x5BD1_E995
    h ^= h >> 15
    return Float(h & 0xFFFF) / 65_535 - 0.5
}

func image(_ buffer: Buffer<V3>) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    let weight = 1 / Float(ss * ss)
    for y in 0..<side {
        for x in 0..<side {
            var acc = V3(0, 0, 0)
            for sy in 0..<ss { for sx in 0..<ss { acc += buffer.p[(y * ss + sy) * W + x * ss + sx] } }
            acc *= weight
            for c in 0..<3 {
                bytes[(y * side + x) * 4 + c] = UInt8(max(0, min(255, (acc[c] * 255 + dither(x, y, c)).rounded())))
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

func image(premultiplied buffer: Buffer<V4>) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    let weight = 1 / Float(ss * ss)
    for y in 0..<side {
        for x in 0..<side {
            var acc = V4(0, 0, 0, 0)
            for sy in 0..<ss { for sx in 0..<ss { acc += buffer.p[(y * ss + sy) * W + x * ss + sx] } }
            acc *= weight
            for c in 0..<4 {
                bytes[(y * side + x) * 4 + c] = UInt8(max(0, min(255, (min(acc[c], acc[3]) * 255).rounded())))
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

/// Camada (pré-multiplicada) que, composta sobre `under`, dá `over`. Serve para a sombra (e o halo do escuro).
func difference(under: Buffer<V3>, over: Buffer<V3>) -> Buffer<V4> {
    let out = Buffer<V4>(pixelCount, V4(0, 0, 0, 0))
    for idx in 0..<pixelCount {
        let b = under.p[idx], s = over.p[idx]
        var alpha: Float = 0
        for c in 0..<3 {
            if b[c] > 1e-4 { alpha = max(alpha, 1 - s[c] / b[c]) }
            if b[c] < 1 - 1e-4 { alpha = max(alpha, (s[c] - b[c]) / (1 - b[c])) }
        }
        alpha = clamp01(alpha)
        if alpha < 1e-4 { continue }
        let p = s - b * (1 - alpha)
        out.p[idx] = V4(max(0, p.x), max(0, p.y), max(0, p.z), alpha)
    }
    return out
}

let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = outputDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func write(_ image: CGImage, _ name: String) {
    let url = outputDirectory.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("não foi possível criar \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("não foi possível gravar \(url.path)") }
    print("gravado \(url.path)")
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Prévias

func color(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, alpha]
    )!
}

func context(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    return ctx
}

/// Máscara do ícone do iOS, aproximada por uma superelipse (n = 5), ou o círculo do watchOS.
func maskPath(in rect: CGRect, circle: Bool) -> CGPath {
    if circle { return CGPath(ellipseIn: rect, transform: nil) }
    let path = CGMutablePath()
    let n = 5.0, steps = 720
    for k in 0..<steps {
        let angle = Double(k) / Double(steps) * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + CGFloat(x) * rect.width / 2, y: rect.midY + CGFloat(y) * rect.height / 2)
        if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(_ ctx: CGContext, _ icon: CGImage, in rect: CGRect, circle: Bool = false) {
    ctx.saveGState()
    ctx.addPath(maskPath(in: rect, circle: circle))
    ctx.clip()
    ctx.draw(icon, in: rect)
    ctx.restoreGState()
}

func masked(_ icon: CGImage, circle: Bool = false) -> CGImage {
    let ctx = context(side, side)
    drawIcon(ctx, icon, in: CGRect(x: 0, y: 0, width: side, height: side), circle: circle)
    return ctx.makeImage()!
}

func drawText(_ ctx: CGContext, _ string: String, centerX: CGFloat, baseline: CGFloat, size: CGFloat, color: CGColor, bold: Bool = false) {
    let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: centerX - width / 2, y: baseline)
    CTLineDraw(line, ctx)
}

/// Vários ícones lado a lado, com rótulo, sobre um fundo neutro.
func comparison(_ items: [(String, CGImage, Bool)], iconSide: CGFloat = 640) -> CGImage {
    let gap: CGFloat = 72, margin: CGFloat = 72, labelHeight: CGFloat = 84
    let width = margin * 2 + iconSide * CGFloat(items.count) + gap * CGFloat(items.count - 1)
    let height = margin * 2 + iconSide + labelHeight
    let ctx = context(Int(width), Int(height))
    ctx.setFillColor(color(0xECECF0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (k, item) in items.enumerated() {
        let x = margin + CGFloat(k) * (iconSide + gap)
        drawIcon(ctx, item.1, in: CGRect(x: x, y: margin + labelHeight, width: iconSide, height: iconSide), circle: item.2)
        drawText(ctx, item.0, centerX: x + iconSide / 2, baseline: margin + 14, size: 40, color: color(0x1C1C1E), bold: true)
    }
    return ctx.makeImage()!
}

/// Simulação da tela inicial: cada linha é um ícone nos tamanhos reais em pixels (60 pt @3x, @2x; 29 pt @3x, @2x).
func sizes(rows: [(String, CGImage)], wallpaperTop: UInt32, wallpaperBottom: UInt32, ink: UInt32) -> CGImage {
    let pixels: [CGFloat] = [180, 120, 87, 58]
    let rowHeight: CGFloat = 250, margin: CGFloat = 48, labelColumn: CGFloat = 190
    let width: CGFloat = 900, height = margin * 2 + rowHeight * CGFloat(rows.count)
    let ctx = context(Int(width), Int(height))
    let wallpaper = CGGradient(colorsSpace: space, colors: [color(wallpaperTop), color(wallpaperBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wallpaper, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    for (r, row) in rows.enumerated() {
        let rowBottom = height - margin - rowHeight * CGFloat(r + 1)
        drawText(ctx, row.0, centerX: margin + labelColumn / 2 - 10, baseline: rowBottom + 130, size: 24, color: color(ink), bold: true)
        var x = margin + labelColumn
        for size in pixels {
            let rect = CGRect(x: x, y: rowBottom + 50 + (180 - size) / 2, width: size, height: size)
            // Reduz primeiro para o tamanho exato em pixels, como o sistema faz, e só então aplica a máscara.
            let small = context(Int(size), Int(size))
            small.draw(row.1, in: CGRect(x: 0, y: 0, width: size, height: size))
            drawIcon(ctx, small.makeImage()!, in: rect)
            drawText(ctx, "\(Int(size)) px", centerX: rect.midX, baseline: rowBottom + 18, size: 18, color: color(ink, 0.7))
            x += size + 44
        }
    }
    return ctx.makeImage()!
}

// MARK: - Camadas para o Icon Composer

func glyphSVG() -> String {
    let points = stairPoints.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <!-- FitJourney · motivo "degraus" para o Icon Composer: importe como camada e aplique o Liquid Glass do sistema. -->
      <polyline points="\(points)" fill="none" stroke="#FFFFFF" stroke-width="\(Int(halfStroke * 2))" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="\(Int(dotCenter.x))" cy="\(Int(dotCenter.y))" r="\(Int(dotRadius))" fill="#FFFFFF"/>
    </svg>

    """
}

func flatGlyph() -> CGImage {
    let ctx = context(side, side)
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: 1, y: -1)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: CGFloat(stairPoints[0].x), y: CGFloat(stairPoints[0].y)))
    for p in stairPoints.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) }
    ctx.addPath(path.copy(strokingWithWidth: CGFloat(halfStroke * 2), lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.addEllipse(in: CGRect(
        x: CGFloat(dotCenter.x - dotRadius), y: CGFloat(dotCenter.y - dotRadius), width: CGFloat(dotRadius * 2), height: CGFloat(dotRadius * 2)
    ))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath(using: .winding)
    return ctx.makeImage()!
}

// MARK: - Execução

let lightRender = render(lightStyle, monolith, stacked: false, wantLayers: true)
let lightImage = image(lightRender.canvas)
let darkImage = image(render(darkStyle, monolith, stacked: false).canvas)
let tintedImage = image(render(tintedStyle, monolith, stacked: false).canvas)
let watchImage = image(render(watchStyle, monolith, stacked: false).canvas)
let altImage = image(render(lightStyle, capsules, stacked: true).canvas)

write(lightImage, "AppIcon-glass.png")
write(darkImage, "AppIcon-glass-dark.png")
write(tintedImage, "AppIcon-glass-tinted.png")
write(watchImage, "AppIcon-glass-watch.png")
write(altImage, "AppIcon-glass-alt.png")

write(masked(lightImage), "preview-glass-1024.png")
write(masked(darkImage), "preview-glass-dark.png")
write(masked(tintedImage), "preview-glass-tinted.png")
write(masked(watchImage, circle: true), "preview-glass-watch.png")
write(masked(altImage), "preview-glass-alt.png")

let currentCatalog = repositoryRoot.appendingPathComponent("FitJourney/Assets.xcassets/AppIcon.appiconset")
if let current = load(currentCatalog.appendingPathComponent("AppIcon.png")) {
    write(comparison([("Atual", current, false), ("Vidro", lightImage, false)]), "preview-compare.png")
    write(comparison([("Vidro", lightImage, false), ("Vidro · cápsulas (alt)", altImage, false)]), "preview-compare-alt.png")
    write(
        sizes(rows: [("Vidro", lightImage), ("Atual", current), ("Vidro alt", altImage)], wallpaperTop: 0xDCE9F7, wallpaperBottom: 0xF6E7DA, ink: 0x1C1C1E),
        "preview-sizes-light.png"
    )
    var darkRows: [(String, CGImage)] = [("Vidro", lightImage), ("Atual", current), ("Vidro escuro", darkImage)]
    if let currentDark = load(currentCatalog.appendingPathComponent("AppIcon-Dark.png")) { darkRows.append(("Atual escuro", currentDark)) }
    darkRows.append(("Vidro tinted", tintedImage))
    write(sizes(rows: darkRows, wallpaperTop: 0x101826, wallpaperBottom: 0x2A1B2E, ink: 0xF2F2F7), "preview-sizes-dark.png")
} else {
    print("aviso: ícone atual não encontrado em \(currentCatalog.path); prévias de comparação puladas")
}
write(
    comparison([("Claro", lightImage, false), ("Escuro", darkImage, false), ("Tinted", tintedImage, false), ("watchOS", watchImage, true)], iconSide: 420),
    "preview-variants.png"
)

// Camadas do claro. Para o Icon Composer use 0-background + glyph.svg; as demais são o vidro "assado" deste script.
write(image(lightRender.background), "layers/0-background.png")
if let shadowed = lightRender.shadowed {
    write(image(premultiplied: difference(under: lightRender.background, over: shadowed)), "layers/1-shadow.png")
}
if let layers = lightRender.layers {
    write(image(premultiplied: layers.glass), "layers/2-glass.png")
    write(image(premultiplied: layers.highlights), "layers/3-highlights.png")
}
write(flatGlyph(), "layers/glyph-flat.png")
do {
    let url = outputDirectory.appendingPathComponent("layers/glyph.svg")
    try glyphSVG().write(to: url, atomically: true, encoding: .utf8)
    print("gravado \(url.path)")
} catch {
    fatalError("não foi possível gravar layers/glyph.svg: \(error)")
}
