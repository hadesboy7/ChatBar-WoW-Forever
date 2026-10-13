#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Renders design directions for the chat bar at true in-game pixel size.

Everything here is drawn with the same primitives the texture generator uses,
so what the mockup shows is what the addon can actually ship: no CSS blur, no
effects the WoW renderer cannot reproduce from a BLP texture.
"""

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 6                      # supersampling factor for antialiasing

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Chat targets as they appear for a grouped character in a guild, ruRU.
CHANNELS = [
    ("С", "Сказать",   (1.00, 1.00, 1.00)),
    ("К", "Крик",      (1.00, 0.25, 0.25)),
    ("Э", "Эмоция",    (1.00, 0.50, 0.25)),
    ("Ш", "Шепот",     (1.00, 0.50, 1.00)),
    ("Г", "Группа",    (0.67, 0.67, 1.00)),
    ("Р", "Рейд",      (1.00, 0.50, 0.00)),
    ("Г", "Гильдия",   (0.25, 1.00, 0.25)),
    ("О", "Общий",     (1.00, 0.75, 0.75)),
    ("Т", "Торговля",  (1.00, 0.75, 0.75)),
]
EMOTE_INDEX = 2             # the one that opens a picker
HOVER_INDEX = 1             # shown in its hover state


def rgb(c, a=255):
    return (int(c[0] * 255), int(c[1] * 255), int(c[2] * 255), a)


def lighten(c, amount):
    return tuple(min(1.0, v + (1.0 - v) * amount) for v in c)


def darken(c, amount):
    return tuple(v * (1.0 - amount) for v in c)


def new_layer(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def downscale(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def font(path, size):
    return ImageFont.truetype(path, size * SS)


def centered_text(draw, cx, cy, text, fnt, fill):
    l, t, r, b = draw.textbbox((0, 0), text, font=fnt)
    draw.text((cx * SS - (r + l) / 2, cy * SS - (b + t) / 2), text, font=fnt, fill=fill)


def vertical_gradient_circle(size, top, bottom, ring=None, ring_w=1.2):
    """A filled circle with a top-to-bottom gradient and an optional ring."""
    layer = new_layer(size, size)
    px = size * SS
    ys = np.linspace(0, 1, px)[:, None]
    grad = np.zeros((px, px, 4), np.uint8)
    for ch in range(3):
        grad[..., ch] = np.uint8(np.clip(top[ch] + (bottom[ch] - top[ch]) * ys, 0, 255))
    grad[..., 3] = 255
    grad_img = Image.fromarray(grad, "RGBA")

    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
    layer.paste(grad_img, (0, 0), mask)

    if ring:
        d = ImageDraw.Draw(layer)
        inset = ring_w * SS / 2
        d.ellipse((inset, inset, px - 1 - inset, px - 1 - inset),
                  outline=ring, width=int(ring_w * SS))
    return layer


def inner_sheen(size, strength=0.18):
    """A restrained light wash across the top, clipped to the circle."""
    px = size * SS
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse((px * 0.16, px * 0.04, px * 0.84, px * 0.46),
              fill=(255, 255, 255, int(255 * strength)))
    layer = layer.filter(ImageFilter.GaussianBlur(px * 0.07))
    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).ellipse((SS, SS, px - 1 - SS, px - 1 - SS), fill=255)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(layer, (0, 0), mask)
    return out


def orb(size, colour, hovered, letter, fnt, chevron=False):
    """One channel button: saturated fill, tinted ring, dark tinted glyph."""
    o = vertical_gradient_circle(
        size,
        rgb(lighten(colour, 0.20))[:3],
        rgb(darken(colour, 0.16))[:3],
        ring=rgb(darken(colour, 0.62), 230), ring_w=1.3,
    )
    o.alpha_composite(inner_sheen(size, 0.24 if hovered else 0.16))
    d = ImageDraw.Draw(o)
    centered_text(d, size / 2, size / 2 - 0.3, letter, fnt,
                  rgb(darken(colour, 0.80), 245))
    if chevron:
        cx, cy = size / 2, size - 4.4
        d.polygon([((cx - 2.2) * SS, cy * SS), ((cx + 2.2) * SS, cy * SS),
                   (cx * SS, (cy + 2.2) * SS)], fill=rgb(darken(colour, 0.78), 215))
    return o


def glow(size, colour, pad, strength=0.85, spread=0.28):
    """Soft outer glow around a circle of `size`, drawn on a `size+2*pad` tile."""
    total = size + 2 * pad
    px = total * SS
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    inset = (pad - 1) * SS
    d.ellipse((inset, inset, px - 1 - inset, px - 1 - inset),
              fill=rgb(colour, int(255 * strength)))
    return layer.filter(ImageFilter.GaussianBlur(px * spread * 0.25))


# ---------------------------------------------------------------------------
# A — orbs, no panel
# ---------------------------------------------------------------------------
def variant_orbs():
    size, step, pad = 22, 28, 7
    w = (len(CHANNELS) - 1) * step + size + 2 * pad
    h = size + 2 * pad
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fnt = font(FONT_BOLD, 12)

    for i, (letter, _name, colour) in enumerate(CHANNELS):
        x = pad + i * step
        hovered = i == HOVER_INDEX
        grow = 2 if hovered else 0

        if hovered:
            g = downscale(glow(size, colour, pad), size + 2 * pad, size + 2 * pad)
            out.alpha_composite(g, (x - pad, 0))

        s = size + grow
        o = orb(s, colour, hovered, letter, fnt, chevron=(i == EMOTE_INDEX))
        out.alpha_composite(downscale(o, s, s), (x - grow // 2, pad - grow // 2))
    return out


# ---------------------------------------------------------------------------
# B — chips with names
# ---------------------------------------------------------------------------
def variant_chips():
    h_chip, gap, pad, dot = 20, 4, 4, 7
    fnt = font(FONT_BOLD, 11)
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))

    widths = []
    for _letter, name, _c in CHANNELS:
        l, _t, r, _b = probe.textbbox((0, 0), name, font=fnt)
        widths.append((r - l) / SS + dot + 17)

    w = int(sum(widths) + gap * (len(CHANNELS) - 1)) + 2 * pad
    h = h_chip + 2 * pad
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    x = pad
    for i, ((_letter, name, colour), cw) in enumerate(zip(CHANNELS, widths)):
        hovered = i == HOVER_INDEX
        cw = int(round(cw))
        chip = new_layer(cw, h_chip)
        d = ImageDraw.Draw(chip)
        r = h_chip * SS / 2
        d.rounded_rectangle((0, 0, cw * SS - 1, h_chip * SS - 1), radius=r,
                            fill=(12, 12, 15, 205) if not hovered else (34, 34, 40, 230),
                            outline=rgb(colour, 150) if hovered else (255, 255, 255, 30),
                            width=int(1.2 * SS))
        d.ellipse(((8 - dot / 2) * SS, (h_chip / 2 - dot / 2) * SS,
                   (8 + dot / 2) * SS, (h_chip / 2 + dot / 2) * SS), fill=rgb(colour))
        l, t, rr, b = d.textbbox((0, 0), name, font=fnt)
        d.text((13 * SS - l, (h_chip * SS - (b + t)) / 2), name, font=fnt,
               fill=(255, 255, 255, 240) if hovered else (215, 215, 220, 225))
        out.alpha_composite(downscale(chip, cw, h_chip), (x, pad))
        x += cw + gap
    return out


# ---------------------------------------------------------------------------
# C — dock
# ---------------------------------------------------------------------------
def variant_dock():
    size, step, inner, pad = 20, 26, 6, 8
    bar_w = (len(CHANNELS) - 1) * step + size + 2 * inner
    bar_h = size + 2 * inner
    w, h = bar_w + 2 * pad, bar_h + 2 * pad
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fnt = font(FONT_BOLD, 11)

    shadow = new_layer(w, h)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (pad * SS, (pad + 1) * SS, (pad + bar_w) * SS, (pad + bar_h + 1) * SS),
        radius=10 * SS, fill=(0, 0, 0, 150))
    out.alpha_composite(downscale(shadow.filter(ImageFilter.GaussianBlur(3 * SS)), w, h))

    panel = new_layer(bar_w, bar_h)
    d = ImageDraw.Draw(panel)
    d.rounded_rectangle((0, 0, bar_w * SS - 1, bar_h * SS - 1), radius=10 * SS,
                        fill=(13, 13, 16, 200),
                        outline=(255, 255, 255, 38), width=int(1.2 * SS))
    d.rounded_rectangle((int(2.5 * SS), int(1.6 * SS), bar_w * SS - int(2.5 * SS), 4 * SS),
                        radius=2 * SS, fill=(255, 255, 255, 26))
    out.alpha_composite(downscale(panel, bar_w, bar_h), (pad, pad))

    for i, (letter, _name, colour) in enumerate(CHANNELS):
        x = pad + inner + i * step
        hovered = i == HOVER_INDEX
        if hovered:
            g = downscale(glow(size, colour, 6, 0.7), size + 12, size + 12)
            out.alpha_composite(g, (x - 6, pad + inner - 6))

        s = size + (2 if hovered else 0)
        o = orb(s, colour, hovered, letter, fnt, chevron=(i == EMOTE_INDEX))
        offset = 2 if hovered else 0
        out.alpha_composite(downscale(o, s, s),
                            (x - offset // 2, pad + inner - offset // 2))

    # active-channel marker under the first orb
    marker = new_layer(size, 3)
    ImageDraw.Draw(marker).rounded_rectangle(
        (3 * SS, 0, (size - 3) * SS, 2 * SS), radius=SS, fill=rgb(CHANNELS[0][2], 230))
    out.alpha_composite(downscale(marker, size, 3), (pad + inner, pad + bar_h - 5))
    return out


# ---------------------------------------------------------------------------
# backdrops & sheet
# ---------------------------------------------------------------------------
def backdrop(w, h, kind):
    y = np.linspace(0, 1, h)[:, None]
    x = np.linspace(0, 1, w)[None, :]
    one = np.ones((h, w))
    if kind == "dark":
        base = np.stack([28 + 26 * y + 14 * x, 21 + 17 * y + 9 * x,
                         15 + 11 * y + 6 * x], -1) * one[..., None]
    else:
        base = np.stack([(118 + 62 * (1 - y)) * one, (132 + 60 * (1 - y)) * one,
                         (108 + 50 * (1 - y)) * one], -1)
    rng = np.random.default_rng(7)
    base = base + rng.normal(0, 3.2, base.shape)
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def place(sheet, tile, x, y, kind, zoom):
    if zoom > 1:
        tile = tile.resize((tile.width * zoom, tile.height * zoom), Image.NEAREST)
    bg = backdrop(tile.width + 16, tile.height + 12, kind)
    bg.alpha_composite(tile, (8, 6))
    sheet.alpha_composite(bg, (x, y))
    return bg.width, bg.height


def main():
    variants = [
        ("A", "Орбы — без подложки, самый лёгкий", variant_orbs()),
        ("B", "Чипы — читается без привыкания, но втрое шире", variant_chips()),
        ("C", "Док — панель со скруглением, полоска активного канала", variant_dock()),
    ]

    title = ImageFont.truetype(FONT_BOLD, 15)
    sub = ImageFont.truetype(FONT_REG, 12)
    tiny = ImageFont.truetype(FONT_REG, 11)

    width = max(t.width * 2 + 16 for _, _, t in variants) + 32
    sheet = Image.new("RGBA", (width, 1400), (18, 18, 20, 255))
    d = ImageDraw.Draw(sheet)

    y = 16
    for key, name, tile in variants:
        d.text((16, y), "%s — %s" % (key, name), font=title, fill=(255, 205, 80, 255))
        y += 24
        _w, h = place(sheet, tile, 16, y, "dark", 2)
        y += h + 6

        d.text((16, y), "настоящий размер, на тёмном и на светлом фоне:",
               font=tiny, fill=(135, 135, 140, 255))
        y += 16
        w1, h1 = place(sheet, tile, 16, y, "dark", 1)
        if 16 + w1 + 14 + w1 <= width:
            place(sheet, tile, 16 + w1 + 14, y, "light", 1)
            y += h1 + 26
        else:
            y += h1 + 6
            _w2, h2 = place(sheet, tile, 16, y, "light", 1)
            y += h2 + 26

    d.text((16, y), "Наведение показано на «Крик». Треугольник на «Эмоция» — "
                    "кнопка открывает список эмоций.", font=sub, fill=(160, 160, 165, 255))
    y += 24

    sheet = sheet.crop((0, 0, width, y)).convert("RGB")
    docs = os.path.join(HERE, os.pardir, "docs")
    os.makedirs(docs, exist_ok=True)
    sheet.save(os.path.join(docs, "variants.png"))
    print("wrote docs/variants.png  %dx%d" % sheet.size)


if __name__ == "__main__":
    main()
