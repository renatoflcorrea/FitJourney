#!/usr/bin/env python3
"""Mockups da proposta "Registrar refeições com IA" (design/proposals/ai-meal-log.md).

Gera HTML estático em src/html/ e PNGs de 1206 x 2622 px (402 x 874 pt @3x, iPhone 17 Pro) na pasta da proposta.
O visual vem do protótipo aprovado: o CSS e os símbolos são lidos de design/prototype.html, com os mesmos
tokens do DesignSystem (FJColor, FJRadius, FJSize). Liquid Glass é simulado com desfoque; só no que flutua.

Uso:  python3 design/proposals/ai-meal-log/src/build.py            # HTML + PNG
      python3 design/proposals/ai-meal-log/src/build.py --html     # só HTML
      python3 design/proposals/ai-meal-log/src/build.py 06         # só os que começam com "06"

Chrome: uma instância por vez, headless, perfil temporário apagado ao fim (nunca em paralelo).
"""
import math, random, re, shutil, subprocess, sys, tempfile
from pathlib import Path

SRC = Path(__file__).resolve().parent
OUT = SRC.parent
HTML = SRC / "html"
PROTO = SRC.parents[2] / "prototype.html"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

proto = PROTO.read_text(encoding="utf-8")
BASE_CSS = re.search(r"<style>(.*?)</style>", proto, re.S).group(1)
SYMBOLS = "".join(re.findall(r"<symbol id=.*?</symbol>", proto, re.S))

EXTRA_SYMBOLS = """
<symbol id="info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 11v5.500M12 7.600v.2"/></symbol>
<symbol id="flash" viewBox="0 0 24 24"><path d="M13 3L6 13.500h5.500L10.500 21 18 10.500h-5.500z"/></symbol>
<symbol id="flip" viewBox="0 0 24 24"><path d="M5 9a7.500 7.500 0 0113-2.500L20 8.500M20 4.500v4h-4M19 15a7.500 7.500 0 01-13 2.500L4 15.500M4 19.500v-4h4"/></symbol>
<symbol id="drop" viewBox="0 0 24 24"><path d="M12 3.500c3 4 6 7 6 10.500a6 6 0 01-12 0c0-3.500 3-6.500 6-10.500z"/></symbol>
<symbol id="mic" viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.500 11.500a6.500 6.500 0 0013 0M12 18v3"/></symbol>
<symbol id="updown" viewBox="0 0 24 24"><path d="M8 9.500l4-4 4 4M8 14.500l4 4 4-4"/></symbol>
<symbol id="checkcirc" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.500"/><path d="M7.500 12.300l3 3 6-6.300" fill="none" stroke="var(--knock,#fff)" stroke-width="2.200" stroke-linecap="round" stroke-linejoin="round"/></symbol>
<symbol id="gear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 3v2.500M12 18.500V21M3 12h2.500M18.500 12H21M5.600 5.600l1.800 1.800M16.600 16.600l1.800 1.800M5.600 18.400l1.800-1.800M16.600 7.400l1.800-1.800"/></symbol>
"""

