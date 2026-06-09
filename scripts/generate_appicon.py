#!/usr/bin/env python3
"""Generate an original SwiftMaestro app icon (no third-party artwork).

Motif: a central "Navigator" node linked to satellite "agent" nodes — a
hub-and-spoke orchestration graph — on a blue→teal gradient squircle.
Rendered at 2x and downscaled with LANCZOS for clean anti-aliased edges.

Usage: python3 generate_appicon.py <output_1024.png>
"""
import math
import sys
from PIL import Image, ImageDraw

SCALE = 2
SIZE = 1024 * SCALE


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(w, h, top, bottom):
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        grad.putpixel((0, y), lerp(top, bottom, y / max(1, h - 1)))
    return grad.resize((w, h))


def main(out_path):
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Rounded-square ("squircle") plate, macOS-style margin + corner radius.
    margin = int(SIZE * 0.085)
    radius = int(SIZE * 0.225)
    plate = (margin, margin, SIZE - margin, SIZE - margin)

    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(plate, radius=radius, fill=255)

    grad = vertical_gradient(SIZE, SIZE, (37, 99, 235), (13, 148, 136)).convert("RGBA")
    img.paste(grad, (0, 0), mask)

    draw = ImageDraw.Draw(img)
    cx = cy = SIZE / 2
    ring = SIZE * 0.265
    line_w = max(1, int(SIZE * 0.013))
    node_fill = (255, 255, 255, 255)
    line_col = (255, 255, 255, 210)

    # Satellite agent nodes evenly placed on a ring; first one points up.
    sats = []
    n = 5
    for k in range(n):
        a = -math.pi / 2 + k * (2 * math.pi / n)
        sats.append((cx + ring * math.cos(a), cy + ring * math.sin(a)))

    # Spokes from the hub to each satellite.
    for (sx, sy) in sats:
        draw.line([(cx, cy), (sx, sy)], fill=line_col, width=line_w)

    # Satellite nodes.
    sr = SIZE * 0.044
    for (sx, sy) in sats:
        draw.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=node_fill)

    # Central hub node (larger), with a gradient-colored core for depth.
    hr = SIZE * 0.082
    draw.ellipse([cx - hr, cy - hr, cx + hr, cy + hr], fill=node_fill)
    cr = hr * 0.5
    draw.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=(37, 99, 235, 255))

    img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(out_path)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "appicon_src.png")
