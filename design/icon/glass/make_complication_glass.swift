// Gera a arte em vidro da COMPLICAÇÃO do Apple Watch do FitJourney (não toca em catálogos, no project.yml nem na extensão).
//
// Uso, de qualquer pasta (as saídas vão sempre para design/icon/glass/complication/; leva poucos segundos):
//   swift -O design/icon/glass/make_complication_glass.swift
// Sem o `-O` também funciona, mas é um sombreador por pixel e demora bem mais. O resultado é determinístico.
//
// Deriva da opção de ícone em vidro (make_icon_glass.swift, ao lado): o mesmo sombreador — campo de distância (SDF) →
// perfil de altura → normais → refração do fundo, parede limpa, miolo leitoso, luz de cima à esquerda, sombra e
// cáustica — copiado para cá porque um script Swift é um arquivo só. O que muda é a composição, refeita para leitura
// minúscula (a complicação circular tem 42–50 pt, isto é, 84–100 px @2x):
//   1. motivo recomposto: lances mais curtos e traço mais grosso (o mesmo esqueleto de três degraus e a meta), para a
//      peça ficar compacta e poder crescer; ela é ajustada sozinha ao círculo (menor círculo que a contém → fração do
//      raio do disco);
//   2. realces que somem nesse tamanho saem (fio interno, reflexo duro) e os que ficam engrossam (fio da borda, brilho
//      de saída, sombra de contato), para sobrarem pelo menos ~1 px a 84 px;
//   3. o disco ganha um chanfro de luz discreto na borda, para não parecer um adesivo chapado sobre o mostrador preto.
//
// A extensão do relógio só usa estas imagens em `widgetRenderingMode == .fullColor`. Nos modos acentuado/vibrante o
// sistema tinge tudo, e a extensão desenha a escada chapada com um Shape (glyphPath() de design/icon/make_icon.swift).
//
// Saídas (em design/icon/glass/complication/):
//   ComplicationGlass.png          240 × 240, com alpha: disco laranja + degraus e meta em vidro; fora do círculo, transparente
//   ComplicationGlass-corner.png   160 × 160, com alpha: só os degraus e a meta, em vidro laranja, sem disco (accessoryCorner)
//   preview-face-dark.png          a complicação a 100, 84 e 64 px num mostrador escuro simulado (pixels 1:1)
//   preview-face-color.png         idem em mostradores de cor cheia (fundo frio e fundo quente, o pior caso)
//   preview-sizes.png              100, 84 e 64 px em 1:1 e ampliados 3× (vizinho mais próximo), para conferir os pixels
//   preview-corner.png             a arte do canto a 72, 64 e 48 px, em 1:1 e ampliada 3×

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

/// Espaço de desenho: 1024 unidades de lado, como o ícone. Tudo é calculado em 960 × 960 px e reduzido no fim
/// (4× para os 240 px da complicação circular, 6× para os 160 px do canto).
let designSide: Float = 1024
let N = 960
/// Pixels (superamostrados) por unidade de desenho.
let k = Float(N) / designSide
let pixelCount = N * N
let canvasCenter = V2(512, 512)
/// Raio do disco, meia unidade aquém da borda para o antisserrilhado não ser cortado pelo quadro.
let discRadius: Float = 511
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

// MARK: - Geometria (unidades do motivo; y cresce para baixo)

/// O motivo "degraus": três lances que sobem até um ponto (a meta). Mesmo esqueleto do ícone, proporções próprias.
struct Glyph {
    let points: [V2]
    let halfStroke: Float
    /// Raio do arredondamento dos cantos internos dos degraus.
    let fillet: Float
    let dotCenter: V2
    let dotRadius: Float

    /// - Parameters:
    ///   - run, rise: largura e altura de cada degrau.
    ///   - dotGap: folga entre a meta e o último lance.
    ///   - dotShift: posição horizontal da meta sobre o último lance (0 = começo, 1 = fim).
    init(run: Float, rise: Float, halfStroke: Float, fillet: Float, dotRadius: Float, dotGap: Float, dotShift: Float) {
        points = [
            V2(0, 0), V2(run, 0), V2(run, -rise), V2(2 * run, -rise), V2(2 * run, -2 * rise), V2(3 * run, -2 * rise),
        ]
        self.halfStroke = halfStroke
        self.fillet = fillet
        self.dotRadius = dotRadius
        dotCenter = V2(2 * run + dotShift * run, -2 * rise - halfStroke - dotGap - dotRadius)
    }

    /// Discos que delimitam a peça (as pontas e as quinas do traço, e a meta).
    var bounds: [(center: V2, radius: Float)] {
        points.map { ($0, halfStroke) } + [(dotCenter, dotRadius)]
    }

    /// Degraus inteiros: traço com pontas e cantos redondos, com os cantos internos arredondados.
    /// É a distância exata por dentro e por fora (as curvas de nível contornam o canto sem vinco), o que o chanfro exige.
    func sdStairs(_ p: V2) -> Float {
        var d = Float.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            d = min(d, sdSegment(p, points[i], points[i + 1]))
        }
        d -= halfStroke
        let reach = fillet + halfStroke
        for i in 1..<(points.count - 1) {
            let v = points[i]
            let a = simd_normalize(v - points[i - 1]), b = simd_normalize(points[i + 1] - v)
            let n = b - a // aponta para o lado côncavo; componentes ±1
            let arcCenter = v + n * reach
            // Coordenadas do canto: (0,0) no centro do arco, crescendo para dentro da peça até o vértice do traço.
            let q = (arcCenter - p) * n
            if q.x >= 0, q.y >= 0, q.x <= reach, q.y <= reach {
                d = max(fillet - simd_length(q), max(q.x, q.y) - reach - halfStroke)
            }
        }
        return d
    }

    func sdDot(_ p: V2) -> Float { simd_length(p - dotCenter) - dotRadius }
}

