#!/usr/bin/env python3
"""Peças da ficha da App Store do FitJourney (capturas de iPhone, header 21:9 e busca 3:2), en-US e pt-BR.

Gera o HTML de cada peça nesta pasta e renderiza com o render.py da skill app-store-launch
(uma instância do Chrome por vez, em sequência; nunca em paralelo).

Uso:
  build.py all                      tudo (capturas, header, busca e folhas)
  build.py shot <en|pt> <1..7>      uma captura
  build.py shots | header | search | sheets
  build.py html                     só escreve os HTML (sem render)

As telas vêm de work/store/raw (capturas reais). A moldura do iPhone e a do Apple Watch Ultra são
desenhos simples em CSS, sem logos. A Dynamic Island e o indicador de início são desenhados por cima
(o simulador não os grava sempre); nada mais é alterado na tela.
"""
import os, subprocess, sys

SRC = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.dirname(os.path.dirname(SRC))
RAW = os.path.join(STORE, "raw")
PNG = os.path.join(STORE, "png")
CRE = os.path.join(STORE, "creatives")
SHEETS = os.path.join(CRE, "sheets")
RENDER = os.path.expanduser("~/.claude/skills/app-store-launch/scripts/render.py")

# Identidade (FJColor / DESIGN_DIRECTION §2.1 e §2.6)
INK = "#1A1206"          # tinta (onFill escuro da paleta)
ORANGE = "#D4450C"       # trainingFill
ORANGE_TEXT = "#C2410C"  # training (texto sobre claro)
ICON_TOP, ICON_BOTTOM = "#FF8B2B", "#DB430A"  # gradiente do ícone
CREAM = "#FFF6EE"

FONT = '-apple-system,"SF Pro Display","SF Pro",system-ui,"Helvetica Neue",sans-serif'

# Telas sem o indicador de início gravado (medido nos pixels do raw): desenhamos igual ao do sistema.
NO_HOME = {"en-01-today", "en-02-session", "en-03-heart", "en-04-progress", "en-05-diet"}

SHOTS = [  # n, slug de saída, tela, título en, título pt  ("|" = quebra de linha; *…* = trecho em laranja)
    (1, "today", "01-today", "Today's workout,|*one tap away*", "O treino do dia|*a um toque*"),
    (2, "session", "02-session", "Log the set.|*Rest is timed.*", "Marcou a série,|*o descanso começa*"),
    (3, "watch", "08-training", "The whole workout|*on your wrist*", "O treino inteiro|*no pulso*"),
    (4, "heart", "03-heart", "Heart rate|*on every exercise*", "Frequência cardíaca|*em cada exercício*"),
    (5, "progress", "04-progress", "See your lifts|*go up*", "Veja sua carga|*subir*"),
    (6, "diet", "05-diet", "Your diet,|*meal by meal*", "Sua dieta,|*refeição a refeição*"),
    (7, "ai", "06-ai", "AI suggests.|*You decide.*", "A IA sugere.|*Você decide.*"),
]
HEADER = {"en": "Every set.|Every meal.", "pt": "Cada série.|Cada refeição."}
SEARCH = {"en": "Log your gym workouts and diet|on iPhone and Apple Watch.",
          "pt": "Registre treino e dieta|no iPhone e no Apple Watch."}


def raw(lang, name):
    return "file://" + os.path.join(RAW, f"{lang}-{name}.png")


def title_html(t, accent=True):
    out = []
    for line in t.split("|"):
        if line.startswith("*") and line.endswith("*"):
            line = f'<span class="{"ac" if accent else ""}">{line[1:-1]}</span>'
        out.append(line)
    return "<br>".join(out)


# ---------- Aparelhos ----------

