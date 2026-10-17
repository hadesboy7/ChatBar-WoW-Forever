#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Decodes the generated BLPs and composites the dock exactly the way the addon
will: nine-slice panel, tinted orb, sheen over it with normal blending, glow
added underneath on hover, marker under the active channel.

Doubles as a check on the BLP writer - the decoder here is written from the
format spec rather than sharing code with the encoder.
"""

import os
import struct

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, os.pardir, "ChatOrbs", "Textures")

ORB, STEP, INNER, CORNER = 20, 26, 6, 12
MARKER = (14, 4)
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

CHANNELS = [
    ("С", (1.00, 1.00, 1.00)), ("К", (1.00, 0.25, 0.25)),
    ("Э", (1.00, 0.50, 0.25)), ("Ш", (1.00, 0.50, 1.00)),
    ("Г", (0.67, 0.67, 1.00)), ("Р", (1.00, 0.50, 0.00)),
    ("Г", (0.25, 1.00, 0.25)), ("О", (1.00, 0.75, 0.75)),
    ("Т", (1.00, 0.75, 0.75)),
]
HOVER, ACTIVE = 1, 0


def read_blp(name):
    """Decodes a shipped texture. Pillow's BLP reader is an implementation of
    the format independent of the writer in tools/make_textures.py, so this
    doubles as a check that the files are well formed."""
    path = os.path.join(TEX, name + ".blp")
    header = open(path, "rb").read(16)
    assert header[:4] == b"BLP2", path
    kind, = struct.unpack_from("<I", header, 4)
    encoding, alpha_depth, alpha_encoding, has_mips = struct.unpack_from("<BBBB", header, 8)
    assert (kind, encoding, alpha_depth, alpha_encoding, has_mips) == (1, 2, 8, 7, 1), \
        ("%s is not BLP2/DXT5 with mips" % path)
    return np.asarray(Image.open(path).convert("RGBA")).astype(float) / 255.0


def resize(arr, w, h):
    img = Image.fromarray(np.clip(arr * 255, 0, 255).astype(np.uint8), "RGBA")
    return np.asarray(img.resize((w, h), Image.LANCZOS)).astype(float) / 255.0


def blend(dst, src, x, y, mode="BLEND", tint=(1, 1, 1), alpha=1.0):
    h, w = src.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(dst.shape[1], x + w), min(dst.shape[0], y + h)
    if x1 <= x0 or y1 <= y0:
        return
    patch = src[y0 - y:y1 - y, x0 - x:x1 - x]
    a = patch[..., 3:4] * alpha
    colour = patch[..., :3] * np.asarray(tint)
    region = dst[y0:y1, x0:x1]
    if mode == "ADD":
        region[..., :3] = np.clip(region[..., :3] + colour * a, 0, 1)
    else:
        region[..., :3] = region[..., :3] * (1 - a) + colour * a
    region[..., 3:4] = np.clip(region[..., 3:4] + a * (1 - region[..., 3:4]), 0, 1)


def nine_slice(dst, tex, x, y, w, h, corner=CORNER):
    """Draws `tex` as a nine-slice box, matching the Lua layout exactly."""
    tw = tex.shape[1]
    cut = int(round(tw * corner / (corner * 2 + 8)))   # texture px per corner
    mid_t = tex[cut:tw - cut, cut:tw - cut]
    mw, mh = w - 2 * corner, h - 2 * corner
    pieces = [
        (tex[:cut, :cut], x, y, corner, corner),
        (tex[:cut, cut:tw - cut], x + corner, y, mw, corner),
        (tex[:cut, tw - cut:], x + w - corner, y, corner, corner),
        (tex[cut:tw - cut, :cut], x, y + corner, corner, mh),
        (mid_t, x + corner, y + corner, mw, mh),
        (tex[cut:tw - cut, tw - cut:], x + w - corner, y + corner, corner, mh),
        (tex[tw - cut:, :cut], x, y + h - corner, corner, corner),
        (tex[tw - cut:, cut:tw - cut], x + corner, y + h - corner, mw, corner),
        (tex[tw - cut:, tw - cut:], x + w - corner, y + h - corner, corner, corner),
    ]
    for piece, px, py, pw, ph in pieces:
        if pw > 0 and ph > 0:
            blend(dst, resize(piece, pw, ph), px, py)


def render_dock(w, h):
    orb = read_blp("Orb")
    sheen = read_blp("OrbSheen")
    glow = read_blp("Glow")
    panel = read_blp("Panel")
    marker = read_blp("Marker")

    dock_w = (len(CHANNELS) - 1) * STEP + ORB + 2 * INNER
    dock_h = ORB + 2 * INNER
    out = np.zeros((h, w, 4))
    ox, oy = (w - dock_w) // 2, (h - dock_h) // 2

    nine_slice(out, panel, ox, oy, dock_w, dock_h)

    for i, (letter, colour) in enumerate(CHANNELS):
        cx = ox + INNER + i * STEP + ORB // 2
        cy = oy + INNER + ORB // 2
        hovered = i == HOVER
        size = ORB + (2 if hovered else 0)

        if hovered:
            g = 34
            blend(out, resize(glow, g, g), cx - g // 2, cy - g // 2,
                  mode="ADD", tint=colour, alpha=0.5)

        blend(out, resize(orb, size, size), cx - size // 2, cy - size // 2,
              tint=colour)
        blend(out, resize(sheen, size, size), cx - size // 2, cy - size // 2,
              alpha=0.30 if hovered else 0.20)

        if i == ACTIVE:
            mw, mh = MARKER
            blend(out, resize(marker, mw, mh), cx - mw // 2,
                  oy + dock_h - INNER + 1, tint=colour, alpha=0.95)
    return out, (ox, oy, dock_w, dock_h)


def draw_letters(img, box):
    ox, oy, _dw, _dh = box
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT_BOLD, 11)
    for i, (letter, colour) in enumerate(CHANNELS):
        cx = ox + INNER + i * STEP + ORB // 2
        cy = oy + INNER + ORB // 2
        l, t, r, b = d.textbbox((0, 0), letter, font=font)
        d.text((cx - (r + l) / 2, cy - (b + t) / 2 - 0.5), letter, font=font,
               fill=tuple(int(c * 255 * 0.20) for c in colour) + (250,))


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
    base = base + np.random.default_rng(7).normal(0, 3.2, base.shape)
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


EMOTES = ["Привет", "Пока", "Помахать", "Поклон", "Отдатьчесть", "Спасибо",
          "Аплодисменты", "Ура", "Смех", "Улыбка", "Танец", "Мускулы",
          "Поцелуй", "Обнять", "Пожатьплечами", "Извинить", "Плакать",
          "Рычать", "Сесть", "Наколени", "Лечь", "Спать", "Указать",
          "Молиться"]
COLS, ROWS, CELL_W, CELL_H, PAD, SEARCH_H = 3, 8, 120, 20, 10, 22


def render_picker():
    """The emote list, laid out exactly as the addon lays it out."""
    panel = read_blp("Panel")
    w = COLS * CELL_W + PAD * 2
    h = PAD * 2 + SEARCH_H + 6 + ROWS * CELL_H
    out = np.zeros((h, w, 4))
    nine_slice(out, panel, 0, 0, w, h)

    img = Image.fromarray(np.clip(out * 255, 0, 255).astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT_BOLD, 11)

    d.rectangle((PAD, PAD, w - PAD - 1, PAD + SEARCH_H - 1), fill=(255, 255, 255, 18))
    d.text((PAD + 7, PAD + SEARCH_H / 2 - 7), "поиск эмоции", font=font,
           fill=(140, 140, 153, 255))

    top = PAD + SEARCH_H + 6
    for i, label in enumerate(EMOTES[: COLS * ROWS]):
        col, row = i % COLS, i // COLS
        x, y = PAD + col * CELL_W, top + row * CELL_H
        if i == 18:                                  # "Сесть", shown hovered
            d.rectangle((x + 2, y, x + CELL_W - 2, y + CELL_H - 1),
                        fill=(255, 255, 255, 31))
            colour = (255, 217, 89, 255)
        else:
            colour = (224, 224, 235, 255)
        d.text((x + 8, y + CELL_H / 2 - 7), label, font=font, fill=colour)

    small = ImageFont.truetype(FONT_BOLD, 10)
    hint = "колесо — прокрутка"
    hw = d.textbbox((0, 0), hint, font=small)[2]
    d.text((w - PAD - 2 - hw, h - PAD - 4), hint, font=small, fill=(128, 128, 140, 255))
    return img


DOCS = os.path.join(HERE, os.pardir, "docs")


def scene(tile, kind, zoom=1, pad=12):
    """Puts a rendered tile on a game-like backdrop with some breathing room."""
    if zoom > 1:
        tile = tile.resize((tile.width * zoom, tile.height * zoom), Image.NEAREST)
    bg = backdrop(tile.width + pad * 2, tile.height + pad * 2, kind)
    bg.alpha_composite(tile, (pad, pad))
    return bg.convert("RGB")


def main():
    os.makedirs(DOCS, exist_ok=True)
    w, h = 272, 44
    tile, box = render_dock(w, h)
    dock = Image.fromarray(np.clip(tile * 255, 0, 255).astype(np.uint8), "RGBA")
    draw_letters(dock, box)
    picker = render_picker()

    # Hero: the dock at 3x so the shading and the active marker are legible.
    scene(dock, "dark", zoom=3, pad=18).save(os.path.join(DOCS, "dock.png"))

    # True size, on a dark and on a bright background.
    left, right = scene(dock, "dark"), scene(dock, "light")
    sizes = Image.new("RGB", (left.width + right.width + 8, left.height), (18, 18, 20))
    sizes.paste(left, (0, 0))
    sizes.paste(right, (left.width + 8, 0))
    sizes.save(os.path.join(DOCS, "sizes.png"))

    # The emote list as it opens above the dock.
    combo = Image.new("RGBA", (max(picker.width, dock.width),
                               picker.height + dock.height + 8), (0, 0, 0, 0))
    combo.alpha_composite(picker, ((combo.width - picker.width) // 2, 0))
    combo.alpha_composite(dock, ((combo.width - dock.width) // 2, picker.height + 8))
    scene(combo, "dark", zoom=2, pad=18).save(os.path.join(DOCS, "emotes.png"))

    for name in ("dock", "sizes", "emotes"):
        path = os.path.join(DOCS, name + ".png")
        print("wrote docs/%s.png  %dx%d" % ((name,) + Image.open(path).size))
    print("all five BLPs decoded and composited")


if __name__ == "__main__":
    main()
