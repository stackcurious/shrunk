#!/usr/bin/env python3
"""Generate Shrunk's flat Scanned Delta App Store icon.

The mark combines four scan corners with five descending bars: scan a package,
then see its size change. The output is an opaque 1024×1024 RGB PNG; iOS adds
the platform-specific corner mask.
"""

from argparse import ArgumentParser
from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 1024
SCALE = 4
RED = "#E24B4A"
PAPER = "#FFF9F2"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / (
    "Shrunk/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)


def rounded_line(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], width: int) -> None:
    scaled = [(x * SCALE, y * SCALE) for x, y in points]
    draw.line(scaled, fill=PAPER, width=width * SCALE, joint="curve")
    radius = width * SCALE // 2
    for x, y in (scaled[0], scaled[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=PAPER)


def generate(output: Path) -> None:
    canvas = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), RED)
    draw = ImageDraw.Draw(canvas)

    # Scan corners. The open center keeps the mark legible at App Store sizes.
    rounded_line(draw, [(190, 335), (190, 190), (335, 190)], 60)
    rounded_line(draw, [(689, 190), (834, 190), (834, 335)], 60)
    rounded_line(draw, [(190, 689), (190, 834), (335, 834)], 60)
    rounded_line(draw, [(689, 834), (834, 834), (834, 689)], 60)

    # A barcode-like sequence that steps down in height: the Scanned Delta.
    bars = [
        (295, 302, 357, 702),
        (382, 344, 444, 702),
        (469, 397, 531, 702),
        (556, 448, 618, 702),
        (643, 499, 705, 702),
    ]
    for left, top, right, bottom in bars:
        draw.rounded_rectangle(
            (left * SCALE, top * SCALE, right * SCALE, bottom * SCALE),
            radius=18 * SCALE,
            fill=PAPER,
        )

    icon = canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    output.parent.mkdir(parents=True, exist_ok=True)
    icon.save(output, "PNG", optimize=True)
    print(f"wrote {output} {icon.size} {icon.mode}")


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    generate(args.output)


if __name__ == "__main__":
    main()