def phone(lang, name, sw, x, y, z=1, shadow=True):
    """iPhone 6,9" genérico. sw = largura da tela em px CSS; x, y = canto superior esquerdo do corpo."""
    bez, ring = sw * 0.024, sw * 0.009
    sh = sw * 2868 / 1320
    r = sw * 0.141
    W, H = sw + 2 * (bez + ring), sh + 2 * (bez + ring)
    home = ""
    if f"{lang}-{name}" in NO_HOME:
        home = (f'<i style="position:absolute;left:{sw * (425 / 1320):.2f}px;width:{sw * (471 / 1320):.2f}px;'
                f'bottom:{sw * (24 / 1320):.2f}px;height:{sw * (15 / 1320):.2f}px;border-radius:99px;'
                f'background:linear-gradient(#4a4a4b,#747476)"></i>')
    island = (f'<i style="position:absolute;left:{sw * (0.5 - 0.1432):.2f}px;width:{sw * 0.2864:.2f}px;top:{sw * 0.0318:.2f}px;'
              f'height:{sw * 0.0841:.2f}px;border-radius:99px;background:#000"></i>')
    bw = sw * 0.011  # botões laterais
    btn = lambda side, top, h: (f'<i style="position:absolute;{side}:{-bw * 0.62:.2f}px;top:{H * top:.2f}px;width:{bw:.2f}px;'
                                f'height:{H * h:.2f}px;border-radius:{bw * 0.4:.2f}px;background:linear-gradient(90deg,#2a2a2c,#5a5a5e,#2a2a2c)"></i>')
    buttons = btn("left", 0.150, 0.034) + btn("left", 0.212, 0.062) + btn("left", 0.292, 0.062) + btn("right", 0.250, 0.098)
    shd = "box-shadow:0 {a}px {b}px rgba(74,24,0,.30),0 {c}px {d}px rgba(74,24,0,.22);".format(
        a=round(sw * 0.07), b=round(sw * 0.16), c=round(sw * 0.012), d=round(sw * 0.03)) if shadow else ""
    return (f'<div style="position:absolute;left:{x:.2f}px;top:{y:.2f}px;width:{W:.2f}px;height:{H:.2f}px;z-index:{z}">{buttons}'
            f'<div style="position:absolute;inset:0;border-radius:{r + bez + ring:.2f}px;padding:{ring:.2f}px;'
            f'background:linear-gradient(135deg,#77777c,#2d2d30 28%,#5d5d62 62%,#262628);{shd}">'
            f'<div style="width:100%;height:100%;border-radius:{r + bez:.2f}px;padding:{bez:.2f}px;background:#070708">'
            f'<div style="position:relative;width:{sw:.2f}px;height:{sh:.2f}px;border-radius:{r:.2f}px;overflow:hidden;background:#f2f2f7">'
            f'<img src="{raw(lang, name)}" style="display:block;width:100%;height:100%">{island}{home}</div></div></div></div>')


def phone_size(sw):
    e = 2 * sw * 0.033
    return sw + e, sw * 2868 / 1320 + e