EXTRA_CSS = """
html,body{margin:0;padding:0;width:402px;height:874px;overflow:hidden;background:#000}
body{padding:0}
.phone{width:402px;height:874px;border:0;border-radius:0;transform:none;box-shadow:none}
.island{top:14px;width:124px;height:36px;margin-left:-62px;border-radius:20px}
.status{height:62px;padding:15px 36px 0 44px;font-size:17px}
.status .sb{display:flex;align-items:center;gap:6px;font-size:13px;letter-spacing:0}
.status .sb svg{display:block}
.scroll{padding-top:66px}
.nav{top:62px}
.scroll.below-nav{padding-top:122px}
.num{font-family:"FJRounded",ui-rounded,"SF Pro Rounded",-apple-system,system-ui,sans-serif}
@font-face{font-family:"FJRounded";src:local(".SF NS Rounded"),local("SF Pro Rounded"),url("file:///System/Library/Fonts/SFNSRounded.ttf");font-weight:100 900}
svg.aig{width:1em;height:1em;flex:none;vertical-align:-.12em;stroke:none;fill:url(#aigL)}
.phone.dark svg.aig{fill:url(#aigD)}
.tabbar.five div{font-size:10px}

/* folha .large do sistema sobre a tela anterior */
.under{position:absolute;inset:0;background:var(--bg)}
.dim{position:absolute;inset:0;background:rgba(0,0,0,.36)}
.phone.dark .dim{background:rgba(0,0,0,.5)}
.peek{position:absolute;left:10px;right:10px;top:56px;height:40px;border-radius:30px 30px 0 0;background:var(--surface);opacity:.55}
.sheet{position:absolute;left:0;right:0;top:66px;bottom:0;background:var(--bg);border-radius:38px 38px 0 0;overflow:hidden;box-shadow:0 -6px 30px rgba(0,0,0,.18)}
.sheet .nav{top:14px;min-height:44px}
.sheet .scroll{padding-top:76px}
.sheet .ttl{position:absolute;left:0;right:0;text-align:center;pointer-events:none}

/* barra "Registrar com IA" (vidro; flutua acima da tab bar) */
.logbar{position:absolute;left:16px;right:16px;bottom:100px;display:flex;gap:8px;z-index:31}
.logbar .field{flex:1;height:52px;border-radius:26px;display:flex;align-items:center;gap:10px;padding:0 18px;font-size:17px;color:var(--text2);position:relative}
.logbar .field svg{font-size:23px}
.logbar .cam{width:52px;height:52px;border-radius:50%;display:grid;place-items:center;font-size:23px;color:var(--text);flex:none}
.logbar .field b{color:var(--text);font-weight:600}
.logbar .field small{font-size:13px;color:var(--text2);margin-left:auto}

/* composição */
.txt{background:var(--surface);border-radius:20px;padding:14px 16px;font-size:17px;line-height:1.42;min-height:150px;position:relative}
.txt .ph{color:var(--text3)}
.txt .caret{display:inline-block;width:2px;height:21px;background:var(--coach);vertical-align:-4px;margin-left:1px;border-radius:1px}
.txt .cnt{position:absolute;right:14px;bottom:10px;font-size:12px;color:var(--text2)}
.lbl{font-size:13px;font-weight:600;color:var(--text2);margin:16px 4px 8px;letter-spacing:.01em}
.chip.glass{background:var(--glass)}
.tiles{display:flex;gap:10px}
.tile{flex:1;min-height:56px;border-radius:16px;border:1.5px dashed color-mix(in srgb,var(--coach) 70%,transparent);background:color-mix(in srgb,var(--coach) 7%,transparent);
  display:flex;align-items:center;justify-content:center;gap:8px;font-size:15px;font-weight:600;color:var(--text)}
.tile svg{font-size:20px;color:var(--coach)}
.daychip{display:inline-flex;align-items:center;gap:6px;height:36px;padding:0 12px;border-radius:18px;background:var(--surface);font-size:15px;font-weight:600}
.daychip svg{color:var(--text2);font-size:15px}

/* foto */
.shot{position:relative;border-radius:20px;overflow:hidden;background:#3a2a1e}
.shot svg.food{display:block;width:100%;height:auto}
.shot .x{position:absolute;top:10px;right:10px;width:32px;height:32px;border-radius:50%;display:grid;place-items:center;font-size:14px;color:var(--text)}
.shot .again{position:absolute;left:10px;bottom:10px;height:36px;padding:0 14px;border-radius:18px;display:flex;align-items:center;gap:6px;font-size:14px;font-weight:600;color:var(--text)}
.pthumb{width:84px;height:84px;border-radius:16px;overflow:hidden;flex:none;background:#3a2a1e}
.pthumb svg{display:block;width:100%;height:100%}
.field2{background:var(--surface);border-radius:14px;padding:12px 14px;font-size:16px;line-height:1.35;min-height:48px}
.field2 .ph{color:var(--text3)}

/* revisão */
.total b{font-size:34px;font-weight:700;line-height:1.05;letter-spacing:-.01em}
.total b small{font-size:17px;font-weight:600;color:var(--text2);margin-left:4px}
.range{position:relative;height:8px;border-radius:4px;background:var(--fill);margin:8px 0 4px}
.range i{position:absolute;top:0;bottom:0;border-radius:4px;background:color-mix(in srgb,var(--nutrition) 38%,transparent)}
.range b{position:absolute;top:-3px;width:4px;height:14px;border-radius:2px;background:var(--nutrition)}
.rcap{display:flex;justify-content:space-between;font-size:12px;color:var(--text2)}
.seg.full{display:flex;width:100%}
.seg.full span{flex:1;text-align:center;padding:8px 4px;font-size:14px;white-space:nowrap}
.it{padding:11px 0;border-top:1px solid var(--sep)}
.it:first-child{border-top:0;padding-top:2px}
.it .l1{display:flex;justify-content:space-between;align-items:baseline;gap:10px;font-size:16px}
.it .l1 span:last-child{font-size:15px;font-weight:600;white-space:nowrap}
.it .l2{display:flex;justify-content:space-between;align-items:center;gap:8px;font-size:13px;color:var(--text2);margin-top:2px}
.it .why{font-size:12.5px;color:var(--text2);margin-top:6px;display:flex;flex-wrap:wrap;align-items:center;gap:6px}
.it .edit{display:flex;align-items:center;gap:10px;margin-top:10px}
.it .edit .rb{width:48px;height:48px;border-radius:50%;background:var(--fill2);display:grid;place-items:center;font-size:19px;flex:none}
.it .edit .val{flex:1;text-align:center;font-size:28px;font-weight:600;line-height:1}
.it .edit .val small{font-size:15px;color:var(--text2);font-weight:500;margin-left:4px}
.addrow{display:flex;align-items:center;gap:8px;min-height:44px;border-top:1px solid var(--sep);font-size:16px;font-weight:600;color:var(--nutrition)}
.mealhd{display:flex;align-items:flex-start;gap:12px}
.mealhd .t{font-weight:600;color:var(--text2);font-size:15px;padding-top:2px;width:44px;flex:none}
.mealhd .kc{margin-left:auto;font-weight:600;font-size:15px;white-space:nowrap;padding-top:2px}
.qchips{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}
.qchips span{min-height:40px;padding:0 14px;border-radius:20px;display:inline-flex;align-items:center;gap:5px;font-size:14px;font-weight:500}
.qchips span.picked{font-weight:600;outline:1.5px solid var(--nutrition);outline-offset:-1.5px}
.qchips span.picked svg{color:var(--nutrition)}
.toast{position:absolute;left:16px;right:16px;bottom:162px;border-radius:26px;min-height:52px;display:flex;align-items:center;gap:10px;padding:6px 6px 6px 16px;z-index:32;font-size:15px;font-weight:600}
.toast svg{font-size:20px;color:var(--success)}
.toast .u{margin-left:auto;height:40px;padding:0 16px;border-radius:20px;background:var(--fill2);display:grid;place-items:center;font-size:15px}
.est{display:inline-flex;align-items:center;gap:3px;font-size:12px;color:var(--text2);font-weight:500}

/* câmera do sistema com dica sobreposta */
.cam-screen{position:absolute;inset:0;background:#000;color:#fff}
.cam-screen .vf{position:absolute;left:0;right:0;top:118px;height:536px;overflow:hidden;background:#2a1d14}
.cam-screen .vf svg{position:absolute;left:50%;top:50%;width:150%;transform:translate(-50%,-50%)}
.cam-screen .hint{position:absolute;left:50%;top:134px;transform:translateX(-50%);height:36px;padding:0 14px;border-radius:18px;display:flex;align-items:center;gap:6px;font-size:14px;font-weight:600;white-space:nowrap;
  background:rgba(30,30,32,.55);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px);border:1px solid rgba(255,255,255,.16)}
.cam-screen .topc{position:absolute;top:70px;left:20px;right:20px;display:flex;justify-content:space-between;font-size:20px}
.cam-screen .topc span{width:40px;height:40px;border-radius:50%;background:rgba(255,255,255,.14);display:grid;place-items:center}
.cam-screen .zoom{position:absolute;left:0;right:0;top:606px;display:flex;justify-content:center;gap:10px}
.cam-screen .zoom span{width:34px;height:34px;border-radius:50%;background:rgba(0,0,0,.45);display:grid;place-items:center;font-size:12px;font-weight:600}
.cam-screen .zoom span.on{color:#FFD60A;width:40px;height:40px;font-size:13px}
.cam-screen .mode{position:absolute;left:0;right:0;top:672px;text-align:center;font-size:13px;font-weight:600;letter-spacing:.04em;color:#FFD60A}
.cam-screen .ctl{position:absolute;left:0;right:0;top:708px;display:flex;align-items:center;justify-content:space-between;padding:0 34px}
.cam-screen .ctl .c{font-size:18px;width:76px}
.cam-screen .ctl .sh{width:74px;height:74px;border-radius:50%;border:4px solid #fff;display:grid;place-items:center}
.cam-screen .ctl .sh i{width:60px;height:60px;border-radius:50%;background:#fff}
.cam-screen .ctl .fl{width:76px;display:flex;justify-content:flex-end}
.cam-screen .ctl .fl span{width:48px;height:48px;border-radius:50%;background:rgba(255,255,255,.14);display:grid;place-items:center;font-size:22px}
.cam-screen .guide{position:absolute;left:38px;right:38px;top:214px;height:326px;border-radius:50%;border:2px dashed rgba(255,255,255,.55)}

/* quadro de estados */
.boardpg{position:absolute;inset:0;background:var(--bg);padding:26px 16px 0;overflow:hidden}
.boardpg h4{font-size:22px;font-weight:700;letter-spacing:-.01em;margin:0 4px 2px}
.boardpg .bn{font-size:11px;font-weight:700;letter-spacing:.06em;color:var(--text2);margin:9px 4px 5px;text-transform:uppercase}
.boardpg .banner{margin-bottom:0;font-size:13.5px;padding:9px 12px}
.boardpg .banner .ba{margin-top:6px}
.boardpg .banner b{font-size:14.5px}
.boardpg .banner .ba span{height:36px;font-size:13.5px;padding:0 14px}
.boardpg .logbar{position:static}
"""

