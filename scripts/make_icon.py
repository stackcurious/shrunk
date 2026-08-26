#!/usr/bin/env python3
"""Generate the Shrunk 1024x1024 App Store icon.

Brand palette (from Shrunk/Core/Theme/ShrunkTheme.swift):
  shrunkRed     #E24B4A
  shrunkRedDeep #B0302F
  shrunkRedDark #791F1F
  paper         #FAFAF7

Concept: a premium "shrinking package" mark — a box that steps down in size
with a downward chevron arrow, over a warm-to-deep red diagonal gradient.
Flat, opaque, no rounded corners (Apple masks automatically).
"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

RED       = hex_rgb("E24B4A")
RED_DEEP  = hex_rgb("B0302F")
RED_DARK  = hex_rgb("791F1F")
PAPER     = hex_rgb("FAFAF7")
PAPER_DIM = hex_rgb("F0E9E3")

def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

# --- Background: diagonal gradient shrunkRed -> shrunkRedDeep -> a touch of dark
bg = Image.new("RGB", (S, S), RED)
px = bg.load()
for y in range(S):
    for x in range(S):
        # diagonal position 0..1 (top-left -> bottom-right)
        t = (x + y) / (2 * (S - 1))
        if t < 0.55:
            c = lerp(RED, RED_DEEP, t / 0.55)
        else:
            c = lerp(RED_DEEP, RED_DARK, (t - 0.55) / 0.45)
        px[x, y] = c

draw = ImageDraw.Draw(bg, "RGBA")

# --- Subtle radial vignette for depth (darken corners slightly)
vig = Image.new("L", (S, S), 0)
vd = ImageDraw.Draw(vig)
cx = cy = S / 2
maxd = math.hypot(cx, cy)
vpx = vig.load()
for y in range(0, S, 2):
    for x in range(0, S, 2):
        d = math.hypot(x - cx, y - cy) / maxd
        v = int(max(0, (d - 0.45)) * 150)
        vpx[x, y] = v
        if x + 1 < S: vpx[x + 1, y] = v
        if y + 1 < S:
            vpx[x, y + 1] = v
            if x + 1 < S: vpx[x + 1, y + 1] = v
vig = vig.filter(ImageFilter.GaussianBlur(40))
shadow_layer = Image.new("RGB", (S, S), (0, 0, 0))
bg = Image.composite(shadow_layer, bg, vig.point(lambda p: int(p * 0.55)))
draw = ImageDraw.Draw(bg, "RGBA")

# ---------------------------------------------------------------------------
# Glyph: three stacked boxes, each smaller than the one below — "shrinking" —
# rendered in warm paper. A downward arrow runs through them.
# ---------------------------------------------------------------------------

def rrect(d, box, r, **kw):
    d.rounded_rectangle(box, radius=r, **kw)

# Drop shadow for the whole mark (soft, offset down)
mark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
md = ImageDraw.Draw(mark)

# Geometry: three nested/stacked rounded boxes, decreasing width, going UP.
# Bottom (largest) sits low; top (smallest) sits high — reads as shrinking.
cxp = S / 2
boxes = [
    # (half_width, height, center_y)
    (300, 150, 690),  # bottom, biggest
    (224, 134, 512),  # middle
    (150, 118, 352),  # top, smallest
]
fills = [PAPER, lerp(PAPER, PAPER_DIM, 0.35), lerp(PAPER, PAPER_DIM, 0.7)]

for (hw, h, cyb), fill in zip(boxes, fills):
    box = (cxp - hw, cyb - h / 2, cxp + hw, cyb + h / 2)
    rad = h * 0.30
    md.rounded_rectangle(box, radius=rad, fill=fill + (255,))

# Add a soft inner shadow line between stacked boxes for separation
for (hw, h, cyb) in boxes[1:]:
    box = (cxp - hw, cyb - h / 2, cxp + hw, cyb + h / 2)
    rad = h * 0.30
    md.rounded_rectangle(box, radius=rad, outline=RED_DEEP + (70,), width=3)

# Downward chevron arrow centered, in brand red, sitting in front
arrow_w = 150
arrow_top = 300
arrow_bottom = 760
shaft_w = 64
# shaft
md.rounded_rectangle(
    (cxp - shaft_w / 2, arrow_top, cxp + shaft_w / 2, arrow_bottom - 120),
    radius=shaft_w / 2, fill=RED + (255,)
)
# arrowhead (triangle) pointing down
md.polygon(
    [
        (cxp - arrow_w, arrow_bottom - 230),
        (cxp + arrow_w, arrow_bottom - 230),
        (cxp, arrow_bottom),
    ],
    fill=RED + (255,)
)
# white keyline around arrow so it pops against paper boxes
md.line(
    [(cxp - arrow_w, arrow_bottom - 230), (cxp, arrow_bottom), (cxp + arrow_w, arrow_bottom - 230)],
    fill=PAPER + (255,), width=10, joint="curve"
)

# Build shadow from mark alpha
alpha = mark.split()[3]
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("L", (S, S), 0)
sh.paste(alpha, (0, 18))
sh = sh.filter(ImageFilter.GaussianBlur(22)).point(lambda p: int(p * 0.30))
shadow.putalpha(sh)
shadow_rgb = Image.new("RGBA", (S, S), (50, 10, 10, 0))
shadow_rgb.putalpha(sh)

bg = bg.convert("RGBA")
bg.alpha_composite(shadow_rgb)
bg.alpha_composite(mark)

# Flatten to opaque RGB (no alpha — App Store requirement)
final = Image.new("RGB", (S, S), PAPER)
final.paste(bg.convert("RGB"), (0, 0))

out = "/Users/drao/Projects/shrunk/Shrunk/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
final.save(out, "PNG")
print("wrote", out, final.size, final.mode)