def watch(lang, name, S, x, y, z=2, band="#232325", band_up=0.15, band_down=0.15, shadow=True):
    """Apple Watch Ultra genérico (caixa de titânio, proteção da coroa, botão de Ação laranja), sem logos.
    S = largura da tela em px CSS; x, y = canto superior esquerdo da caixa."""
    g, rim = S * 0.058, S * 0.052
    sh = S * 514 / 422
    W, H = S + 2 * (g + rim), sh + 2 * (g + rim)
    rs = S * 0.2
    ti = "linear-gradient(145deg,#efeae2,#b9b3a8 30%,#dcd7ce 55%,#a29c92 80%,#c9c4bb)"
    ti_side = "linear-gradient(180deg,#d9d4cb,#b3ada3 45%,#cfcac1 70%,#9d978d)"
    shd = "box-shadow:0 {a}px {b}px rgba(40,12,0,.38),0 {c}px {d}px rgba(40,12,0,.25);".format(
        a=round(S * 0.09), b=round(S * 0.2), c=round(S * 0.015), d=round(S * 0.04)) if shadow else ""
    bw = W * 0.78
    bands = ""
    if band:  # pulseira só como "tocos" retos, como no glifo do sistema: simples e sem inventar um modelo
        fill = f"linear-gradient(90deg,rgba(0,0,0,.45),rgba(255,255,255,.07) 14%,rgba(255,255,255,0) 50%,rgba(0,0,0,.15) 86%,rgba(0,0,0,.5)),{band}"
        rr = S * 0.04
        if band_up:
            L = H * band_up
            bands += (f'<i style="position:absolute;left:{(W - bw) / 2:.2f}px;width:{bw:.2f}px;top:{-L:.2f}px;height:{L + H * 0.2:.2f}px;'
                      f'border-radius:{rr:.2f}px {rr:.2f}px 0 0;background:{fill}"></i>')
        if band_down:
            L = H * band_down
            bands += (f'<i style="position:absolute;left:{(W - bw) / 2:.2f}px;width:{bw:.2f}px;top:{H * 0.8:.2f}px;height:{L + H * 0.2:.2f}px;'
                      f'border-radius:0 0 {rr:.2f}px {rr:.2f}px;background:{fill}"></i>')
    # lado direito: proteção + coroa + botão lateral
    gw = S * 0.075
    guard = (f'<i style="position:absolute;left:{W - S * 0.03:.2f}px;top:{H * 0.255:.2f}px;width:{gw + S * 0.03:.2f}px;height:{H * 0.49:.2f}px;'
             f'border-radius:0 {S * 0.05:.2f}px {S * 0.05:.2f}px 0;background:{ti_side}"></i>')
    ch = H * 0.185
    crown = (f'<i style="position:absolute;left:{W + gw * 0.42:.2f}px;top:{H * 0.305:.2f}px;width:{S * 0.085:.2f}px;height:{ch:.2f}px;'
             f'border-radius:{S * 0.022:.2f}px;background:repeating-linear-gradient(180deg,#8f897f 0 {S * 0.008:.2f}px,#e2ddd4 {S * 0.008:.2f}px {S * 0.02:.2f}px);'
             f'box-shadow:inset {S * 0.016:.2f}px 0 0 #F2681C"></i>')
    side_btn = (f'<i style="position:absolute;left:{W + gw - S * 0.012:.2f}px;top:{H * 0.555:.2f}px;width:{S * 0.03:.2f}px;height:{H * 0.14:.2f}px;'
                f'border-radius:{S * 0.015:.2f}px;background:linear-gradient(180deg,#cfc9bf,#989287)"></i>')
    action = (f'<i style="position:absolute;left:{-S * 0.034:.2f}px;top:{H * 0.385:.2f}px;width:{S * 0.07:.2f}px;height:{H * 0.2:.2f}px;'
              f'border-radius:{S * 0.03:.2f}px;background:linear-gradient(180deg,#ff8a3c,#ef5f14 60%,#d94e0b)"></i>')
    return (f'<div style="position:absolute;left:{x:.2f}px;top:{y:.2f}px;width:{W:.2f}px;height:{H:.2f}px;z-index:{z}">{bands}{action}{guard}{crown}{side_btn}'
            f'<div style="position:absolute;inset:0;border-radius:{rs + g + rim:.2f}px;padding:{rim:.2f}px;background:{ti};{shd}">'
            f'<div style="width:100%;height:100%;border-radius:{rs + g:.2f}px;padding:{g:.2f}px;background:#050505;'
            f'box-shadow:0 0 0 {max(S * 0.006, 0.5):.2f}px rgba(60,54,46,.55)">'
            f'<img src="{raw(lang, name)}" style="display:block;width:{S:.2f}px;height:{sh:.2f}px;border-radius:{rs:.2f}px"></div></div></div>')


def watch_size(S):
    e = 2 * S * 0.11
    return S + e, S * 514 / 422 + e


# ---------- Páginas ----------

BASE = f"""*{{box-sizing:border-box;margin:0;padding:0}}
i{{display:block;font-style:normal}}
body{{position:relative;overflow:hidden;font-family:{FONT};-webkit-font-smoothing:antialiased;text-rendering:geometricPrecision}}"""