GRADS = """
<linearGradient id="aigL" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0A6FB8"/><stop offset=".52" stop-color="#7C3AED"/><stop offset="1" stop-color="#C2256E"/></linearGradient>
<linearGradient id="aigD" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5AC8FA"/><stop offset=".52" stop-color="#A78BFA"/><stop offset="1" stop-color="#F472B6"/></linearGradient>
"""


def ic(name, cls="i", style=""):
    st = f' style="{style}"' if style else ""
    return f'<svg class="{cls}"{st}><use href="#{name}"/></svg>'


def ai(style=""):
    st = f' style="{style}"' if style else ""
    return f'<svg class="aig"{st}><use href="#sparkles"/></svg>'


def status(time):
    return (f'<div class="island"></div><div class="status"><span class="num">{time}</span><span class="sb">'
            '<svg width="18" height="12" viewBox="0 0 18 12"><rect x="0" y="8" width="3" height="4" rx="1" fill="currentColor"/><rect x="5" y="5.500" width="3" height="6.500" rx="1" fill="currentColor"/><rect x="10" y="3" width="3" height="9" rx="1" fill="currentColor"/><rect x="15" y="0" width="3" height="12" rx="1" fill="currentColor"/></svg>'
            '<svg width="17" height="12" viewBox="0 0 17 12" fill="none" stroke="currentColor" stroke-width="1.900" stroke-linecap="round"><path d="M1.500 4.300a10.500 10.500 0 0114 0M4 7a6.800 6.800 0 019 0"/><circle cx="8.500" cy="10" r="1.300" fill="currentColor" stroke="none"/></svg>'
            '<svg width="27" height="13" viewBox="0 0 27 13"><rect x=".500" y=".500" width="22" height="12" rx="3.800" fill="none" stroke="currentColor" opacity=".4"/><rect x="2" y="2" width="16" height="9" rx="2.400" fill="currentColor"/><rect x="24" y="4.300" width="2" height="4.400" rx="1" fill="currentColor" opacity=".45"/></svg>'
            '</span></div><div class="home"></div>')


TABS = [("sun", "Hoje"), ("dumbbell", "Treinos"), ("fork", "Dieta"), ("heart", "Saúde"), ("sparkles", "Coach")]


def tabbar(on=2):
    cells = "".join(f'<div class="{"on" if i == on else ""}">{ic(n)}{t}</div>' for i, (n, t) in enumerate(TABS))
    return f'<div class="tabbar glass five">{cells}</div>'


def logbar(text="O que você comeu?", extra=""):
    return (f'<div class="logbar"><div class="field glass aiborder">{ai()}<span>{text}</span>{extra}</div>'
            f'<div class="cam glass">{ic("camera")}</div></div>')


