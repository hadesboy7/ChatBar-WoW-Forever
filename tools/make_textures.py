#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generates ChatOrbs/Textures/*.blp.

Everything here is drawn from scratch: no source artwork, no screenshots.
Each texture is written as BLP2 / DXT5 with a full mip chain - the format every
texture the game itself ships uses. An earlier revision wrote the palettised
BLP2 variant instead; the client refused to load it and rendered the missing
texture green, so that path is gone.

    Orb       greyscale sphere + ring, tinted with the chat colour
    OrbSheen  white top wash, drawn over the orb with normal blending
    Glow      soft radial glow, tinted, drawn additively on hover
    Panel     nine-slice rounded panel for the dock and the emote popup
    Marker    rounded pill marking the active channel

The orb is split in two because SetVertexColor can only darken: the ring and
the vertical falloff are multiplies and live in Orb, while the highlight has
to lighten and therefore needs its own layer.

Every file is verified after writing by decoding it again with Pillow, whose
BLP reader is an independent implementation of the format.
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
# Orb: a shaded sphere, greyscale so SetVertexColor can tint it
# ---------------------------------------------------------------------------
LIGHT = np.array([-0.42, -0.55, 0.72])      # upper left, tilted towards us
LIGHT = LIGHT / np.linalg.norm(LIGHT)


def _sphere(size):
    """Surface normal and coverage for a unit sphere filling the tile."""
    axis = (np.arange(size) + 0.5) / size * 2.0 - 1.0
    gx, gy = np.meshgrid(axis, axis)
    r = np.sqrt(gx * gx + gy * gy)
    z = np.sqrt(np.clip(1.0 - r * r, 0.0, 1.0))
    lit = np.clip(gx * LIGHT[0] + gy * LIGHT[1] + z * LIGHT[2], 0.0, 1.0)
    # One texel of feathering; the mip chain turns this into proper
    # antialiasing at whatever size the orb is actually drawn.
    coverage = np.clip((1.0 - r) * size / 2.0, 0.0, 1.0)
    return r, lit, coverage


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_orb(size=128, ambient=0.54, rim=0.26, outline=0.60):
    """Diffuse ball, darkened towards the rim, with a dark outline."""
    r, lit, coverage = _sphere(size)
    value = ambient + (1.0 - ambient) * lit
    value = value * (1.0 - rim * smoothstep(0.80, 1.0, r))
    value = value * (1.0 - outline * smoothstep(0.90, 1.0, r))

    out = np.zeros((size, size, 4))
    out[..., 0] = out[..., 1] = out[..., 2] = np.clip(value, 0.0, 1.0)
    out[..., 3] = coverage
    return out


# ---------------------------------------------------------------------------
# OrbSheen: the specular highlight, drawn untinted over the orb
# ---------------------------------------------------------------------------
def make_sheen(size=128, tightness=24.0, strength=0.97, gloss=0.18):
    r, lit, coverage = _sphere(size)
    spec = np.power(lit, tightness) * strength
    # A faint wash over the upper half keeps the ball from looking matte.
    spec = spec + gloss * np.power(np.clip(lit, 0.0, 1.0), 2.2)
    spec = spec * (1.0 - smoothstep(0.88, 1.0, r))

    out = np.zeros((size, size, 4))
    out[..., :3] = 1.0
    out[..., 3] = np.clip(spec, 0.0, 1.0) * coverage
    return out


# ---------------------------------------------------------------------------
# Glow: soft radial halo drawn additively behind a hovered orb
# ---------------------------------------------------------------------------
def make_glow(size=128, inner=0.30, blur=0.11):
    px = size * SS // 4
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(
        (px * inner, px * inner, px * (1 - inner), px * (1 - inner)),
        fill=(255, 255, 255, 255))
    layer = layer.filter(ImageFilter.GaussianBlur(px * blur))
    arr = to_array(layer.resize((size, size), Image.LANCZOS))
    arr[..., :3] = 1.0
    return arr


# ---------------------------------------------------------------------------
# Panel: nine-slice rounded panel, dark fill with a light hairline
# ---------------------------------------------------------------------------
def make_panel(size=128, fill=(13, 13, 16, 210),
               border=(255, 255, 255, 46), sheen=(255, 255, 255, 28)):
    radius = size * 0.3125                      # 40 at 128, i.e. 10 on screen
    border_w = size / 32.0                      # a crisp hairline once scaled
    px = size * SS // 2
    k = px / size
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((0, 0, px - 1, px - 1), radius=radius * k, fill=fill)
    d.rounded_rectangle((border_w * k / 2, border_w * k / 2,
                         px - 1 - border_w * k / 2, px - 1 - border_w * k / 2),
                        radius=radius * k, outline=border, width=int(border_w * k))
    d.rounded_rectangle((radius * k * 0.5, border_w * k * 1.5,
                         px - 1 - radius * k * 0.5, border_w * k * 3.4),
                        radius=border_w * k, fill=sheen)
    return to_array(layer.resize((size, size), Image.LANCZOS))