func sdSegment(_ p: V2, _ a: V2, _ b: V2) -> Float {
    let pa = p - a, ba = b - a
    let h = clamp01(simd_dot(pa, ba) / simd_dot(ba, ba))
    return simd_length(pa - ba * h)
}

/// Onde o motivo cai no quadro: `canvas = canvasAnchor + (glyph − glyphAnchor) · scale`.
struct Placement {
    let scale: Float
    let glyphAnchor: V2
    let canvasAnchor: V2
    func toGlyph(_ canvasPoint: V2) -> V2 { (canvasPoint - canvasAnchor) / scale + glyphAnchor }
}

/// Menor círculo que contém a peça (Bădoiu–Clarkson: anda um pouco, cada vez menos, na direção do ponto mais distante).
func enclosingCircle(_ glyph: Glyph) -> (center: V2, radius: Float) {
    let discs = glyph.bounds
    var c = discs.reduce(V2(0, 0)) { $0 + $1.center } / Float(discs.count)
    func farthest(_ from: V2) -> (point: V2, distance: Float) {
        var best = (from, Float(0))
        for disc in discs {
            let offset = disc.center - from
            let length = simd_length(offset)
            let distance = length + disc.radius
            if distance > best.1 {
                best = (disc.center + (length > 1e-6 ? offset / length : V2(1, 0)) * disc.radius, distance)
            }
        }
        return best
    }
    for step in 1...20_000 { c += (farthest(c).point - c) / Float(step + 1) }
    return (c, farthest(c).distance)
}

/// Complicação circular: a peça ocupa `fill` do raio do disco, centrada pelo menor círculo que a contém.
func placeInDisc(_ glyph: Glyph, fill: Float, nudge: V2 = V2(0, 0)) -> Placement {
    let circle = enclosingCircle(glyph)
    return Placement(scale: fill * discRadius / circle.radius, glyphAnchor: circle.center, canvasAnchor: canvasCenter + nudge)
}