# ---------- prato (ilustração vetorial; a foto real vem da câmera) ----------
def plate(seed=7):
    rnd = random.Random(seed)
    o = ['<svg class="food" viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice">',
         '<defs>',
         '<linearGradient id="wood" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9A6A45"/><stop offset=".55" stop-color="#7B4E31"/><stop offset="1" stop-color="#5B3722"/></linearGradient>',
         '<radialGradient id="pl" cx=".42" cy=".36" r=".75"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".72" stop-color="#F3F1EC"/><stop offset="1" stop-color="#CFCAC0"/></radialGradient>',
         '<radialGradient id="ricesh" cx=".4" cy=".35" r=".8"><stop offset="0" stop-color="#FFFDF6"/><stop offset="1" stop-color="#E7E0CC"/></radialGradient>',
         '<linearGradient id="chk" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E2A662"/><stop offset="1" stop-color="#B97A3C"/></linearGradient>',
         '<radialGradient id="bean" cx=".4" cy=".35" r=".9"><stop offset="0" stop-color="#6E3B28"/><stop offset="1" stop-color="#3E1F15"/></radialGradient>',
         '<radialGradient id="vig" cx=".5" cy=".5" r=".75"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".42"/></radialGradient>',
         '<filter id="soft"><feGaussianBlur stdDeviation="7"/></filter>',
         '</defs>',
         '<rect width="400" height="300" fill="url(#wood)"/>']
    for i in range(26):  # veios da madeira
        y = rnd.uniform(-10, 310)
        o.append(f'<path d="M-10 {y:.0f} C 120 {y + rnd.uniform(-9, 9):.0f}, 260 {y + rnd.uniform(-9, 9):.0f}, 410 {y + rnd.uniform(-6, 6):.0f}" '
                 f'stroke="#3B2315" stroke-opacity="{rnd.uniform(.08, .24):.2f}" stroke-width="{rnd.uniform(.6, 2.2):.1f}" fill="none"/>')
    for x in (132, 268):  # juntas das tábuas
        o.append(f'<path d="M{x} -5 V305" stroke="#2A170D" stroke-opacity=".35" stroke-width="2"/>')
    # garfo
    o.append('<g transform="translate(352 150) rotate(8)" fill="#C9CCD1" stroke="#8E9299" stroke-width=".8">'
             '<rect x="-4" y="-10" width="8" height="118" rx="4"/><path d="M-11 -62h4v40h3v-40h4v40h3v-40h4v44a9 9 0 01-9 9a9 9 0 01-9-9z"/></g>')
    # prato
    o.append('<ellipse cx="204" cy="160" rx="134" ry="130" fill="#000" opacity=".38" filter="url(#soft)"/>')
    o.append('<circle cx="198" cy="150" r="128" fill="url(#pl)"/>')
    o.append('<circle cx="198" cy="150" r="97" fill="none" stroke="#DAD5CA" stroke-width="2"/>')
    o.append('<circle cx="198" cy="150" r="96" fill="#FBFAF7"/>')
    # arroz (esquerda, em cima)
    o.append('<path d="M118 132c-6-30 22-58 58-56 30 2 44 22 40 46-4 26-26 44-56 44-22 0-38-12-42-34z" fill="url(#ricesh)"/>')
    for i in range(210):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0, 1) ** .6
        x = 166 + math.cos(a) * 46 * r; y = 122 + math.sin(a) * 40 * r
        o.append(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="4.200" ry="1.700" transform="rotate({rnd.uniform(0, 180):.0f} {x:.1f} {y:.1f})" '
                 f'fill="#FFFEF9" stroke="#D9D0B8" stroke-width=".5"/>')
    # feijão (direita, em cima)
    o.append('<path d="M214 96c20-12 52-4 62 18 8 18-2 38-24 42-24 4-44-8-48-28-2-14 2-26 10-32z" fill="#4A2618"/>')
    for i in range(46):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0, 1) ** .55
        x = 242 + math.cos(a) * 30 * r; y = 124 + math.sin(a) * 26 * r
        o.append(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="6.300" ry="4" transform="rotate({rnd.uniform(0, 180):.0f} {x:.1f} {y:.1f})" fill="url(#bean)"/>')
        o.append(f'<ellipse cx="{x - 1.5:.1f}" cy="{y - 1.2:.1f}" rx="1.800" ry=".900" fill="#B98A6E" opacity=".55"/>')
    # frango grelhado (embaixo, à esquerda)
    o.append('<path d="M112 176c10-16 40-20 70-12 26 7 40 22 34 40-6 18-34 26-64 20-30-6-50-28-40-48z" fill="url(#chk)" stroke="#9A6230" stroke-width="1.500"/>')
    for k in range(5):
        x0 = 124 + k * 17
        o.append(f'<path d="M{x0} {214 - k * 1.5:.0f} L{x0 + 26} {176 + k * 2}" stroke="#5E3414" stroke-width="5" stroke-linecap="round" opacity=".78"/>')
    o.append('<path d="M126 186c14-10 36-10 58-4" stroke="#F4CF9A" stroke-width="3" stroke-linecap="round" fill="none" opacity=".6"/>')
    # salada (embaixo, à direita)
    for i in range(11):
        x = 248 + rnd.uniform(-26, 26); y = 196 + rnd.uniform(-22, 22); s = rnd.uniform(14, 24)
        col = rnd.choice(["#6FAE3A", "#86C24A", "#5B9A2E", "#9BD05C"])
        o.append(f'<path d="M{x:.0f} {y:.0f} q{s:.0f} {-s * .9:.0f} {s * 1.5:.0f} {-s * .1:.0f} q{-s * .2:.0f} {s:.0f} {-s * 1.2:.0f} {s * .7:.0f} q{-s * .6:.0f} {-s * .1:.0f} {-s * .3:.0f} {-s * .6:.0f}z" '
                 f'fill="{col}" stroke="#3F7420" stroke-width=".8" transform="rotate({rnd.uniform(-40, 40):.0f} {x:.0f} {y:.0f})"/>')
    for (x, y, r) in ((238, 182, 13), (266, 204, 12), (244, 214, 11)):
        o.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#D9412E" stroke="#A82A1C" stroke-width="1.200"/>')
        o.append(f'<circle cx="{x}" cy="{y}" r="{r - 4}" fill="#EE6A55"/>')
        for a in range(0, 360, 60):
            o.append(f'<ellipse cx="{x + math.cos(math.radians(a)) * (r - 6.5):.1f}" cy="{y + math.sin(math.radians(a)) * (r - 6.5):.1f}" rx="1.500" ry="1" fill="#F9D7A0"/>')
    o.append('<path d="M108 96a128 128 0 0196-70" stroke="#fff" stroke-width="5" stroke-linecap="round" fill="none" opacity=".5"/>')
    o.append('<rect width="400" height="300" fill="url(#vig)"/>')
    o.append('</svg>')
    return "".join(o)


def page(name, body, theme="t-nutrition", dark=False):
    cls = "phone " + theme + (" dark" if dark else "")
    html = (f'<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>{name}</title>'
            f'<style>{BASE_CSS}{EXTRA_CSS}</style></head><body>'
            f'<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>{GRADS}</defs>{SYMBOLS}{EXTRA_SYMBOLS}</svg>'
            f'<div class="{cls}">{body}</div></body></html>')
    (HTML / f"{name}.html").write_text(html, encoding="utf-8")
    return name


def sheet(time, title, inner, bottom="", left="Cancelar", right=""):
    rightbox = right or '<div style="width:86px"></div>'
    leftbox = f'<div class="pill glass">{left}</div>' if left else '<div style="width:86px"></div>'
    return (status(time) + '<div class="under"></div><div class="dim"></div><div class="peek"></div>'
            f'<div class="sheet"><div class="nav">{leftbox}<div class="ttl">{title}</div>{rightbox}</div>'
            f'<div class="scroll">{inner}</div>'
            + (f'<div class="fade"></div><div class="bottom">{bottom}</div>' if bottom else "") + '</div>')


PAGES = {}


def register(fn):
    PAGES[fn.__name__] = fn
    return fn


# ---------- peças repetidas ----------
def totals(kcal, of, pct, p, c, g, foot=""):
    off = 232.5 * (1 - pct)
    return (f'<div class="card"><div class="row" style="gap:16px;align-items:flex-start">'
            f'<div class="ring"><svg viewBox="0 0 84 84"><circle class="t" cx="42" cy="42" r="37"/><circle class="p" cx="42" cy="42" r="37" stroke-dasharray="232.5" stroke-dashoffset="{off:.1f}"/></svg>'
            f'<div class="num">{kcal}<small>de {of} kcal</small></div></div><div style="flex:1">'
            + "".join(f'<div class="goal"><div class="row"><span>{n}</span><span class="num">{v}</span></div><div class="bar"><i style="width:{w}%"></i></div></div>'
                      for n, v, w in (("Proteína", *p), ("Carboidrato", *c), ("Gordura", *g)))
            + f'</div></div>{foot}</div>')


def water(text, on):
    cups = "".join(f'<i class="{"on" if i < on else ""}"></i>' for i in range(12))
    return (f'<div class="card" style="padding:12px 16px"><div class="row"><div style="white-space:nowrap"><div class="cap">Água</div>'
            f'<b class="num" style="font-weight:600">{text}</b></div><div class="cups sp">{cups}</div></div></div>')


def conf(level, text):
    bars = "".join(f'<i class="{"f" if i < level else ""}"></i>' for i in range(3))
    cls = {3: " hi", 2: "", 1: " lo"}[level]
    warn = ic("warn") if level == 1 else ""
    return f'<span class="conf{cls}">{warn}<span class="bars">{bars}</span>{text}</span>'


DAYNAV = (f'<div class="daynav"><span>{ic("left")}</span>Hoje, 15 nov<span>{ic("right")}</span></div>')
LARGE = (f'<div class="large"><h3>Dieta</h3><div class="acts"><div class="gbtn glass">{ic("plus")}</div>'
         f'<div class="gbtn glass">{ic("dots")}</div></div></div>')


# ---------- 01 · entrada na aba Dieta ----------
@register
def p01_dieta_entrada(dark=False):
    body = status("12:41") + f"""
<div class="scroll">{LARGE}{DAYNAV}
{totals("600", "2.200", .27, ("38 / 150 g", 25), ("72 / 220 g", 33), ("19 / 70 g", 27))}
{water("1,0 / 3,0 L", 4)}
<div class="tl">
  <div class="meal done"><span class="hrs num">7:30</span><div class="card"><div class="row"><div class="h" style="font-size:16px">Café da manhã</div><span class="cap num sp">420 kcal</span><span class="tag ok">{ic("check")}Feita</span></div></div></div>
  <div class="meal done"><span class="hrs num">10:00</span><div class="card"><div class="row"><div class="h" style="font-size:16px">Lanche</div><span class="cap num sp">180 kcal</span><span class="tag ok">{ic("check")}Feita</span></div></div></div>
  <div class="meal next"><span class="hrs num" style="color:var(--text);font-weight:600">12:30</span><div class="card">
    <div class="row"><div class="h">Almoço</div><span class="cap num sp">680 kcal</span><span class="tag ok">{ic("fork")}Agora</span></div>
    <div style="margin-top:8px">
      <div class="item"><span>Arroz integral</span><span class="num">150 g · 170 kcal</span></div>
      <div class="item"><span>Frango grelhado {ic("swap", "i", "color:var(--text2);font-size:13px")}</span><span class="num">180 g · 300 kcal</span></div>
      <div class="item"><span>Feijão</span><span class="num">100 g · 80 kcal</span></div>
    </div>
    <div class="acts2"><div class="chk">{ic("check")}</div><b style="font-weight:600">Feita</b><span class="lnk sp">Ajustar</span><span class="lnk">Pular</span></div>
  </div></div>
  <div class="meal"><span class="hrs num">16:00</span><div class="card"><div class="h" style="font-size:16px">Lanche da tarde</div></div></div>
  <div class="meal"><span class="hrs num">20:00</span><div class="card"><div class="h" style="font-size:16px">Jantar</div></div></div>
</div></div>
<div class="fade" style="height:250px;background:linear-gradient(transparent,var(--bg) 46%)"></div>
{logbar()}{tabbar(2)}"""
    return page("01-dieta-entrada" + ("-escuro" if dark else ""), body, dark=dark)


# ---------- 02 · folha: texto do dia ----------
@register
def p02_folha_texto(dark=False):
    inner = f"""
<div class="row" style="justify-content:space-between;margin:0 2px 12px">
  <span class="daychip">{ic("cal")}Hoje, 15 nov{ic("down")}</span>
  <span class="cap">registros entram neste dia</span></div>
<div class="txt">Café: 2 ovos mexidos e 1 pão francês com manteiga, café com leite.<br>
Almoço como no plano.<br>
À tarde tomei um açaí com granola.<br>
Jantar: omelete de 3 ovos com queijo e salada.<span class="caret"></span>
<div style="height:22px"></div><span class="cnt num">176 / 2.000</span></div>
<div class="lbl">Inserir refeição do plano</div>
<div class="chips"><span class="chip glass">Café da manhã</span><span class="chip glass">Lanche</span><span class="chip glass">Almoço</span><span class="chip glass">Lanche da tarde</span><span class="chip glass">Jantar</span></div>
<div class="lbl">Fotos (opcional, até 4)</div>
<div class="tiles"><div class="tile">{ic("camera")}Câmera</div><div class="tile">{ic("photo")}Galeria</div></div>
<div class="banner" style="margin-top:16px">{ic("lock")}<div><b>O texto e as fotos vão para a OpenAI</b>As fotos saem reduzidas e sem localização. Seu histórico e seu plano não são enviados.</div></div>
"""
    bottom = f'<div class="aibtn">{ic("sparkles", "i f")}Analisar</div>'
    return page("02-folha-texto" + ("-escuro" if dark else ""), sheet("21:34", "Registrar com IA", inner, bottom), dark=dark)


# ---------- 03 · câmera ----------
@register
def p03_captura_foto(dark=False):
    body = f"""<div class="cam-screen">
<div class="island"></div>
<div class="topc"><span>{ic("flash")}</span><span>{ic("x")}</span></div>
<div class="vf">{plate()}</div>
<div class="hint">{ic("camera")}Prato inteiro, de cima, com boa luz</div>
<div class="zoom"><span class="num">,5</span><span class="on num">1x</span><span class="num">2</span></div>
<div class="mode">FOTO</div>
<div class="ctl"><div class="c">Cancelar</div><div class="sh"><i></i></div><div class="fl"><span>{ic("flip")}</span></div></div>
<div class="home" style="background:#fff"></div></div>"""
    return page("03-captura-foto", body, dark=True)


# ---------- 04 · foto anexada, antes de enviar ----------
@register
def p04_foto_anexada(dark=False):
    inner = f"""
<div class="shot">{plate()}<span class="x glass">{ic("x")}</span><span class="again glass">{ic("camera")}Tirar outra</span></div>
<div class="lbl">Algo que a foto não mostra? (opcional)</div>
<div class="field2">Arroz integral. Frango grelhado sem óleo.</div>
<div class="lbl">Refeição</div>
<div class="form"><div class="fr"><div>Almoço · <span class="num">12:30</span><small>Sugerida pelo horário</small></div><div class="v">Trocar {ic("updown")}</div></div>
<div class="fr">Horário<div class="v num">12:41</div></div></div>
<div class="banner" style="margin-top:14px">{ic("lock")}<div><b>A foto vai para a OpenAI</b>Reduzida e sem localização. Não fica guardada no FitJourney. Seu histórico não é enviado.</div></div>
"""
    bottom = f'<div class="aibtn">{ic("sparkles", "i f")}Analisar foto</div>'
    return page("04-foto-anexada" + ("-escuro" if dark else ""), sheet("12:41", "Registrar com IA", inner, bottom), dark=dark)


# ---------- 05 · analisando ----------
@register
def p05_analisando(dark=False):
    inner = f"""
<div style="height:70px"></div>
<div class="orb lg">{ai()}</div>
<div class="h" style="text-align:center;font-size:20px;margin-top:14px">Lendo a foto…</div>
<div class="sub" style="text-align:center;margin-top:2px">Enviada à OpenAI · <span class="num">0:06</span></div>
<div class="steps2" style="padding:0 6px">
  <div class="st">{ic("check")}<div>Foto enviada<small>1 foto · 240 KB · sem localização</small></div></div>
  <div class="st">{ai("font-size:18px;width:24px;margin-top:1px")}<div><b>Encontrei 4 alimentos</b><small>Arroz · Frango grelhado · Feijão · Salada</small></div></div>
  <div class="st">{ic("dots", "i aisym")}<div><b>Estimando porções e calorias</b><small>Item 3 de 4</small></div></div>
  <div class="st pend">{ic("ring")}<div>Comparar com o almoço do plano<small>No aparelho, sem enviar o plano</small></div></div>
</div>
"""
    bottom = '<div style="display:flex;justify-content:center"><div class="secondary glass" style="flex:none;padding:0 34px">Cancelar</div></div>'
    return page("05-analisando" + ("-escuro" if dark else ""), sheet("12:41", "Registrar com IA", inner, bottom, left=""), dark=dark)


# ---------- 06 · revisão da estimativa (foto) ----------
@register
def p06_revisao_foto(dark=False):
    inner = f"""
<div class="row" style="align-items:flex-start;gap:14px;margin:0 2px 12px">
  <div class="pthumb">{plate()}</div>
  <div class="total" style="flex:1;min-width:0">
    <span class="aitag">{ai()}Estimativa da IA</span>
    <div style="margin-top:6px"><b class="num">≈ 545<small>kcal</small></b></div>
    <div class="range"><i style="left:16%;right:22%"></i><b style="left:44%"></b></div>
    <div class="rcap num"><span>450</span><span>entre 450 e 660 kcal</span><span>660</span></div>
  </div>
</div>
<div class="card" style="padding:12px 16px">
  <div class="metrics"><div class="metric"><div class="cap">Proteína</div><b class="num">≈ 52<small>g</small></b></div>
  <div class="metric"><div class="cap">Carboidrato</div><b class="num">≈ 58<small>g</small></b></div>
  <div class="metric"><div class="cap">Gordura</div><b class="num">≈ 9<small>g</small></b></div></div>
</div>
<div class="card">
  <div class="row"><div><div class="over">REGISTRAR COMO</div><div class="h" style="margin-top:2px">Almoço · <span class="num">12:30</span></div></div><div class="sp cap" style="color:var(--nutrition);font-weight:600;font-size:15px">Trocar</div></div>
  <div class="seg full" style="margin-top:10px"><span>Feita</span><span class="on">Ajustada</span><span>Fora da dieta</span></div>
  <div class="cap" style="margin-top:8px;line-height:1.35">Registra o que a foto mostra no lugar dos itens do plano (arroz integral 150 g, frango 180 g, feijão 100 g).</div>
</div>
<div class="card" style="padding-bottom:4px">
  <div class="over" style="margin-bottom:8px">ITENS · TOQUE PARA EDITAR</div>
  <div class="it">
    <div class="l1"><span>Arroz integral</span><span class="num">≈ 185 kcal</span></div>
    <div class="edit"><span class="rb">{ic("minus")}</span><div class="val num">150<small>g</small></div><span class="rb">{ic("plus")}</span></div>
    <div class="why">{conf(2, "Conferir")}porção entre 120 e 190 g</div>
  </div>
  <div class="it"><div class="l1"><span>Frango grelhado</span><span class="num">≈ 265 kcal</span></div><div class="l2"><span class="num">≈ 160 g</span></div></div>
  <div class="it"><div class="l1"><span>Feijão carioca</span><span class="num">≈ 70 kcal</span></div><div class="l2"><span class="num">≈ 90 g</span></div>
    <div class="why">{conf(1, "Revisar")}parte está sob o frango</div></div>
  <div class="it"><div class="l1"><span>Salada de alface e tomate</span><span class="num">≈ 25 kcal</span></div><div class="l2"><span class="num">≈ 90 g</span></div></div>
  <div class="addrow">{ic("plus")}Adicionar item</div>
</div>
<div class="cap" style="margin:0 4px">Não aparecem na foto: óleo de preparo e bebida. Adicione se quiser.</div>
"""
    bottom = '<div class="primary" style="background:var(--nutrition-fill)">Registrar</div>'
    return page("06-revisao-foto" + ("-escuro" if dark else ""),
                sheet("12:41", "Revisar registro", inner, bottom, right=f'<div class="gbtn glass">{ic("dots")}</div>'), dark=dark)


# ---------- 07 · revisão do dia (texto) ----------
@register
def p07_revisao_dia(dark=False):
    def row(name, qty, kcal, why=""):
        return (f'<div class="rvx"><div style="display:flex;justify-content:space-between;gap:10px"><span>{name}</span>'
                f'<span class="p num" style="white-space:nowrap">{qty} · {kcal}</span></div>{why}</div>')
    mudar = '<span class="cap" style="color:var(--nutrition);font-weight:600;margin-left:auto;font-size:14px">Mudar</span>'
    inner = f"""
<div class="row" style="justify-content:space-between;align-items:flex-end;margin:0 2px 10px">
  <div class="total"><span class="aitag">{ai()}Rascunho da IA</span>
    <div style="margin-top:6px"><b class="num">≈ 1.790<small>kcal</small></b></div>
    <div class="cap">Hoje, 15 nov · 4 refeições · 12 itens</div></div>
  <div class="cap" style="text-align:right;line-height:1.3"><span class="num">680</span> informadas<br><span class="num">≈ 1.110</span> estimadas</div>
</div>
<div class="card" style="padding-bottom:6px">
  <div class="mealhd"><span class="t num">07:30</span><div><div class="h">Café da manhã</div></div><span class="kc num">≈ 480 kcal</span></div>
  <div class="row" style="margin:8px 0 2px;gap:6px"><span class="tag at">{ic("pencil")}Ajustada</span><span class="cap">no lugar de aveia, ovos e banana</span>{mudar}</div>
  <div style="margin-top:8px">
  {row("Ovos mexidos", "2 un", "≈ 180 kcal")}
  {row("Pão francês", "1 un", "≈ 140 kcal")}
  {row("Manteiga", "≈ 10 g", "≈ 70 kcal", f'<div class="why">{conf(2, "Conferir")}quantidade não informada</div>')}
  {row("Café com leite", "≈ 200 ml", "≈ 90 kcal")}
  </div>
</div>
<div class="card">
  <div class="mealhd"><span class="t num">12:30</span><div><div class="h">Almoço</div></div><span class="kc num">680 kcal</span></div>
  <div class="row" style="margin-top:8px;gap:6px"><span class="tag ok">{ic("check")}Feita</span><span class="cap">como no plano · 5 itens</span>{mudar}</div>
</div>
<div class="card" style="padding-bottom:12px">
  <div class="mealhd"><span class="t num">16:00</span><div><div class="h">Açaí com granola</div></div><span class="kc num">≈ 390 kcal</span></div>
  <div class="row" style="margin:8px 0 8px;gap:6px"><span class="tag">{ic("fork")}Fora da dieta</span><span class="cap">sem refeição perto</span>{mudar}</div>
  <div class="why cap" style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;font-size:12.5px">{conf(1, "Revisar")}tamanho não informado. Qual foi?</div>
  <div class="qchips"><span class="glass num">200 ml</span><span class="glass picked num">{ic("check")}300 ml</span><span class="glass num">500 ml</span><span class="glass">Outro</span></div>
</div>
<div class="card">
  <div class="mealhd"><span class="t num">20:00</span><div><div class="h">Jantar</div></div><span class="kc num">≈ 240 kcal</span></div>
  <div class="row" style="margin-top:8px;gap:6px"><span class="tag at">{ic("pencil")}Ajustada</span><span class="cap">no lugar de peixe e legumes</span>{mudar}</div>
</div>
"""
    bottom = '<div class="primary" style="background:var(--nutrition-fill)">Registrar 4 refeições</div>'
    return page("07-revisao-dia" + ("-escuro" if dark else ""),
                sheet("21:34", "Revisar registro", inner, bottom, right=f'<div class="gbtn glass">{ic("dots")}</div>'), dark=dark)


# ---------- 08 · resultado registrado ----------
@register
def p08_registrado(dark=False):
    foot = (f'<div class="cap" style="margin-top:12px;display:flex;align-items:center;gap:6px">{ic("scale")}inclui 7 itens estimados pela IA</div>')
    body = status("21:35") + f"""
<div class="scroll">{LARGE}{DAYNAV}
{totals("1.970", "2.200", .895, ("118 / 150 g", 79), ("214 / 220 g", 97), ("66 / 70 g", 94), foot)}
<div class="tl">
  <div class="meal done"><span class="hrs num">7:30</span><div class="card">
    <div class="row"><div class="h" style="font-size:16px">Café da manhã</div><span class="cap num sp">≈ 480 kcal</span></div>
    <div class="cap" style="margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">Ovos mexidos, pão francês, manteiga, café com leite</div>
    <div class="row" style="margin-top:8px;gap:8px"><span class="tag at">{ic("pencil")}Ajustada <span class="num">07:30</span></span><span class="est">{ic("scale")}estimado pela IA</span></div></div></div>
  <div class="meal done"><span class="hrs num">10:00</span><div class="card"><div class="row"><div class="h" style="font-size:16px">Lanche</div><span class="cap num sp">180 kcal</span><span class="tag ok">{ic("check")}Feita</span></div></div></div>
  <div class="meal done"><span class="hrs num">12:30</span><div class="card"><div class="row"><div class="h" style="font-size:16px">Almoço</div><span class="cap num sp">680 kcal</span><span class="tag ok">{ic("check")}Feita <span class="num">12:30</span></span></div></div></div>
  <div class="meal"><span class="hrs num">16:00</span><div class="card">
    <div class="row"><div class="h" style="font-size:16px">Açaí com granola</div><span class="cap num sp">≈ 390 kcal</span></div>
    <div class="row" style="margin-top:8px;gap:8px"><span class="tag">{ic("fork")}Fora da dieta</span><span class="cap num">300 ml</span><span class="est">{ic("scale")}estimado pela IA</span></div></div></div>
  <div class="meal done"><span class="hrs num">20:00</span><div class="card">
    <div class="row"><div class="h" style="font-size:16px">Jantar</div><span class="cap num sp">≈ 240 kcal</span></div>
    <div class="row" style="margin-top:8px;gap:8px"><span class="tag at">{ic("pencil")}Ajustada <span class="num">20:00</span></span><span class="est">{ic("scale")}estimado pela IA</span></div></div></div>
</div></div>
<div class="fade" style="height:270px"></div>
<div class="toast glass">{ic("checkcirc", "i f")}4 refeições registradas<span class="u">Desfazer</span></div>
{logbar()}{tabbar(2)}"""
    return page("08-registrado" + ("-escuro" if dark else ""), body, dark=dark)


# ---------- 09 e 10 · estados ----------
@register
def p09_estados_antes(dark=False):
    body = f"""<div class="boardpg">
<h4>Estados · antes de enviar</h4><div class="cap" style="margin:0 4px">Registrar com IA: o que aparece em cada situação</div>
<div class="bn">Rascunho por terminar (barra na Dieta)</div>
<div class="logbar"><div class="field glass aiborder">{ai()}<b>Continuar rascunho</b><small>4 refeições</small></div><div class="cam glass">{ic("camera")}</div></div>
<div class="bn">IA não configurada (no lugar de “Analisar”)</div>
<div class="banner at">{ic("warn")}<div><b>Falta configurar a IA</b>Escolha um provedor e informe a chave. O que você escreveu fica aqui.<div class="ba"><span class="p" style="background:var(--coach-fill)">Configurar</span><span>Registrar à mão</span></div></div></div>
<div class="bn">Primeiro envio, sem consentimento do Coach</div>
<div class="banner">{ic("lock")}<div><b>O texto e as fotos vão ao provedor de IA</b>Só o que você escrever e fotografar. Histórico, plano e perfil continuam sem compartilhar.<div class="ba"><span class="p" style="background:var(--coach-fill)">Concordar e analisar</span><span>Agora não</span></div></div></div>
<div class="bn">Sem conexão</div>
<div class="banner">{ic("nowifi")}<div><b>Sem conexão</b>O texto fica guardado. Analise quando a rede voltar, ou registre à mão.</div></div>
<div class="bn">Modelo sem visão</div>
<div class="banner at">{ic("warn")}<div><b>O modelo llama3.1 não lê fotos</b>Descreva a refeição por texto ou escolha outro modelo.<div class="ba"><span>Trocar modelo</span></div></div></div>
<div class="bn">Câmera sem acesso</div>
<div class="banner at">{ic("camera")}<div><b>Câmera sem acesso</b>Libere em Ajustes para fotografar o prato. Galeria e texto continuam disponíveis.<div class="ba"><span>Abrir Ajustes</span></div></div></div>
</div>"""
    return page("09-estados-antes" + ("-escuro" if dark else ""), body, dark=dark)


@register
def p10_estados_depois(dark=False):
    body = f"""<div class="boardpg">
<h4>Estados · depois da leitura</h4><div class="cap" style="margin:0 4px">Registrar com IA: resultado, incerteza e erro</div>
<div class="bn">Foto ilegível ou sem comida</div>
<div class="card" style="margin-bottom:0;text-align:center;padding:12px 16px">
  <div class="h">{ai()} Não encontrei comida nesta foto</div><div class="cap" style="margin-top:2px">A imagem parece escura e desfocada.</div>
  <div class="row" style="margin-top:10px;gap:8px"><div class="primary" style="height:48px;flex:1;font-size:15px;background:var(--nutrition-fill);box-shadow:none">{ic("camera")}Tirar outra</div><div class="secondary glass">Descrever por texto</div></div></div>
<div class="bn">Estimativa incerta (topo da revisão)</div>
<div class="banner at">{ic("warn")}<div><b>Estimativa incerta</b>Mais da metade das calorias tem confiança baixa. Confira antes de registrar.</div></div>
<div class="bn">Item sem quantidade (bloqueia “Registrar”)</div>
<div class="card" style="margin-bottom:0;padding:10px 16px"><div class="rvx" style="border-top:0"><div style="display:flex;justify-content:space-between"><span>Molho</span><span class="p num">— · —</span></div>
  <div class="why">{conf(1, "Revisar")}sem estimativa · <span style="color:var(--nutrition);font-weight:600">Informar</span> · <span style="color:var(--nutrition);font-weight:600">Remover</span></div></div></div>
<div class="bn">Refeição que já tem registro</div>
<div class="banner">{ic("info")}<div><b>O almoço já está como Feita às <span class="num">12:40</span></b>Este rascunho não mexe nele.<div class="ba"><span>Substituir o registro</span></div></div></div>
<div class="bn">Dieta não compartilhada (dica na revisão)</div>
<div class="banner">{ic("lock")}<div><b>A IA não vê o seu plano</b>O vínculo com as refeições foi feito no aparelho, pelo horário e pelos nomes.<div class="ba"><span>Permitir comparar com o plano</span></div></div></div>
<div class="bn">Erro do provedor</div>
<div class="banner de">{ic("warn")}<div><b>Não foi possível analisar</b>O provedor está com problemas. Nada foi perdido.<div class="ba"><span class="p" style="background:var(--coach-fill)">Tentar de novo</span><span>Registrar à mão</span></div></div></div>
</div>"""
    return page("10-estados-depois" + ("-escuro" if dark else ""), body, dark=dark)


# ---------- render ----------
def shoot(name):
    src = HTML / f"{name}.html"
    dst = OUT / f"{name}.png"
    profile = tempfile.mkdtemp(prefix="fj-mock-")
    try:
        subprocess.run([CHROME, "--headless=new", f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
                        "--disable-extensions", "--disable-sync", "--disable-background-networking", "--disable-component-update",
                        "--hide-scrollbars", "--allow-file-access-from-files", "--force-device-scale-factor=3",
                        "--window-size=402,874", "--virtual-time-budget=2500", f"--screenshot={dst}", src.as_uri()],
                       check=True, timeout=90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        subprocess.run(["pkill", "-f", profile], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # só a instância deste perfil
        shutil.rmtree(profile, ignore_errors=True)
    return dst


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only_html = "--html" in sys.argv
    HTML.mkdir(exist_ok=True)
    names = []
    for key, fn in PAGES.items():
        names.append(fn())
    names.append(p06_revisao_foto(dark=True))
    names.append(p01_dieta_entrada(dark=True))
    if args:
        names = [n for n in names if any(n.startswith(a) for a in args)]
    for name in names:
        if only_html:
            print("html", name)
        else:
            print("png ", shoot(name).name)  # uma instância por vez


if __name__ == "__main__":
    main()