# ---------------------------------------------------------------------------
# Marker: rounded pill under the active channel
# ---------------------------------------------------------------------------
def make_marker(w=64, h=32):
    layer = Image.new("RGBA", (w * SS // 2, h * SS // 2), (0, 0, 0, 0))
    k = SS // 2
    ImageDraw.Draw(layer).rounded_rectangle(
        (0, 0, w * k - 1, h * k - 1), radius=h * k / 2, fill=(255, 255, 255, 255))
    arr = to_array(layer.resize((w, h), Image.LANCZOS))
    arr[..., :3] = 1.0
    return arr


# ---------------------------------------------------------------------------
# mip chain
# ---------------------------------------------------------------------------
def mip_chain(rgba_u8):
    """Box-filtered chain down to 1x1, averaged in premultiplied space."""
    levels = [rgba_u8]
    cur = rgba_u8.astype(float)
    while cur.shape[0] > 1 or cur.shape[1] > 1:
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
# DXT5
# ---------------------------------------------------------------------------
def _to565(colour):
    r, g, b = [int(round(c)) for c in colour]
    r, g, b = min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b))
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def _from565(value):
    r, g, b = (value >> 11) & 0x1F, (value >> 5) & 0x3F, value & 0x1F
    return np.array([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)],
                    dtype=float)


def _encode_alpha(values):
    """Eight-value DXT5 alpha block for one 4x4 tile."""
    hi, lo = int(values.max()), int(values.min())
    if hi == lo:
        return bytes([hi, lo, 0, 0, 0, 0, 0, 0])
    # Indices 2..7 interpolate between the endpoints: (6a0+a1)/7 ... (a0+6a1)/7.
    table = np.array([hi, lo] + [((6 - i) * hi + (i + 1) * lo) / 7.0 for i in range(6)])
    indices = np.abs(values[:, None] - table[None, :]).argmin(axis=1)
    bits = 0
    for i, idx in enumerate(indices):
        bits |= int(idx) << (3 * i)
    return bytes([hi, lo]) + bits.to_bytes(6, "little")


def _encode_colour(pixels, weights):
    """Four-colour DXT5 block; endpoints fitted along the principal axis."""
    mean = np.average(pixels, axis=0, weights=weights) if weights.sum() > 0 \
        else pixels.mean(axis=0)
    centred = (pixels - mean) * weights[:, None]
    # Power iteration for the dominant eigenvector of the covariance.
    axis = np.array([1.0, 1.0, 1.0])
    cov = centred.T @ centred
    for _ in range(12):
        nxt = cov @ axis
        norm = np.linalg.norm(nxt)
        if norm < 1e-9:
            break
        axis = nxt / norm
    projection = (pixels - mean) @ axis
    c0 = mean + axis * projection.max()
    c1 = mean + axis * projection.min()

    # Two least-squares refinements against the indices they produce.
    for _ in range(2):
        q0, q1 = _from565(_to565(c0)), _from565(_to565(c1))
        table = np.stack([q0, q1, (2 * q0 + q1) / 3.0, (q0 + 2 * q1) / 3.0])
        idx = ((pixels[:, None, :] - table[None, :, :]) ** 2).sum(axis=2).argmin(axis=1)
        t = np.array([0.0, 1.0, 1 / 3.0, 2 / 3.0])[idx]
        w = weights
        s00, s01, s11 = (w * (1 - t) ** 2).sum(), (w * t * (1 - t)).sum(), (w * t ** 2).sum()
        det = s00 * s11 - s01 * s01
        if abs(det) < 1e-9:
            break
        b0 = (w[:, None] * (1 - t)[:, None] * pixels).sum(axis=0)
        b1 = (w[:, None] * t[:, None] * pixels).sum(axis=0)
        c0, c1 = (s11 * b0 - s01 * b1) / det, (s00 * b1 - s01 * b0) / det

    v0, v1 = _to565(c0), _to565(c1)
    if v0 < v1:
        v0, v1 = v1, v0
    q0, q1 = _from565(v0), _from565(v1)
    table = np.stack([q0, q1, (2 * q0 + q1) / 3.0, (q0 + 2 * q1) / 3.0])
    idx = ((pixels[:, None, :] - table[None, :, :]) ** 2).sum(axis=2).argmin(axis=1)
    bits = 0
    for i, value in enumerate(idx):
        bits |= int(value) << (2 * i)
    return struct.pack("<HH", v0, v1) + bits.to_bytes(4, "little")


