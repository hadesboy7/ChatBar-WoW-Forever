#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generates ChatBar/Textures/Orb.* and OrbGloss.* from the reference screenshot.

The nine orbs on the reference panel are rendered by the game as

    pixel = A(x,y) * tint  +  B(x,y)

where A is a neutral (grey) sphere that IS tinted by the chat-type colour and
B is a gold rim + specular gloss that is NOT tinted.  Because the screenshot
contains nine orbs with nine *known* tints (the default ChatTypeInfo colours),
A and B can be recovered per-pixel by least squares and baked into two
textures:

    Orb       -- greyscale sphere, drawn with SetVertexColor(chat colour)
    OrbGloss  -- gold rim + gloss, drawn untinted with blend mode "ADD"

Both are written as BLP2 (palettised, 8-bit alpha, full mip chain) for modern
clients and as uncompressed 32-bit TGA for pre-Legion clients.
"""

import os
import struct

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, os.pardir, "ChatBar", "Textures")

# --- reference screenshot geometry (measured, see README) --------------------
SCREENSHOT = os.environ.get(
    "CHATBAR_REF",
    "/tmp/claude-0/-home-user-ChatBar-WoW-Forever/"
    "2487288f-a1f5-57cf-82bc-4f17b65c0713/images/1.png",
)

ORB_CENTERS_X = [83.0, 108.5, 134.5, 161.0, 187.0, 212.5, 238.5, 264.0, 290.5]
ORB_CENTER_Y = 86.3

# Default ChatTypeInfo colours of the nine orbs, in screenshot order:
# SAY, YELL, WHISPER, BN_WHISPER, EMOTE, CHANNEL x4
TINTS = [
    (1.00, 1.00, 1.00),
    (1.00, 0.25, 0.25),
    (1.00, 0.50, 1.00),
    (0.00, 1.00, 0.96),
    (1.00, 0.50, 0.25),
    (1.00, 0.75, 0.75),
    (1.00, 0.75, 0.75),
    (1.00, 0.75, 0.75),
    (1.00, 0.75, 0.75),
]

SPAN = 11.0        # texture covers +/- 11 screenshot px around the orb centre
TEX = 64           # output texture size (power of two)
R_SOLID = 9.2      # orb is fully opaque inside this radius (screenshot px)
R_EDGE = 10.0      # ...and fully transparent outside this one
BG = 11.0          # near-black backdrop behind the panel in the screenshot
CLIP = 250.0       # observations at/above this are clipped -> unusable


# ---------------------------------------------------------------------------
# sampling
# ---------------------------------------------------------------------------
def sample(img, cx, cy):
    """Bilinearly sample a TEXxTEX patch of +/-SPAN px around (cx, cy)."""
    h, w, _ = img.shape
    # pixel centres of the output grid, in screenshot coordinates
    t = (np.arange(TEX) + 0.5) / TEX * (2 * SPAN) - SPAN
    xs = cx + t
    ys = cy + t
    gx, gy = np.meshgrid(xs, ys)

    x0 = np.clip(np.floor(gx).astype(int), 0, w - 2)
    y0 = np.clip(np.floor(gy).astype(int), 0, h - 2)
    fx = (gx - x0)[..., None]
    fy = (gy - y0)[..., None]

    return (
        img[y0, x0] * (1 - fx) * (1 - fy)
        + img[y0, x0 + 1] * fx * (1 - fy)
        + img[y0 + 1, x0] * (1 - fx) * fy
        + img[y0 + 1, x0 + 1] * fx * fy
    )


def gaussian_blur(a, sigma):
    """Separable Gaussian blur with edge clamping (no scipy dependency)."""
    radius = max(1, int(round(3 * sigma)))
    k = np.exp(-0.5 * (np.arange(-radius, radius + 1) / sigma) ** 2)
    k /= k.sum()
    out = a.astype(float)
    for axis in (0, 1):
        padded = np.apply_along_axis(
            lambda m: np.pad(m, radius, mode="edge"), axis, out
        )
        out = np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), axis, padded)
    return out


def decompose():
    """Recover the tinted sphere A and the untinted gloss B."""
    img = np.asarray(Image.open(SCREENSHOT).convert("RGB")).astype(float)

    obs = np.stack([sample(img, cx, ORB_CENTER_Y) for cx in ORB_CENTERS_X])
    obs = np.clip(obs - BG, 0.0, None)          # (9, TEX, TEX, 3)
    usable = obs < (CLIP - BG)

    tints = np.asarray(TINTS)                   # (9, 3)

    # Unknowns per pixel: x = [A, Br, Bg, Bb].
    # Each observation obs[i, c] contributes the row [tint[i, c], e_c].
    rows = []
    for i in range(len(TINTS)):
        for c in range(3):
            r = np.zeros(4)
            r[0] = tints[i, c]
            r[1 + c] = 1.0
            rows.append(r)
    design = np.asarray(rows)                   # (27, 4)

    flat_obs = obs.transpose(1, 2, 0, 3).reshape(TEX * TEX, 27)
    flat_use = usable.transpose(1, 2, 0, 3).reshape(TEX * TEX, 27)

    solution = np.zeros((TEX * TEX, 4))
    # Group pixels by which observations are usable: only a handful of distinct
    # masks exist, so one pseudo-inverse per mask solves every pixel at once.
    masks, inverse = np.unique(flat_use, axis=0, return_inverse=True)
    for mi, mask in enumerate(masks):
        if mask.sum() < 4:
            continue
        sel = inverse == mi
        pinv = np.linalg.pinv(design[mask])
        solution[sel] = flat_obs[sel][:, mask] @ pinv.T

    solution = solution.reshape(TEX, TEX, 4)
    a = np.clip(solution[..., 0], 0.0, None)
    b = np.clip(solution[..., 1:], 0.0, None)

    # The screenshot is lossy, so smooth away the per-pixel noise, then undo
    # part of the screenshot's own blur with a gentle unsharp mask.  sigma is
    # in texture pixels; TEX/(2*SPAN) ~= 2.9 texels per screenshot pixel.
    def clean(plane):
        plane = gaussian_blur(plane, 1.1)
        return np.clip(plane + 0.55 * (plane - gaussian_blur(plane, 2.6)), 0.0, None)

    a = clean(a)
    b = np.stack([clean(b[..., c]) for c in range(3)], axis=-1)
    return a, b


# ---------------------------------------------------------------------------
# layer -> RGBA
# ---------------------------------------------------------------------------
def radius_grid():
    t = (np.arange(TEX) + 0.5) / TEX * (2 * SPAN) - SPAN
    gx, gy = np.meshgrid(t, t)
    return np.sqrt(gx * gx + gy * gy)


def build_orb(a):
    """Greyscale sphere: RGB carries the shading, alpha the silhouette."""
    r = radius_grid()
    alpha = np.clip((R_EDGE - r) / (R_EDGE - R_SOLID), 0.0, 1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        rgb = np.where(alpha > 1e-3, a / 255.0 / np.maximum(alpha, 1e-3), 0.0)
    rgb = np.clip(rgb, 0.0, 1.0)
    out = np.zeros((TEX, TEX, 4))
    out[..., 0] = out[..., 1] = out[..., 2] = rgb
    out[..., 3] = alpha
    return out


def build_gloss(b):
    """Gold rim + specular highlight, premultiplied into RGB x alpha."""
    alpha = np.clip(b.max(axis=-1) / 255.0, 0.0, 1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        rgb = np.where(
            alpha[..., None] > 1e-3,
            b / 255.0 / np.maximum(alpha[..., None], 1e-3),
            0.0,
        )
    rgb = np.clip(rgb, 0.0, 1.0)
    out = np.zeros((TEX, TEX, 4))
    out[..., :3] = rgb
    out[..., 3] = alpha
    return out


def to_u8(rgba):
    return np.clip(np.round(rgba * 255.0), 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# mip chain
# ---------------------------------------------------------------------------
def mip_chain(rgba_u8):
    """Box-filtered mip chain, averaged in premultiplied space."""
    levels = [rgba_u8]
    cur = rgba_u8.astype(float)
    while cur.shape[0] > 1:
        n = cur.shape[0] // 2
        alpha = cur[..., 3:4] / 255.0
        prem = np.concatenate([cur[..., :3] * alpha, cur[..., 3:4]], axis=-1)
        prem = prem.reshape(n, 2, n, 2, 4).mean(axis=(1, 3))
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
    pal_img = img.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
    raw = pal_img.getpalette()[: 256 * 3]
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
        offsets[i] = cursor
        sizes[i] = len(data)
        cursor += len(data)

    out = bytearray()
    out += b"BLP2"
    out += struct.pack("<I", 1)                      # type: direct (not JPEG)
    out += struct.pack("<BBBB", 1, 8, 0, 1)          # encoding, alphaDepth,
    #                                                  alphaEncoding, hasMips
    out += struct.pack("<II", levels[0].shape[1], levels[0].shape[0])
    out += struct.pack("<16I", *offsets)
    out += struct.pack("<16I", *sizes)
    for r, g, b in pal:
        out += struct.pack("<BBBB", b, g, r, 0)      # palette is BGRA
    assert len(out) == header_size, len(out)
    for data in mips[:16]:
        out += data

    with open(path, "wb") as fh:
        fh.write(bytes(out))
    return bytes(out)


def write_tga(path, rgba_u8):
    """Uncompressed 32-bit TGA, bottom-up, for pre-Legion clients."""
    h, w, _ = rgba_u8.shape
    out = bytearray()
    out += struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    for y in range(h - 1, -1, -1):
        row = rgba_u8[y]
        bgra = row[:, [2, 1, 0, 3]]
        out += bgra.tobytes()
    with open(path, "wb") as fh:
        fh.write(bytes(out))


# ---------------------------------------------------------------------------
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    a, b = decompose()

    for name, rgba, grey in (
        ("Orb", build_orb(a), True),
        ("OrbGloss", build_gloss(b), False),
    ):
        u8 = to_u8(rgba)
        levels = mip_chain(u8)
        blp = write_blp(os.path.join(OUT_DIR, name + ".blp"), levels, grey)
        write_tga(os.path.join(OUT_DIR, name + ".tga"), u8)
        print(
            "%-9s %dx%d  %d mips  blp=%d bytes  tga=%d bytes"
            % (name, TEX, TEX, len(levels), len(blp), TEX * TEX * 4 + 18)
        )


if __name__ == "__main__":
    main()