# Motivo do ícone (degraus + cabeça), para o fundo
STEPS = ('<svg viewBox="0 0 1024 1024" style="position:absolute;{pos}" fill="none">'
         '<path d="M237 770H420V600H602V430H787" stroke="#fff" stroke-width="92" stroke-linecap="round" stroke-linejoin="round"/>'
         '<circle cx="706" cy="284" r="66" fill="#fff"/></svg>')


def orange_field(extra=""):
    return (f"background:radial-gradient(120% 90% at 78% 0%,rgba(255,170,96,.85) 0,rgba(255,170,96,0) 55%),"
            f"linear-gradient(180deg,{ICON_TOP} 0%,#EE6416 42%,{ICON_BOTTOM} 100%);{extra}")


def shot_page(lang, n):
    _, slug, screen, t_en, t_pt = SHOTS[n - 1]
    w, h = 660, 1434
    sw = 326 if slug == "watch" else 462
    pw, ph = phone_size(sw)
    px, py = (w - pw) / 2, 326
    title = title_html(t_en if lang == "en" else t_pt)
    devices = phone(lang, screen, sw, px, py)
    if slug == "watch":  # iPhone com o programa atrás; os dois relógios reais (série e descanso) na frente
        S = 208
        ww, wh = watch_size(S)
        crown, gap = S * 0.11, 30
        x1 = (w - (2 * ww + 2 * crown + gap)) / 2 + 8
        wy = py + ph + wh * 0.12 + 12  # iPhone em cima, relógios embaixo: nada cobre a tela do iPhone
        devices += watch(lang, "w1-set", S, x1, wy, band_up=0.12, band_down=0.4)
        devices += watch(lang, "w2-rest", S, x1 + ww + crown + gap, wy, band_up=0.12, band_down=0.4)
    return f"""<!doctype html><meta charset="utf-8"><style>{BASE}
html,body{{width:{w}px;height:{h}px;background:{CREAM}}}
.stage{{position:absolute;left:20px;right:20px;top:486px;bottom:20px;border-radius:72px;overflow:hidden;{orange_field()}}}
h1{{position:absolute;left:14px;right:14px;top:40px;height:262px;display:flex;align-items:center;justify-content:center;text-align:center;
font-size:66px;font-weight:800;letter-spacing:-.026em;word-spacing:.03em;line-height:1.07;color:{INK};white-space:nowrap}}
h1 .ac{{color:{ORANGE_TEXT}}}
</style><div class="stage"></div><h1><span>{title}</span></h1>{devices}"""


def creative_bg():
    # Laranja do ícone; o centro fica no tom trainingFill (#D4450C) para o texto branco ter 4,5:1.
    return ("background:radial-gradient(46% 78% at 50% 46%,#D4450C 0,rgba(212,69,12,.9) 45%,rgba(212,69,12,0) 100%),"
            "radial-gradient(60% 90% at 100% 0%,rgba(255,176,104,.9) 0,rgba(255,176,104,0) 60%),"
            "radial-gradient(60% 90% at 0% 100%,rgba(190,52,4,.9) 0,rgba(190,52,4,0) 60%),"
            f"linear-gradient(115deg,#E9590F 0%,#DB430A 45%,#E65A12 70%,{ICON_TOP} 100%)")


def steps_path(w, h, pts, sw, op=0.075):
    d = "M" + " ".join(f"{'L' if i else ''}{x} {y}" for i, (x, y) in enumerate(pts))
    return (f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" style="position:absolute;left:0;top:0" fill="none">'
            f'<path d="{d}" stroke="#fff" stroke-opacity="{op}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/></svg>')