def encode_dxt5(rgba):
    """Compresses one RGBA mip level into DXT5 blocks, row-major."""
    h, w = rgba.shape[:2]
    out = bytearray()
    for by in range(0, max(h, 4), 4):
        for bx in range(0, max(w, 4), 4):
            block = np.zeros((4, 4, 4), dtype=float)
            for y in range(4):
                for x in range(4):
                    # Blocks past the edge repeat the last real texel.
                    block[y, x] = rgba[min(by + y, h - 1), min(bx + x, w - 1)]
            flat = block.reshape(16, 4)
            alpha = flat[:, 3]
            # Transparent texels carry no visible colour, so they must not pull
            # the endpoints around; weight them out of the fit.
            weights = np.maximum(alpha / 255.0, 1e-3)
            out += _encode_alpha(np.round(alpha).astype(int))
            out += _encode_colour(flat[:, :3], weights)
    return bytes(out)


# ---------------------------------------------------------------------------
# BLP2 writer (type 1 / encoding 2 / alphaEncoding 7: DXT5, 8-bit alpha)
# ---------------------------------------------------------------------------
def write_blp(path, levels):
    mips = [encode_dxt5(level.astype(float)) for level in levels]

    header_size = 148 + 256 * 4          # the palette block is always present
    offsets, sizes, cursor = [0] * 16, [0] * 16, header_size
    for i, data in enumerate(mips[:16]):
        offsets[i], sizes[i] = cursor, len(data)
        cursor += len(data)

    out = bytearray()
    out += b"BLP2"
    out += struct.pack("<I", 1)                   # type: direct colour
    out += struct.pack("<BBBB", 2, 8, 7, 1)       # encoding DXT, alphaDepth 8,
    #                                               alphaEncoding DXT5, hasMips
    out += struct.pack("<II", levels[0].shape[1], levels[0].shape[0])
    out += struct.pack("<16I", *offsets)
    out += struct.pack("<16I", *sizes)
    out += b"\0" * 1024                           # unused for DXT
    assert len(out) == header_size, len(out)
    for data in mips[:16]:
        out += data

    with open(path, "wb") as fh:
        fh.write(bytes(out))
    return len(out)


def verify(path, expected):
    """Re-reads the file: structure by hand, pixels through Pillow's decoder."""
    data = open(path, "rb").read()
    assert data[:4] == b"BLP2", path
    kind, = struct.unpack_from("<I", data, 4)
    encoding, alpha_depth, alpha_encoding, has_mips = struct.unpack_from("<BBBB", data, 8)
    w, h = struct.unpack_from("<II", data, 12)
    offsets = struct.unpack_from("<16I", data, 20)
    sizes = struct.unpack_from("<16I", data, 84)
    assert (kind, encoding, alpha_depth, alpha_encoding, has_mips) == (1, 2, 8, 7, 1)
    assert (w, h) == (expected.shape[1], expected.shape[0])

    levels, ew, eh = 0, w, h
    while levels < 16 and sizes[levels]:
        blocks = max(1, (ew + 3) // 4) * max(1, (eh + 3) // 4)
        assert sizes[levels] == blocks * 16, (path, levels, sizes[levels])
        levels += 1
        ew, eh = max(1, ew // 2), max(1, eh // 2)
    assert (ew, eh) == (1, 1) or levels == 16, (path, ew, eh)
    assert offsets[levels - 1] + sizes[levels - 1] == len(data), path

    decoded = np.asarray(Image.open(path).convert("RGBA")).astype(float)
    weight = expected[..., 3:4] / 255.0
    rgb_diff = np.abs(decoded[..., :3] - expected[..., :3]) * weight
    alpha_diff = np.abs(decoded[..., 3] - expected[..., 3])
    return levels, rgb_diff.max(), rgb_diff.mean(), alpha_diff.max(), alpha_diff.mean()


# ---------------------------------------------------------------------------
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    textures = [
        ("Orb",      make_orb()),
        ("OrbSheen", make_sheen()),
        ("Glow",     make_glow()),
        ("Panel",    make_panel()),
        ("Marker",   make_marker()),
    ]
    for name, arr in textures:
        u8 = np.clip(np.round(arr * 255.0), 0, 255).astype(np.uint8)
        path = os.path.join(OUT_DIR, name + ".blp")
        written = write_blp(path, mip_chain(u8))
        levels, rgb_max, rgb_mean, a_max, a_mean = verify(path, u8.astype(float))
        print("%-9s %dx%d %d mips %5d B   round-trip err rgb max %4.1f mean %4.2f"
              "   alpha max %4.1f mean %4.2f"
              % (name, u8.shape[1], u8.shape[0], levels, written,
                 rgb_max, rgb_mean, a_max, a_mean))


if __name__ == "__main__":
    main()
