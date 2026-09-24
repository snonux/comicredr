#!/usr/bin/env python3
"""Generate synthetic comic pages with ground-truth panel boxes.

Throwaway M1 spike helper. Each layout family targets one failure mode from
section 10 of the design plan, so the classic-CV pipeline can be checked
before real comics are available:

  grid6      golden-age six-panel grid, JPEG artefacts, slight skew
  irregular  mixed row heights and widths, white gutters
  crossing   grid with balloons straddling the gutters
  bleed      full-bleed colour art, panels split only by thin black rules
  splash     one panel covering the page
  inset      a large panel with a small inset panel on top of it

Writes <out>/<name>.jpg and <out>/<name>.json ({"panels": [[x,y,w,h],...]})
with boxes in pixels of the saved image, listed in reading order.
"""
import argparse
import json
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H = 1300, 2000
MARGIN = 70
GUTTER = 28


def art(draw, box, rng, palette):
    """Fill a panel with blobs, lines and gradients that look vaguely like art."""
    x0, y0, x1, y1 = box
    base = rng.choice(palette)
    draw.rectangle(box, fill=base)
    for _ in range(rng.randint(6, 16)):
        cx, cy = rng.uniform(x0, x1), rng.uniform(y0, y1)
        r = rng.uniform(15, (x1 - x0) / 3)
        c = rng.choice(palette)
        if rng.random() < 0.5:
            draw.ellipse([cx - r, cy - r * 0.7, cx + r, cy + r * 0.7], fill=c, outline=(20, 20, 20), width=3)
        else:
            draw.polygon([(cx + r * math.cos(a), cy + r * math.sin(a)) for a in
                          [rng.uniform(0, 6.28) for _ in range(5)]], fill=c, outline=(20, 20, 20))
    for _ in range(rng.randint(4, 10)):
        draw.line([rng.uniform(x0, x1), rng.uniform(y0, y1), rng.uniform(x0, x1), rng.uniform(y0, y1)],
                  fill=(25, 25, 25), width=rng.randint(2, 5))


def balloon(draw, cx, cy, rng, text_lines=3):
    rx, ry = rng.uniform(70, 130), rng.uniform(40, 70)
    draw.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill="white", outline="black", width=3)
    draw.polygon([(cx - 15, cy + ry - 5), (cx + 10, cy + ry - 5), (cx - 30, cy + ry + 35)],
                 fill="white", outline="black")
    for i in range(text_lines):
        yy = cy - ry * 0.5 + i * ry * 0.45
        draw.line([cx - rx * 0.6, yy, cx + rx * 0.6, yy], fill="black", width=4)


def grid_rows(rows):
    """rows: list of (height_fraction, [width_fractions]). Returns panel boxes."""
    boxes = []
    usable_h = H - 2 * MARGIN - GUTTER * (len(rows) - 1)
    y = MARGIN
    for hf, widths in rows:
        h = usable_h * hf
        usable_w = W - 2 * MARGIN - GUTTER * (len(widths) - 1)
        x = MARGIN
        for wf in widths:
            w = usable_w * wf
            boxes.append((x, y, x + w, y + h))
            x += w + GUTTER
        y += h + GUTTER
    return boxes


def layout(kind, rng):
    if kind in ("grid6", "crossing"):
        return grid_rows([(1 / 3, [0.5, 0.5])] * 3)
    if kind == "irregular":
        return grid_rows([(0.28, [0.35, 0.65]), (0.36, [1.0]), (0.36, [0.3, 0.4, 0.3])])
    if kind == "splash":
        return [(MARGIN, MARGIN, W - MARGIN, H - MARGIN)]
    if kind == "inset":
        big = (MARGIN, MARGIN, W - MARGIN, H * 0.7)
        small = (W - MARGIN - 380, MARGIN + 40, W - MARGIN - 40, MARGIN + 340)
        low = grid_rows([(1.0, [0.5, 0.5])])
        low = [(x0, H * 0.7 + GUTTER, x1, H - MARGIN) for x0, _, x1, _ in low]
        return [big, small] + low
    if kind == "bleed":
        # Panels touch each other and the page edge; separated by thin rules.
        ys = [0, H * 0.34, H * 0.62, H]
        boxes = []
        splits = [[0, W * 0.55, W], [0, W], [0, W * 0.4, W * 0.7, W]]
        for r in range(3):
            for c in range(len(splits[r]) - 1):
                boxes.append((splits[r][c], ys[r], splits[r][c + 1], ys[r + 1]))
        return boxes
    raise ValueError(kind)


def render(kind, seed):
    rng = random.Random(seed)
    colour = kind in ("bleed", "irregular", "inset", "splash")
    palette = ([(rng.randint(40, 230), rng.randint(40, 230), rng.randint(40, 230)) for _ in range(6)]
               if colour else [(v, v, v) for v in (70, 110, 150, 190, 215)])
    paper = (246, 240, 222) if kind == "grid6" else (255, 255, 255)
    img = Image.new("RGB", (W, H), paper)
    d = ImageDraw.Draw(img)
    boxes = layout(kind, rng)
    for b in boxes:
        # Draw the art on its own canvas so it is clipped to the panel, as in print.
        x0, y0, x1, y1 = (round(v) for v in b)
        tile = Image.new("RGB", (x1 - x0, y1 - y0))
        art(ImageDraw.Draw(tile), (0, 0, x1 - x0, y1 - y0), rng, palette)
        img.paste(tile, (x0, y0))
        if kind == "bleed":
            d.rectangle(b, outline=(10, 10, 10), width=4)
        else:
            d.rectangle(b, outline=(15, 15, 15), width=5)
    if kind == "crossing":
        # Balloons straddling the vertical and horizontal gutters.
        balloon(d, W / 2, MARGIN + 180, rng)
        balloon(d, W * 0.3, MARGIN + (H - 2 * MARGIN) / 3 + 5, rng)
    else:
        for b in boxes[: max(1, len(boxes) // 2)]:
            balloon(d, (b[0] + b[2]) / 2, b[1] + 90, rng, 2)

    if kind == "grid6":
        img = img.rotate(0.8, resample=Image.BICUBIC, fillcolor=paper)
        img = img.filter(ImageFilter.GaussianBlur(0.6))
    gt = [[round(x0), round(y0), round(x1 - x0), round(y1 - y0)] for x0, y0, x1, y1 in boxes]
    return img, gt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="spike/synthetic")
    ap.add_argument("--per-kind", type=int, default=3)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    kinds = ["grid6", "irregular", "crossing", "bleed", "splash", "inset"]
    for ki, k in enumerate(kinds):
        for i in range(a.per_kind):
            img, gt = render(k, seed=ki * 100 + i)
            name = f"{k}_{i:02d}"
            img.save(out / f"{name}.jpg", quality=55 if k == "grid6" else 85)
            (out / f"{name}.json").write_text(json.dumps({"kind": k, "panels": gt}))
    print(f"wrote {len(kinds) * a.per_kind} pages to {out}")


if __name__ == "__main__":
    main()