def header_page(lang):
    w, h = 1920, 823
    lines = HEADER[lang].split("|")
    fs, lh, gap = 76, 1.04, 34
    S = 190
    ww, wh = watch_size(S)
    stub = wh * 0.1
    text_h = len(lines) * fs * lh
    total = text_h + gap + stub + wh + stub
    top = (h - total) / 2 + 10
    sw = 300
    pw, ph = phone_size(sw)
    col = 296  # meia largura da coluna central (frase + relógio)
    py = (h - ph) / 2
    devices = (phone(lang, "02-session", sw, w / 2 - col - pw, py) + phone(lang, "05-diet", sw, w / 2 + col, py)
               + watch(lang, "w1-set", S, (w - ww) / 2, top + text_h + gap + stub, band_up=0.1, band_down=0.1))
    # degraus do ícone só nas laterais (ambiente que pode ser recortado); o centro fica limpo
    motif = (steps_path(w, h, [(-120, 742), (176, 742), (176, 600), (520, 600)], 118)
             + steps_path(w, h, [(1400, 250), (1744, 250), (1744, 96), (2040, 96)], 118))
    return f"""<!doctype html><meta charset="utf-8"><style>{BASE}
html,body{{width:{w}px;height:{h}px;{creative_bg()}}}
h1{{position:absolute;left:0;right:0;top:{top:.1f}px;text-align:center;font-size:{fs}px;font-weight:800;letter-spacing:-.028em;
line-height:{lh};color:#fff;white-space:nowrap}}
</style>{motif}<h1>{"<br>".join(lines)}</h1>{devices}"""


def search_page(lang):
    w, h = 1920, 1280
    lines = SEARCH[lang].split("|")
    fs, lh = 104, 1.07
    top = 92
    text_h = len(lines) * fs * lh
    sw = 376
    pw, ph = phone_size(sw)
    py = top + text_h + 62
    S = 268
    ww, wh = watch_size(S)
    gap = 64
    crown = S * 0.11
    total = pw + gap + ww + crown + gap + pw
    x0 = (w - total) / 2
    wy = py + (ph - wh) / 2
    devices = (phone(lang, "02-session", sw, x0, py) + watch(lang, "w1-set", S, x0 + pw + gap, wy, band_up=0.12, band_down=0.12)
               + phone(lang, "05-diet", sw, x0 + pw + gap + ww + crown + gap, py))
    motif = (steps_path(w, h, [(-120, 1150), (150, 1150), (150, 900), (520, 900)], 170)
             + steps_path(w, h, [(1400, 900), (1770, 900), (1770, 650), (2040, 650)], 170))
    return f"""<!doctype html><meta charset="utf-8"><style>{BASE}
html,body{{width:{w}px;height:{h}px;{creative_bg()}}}
h1{{position:absolute;left:0;right:0;top:{top}px;text-align:center;font-size:{fs}px;font-weight:800;letter-spacing:-.028em;
line-height:{lh};color:#fff;white-space:nowrap}}
</style>{motif}<h1>{"<br>".join(lines)}</h1>{devices}"""


# ---------- Folhas de validação ----------

SHEET_CSS = (f"{BASE}\nbody{{background:#e9e9ee;color:#1c1c1e}}\n.lab{{position:absolute;font-size:15px;font-weight:600;color:#3a3a3c;white-space:nowrap}}\n"
             ".sm{font-weight:400;color:#6b6b70;font-size:13px}")


def existing_shots(lang):
    return [(n, slug, os.path.join(PNG, f"{lang}-0{n}-{slug}.png")) for n, slug, *_ in SHOTS]


def contact_page(lang):
    tw, th, g = 300, 300 * 2868 / 1320, 24
    w, h = round(7 * tw + 8 * g), round(th + 96)
    cells = ""
    for i, (n, slug, f) in enumerate(existing_shots(lang)):
        x = g + i * (tw + g)
        if os.path.exists(f):
            cells += f'<img src="file://{f}" style="position:absolute;left:{x}px;top:56px;width:{tw}px;height:{th:.1f}px;border-radius:14px">'
        else:
            cells += (f'<div style="position:absolute;left:{x}px;top:56px;width:{tw}px;height:{th:.1f}px;border-radius:14px;border:2px dashed #b00020;'
                      f'display:flex;align-items:center;justify-content:center;text-align:center;color:#b00020;font-size:17px;font-weight:600;padding:20px">'
                      f'FALTA<br>tela real em branco:<br>raw/{lang}-{SHOTS[n - 1][2]}.png</div>')
        cells += f'<div class="lab" style="left:{x}px;top:22px">{lang}-0{n}-{slug} <span class="sm">1320x2868</span></div>'
    return f'<!doctype html><meta charset="utf-8"><style>{SHEET_CSS}\nhtml,body{{width:{w}px;height:{h}px}}</style>{cells}', w, h


