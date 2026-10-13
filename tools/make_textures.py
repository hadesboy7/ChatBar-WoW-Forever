#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generates ChatOrbs/Textures/*.blp.

Everything here is drawn from scratch: no source artwork, no screenshots.
Each texture is written as BLP2 (type 1, palettised, 8-bit alpha, full mip
chain), which is the uncompressed variant every WoW client reads.

    Orb       greyscale sphere + ring, tinted with the chat colour
    OrbSheen  white top wash, drawn over the orb with normal blending
    Glow      soft radial glow, tinted, drawn additively on hover
    Panel     nine-slice rounded panel for the dock and the emote popup
    Marker    rounded pill marking the active channel

The orb is split in two because SetVertexColor can only darken: the ring and
the vertical falloff are multiplies and live in Orb, while the highlight has
to lighten and therefore needs its own layer.
"""

import os
import struct

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       os.pardir, "ChatOrbs", "Textures")
SS = 8                      # supersampling factor


# ---------------------------------------------------------------------------
# drawing helpers
# ---------------------------------------------------------------------------
def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def shrink(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def to_array(img):
    return np.asarray(img).astype(float) / 255.0


def from_array(arr):
    return Image.fromarray(np.clip(arr * 255.0, 0, 255).astype(np.uint8), "RGBA")


# ---------------------------------------------------------------------------
# Orb: greyscale, tinted by the chat colour
# ---------------------------------------------------------------------------
def make_orb(size=64, ring=0.38, top=1.0, bottom=0.84, ring_width=0.13):
    """Vertical falloff inside, a darker ring at the rim, alpha for the edge."""
    axis = (np.arange(size) + 0.5) / size * 2.0 - 1.0
    gx, gy = np.meshgrid(axis, axis)
    r = np.sqrt(gx * gx + gy * gy)

    fill = top + (bottom - top) * ((gy + 1.0) / 2.0)

    # Blend from the fill into the ring across a narrow band, so the rim does
    # not alias once the 64px texture is drawn at 20px.
    inner = 1.0 - ring_width
    t = np.clip((r - inner) / max(ring_width * 0.55, 1e-6), 0.0, 1.0)
    value = fill * (1.0 - t) + ring * t

    alpha = np.clip((1.0 - r) / (1.6 / (size / 2.0)), 0.0, 1.0)

    out = np.zeros((size, size, 4))
    out[..., 0] = out[..., 1] = out[..., 2] = value
    out[..., 3] = alpha
    return out


# ---------------------------------------------------------------------------
# OrbSheen: white wash over the upper half, clipped to the orb
# ---------------------------------------------------------------------------
def make_sheen(size=64, strength=0.62):
    layer = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    px = size * SS
    d.ellipse((px * 0.17, px * 0.04, px * 0.83, px * 0.47),
              fill=(255, 255, 255, int(255 * strength)))
    layer = layer.filter(ImageFilter.GaussianBlur(px * 0.065))

    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).ellipse((px * 0.055, px * 0.055, px * 0.945, px * 0.945),
                                 fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(px * 0.012))
    clipped = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    clipped.paste(layer, (0, 0), mask)

    arr = to_array(shrink(clipped, size, size))
    arr[..., :3] = 1.0                      # keep RGB pure white
    return arr


# ---------------------------------------------------------------------------
# Glow: soft halo drawn additively behind a hovered orb
# ---------------------------------------------------------------------------
def make_glow(size=64, inner=0.30, blur=0.11):
    px = size * SS
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(
        (px * inner, px * inner, px * (1 - inner), px * (1 - inner)),
        fill=(255, 255, 255, 255))
    layer = layer.filter(ImageFilter.GaussianBlur(px * blur))
    arr = to_array(shrink(layer, size, size))
    arr[..., :3] = 1.0
    return arr


# ---------------------------------------------------------------------------
# Panel: nine-slice rounded rectangle, dark fill with a light hairline
# ---------------------------------------------------------------------------
def make_panel(size=64, radius=20, fill=(13, 13, 16, 205),
               border=(255, 255, 255, 40), border_w=2.4, sheen=(255, 255, 255, 26)):
    px = size * SS
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((0, 0, px - 1, px - 1), radius=radius * SS, fill=fill)
    d.rounded_rectangle((border_w * SS / 2, border_w * SS / 2,
                         px - 1 - border_w * SS / 2, px - 1 - border_w * SS / 2),
                        radius=radius * SS, outline=border, width=int(border_w * SS))
    # A hairline of light along the top edge, inside the border.
    d.rounded_rectangle((radius * SS * 0.5, border_w * SS * 1.4,
                         px - 1 - radius * SS * 0.5, border_w * SS * 3.2),
                        radius=border_w * SS, fill=sheen)
    return to_array(shrink(layer, size, size))


# ---------------------------------------------------------------------------
# Marker: small rounded pill under the active channel
# ---------------------------------------------------------------------------
def make_marker(w=32, h=8):
    layer = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (0, 0, w * SS - 1, h * SS - 1), radius=h * SS / 2, fill=(255, 255, 255, 255))
    arr = to_array(shrink(layer, w, h))
    arr[..., :3] = 1.0
    return arr


# ---------------------------------------------------------------------------
# mip chain
# ---------------------------------------------------------------------------
def mip_chain(rgba_u8):
    levels = [rgba_u8]
    cur = rgba_u8.astype(float)
    while min(cur.shape[0], cur.shape[1]) > 1:
        h, w = max(1, cur.shape[0] // 2), max(1, cur.shape[1] // 2)
        alpha = cur[..., 3:4] / 255.0
        prem = np.concatenate([cur[..., :3] * alpha, cur[..., 3:4]], axis=-1)
        prem = prem.reshape(h, cur.shape[0] // h, w, cur.shape[1] // w, 4).mean(axis=(1, 3))
        alpha = prem[..., 3:4] / 255.0
        rgb = np.where(alpha > 1e-4, prem[..., :3] / np.maximum(alpha, 1e-4), 0.0)
        cur = np.concatenate([rgb, prem[..., 3:4]], axis=-1)
        levels.append(np.clip(np.round(cur), 0, 255).astype(np.uint8))
    return levels


# ---------------------------------------------------------------------------
# BLP2 writer (type 1 / encoding 1: palettised, 8-bit alpha)
# ---------------------------------------------------------------------------
def build_palette(levels, greyscale):
    if greyscale:
        return [(i, i, i) for i in range(256)]
    rgb = np.concatenate([lv[..., :3].reshape(-1, 3) for lv in levels])
    img = Image.fromarray(rgb.reshape(1, -1, 3).astype(np.uint8), "RGB")
    quantized = img.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
    raw = quantized.getpalette()[: 256 * 3]
    pal = [tuple(raw[i * 3: i * 3 + 3]) for i in range(len(raw) // 3)]
    while len(pal) < 256:
        pal.append((0, 0, 0))
    return pal


def map_to_palette(rgb, pal_arr):
    flat = rgb.reshape(-1, 3).astype(np.int32)
    d = ((flat[:, None, :] - pal_arr[None, :, :]) ** 2).sum(axis=2)
    return d.argmin(axis=1).astype(np.uint8).reshape(rgb.shape[:2])


def write_blp(path, levels, greyscale):
    pal = build_palette(levels, greyscale)
    pal_arr = np.asarray(pal, dtype=np.int32)

    mips = []
    for lv in levels:
        idx = map_to_palette(lv[..., :3], pal_arr)
        mips.append(idx.tobytes() + lv[..., 3].tobytes())

    header_size = 148 + 256 * 4
    offsets, sizes, cursor = [0] * 16, [0] * 16, header_size
    for i, data in enumerate(mips[:16]):
        offsets[i], sizes[i] = cursor, len(data)
        cursor += len(data)

    out = bytearray()
    out += b"BLP2"
    out += struct.pack("<I", 1)                   # type: direct colour
    out += struct.pack("<BBBB", 1, 8, 0, 1)       # encoding, alphaDepth,
    #                                               alphaEncoding, hasMips
    out += struct.pack("<II", levels[0].shape[1], levels[0].shape[0])
    out += struct.pack("<16I", *offsets)
    out += struct.pack("<16I", *sizes)
    for r, g, b in pal:
        out += struct.pack("<BBBB", b, g, r, 0)   # palette entries are BGRA
    assert len(out) == header_size, len(out)
    for data in mips[:16]:
        out += data

    with open(path, "wb") as fh:
        fh.write(bytes(out))
    return len(out)


# ---------------------------------------------------------------------------
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    textures = [
        ("Orb",      make_orb(),     True),
        ("OrbSheen", make_sheen(),   True),
        ("Glow",     make_glow(),    True),
        ("Panel",    make_panel(),   False),
        ("Marker",   make_marker(),  True),
    ]
    for name, arr, greyscale in textures:
        u8 = np.clip(np.round(arr * 255.0), 0, 255).astype(np.uint8)
        levels = mip_chain(u8)
        written = write_blp(os.path.join(OUT_DIR, name + ".blp"), levels, greyscale)
        print("%-9s %dx%d  %d mips  %d bytes"
              % (name, u8.shape[1], u8.shape[0], len(levels), written))


if __name__ == "__main__":
    main()
