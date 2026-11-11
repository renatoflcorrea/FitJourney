#!/usr/bin/env python3
"""Confere o contraste WCAG da paleta de fichas (FJRoutineColor, DESIGN_DIRECTION §2.1).

Regras: onFill sobre fill >= 4,5:1; fill sobre a superfície do cartão e sobre o fundo da tela >= 3:1,
em claro e escuro. Os valores aqui devem ser os mesmos de FitJourney/DesignSystem/Tokens/FJRoutineColor.swift.
Uso: python3 design/tools/routine_palette_check.py
"""
import sys

WHITE = 0xFFFFFF
INK = 0x1A1206  # texto escuro sobre tons claros

# nome: (fill claro, onFill claro, fill escuro, onFill escuro)
PALETTE = {
    "orange": (0xD4450C, WHITE, 0xD4450C, WHITE),
    "green": (0x18803A, WHITE, 0x1C8540, WHITE),
    "pink": (0xC2256E, WHITE, 0xC92C75, WHITE),
    "blue": (0x0A66C2, WHITE, 0x1F71CC, WHITE),
    "purple": (0x7C3AED, WHITE, 0x8349EE, WHITE),
    "teal": (0x0B7F83, WHITE, 0x5AD1D6, INK),
    "yellow": (0xAD8200, INK, 0xFFD23F, INK),
    "gray": (0x5F6B7A, WHITE, 0xAEB7C2, INK),
}

# superfície do cartão / fundo da tela
LIGHT = (0xFFFFFF, 0xF2F2F7)
DARK = (0x1C1C1E, 0x000000)


def luminance(hex_value):
    def channel(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (hex_value >> 16) & 255, (hex_value >> 8) & 255, hex_value & 255
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def main():
    failed = False
    print(f"{'cor':8} {'tema':7} {'fill':8} onFill  cartão  fundo")
    for name, (lf, lo, df, do) in PALETTE.items():
        for theme, fill, on, (surface, background) in (("claro", lf, lo, LIGHT), ("escuro", df, do, DARK)):
            text, card, page = contrast(fill, on), contrast(fill, surface), contrast(fill, background)
            ok = text >= 4.5 and card >= 3 and page >= 3
            failed |= not ok
            print(f"{name:8} {theme:7} #{fill:06X}  {text:5.2f}  {card:5.2f}  {page:5.2f}  {'ok' if ok else 'FALHA'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