def search_sim_page():
    """Resultado de busca em iPhone de 402 pt: ícone, nome, subtítulo e as 3 primeiras capturas a ~120 pt. 1 px CSS = 1 pt."""
    import json
    kit = json.load(open(os.path.join(STORE, "store.json")))
    icon = "file://" + os.path.join(os.path.dirname(os.path.dirname(STORE)), "FitJourney/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    cw, pad = 402, 16
    tw = (cw - 2 * pad - 2 * 7) / 3  # ~118,7 pt
    th = tw * 2868 / 1320
    cols = ""
    blocks = [("shots", "en", "en-US"), ("shots", "pt", "pt-BR"), ("asset", "en", "en-US"), ("asset", "pt", "pt-BR")]
    for i, (kind, lang, loc) in enumerate(blocks):
        c = kit["locales"][loc]
        x = 30 + i * (cw + 30)
        head = (f'<img src="{icon}" style="position:absolute;left:{pad}px;top:16px;width:60px;height:60px;border-radius:13.5px">'
                f'<div style="position:absolute;left:{pad + 72}px;top:20px;font-size:17px;font-weight:600;letter-spacing:-.01em">{c["name"]}</div>'
                f'<div style="position:absolute;left:{pad + 72}px;top:44px;font-size:13px;color:#6b6b70">{c["subtitle"]}</div>')
        if kind == "shots":
            body = ""
            for j, (n, slug, f) in enumerate(existing_shots(lang)[:3]):
                body += (f'<img src="file://{f}" style="position:absolute;left:{pad + j * (tw + 7):.2f}px;top:92px;width:{tw:.2f}px;height:{th:.2f}px;'
                         f'border-radius:9px;box-shadow:0 0 0 .5px rgba(0,0,0,.12)">')
            lab = f"Busca sem ativo próprio · 3 primeiras a {tw:.0f} pt · {loc}"
        else:
            aw = cw - 2 * pad
            body = (f'<img src="file://{os.path.join(CRE, f"search-{lang}.png")}" style="position:absolute;left:{pad}px;top:92px;width:{aw}px;'
                    f'height:{aw * 2 / 3:.2f}px;border-radius:12px;box-shadow:0 0 0 .5px rgba(0,0,0,.12)">')
            lab = f"Ativo de busca 3:2 a {aw} pt · {loc}"
        cols += (f'<div class="lab" style="left:{x}px;top:18px">{lab}</div>'
                 f'<div style="position:absolute;left:{x}px;top:48px;width:{cw}px;height:{92 + th + 18:.1f}px;background:#fff;border-radius:22px;overflow:hidden">{head}{body}</div>')
    w, h = 30 + 4 * (cw + 30), round(48 + 92 + th + 18 + 30)
    return f'<!doctype html><meta charset="utf-8"><style>{SHEET_CSS}\nhtml,body{{width:{w}px;height:{h}px}}</style>{cols}', w, h


def header_sheet_page(lang):
    f = "file://" + os.path.join(CRE, f"header-{lang}.png")
    W, H = 3840, 1646
    fw = 1640; fh = fw * H / W
    w = fw + 80
    out = (f'<div class="lab" style="left:40px;top:22px">header-{lang}.png · 3840x1646 (21:9) <span class="sm">tracejado = área segura central 60% x 60%</span></div>'
           f'<img src="{f}" style="position:absolute;left:40px;top:56px;width:{fw}px;height:{fh:.1f}px">'
           f'<div style="position:absolute;left:{40 + fw * 0.2:.1f}px;top:{56 + fh * 0.2:.1f}px;width:{fw * 0.6:.1f}px;height:{fh * 0.6:.1f}px;'
           f'border:3px dashed #fff;outline:1px dashed rgba(0,0,0,.6)"></div>')
    y = 56 + fh + 70
    ch = 300
    crops = [("16:9", 16 / 9), ("4:3", 4 / 3), ("1:1", 1.0), ("3:4", 3 / 4)]
    total = sum(ch * r for _, r in crops) + 40 * (len(crops) - 1)
    x = (w - total) / 2
    for name, r in crops:
        cw = ch * r
        iw = ch * W / H
        out += (f'<div class="lab" style="left:{x:.1f}px;top:{y - 30:.1f}px">recorte central {name}</div>'
                f'<div style="position:absolute;left:{x:.1f}px;top:{y:.1f}px;width:{cw:.1f}px;height:{ch}px;overflow:hidden;border-radius:6px">'
                f'<img src="{f}" style="position:absolute;left:{(cw - iw) / 2:.1f}px;top:0;width:{iw:.1f}px;height:{ch}px"></div>')
        x += cw + 40
    h = round(y + ch + 40)
    return f'<!doctype html><meta charset="utf-8"><style>{SHEET_CSS}\nhtml,body{{width:{w}px;height:{h}px}}</style>{out}', w, h


def write(name, html):
    p = os.path.join(SRC, name)
    open(p, "w").write(html)
    return p


def render(src, out, W, H, scale=2):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([sys.executable, RENDER, src, out, f"{W}x{H}", "--scale", str(scale)], check=True, stdout=subprocess.DEVNULL)  # sequencial: um Chrome por vez
    print(out)


def build_shot(lang, n, do_render=True):
    slug, screen = SHOTS[n - 1][1], SHOTS[n - 1][2]
    f = os.path.join(RAW, f"{lang}-{screen}.png")
    if os.path.getsize(f) < 150_000:
        print(f"PULADA {lang}-0{n}-{slug}: {f} parece em branco ({os.path.getsize(f)} bytes); recapture e rode de novo")
        return
    src = write(f"shot-{lang}-0{n}-{slug}.html", shot_page(lang, n))
    if do_render:
        render(src, os.path.join(PNG, f"{lang}-0{n}-{slug}.png"), 1320, 2868)


def build_sheets(do=True):
    for lang in ("en", "pt"):
        html, w, h = contact_page(lang)
        src = write(f"sheet-contact-{lang}.html", html)
        if do:
            render(src, os.path.join(SHEETS, f"contact-{lang}.png"), w, h, 1)
    html, w, h = search_sim_page()
    src = write("sheet-search-sim.html", html)
    if do:
        render(src, os.path.join(SHEETS, "search-sim.png"), w * 3, h * 3, 3)
    for lang in ("en", "pt"):
        html, w, h = header_sheet_page(lang)
        src = write(f"sheet-header-crops-{lang}.html", html)
        if do:
            render(src, os.path.join(SHEETS, f"header-crops-{lang}.png"), w, h, 1)


def main(argv):
    cmd = argv[0] if argv else "all"
    do = cmd != "html"
    if cmd == "shot":
        build_shot(argv[1], int(argv[2]))
        return
    langs = argv[1:2] if len(argv) > 1 else ["en", "pt"]
    if cmd in ("all", "shots", "html"):
        for lang in langs:
            for n in range(1, 8):
                build_shot(lang, n, do)
    if cmd in ("all", "header", "html"):
        for lang in langs:
            src = write(f"header-{lang}.html", header_page(lang))
            if do:
                render(src, os.path.join(CRE, f"header-{lang}.png"), 3840, 1646)
    if cmd in ("all", "search", "html"):
        for lang in langs:
            src = write(f"search-{lang}.html", search_page(lang))
            if do:
                render(src, os.path.join(CRE, f"search-{lang}.png"), 3840, 2560)
    if cmd in ("all", "sheets", "html"):
        build_sheets(do)


if __name__ == "__main__":
    main(sys.argv[1:])