/// Canto: sem disco, a peça ocupa o quadro inteiro menos a margem, centrada pela caixa.
func placeInSquare(_ glyph: Glyph, padding: Float) -> Placement {
    var lo = V2(.greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
    for disc in glyph.bounds {
        lo = simd_min(lo, disc.center - V2(disc.radius, disc.radius))
        hi = simd_max(hi, disc.center + V2(disc.radius, disc.radius))
    }
    let size = hi - lo
    return Placement(scale: (designSide - 2 * padding) / max(size.x, size.y), glyphAnchor: (lo + hi) / 2, canvasAnchor: canvasCenter)
}

struct Piece {
    let name: String
    /// Distância com sinal em unidades do motivo (negativa dentro).
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

    /// Suavização do perfil de altura, em unidades do motivo (mais alta que no ícone: a luz corre mais macia).
    var heightBlur: Float = 3.4
    /// Deslocamento máximo da amostra refratada, em unidades do motivo.
    var refraction: Float = 44
    /// Escurecimento da parede no lado da luz e do miolo que dá as costas à luz.
    var wallShade: Float = 0.04
    /// Clareia a parede do lado da luz com a cor do brilho de saída (para ela não virar contorno escuro).
    var wallLift: Float = 0
    var shadeAmount: Float = 0.10
    /// Clareamento do miolo voltado para a luz.
    var litColor = V3(1, 1, 1)
    var litAmount: Float = 0.6
    /// Especular largo (chanfro) e reflexo duro (ponto de luz; some no tamanho da complicação, fica quase desligado).
    var specularPower: Float = 22
    var specularAmount: Float = 0.85
    var glintPower: Float = 140
    var glintAmount: Float = 0
    /// Fio de luz na borda de fora: largura e intensidades (base, lado da luz, lado oposto).
    var rimColor = V3(1, 1, 1)
    var rimWidth: Float = 5.5
    var rimBase: Float = 0.30
    var rimLight: Float = 0.85
    var rimBack: Float = 0.45
    /// Segundo fio, onde a parede encontra o topo. Desligado: é fino demais para a complicação.
    var innerRim: Float = 0
    /// Brilho de saída: a luz que atravessa o vidro acende a parede do lado oposto com a cor do fundo.
    var exitGlowColor: V3
    var exitGlowAmount: Float

    /// Sombra sobre o fundo (multiplica) — contato e ampla. `shadowReach` estica deslocamentos e larguras.
    var shadowTint: V3
    var contactShadow: Float = 0.52
    var wideShadow: Float = 0.38
    var shadowReach: Float = 1.25
    /// Cáustica: luz concentrada que cai no fundo logo depois da borda oposta à luz.
    var causticColor = V3(0, 0, 0)
    var causticAmount: Float = 0

    /// Chanfro de luz na borda do disco: largura (unidades) e intensidades do lado da luz e do lado oposto.
    var discRimWidth: Float = 15
    var discRimLight: Float = 0.42
    var discRimBack: Float = 0.16
    /// Escurecimento suave do disco perto da borda oposta à luz (dá volume de lente).
    var discShade: Float = 0.16
}

/// Complicação circular: vidro leitoso branco sobre o gradiente laranja do ícone.
let discStyle: Style = {
    var s = Style(
        backgroundTop: 0xFF8B2B, backgroundBottom: 0xDB430A, glow: true,
        milkTop: hex(0xFFFFFF), milkBottom: hex(0xFFF3E6), milkAmountTop: 0.98, milkAmountBottom: 0.90, milkWall: 0.16,
        milkFar: 0.64, milkFarColor: hex(0xFFD08A),
        wallTint: hex(0xFFA04A), wallTintAmount: 0.32,
        exitGlowColor: hex(0xFFD79A), exitGlowAmount: 0.85,
        shadowTint: hex(0x8A2A04)
    )
    s.wallLift = 0.46
    s.rimWidth = 6.5
    s.rimLight = 1.0
    s.causticColor = hex(0xFFC774)
    s.causticAmount = 0.36
    return s
}()

/// Canto: vidro laranja sem fundo (como o ícone escuro). O "fundo" é preto puro e não sai na imagem.
let cornerStyle: Style = {
    var s = Style(
        backgroundTop: 0x000000, backgroundBottom: 0x000000, glow: false,
        milkTop: hex(0xFFA347), milkBottom: hex(0xEE5A12), milkAmountTop: 0.98, milkAmountBottom: 0.95, milkWall: 0.90,
        milkFar: 0.86, milkFarColor: hex(0xC63A06),
        wallTint: hex(0xD14A0C), wallTintAmount: 0.40,
        exitGlowColor: hex(0xFFC27A), exitGlowAmount: 0.80,
        shadowTint: hex(0x000000)
    )
    s.litColor = hex(0xFFD9A8)
    s.litAmount = 0.95
    s.shadeAmount = 0.30
    s.wallLift = 0.50
    s.rimColor = hex(0xFFE9CF)
    s.rimWidth = 6.5
    s.rimBase = 0.34
    s.rimLight = 1.0
    s.specularAmount = 0.8
    s.contactShadow = 0
    s.wideShadow = 0
    return s
}()

// MARK: - Fundo

func background(_ style: Style, disc: Bool) -> Buffer<V3> {
    let out = Buffer<V3>(pixelCount, V3(0, 0, 0))
    let top = hex(style.backgroundTop), bottom = hex(style.backgroundBottom)
    let glowColor = hex(0xFFD08A), glowCenter = V2(760, 150)
    let light2 = simd_normalize(V2(style.light.x, style.light.y))
    for j in 0..<N {
        let y = (Float(j) + 0.5) / k
        for i in 0..<N {
            let x = (Float(i) + 0.5) / k
            var c = mix(top, bottom, y / designSide)
            if style.glow {
                let a = 0.55 * max(0, 1 - simd_length(V2(x, y) - glowCenter) / 620)
                c = mix(c, glowColor, a)
            }
            if disc {
                let offset = V2(x, y) - canvasCenter
                let radius = simd_length(offset)
                let inset = discRadius - radius // distância até a borda, por dentro
                if inset > 0, radius > 1 {
                    let facing = simd_dot(offset / radius, light2) // +1 na borda voltada para a luz
                    // Volume: a borda oposta à luz escurece um pouco, como a parede de uma lente.
                    let shade = style.discShade * (1 - smoothstep(0, 120, inset)) * smoothstep(-0.2, 1, -facing)
                    c = c * (1 - shade)
                    // Chanfro: faixa clara junto à borda, forte do lado da luz e fraca do lado oposto.
                    let band = exp(-(inset / style.discRimWidth) * (inset / style.discRimWidth))
                    let strength = style.discRimLight * pow(max(facing, 0), 1.4) + style.discRimBack * pow(max(-facing, 0), 2.4)
                    c = c + (V3(1, 1, 1) - c) * hex(0xFFE2B8) * clamp01(band * strength)
                }
            }
            out.p[j * N + i] = c
        }
    }
    return out
}

// MARK: - Campos da peça

struct Field {
    /// Distância com sinal, em unidades do motivo.
    let distance: Buffer<Float>
    /// Altura normalizada 0…1, já suavizada.
    let height: Buffer<Float>
}

func gaussianBlur(_ buffer: Buffer<Float>, sigma: Float) {
    let radius = Int((sigma * 3).rounded(.up))
    guard radius > 0 else { return }
    var kernel = [Float](repeating: 0, count: 2 * radius + 1)
    var sum: Float = 0
    for n in -radius...radius {
        let w = exp(-Float(n * n) / (2 * sigma * sigma))
        kernel[n + radius] = w
        sum += w
    }
    for n in 0..<kernel.count { kernel[n] /= sum }
    let tmp = Buffer<Float>(pixelCount, 0)
    kernel.withUnsafeBufferPointer { kp in
        for j in 0..<N {
            for i in 0..<N {
                var acc: Float = 0
                for n in -radius...radius {
                    acc += buffer.p[j * N + min(N - 1, max(0, i + n))] * kp[n + radius]
                }
                tmp.p[j * N + i] = acc
            }
        }
        for j in 0..<N {
            for i in 0..<N {
                var acc: Float = 0
                for n in -radius...radius {
                    acc += tmp.p[min(N - 1, max(0, j + n)) * N + i] * kp[n + radius]
                }
                buffer.p[j * N + i] = acc
            }
        }
    }
}

func makeField(_ piece: Piece, _ placement: Placement, _ style: Style) -> Field {
    let distance = Buffer<Float>(pixelCount, 0)
    let height = Buffer<Float>(pixelCount, 0)
    for j in 0..<N {
        for i in 0..<N {
            let canvasPoint = V2((Float(i) + 0.5) / k, (Float(j) + 0.5) / k)
            let d = piece.sdf(placement.toGlyph(canvasPoint))
            distance.p[j * N + i] = d
            let t = -d
            guard t > 0 else { continue }
            let e = 1 - clamp01(t / piece.wall)
            let rim = (1 - e * e).squareRoot() // quarto de círculo: quina arredondada da placa
            let lens = sin(clamp01(t / piece.halfWidth) * .pi / 2)
            height.p[j * N + i] = mix(rim, lens, piece.dome)
        }
    }
    // Suaviza o encontro da quina com o topo para a luz correr contínua pela peça.
    gaussianBlur(height, sigma: style.heightBlur * k * placement.scale)
    return Field(distance: distance, height: height)
}

// MARK: - Sombra

func applyShadow(_ canvas: Buffer<V3>, _ field: Field, _ placement: Placement, _ style: Style) {
    let pixelsPerUnit = k * placement.scale
    let reach = style.shadowReach
    func shifted(_ i: Int, _ j: Int, _ dx: Float, _ dy: Float) -> Float {
        field.distance.p[
            min(N - 1, max(0, j - Int((dy * pixelsPerUnit).rounded()))) * N + min(N - 1, max(0, i - Int((dx * pixelsPerUnit).rounded())))
        ]
    }
    for j in 0..<N {
        for i in 0..<N {
            let idx = j * N + i
            var c = canvas.p[idx]
            // Ampla e macia, para baixo e um pouco à direita (a luz vem de cima à esquerda).
            let wide = (1 - smoothstep(-26 * reach, 78 * reach, shifted(i, j, 9 * reach, 34 * reach))) * style.wideShadow
            if wide > 0 { c = mix(c, c * style.shadowTint, wide) }
            // Cáustica: a luz atravessa a peça e cai concentrada perto da borda oposta, dentro da sombra.
            if style.causticAmount > 0 {
                let caustic = (1 - smoothstep(-16, 6, shifted(i, j, 6, 17))) * style.causticAmount
                c = c + (V3(1, 1, 1) - c) * style.causticColor * caustic
            }
            // Contato: faixa curta e escura que assenta a peça no fundo (é ela que separa o branco do laranja a 64 px).
            let contact = (1 - smoothstep(-4 * reach, 12 * reach, shifted(i, j, 2.5 * reach, 7 * reach))) * style.contactShadow
            if contact > 0 { c = mix(c, c * style.shadowTint, contact) }
            canvas.p[idx] = c
        }
    }
}

// MARK: - Vidro

func sample(_ buffer: Buffer<V3>, _ x: Float, _ y: Float) -> V3 {
    let fx = min(Float(N - 1), max(0, x * k - 0.5)), fy = min(Float(N - 1), max(0, y * k - 0.5))
    let x0 = Int(fx), y0 = Int(fy)
    let x1 = min(N - 1, x0 + 1), y1 = min(N - 1, y0 + 1)
    let tx = fx - Float(x0), ty = fy - Float(y0)
    let top = mix(buffer.p[y0 * N + x0], buffer.p[y0 * N + x1], tx)
    let bottom = mix(buffer.p[y1 * N + x0], buffer.p[y1 * N + x1], tx)
    return mix(top, bottom, ty)
}

/// Pinta a peça sobre `canvas` e soma a cobertura dela em `coverageSum` (a união das peças, para o alpha do canto).
func shadeGlass(_ canvas: Buffer<V3>, _ field: Field, _ piece: Piece, _ placement: Placement, _ style: Style, _ coverageSum: Buffer<Float>) {
    let behind = canvas.copy()
    let scale = placement.scale
    let unit = 1 / (k * scale) // unidades do motivo por pixel superamostrado
    let light = simd_normalize(style.light)
    let light2 = simd_normalize(V2(style.light.x, style.light.y))
    let halfVector = simd_normalize(light + V3(0, 0, 1))
    let white = V3(1, 1, 1)

    for j in 1..<(N - 1) {
        for i in 1..<(N - 1) {
            let idx = j * N + i
            let d = field.distance.p[idx]
            let coverage = clamp01(0.5 - d / unit)
            if coverage <= 0 { continue }

            let hx = (field.height.p[idx + 1] - field.height.p[idx - 1]) / (2 * unit)
            let hy = (field.height.p[idx + N] - field.height.p[idx - N]) / (2 * unit)
            let slope = V2(-hx, -hy) * piece.thickness // aponta para fora da peça
            let normal = simd_normalize(V3(slope.x, slope.y, 1))
            var outward = V2(field.distance.p[idx + 1] - field.distance.p[idx - 1], field.distance.p[idx + N] - field.distance.p[idx - N])
            let outwardLength = simd_length(outward)
            outward = outwardLength > 1e-6 ? outward / outwardLength : V2(0, 0)

            let canvasPoint = V2((Float(i) + 0.5) / k, (Float(j) + 0.5) / k)
            let glyphPoint = placement.toGlyph(canvasPoint)
            // 0 no lado da luz, 1 no lado oposto, ao longo do motivo inteiro.
            let along = clamp01(0.5 - simd_dot(glyphPoint - placement.glyphAnchor, light2) / 640)
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

            // Realces (pré-multiplicados), compostos por cima no fim.
            var hc = V3(0, 0, 0)
            var ha: Float = 0
            func add(_ tint: V3, _ amount: Float) {
                let a = clamp01(amount)
                hc = hc * (1 - a) + tint * a
                ha = ha * (1 - a) + a
            }
            if lambert > 0 { add(style.litColor, lambert * style.litAmount * core) }
            do { // luz que sai pela parede oposta
                let band = smoothstep(0, piece.wall * 0.35, t) * (1 - smoothstep(piece.wall * 0.6, piece.wall * 1.25, t))
                add(style.exitGlowColor, style.exitGlowAmount * band * pow(max(-facing, 0), 1.2))
            }
            // especular largo na quina voltada para a luz
            add(white, pow(max(simd_dot(normal, halfVector), 0), style.specularPower) * style.specularAmount * (1 - core * 0.7))
            if style.glintAmount > 0 { // reflexo duro
                add(white, pow(max(simd_dot(normal, halfVector), 0), style.glintPower) * style.glintAmount)
            }
            if style.innerRim > 0 { // fio de luz onde a parede encontra o topo
                let x = (t - piece.wall * 0.92) / 2.4
                add(style.rimColor, exp(-x * x) * style.innerRim * (0.35 + 0.65 * max(facing, 0)))
            }
            do { // fio de luz na borda de fora
                let line = exp(-(t / style.rimWidth) * (t / style.rimWidth))
                let strength = style.rimBase + style.rimLight * pow(max(facing, 0), 1.3) + style.rimBack * pow(max(-facing, 0), 2.2)
                add(style.rimColor, line * strength)
            }

            let final = color * (1 - ha) + hc
            canvas.p[idx] = mix(behind.p[idx], final, coverage)
            coverageSum.p[idx] = 1 - (1 - coverageSum.p[idx]) * (1 - coverage)
        }
    }
}

// MARK: - Cenas

/// `dome`: abaulado dos degraus (a meta é sempre uma conta, bem mais abaulada).
func pieces(_ glyph: Glyph, wall: Float, dotWall: Float, dome: Float = 0.22, thickness: Float = 30) -> [Piece] {
    [
        Piece(name: "degraus", sdf: glyph.sdStairs, wall: wall, halfWidth: glyph.halfStroke, dome: dome, thickness: thickness),
        Piece(name: "meta", sdf: glyph.sdDot, wall: dotWall, halfWidth: glyph.dotRadius, dome: max(0.55, dome), thickness: thickness * 1.5),
    ]
}

struct Rendered {
    /// Cor já pré-multiplicada pelo alpha.
    let color: Buffer<V3>
    let alpha: Buffer<Float>
}

/// `disc`: com o disco de fundo (o alpha é o do disco). Sem ele, só o vidro (o alpha é a cobertura das peças).
func render(_ glyph: Glyph, _ placement: Placement, _ style: Style, _ parts: [Piece], disc: Bool) -> Rendered {
    let canvas = background(style, disc: disc)
    let fields = parts.map { makeField($0, placement, style) }
    if style.wideShadow > 0 || style.contactShadow > 0 || style.causticAmount > 0 {
        for field in fields { applyShadow(canvas, field, placement, style) }
    }
    let coverage = Buffer<Float>(pixelCount, 0)
    for (piece, field) in zip(parts, fields) { shadeGlass(canvas, field, piece, placement, style, coverage) }
    guard disc else { return Rendered(color: canvas, alpha: coverage) } // sobre preto puro a cor já está pré-multiplicada
    let alpha = Buffer<Float>(pixelCount, 0)
    for j in 0..<N {
        for i in 0..<N {
            let point = V2((Float(i) + 0.5) / k, (Float(j) + 0.5) / k)
            let a = clamp01(0.5 - (simd_length(point - canvasCenter) - discRadius) * k)
            alpha.p[j * N + i] = a
            canvas.p[j * N + i] *= a
        }
    }
    return Rendered(color: canvas, alpha: alpha)
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

/// Reduz (média de bloco) para `side` × `side` e monta a imagem com alpha pré-multiplicado.
func image(_ rendered: Rendered, side: Int) -> CGImage {
    precondition(N % side == 0, "o lado de saída precisa dividir \(N)")
    let ss = N / side
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    let weight = 1 / Float(ss * ss)
    for y in 0..<side {
        for x in 0..<side {
            var color = V3(0, 0, 0)
            var alpha: Float = 0
            for sy in 0..<ss {
                for sx in 0..<ss {
                    let idx = (y * ss + sy) * N + x * ss + sx
                    color += rendered.color.p[idx]
                    alpha += rendered.alpha.p[idx]
                }
            }
            color *= weight
            alpha *= weight
            let a = UInt8(max(0, min(255, (alpha * 255).rounded())))
            for c in 0..<3 {
                let value = UInt8(max(0, min(255, (color[c] * 255 + dither(x, y, c)).rounded())))
                bytes[(y * side + x) * 4 + c] = min(value, a)
            }
            bytes[(y * side + x) * 4 + 3] = a
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("complication")

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

// MARK: - Prévias (coordenadas de tela: origem no canto superior esquerdo, y para baixo)

func color(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, alpha]
    )!
}

/// Contexto com y para baixo. Imagens e texto passam por `drawImage` e `drawText`, que desviram localmente.
func context(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func drawImage(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect, pixelated: Bool = false) {
    ctx.saveGState()
    ctx.interpolationQuality = pixelated ? .none : .high
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

/// Reduz para o tamanho exato em pixels, como o sistema faz com a imagem da complicação.
func resized(_ image: CGImage, _ pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
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
    ctx.saveGState()
    ctx.translateBy(x: centerX - width / 2, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Direção de um ângulo em graus, no sentido horário a partir das 12 h.
func clockDirection(_ degrees: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: sin(radians), y: -cos(radians))
}

func arcPath(center: CGPoint, radius: CGFloat, from: CGFloat, sweep: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = max(2, Int(abs(sweep) / 2))
    for n in 0...steps {
        let direction = clockDirection(from + sweep * CGFloat(n) / CGFloat(steps))
        let point = CGPoint(x: center.x + direction.x * radius, y: center.y + direction.y * radius)
        if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

func strokeArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from: CGFloat, sweep: CGFloat, width: CGFloat, color: CGColor) {
    ctx.addPath(arcPath(center: center, radius: radius, from: from, sweep: sweep))
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

func fillCircle(_ ctx: CGContext, center: CGPoint, diameter: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
}

enum FaceKind {
    /// Mostrador preto com complicações multicoloridas (tipo Infograph).
    case dark
    /// Mostrador com fundo em cor cheia.
    case color(top: UInt32, bottom: UInt32)

    var isColor: Bool { if case .color = self { true } else { false } }
}

let faceSize = CGSize(width: 416, height: 496) // tela de 46 mm, em pixels

// Complicações genéricas (só para dar contexto; não são do FitJourney).

func drawRings(_ ctx: CGContext, center: CGPoint, diameter: CGFloat) {
    let rings: [(UInt32, CGFloat, CGFloat)] = [(0xFA114F, 0.41, 0.78), (0xA6FF00, 0.28, 0.62), (0x00D8FF, 0.15, 0.86)]
    for ring in rings {
        strokeArc(ctx, center: center, radius: diameter * ring.1, from: 0, sweep: 360, width: diameter * 0.11, color: color(ring.0, 0.24))
        strokeArc(ctx, center: center, radius: diameter * ring.1, from: 0, sweep: 360 * ring.2, width: diameter * 0.11, color: color(ring.0))
    }
}

func drawGauge(_ ctx: CGContext, center: CGPoint, diameter: CGFloat) {
    let stops: [V3] = [hex(0x3FA9FF), hex(0x4CE0B3), hex(0xFFD60A), hex(0xFF7A3C)]
    let segments = 54
    for n in 0..<segments {
        let t = Float(n) / Float(segments - 1)
        let scaled = t * Float(stops.count - 1)
        let c = mix(stops[min(stops.count - 2, Int(scaled))], stops[min(stops.count - 1, Int(scaled) + 1)], scaled - Float(min(stops.count - 2, Int(scaled))))
        let tint = CGColor(colorSpace: space, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])!
        strokeArc(ctx, center: center, radius: diameter * 0.42, from: 225 + 270 * CGFloat(t), sweep: 1, width: diameter * 0.09, color: tint)
    }
    let marker = clockDirection(225 + 270 * 0.62)
    fillCircle(ctx, center: CGPoint(x: center.x + marker.x * diameter * 0.42, y: center.y + marker.y * diameter * 0.42), diameter: diameter * 0.15, color: color(0x000000))
    fillCircle(ctx, center: CGPoint(x: center.x + marker.x * diameter * 0.42, y: center.y + marker.y * diameter * 0.42), diameter: diameter * 0.10, color: color(0xFFFFFF))
    drawText(ctx, "22°", centerX: center.x + 3, baseline: center.y + diameter * 0.12, size: diameter * 0.33, color: color(0xFFFFFF), bold: true)
}

func drawDate(_ ctx: CGContext, center: CGPoint, diameter: CGFloat, kind: FaceKind) {
    if !kind.isColor { fillCircle(ctx, center: center, diameter: diameter, color: color(0x1C1C1E)) }
    drawText(ctx, "SEX", centerX: center.x, baseline: center.y - diameter * 0.14, size: diameter * 0.19, color: color(kind.isColor ? 0xFFFFFF : 0xFF453A, kind.isColor ? 0.85 : 1), bold: true)
    drawText(ctx, "13", centerX: center.x, baseline: center.y + diameter * 0.28, size: diameter * 0.42, color: color(0xFFFFFF), bold: true)
}

/// Um mostrador analógico simulado, em pixels 1:1, com a complicação do FitJourney no lugar de baixo.
func face(_ kind: FaceKind, complication: CGImage, pixels: Int, corner: CGImage?, cornerPixels: Int = 56) -> CGImage {
    let width = faceSize.width, height = faceSize.height
    let ctx = context(Int(width), Int(height))
    let screen = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 88, cornerHeight: 88, transform: nil))
    ctx.clip()
    switch kind {
    case .dark:
        ctx.setFillColor(color(0x000000))
        ctx.fill(screen)
    case let .color(top, bottom):
        let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width * 0.35, y: height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    let center = CGPoint(x: width / 2, y: height / 2)
    // Marcas dos minutos e das horas.
    for n in 0..<60 {
        let direction = clockDirection(CGFloat(n) * 6)
        let hour = n % 5 == 0
        let outer: CGFloat = 197, inner: CGFloat = hour ? 180 : 188
        ctx.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
        ctx.addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
        ctx.setStrokeColor(color(0xFFFFFF, hour ? 0.92 : 0.36))
        ctx.setLineWidth(hour ? 4 : 2)
        ctx.setLineCap(.butt)
        ctx.strokePath()
    }

    // Subdiais: os três genéricos e, embaixo, a complicação do FitJourney.
    let spread: CGFloat = 104, generic: CGFloat = 94
    let top = CGPoint(x: center.x, y: center.y - spread), left = CGPoint(x: center.x - spread, y: center.y)
    let right = CGPoint(x: center.x + spread, y: center.y), bottom = CGPoint(x: center.x, y: center.y + spread)
    if kind.isColor {
        for point in [top, left, right] { fillCircle(ctx, center: point, diameter: generic, color: color(0x000000, 0.26)) }
    }
    drawRings(ctx, center: top, diameter: generic)
    drawGauge(ctx, center: left, diameter: generic)
    drawDate(ctx, center: right, diameter: generic, kind: kind)
    let size = CGFloat(pixels)
    drawImage(ctx, resized(complication, pixels), CGRect(x: (bottom.x - size / 2).rounded(), y: (bottom.y - size / 2).rounded(), width: size, height: size))

    // Cantos: um medidor curvo e um símbolo em cada um; no de cima à esquerda, a arte do canto do FitJourney.
    let cornerAngles: [CGFloat] = [320, 40, 140, 220]
    let cornerTints: [UInt32] = [0xFF7A1A, 0xFFD60A, 0x30D158, 0xFF375F]
    for (n, angle) in cornerAngles.enumerated() {
        let tint = kind.isColor ? UInt32(0xFFFFFF) : cornerTints[n]
        strokeArc(ctx, center: center, radius: 213, from: angle - 17, sweep: 34, width: 7, color: color(tint, 0.26))
        strokeArc(ctx, center: center, radius: 213, from: angle - 17, sweep: 34 * [0.7, 0.45, 0.8, 0.55][n], width: 7, color: color(tint))
        let direction = clockDirection(angle)
        let spot = CGPoint(x: center.x + direction.x * 254, y: center.y + direction.y * 254)
        if n == 0, let corner {
            let side = CGFloat(cornerPixels)
            drawImage(ctx, resized(corner, cornerPixels), CGRect(x: (spot.x - side / 2).rounded(), y: (spot.y - side / 2).rounded(), width: side, height: side))
        } else if n == 1 { // sol
            fillCircle(ctx, center: spot, diameter: 22, color: color(tint))
            for ray in 0..<8 {
                let d = clockDirection(CGFloat(ray) * 45)
                ctx.move(to: CGPoint(x: spot.x + d.x * 16, y: spot.y + d.y * 16))
                ctx.addLine(to: CGPoint(x: spot.x + d.x * 22, y: spot.y + d.y * 22))
                ctx.setStrokeColor(color(tint))
                ctx.setLineWidth(3.5)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        } else {
            drawText(ctx, ["", "", "8,2", "72"][n], centerX: spot.x, baseline: spot.y + 9, size: 26, color: color(tint), bold: true)
        }
    }

    // Ponteiros (10:09, segundos para baixo à esquerda): nenhum passa por cima da complicação de baixo.
    func hand(_ degrees: CGFloat, length: CGFloat, width: CGFloat, tint: CGColor, tail: CGFloat = 0) {
        let direction = clockDirection(degrees)
        ctx.move(to: CGPoint(x: center.x - direction.x * tail, y: center.y - direction.y * tail))
        ctx.addLine(to: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
        ctx.setStrokeColor(tint)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: color(0x000000, 0.5))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
    hand(304.5, length: 104, width: 11, tint: color(0xFFFFFF))
    hand(54, length: 168, width: 9, tint: color(0xFFFFFF))
    hand(226, length: 176, width: 2.5, tint: color(kind.isColor ? 0xFFFFFF : 0x64D2FF), tail: 26)
    fillCircle(ctx, center: center, diameter: 14, color: color(0xFFFFFF))
    fillCircle(ctx, center: center, diameter: 6, color: color(0x000000))
    return ctx.makeImage()!
}

/// Folha de conferência: uma linha por tipo de mostrador, uma coluna por tamanho da complicação.
func faceSheet(title: String, rows: [(label: String, kind: FaceKind, corner: CGImage?)], complication: CGImage, sizes: [(pixels: Int, note: String)]) -> CGImage {
    let margin: CGFloat = 52, gap: CGFloat = 60, titleHeight: CGFloat = 64, labelHeight: CGFloat = 62, rowLabel: CGFloat = 34
    let width = margin * 2 + faceSize.width * CGFloat(sizes.count) + gap * CGFloat(sizes.count - 1)
    let rowHeight = rowLabel + faceSize.height + labelHeight
    let height = margin + titleHeight + rowHeight * CGFloat(rows.count) + margin - 20
    let ctx = context(Int(width), Int(height))
    ctx.setFillColor(color(0x2A2A2E))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(ctx, title, centerX: width / 2, baseline: margin + 26, size: 27, color: color(0xF2F2F7), bold: true)
    for (r, row) in rows.enumerated() {
        let rowTop = margin + titleHeight + rowHeight * CGFloat(r)
        drawText(ctx, row.label, centerX: width / 2, baseline: rowTop + 16, size: 19, color: color(0xF2F2F7, 0.62))
        for (n, size) in sizes.enumerated() {
            let x = margin + CGFloat(n) * (faceSize.width + gap), y = rowTop + rowLabel
            // Caixa do relógio, só para delimitar a tela.
            ctx.addPath(CGPath(roundedRect: CGRect(x: x - 12, y: y - 12, width: faceSize.width + 24, height: faceSize.height + 24), cornerWidth: 100, cornerHeight: 100, transform: nil))
            ctx.setFillColor(color(0x0E0E10))
            ctx.fillPath()
            drawImage(ctx, face(row.kind, complication: complication, pixels: size.pixels, corner: row.corner), CGRect(x: x, y: y, width: faceSize.width, height: faceSize.height))
            drawText(ctx, "\(size.pixels) px · \(size.note)", centerX: x + faceSize.width / 2, baseline: y + faceSize.height + 44, size: 20, color: color(0xF2F2F7), bold: true)
        }
    }
    return ctx.makeImage()!
}

/// A arte em vários tamanhos, em 1:1 e ampliada 3× sem interpolação, sobre preto e sobre uma cor.
func sizeSheet(title: String, art: CGImage, sizes: [Int], backgrounds: [UInt32], zoom: CGFloat = 3) -> CGImage {
    let margin: CGFloat = 40, gap: CGFloat = 36, titleHeight: CGFloat = 52, captionHeight: CGFloat = 34
    let largest = CGFloat(sizes.max()!)
    let cellWidths = sizes.map { CGFloat($0) * zoom + gap + CGFloat($0) }
    let width = margin * 2 + cellWidths.reduce(0, +) + gap * 1.5 * CGFloat(sizes.count - 1)
    let rowHeight = largest * zoom + captionHeight + gap
    let height = margin + titleHeight + rowHeight * CGFloat(backgrounds.count) + margin - gap
    let ctx = context(Int(width), Int(height))
    ctx.setFillColor(color(0x2A2A2E))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(ctx, title, centerX: width / 2, baseline: margin + 22, size: 22, color: color(0xF2F2F7), bold: true)
    for (r, background) in backgrounds.enumerated() {
        let rowTop = margin + titleHeight + rowHeight * CGFloat(r)
        ctx.setFillColor(color(background))
        ctx.fill(CGRect(x: margin - 16, y: rowTop - 12, width: width - 2 * margin + 32, height: largest * zoom + captionHeight + 20))
        var x = margin
        let ink: UInt32 = 0xF2F2F7
        for (n, size) in sizes.enumerated() {
            let small = resized(art, size)
            let s = CGFloat(size)
            drawImage(ctx, small, CGRect(x: x, y: rowTop + (largest * zoom - s * zoom) / 2, width: s * zoom, height: s * zoom), pixelated: true)
            drawImage(ctx, small, CGRect(x: x + s * zoom + gap, y: rowTop + (largest * zoom - s) / 2, width: s, height: s))
            drawText(ctx, "\(size) px  (\(Int(zoom))× e 1:1)", centerX: x + cellWidths[n] / 2, baseline: rowTop + largest * zoom + 26, size: 17, color: color(ink, 0.8))
            x += cellWidths[n] + gap * 1.5
        }
    }
    return ctx.makeImage()!
}

// MARK: - Execução

/// Motivo da complicação circular: degraus mais curtos e mais grossos que os do ícone (lá: 186 × 174, traço 108).
let discGlyph = Glyph(run: 172, rise: 164, halfStroke: 62, fillet: 22, dotRadius: 80, dotGap: 42, dotShift: 0.56)
/// O menor círculo deixa o lance de cima colado na borda direita; 18 unidades para a esquerda equilibram as margens.
let discPlacement = placeInDisc(discGlyph, fill: 0.86, nudge: V2(-18, 0))
let discArt = image(render(discGlyph, discPlacement, discStyle, pieces(discGlyph, wall: 15, dotWall: 18), disc: true), side: 240)
write(discArt, "ComplicationGlass.png")

/// Motivo do canto: ainda mais grosso (a arte aparece com ~32–36 pt) e ocupando o quadro todo.
let cornerGlyph = Glyph(run: 172, rise: 164, halfStroke: 66, fillet: 22, dotRadius: 84, dotGap: 44, dotShift: 0.56)
let cornerPlacement = placeInSquare(cornerGlyph, padding: 36)
let cornerArt = image(render(cornerGlyph, cornerPlacement, cornerStyle, pieces(cornerGlyph, wall: 17, dotWall: 20, dome: 0.50, thickness: 36), disc: false), side: 160)
write(cornerArt, "ComplicationGlass-corner.png")

let complicationSizes: [(pixels: Int, note: String)] = [(100, "50 pt @2x"), (84, "42 pt @2x"), (64, "piso de leitura")]
write(
    faceSheet(
        title: "Complicação em vidro · mostrador escuro · pixels 1:1 (tela de 46 mm, 416 × 496)",
        rows: [("Embaixo: ComplicationGlass.png · canto de cima à esquerda: ComplicationGlass-corner.png a 56 px", .dark, cornerArt)],
        complication: discArt, sizes: complicationSizes
    ),
    "preview-face-dark.png"
)
write(
    faceSheet(
        title: "Complicação em vidro · mostradores em cor cheia · pixels 1:1",
        rows: [
            ("Fundo frio", .color(top: 0x1E6BFF, bottom: 0x6A2BD9), nil),
            ("Fundo quente (pior caso: laranja sobre vermelho)", .color(top: 0xFF9F0A, bottom: 0xE0281E), nil),
        ],
        complication: discArt, sizes: complicationSizes
    ),
    "preview-face-color.png"
)
write(sizeSheet(title: "ComplicationGlass.png · tamanhos reais", art: discArt, sizes: [100, 84, 64], backgrounds: [0x000000, 0x24406E]), "preview-sizes.png")
write(sizeSheet(title: "ComplicationGlass-corner.png · tamanhos reais", art: cornerArt, sizes: [72, 64, 48], backgrounds: [0x000000, 0x24406E]), "preview-corner.png")
