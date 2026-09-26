#!/usr/bin/env python3
"""Synthetic modern comic pages, with exact labels, for training the detector.

The real training set has few modern layouts under a licence that lets the
model be published. This makes more from what it has: art is cut from the
labelled frames of the training pages (spike/labels/train, all public domain
or CC BY, credited in NOTICE) and laid out again the way modern comics do:

  touching   grids whose panels touch, split only by thin rules or nothing
  slanted    gutters at an angle, wedge-shaped panels
  dark       panels on a black page, square or rounded corners
  rounded    rounded frames and the odd round panel on paper
  collage    thin-lined panels tilted a few degrees, on paper or black
  bleed      irregular grids, some panels running off the page edge

Each frame is labelled with the axis-aligned box of its outline, as
spike/LABELLING.md asks for slanted frames. Balloons and captions that come
with the art keep their labels when they stay whole; a placement that would
cut one in half is tried again elsewhere.

    python3 spike/synth_modern.py spike/train_pages spike/synth_pages --count 400

Writes <out>/modern-synth/synth-NNNN.jpg and .json in labelkit's format, so
spike/train.py takes the folder beside spike/train_pages. The same seed gives
the same pages.
"""
import argparse
import json
import math
import random
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np

FAMILIES = ["touching", "slanted", "dark", "rounded", "collage", "bleed"]
MIN_ART = 160  # px; smaller source frames are too blurry once enlarged


def sources(pages):
    """(image path, frame box, [(kind, box)] inside it) for every labelled frame."""
    out = []
    for js in sorted(Path(pages).rglob("*.json")):
        if any(t in js.name for t in (".cand.", ".cv.", ".yolo.")):
            continue
        img = js.with_suffix(".jpg")
        if not img.exists():
            continue
        lab = json.loads(js.read_text())
        extras = [("balloons", b) for b in lab.get("balloons", [])] + [("captions", c) for c in lab.get("captions", [])]
        for f in lab.get("panels", []):
            x, y, w, h = f
            if w < MIN_ART or h < MIN_ART or w * h > 0.9 * lab["w"] * lab["h"]:
                continue
            # every balloon touching the frame, so none shows up unlabelled
            inside = [(k, b) for k, b in extras
                      if b[0] < x + w and b[0] + b[2] > x and b[1] < y + h and b[1] + b[3] > y]
            out.append((str(img), f, inside))
    return out


@lru_cache(maxsize=64)
def load(path):
    return cv2.imread(path)


# ------------------------------------------------------------------ geometry

def clip_poly(poly, a, b, c):
    """Keep the part of [poly] where a*x + b*y <= c (Sutherland-Hodgman)."""
    out = []
    n = len(poly)
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        fp, fq = a * p[0] + b * p[1] - c, a * q[0] + b * q[1] - c
        if fp <= 0:
            out.append(p)
        if (fp < 0) != (fq < 0) and fp != fq:
            t = fp / (fp - fq)
            out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    return out


def cell(x0, y0, x1, y1, top, bottom, left, right, gutter):
    """The polygon between two row lines y = k + m*x and two column lines
    x = k + m*y, each moved in by half the gutter, inside the live area."""
    poly = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    g = gutter / 2
    k, m = top      # y >= k + m*x + g'   ->  m*x - y <= -k - g'
    poly = clip_poly(poly, m, -1, -k - g * math.hypot(1, m))
    k, m = bottom   # y <= k + m*x - g'
    poly = clip_poly(poly, -m, 1, k - g * math.hypot(1, m))
    k, m = left     # x >= k + m*y + g'
    poly = clip_poly(poly, -1, m, -k - g * math.hypot(1, m))
    k, m = right    # x <= k + m*y - g'
    poly = clip_poly(poly, 1, -m, k - g * math.hypot(1, m))
    return poly


def rounded(x0, y0, x1, y1, r, steps=6):
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for i in range(steps + 1):
            a = math.radians(a0 + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def ellipse(x0, y0, x1, y1, steps=48):
    cx, cy, rx, ry = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    return [(cx + rx * math.cos(2 * math.pi * i / steps), cy + ry * math.sin(2 * math.pi * i / steps)) for i in range(steps)]


def rotated(x0, y0, x1, y1, deg):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a = math.radians(deg)
    return [(cx + (x - cx) * math.cos(a) - (y - cy) * math.sin(a), cy + (x - cx) * math.sin(a) + (y - cy) * math.cos(a))
            for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))]


# ------------------------------------------------------------------ layouts

def split(total, n, rng, lo=0.6):
    """[n] sizes summing to [total], each at least [lo] of the mean."""
    w = [rng.uniform(lo, 1.6) for _ in range(n)]
    s = sum(w)
    return [total * v / s for v in w]


def grid(rng, x0, y0, x1, y1, gutter, slant=0.0, rows=None):
    """Rows of cells; with [slant] the cuts lean by up to that share of the page."""
    H, W = y1 - y0, x1 - x0
    n = rows or rng.randint(2, 4)
    heights = split(H, n, rng)
    polys = []
    top = (y0 - 10 * H, 0.0)  # far above: no cut
    y = y0
    for r in range(n):
        y += heights[r]
        if r == n - 1:
            bottom = (y1 + 10 * H, 0.0)
        else:
            m = rng.uniform(-slant, slant) * H / W if slant and rng.random() < 0.75 else 0.0
            bottom = (y - m * (x0 + W / 2), m)
        cols = rng.choice([1, 2, 2, 2, 3, 3]) if heights[r] > 0.2 * H else rng.choice([2, 3, 3, 4])
        widths = split(W, cols, rng)
        left = (x0 - 10 * W, 0.0)
        x = x0
        for c in range(cols):
            x += widths[c]
            if c == cols - 1:
                right = (x1 + 10 * W, 0.0)
            else:
                m = rng.uniform(-slant, slant) * W / heights[r] if slant and rng.random() < 0.5 else 0.0
                ym = (top[0] + top[1] * x + bottom[0] + bottom[1] * x) / 2 if r not in (0, n - 1) else y - heights[r] / 2
                right = (x - m * ym, m)
            p = cell(x0, y0, x1, y1, top, bottom, left, right, gutter)
            if len(p) >= 3:
                polys.append(p)
            left = right
        top = bottom
    return polys


def layout(family, rng, W, H):
    """(background BGR, [(polygon, border px, border BGR)])"""
    paper = rng.choice([(255, 255, 255), (245, 248, 250), (225, 238, 246), (238, 238, 238)])
    black = rng.choice([(0, 0, 0), (18, 18, 18), (30, 26, 24)])
    m = rng.uniform(0.03, 0.07) * W
    if family == "touching":
        bg = paper if rng.random() < 0.6 else black
        gutter = rng.choice([0, 0, 3, 6, 10])
        border = rng.choice([0, 0, 2, 3])
        polys = grid(rng, m, m, W - m, H - m, gutter)
        return bg, [(p, border, (0, 0, 0)) for p in polys]
    if family == "slanted":
        bg = paper if rng.random() < 0.7 else black
        gutter = rng.uniform(8, 30)
        border = rng.choice([0, 2, 3, 5])
        polys = grid(rng, m, m, W - m, H - m, gutter, slant=rng.uniform(0.06, 0.18))
        colour = (0, 0, 0) if bg == paper else (235, 235, 235)
        return bg, [(p, border, colour) for p in polys]
    if family == "dark":
        gutter = rng.uniform(10, 40)
        border = rng.choice([0, 0, 2, 3])
        polys = grid(rng, m, m, W - m, H - m, gutter)
        if rng.random() < 0.5:
            r = rng.uniform(15, 60)
            polys = [rounded(*box(p), min(r, (box(p)[2] - box(p)[0]) / 3, (box(p)[3] - box(p)[1]) / 3)) for p in polys]
        colour = rng.choice([(255, 255, 255), (200, 200, 200), (0, 0, 0)])
        return black, [(p, border, colour) for p in polys]
    if family == "rounded":
        gutter = rng.uniform(15, 40)
        polys = []
        for p in grid(rng, m, m, W - m, H - m, gutter):
            x0, y0, x1, y1 = box(p)
            if rng.random() < 0.12 and 0.6 < (x1 - x0) / (y1 - y0) < 1.6:
                polys.append(ellipse(x0, y0, x1, y1))
            else:
                polys.append(rounded(x0, y0, x1, y1, min(rng.uniform(20, 70), (x1 - x0) / 3, (y1 - y0) / 3)))
        return paper, [(p, rng.choice([2, 3, 5]), (0, 0, 0)) for p in polys]
    if family == "collage":
        bg = paper if rng.random() < 0.7 else black
        colour = (0, 0, 0) if bg == paper else (235, 235, 235)
        out = []
        for p in grid(rng, m, m, W - m, H - m, rng.uniform(30, 60)):
            x0, y0, x1, y1 = box(p)
            s = rng.uniform(0.0, 0.04)
            dx, dy = (x1 - x0) * s, (y1 - y0) * s
            out.append((rotated(x0 + dx, y0 + dy, x1 - dx, y1 - dy, rng.uniform(-7, 7)), rng.choice([1, 2, 2, 3]), colour))
        return bg, out
    # bleed: live area reaches the page edge on some sides
    bg = paper if rng.random() < 0.8 else black
    x0, y0, x1, y1 = [0 if rng.random() < 0.5 else m for _ in range(2)] + [W - (0 if rng.random() < 0.5 else m), H - (0 if rng.random() < 0.5 else m)]
    polys = grid(rng, x0, y0, x1, y1, rng.uniform(10, 30), slant=rng.choice([0, 0, 0.05]))
    return bg, [(p, rng.choice([0, 3, 4]), (0, 0, 0)) for p in polys]


def box(poly):
    xs, ys = [p[0] for p in poly], [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


# ------------------------------------------------------------------ drawing

def place(canvas, poly, pool, rng, labels, tries=8):
    """Fill [poly] with art from a random source frame; record kept balloons."""
    H, W = canvas.shape[:2]
    x0, y0, x1, y1 = box(poly)
    bx0, by0 = max(0, int(x0)), max(0, int(y0))
    bx1, by1 = min(W, int(math.ceil(x1))), min(H, int(math.ceil(y1)))
    tw, th = bx1 - bx0, by1 - by0
    if tw < 8 or th < 8:
        return False
    mask = np.zeros((th, tw), np.uint8)
    cv2.fillPoly(mask, [np.int32([(x - bx0, y - by0) for x, y in poly])], 1)
    for _ in range(tries):
        path, (fx, fy, fw, fh), extras = rng.choice(pool)
        s = max(tw / fw, th / fh) * rng.uniform(1.0, 1.35)
        ox = rng.uniform(0, fw * s - tw)
        oy = rng.uniform(0, fh * s - th)
        kept, ok = [], True
        for kind, (ex, ey, ew, eh) in extras:
            ax0, ay0 = (ex - fx) * s - ox, (ey - fy) * s - oy
            ax1, ay1 = ax0 + ew * s, ay0 + eh * s
            cx0, cy0, cx1, cy1 = max(0, ax0), max(0, ay0), min(tw, ax1), min(th, ay1)
            if cx1 <= cx0 or cy1 <= cy0:
                continue
            full = (ax1 - ax0) * (ay1 - ay0)
            seen = mask[int(cy0):int(math.ceil(cy1)), int(cx0):int(math.ceil(cx1))].sum()
            share = seen / full
            if share >= 0.85:
                ys, xs = np.nonzero(mask[int(cy0):int(math.ceil(cy1)), int(cx0):int(math.ceil(cx1))])
                kept.append((kind, [bx0 + cx0 + xs.min(), by0 + cy0 + ys.min(), xs.max() - xs.min() + 1, ys.max() - ys.min() + 1]))
            elif share > 0.15:
                ok = False
                break
        if not ok:
            continue
        img = load(path)
        # source window in the source image
        sx0, sy0 = fx + ox / s, fy + oy / s
        M = np.float32([[s, 0, -sx0 * s], [0, s, -sy0 * s]])
        art = cv2.warpAffine(img, M, (tw, th), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        region = canvas[by0:by1, bx0:bx1]
        region[mask > 0] = art[mask > 0]
        for kind, b in kept:
            labels[kind].append([float(v) for v in b])
        return True
    return False


def page(rng, pool, family):
    W = 1300
    H = int(W * rng.uniform(1.4, 1.6))
    bg, cells = layout(family, rng, W, H)
    canvas = np.zeros((H, W, 3), np.uint8)
    canvas[:] = bg
    labels = {"panels": [], "balloons": [], "captions": []}
    for poly, border, colour in cells:
        poly = [(min(max(x, 0), W), min(max(y, 0), H)) for x, y in poly]
        x0, y0, x1, y1 = box(poly)
        if (x1 - x0) < 60 or (y1 - y0) < 60:
            continue
        if not place(canvas, poly, pool, rng, labels):
            continue
        if border:
            cv2.polylines(canvas, [np.int32(poly)], True, colour, int(border), cv2.LINE_AA)
            h = border / 2
            x0, y0, x1, y1 = max(0, x0 - h), max(0, y0 - h), min(W, x1 + h), min(H, y1 + h)
        labels["panels"].append([x0, y0, x1 - x0, y1 - y0])
    return canvas, {"w": W, "h": H, **{k: [[round(v) for v in b] for b in bs] for k, bs in labels.items()}}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pages", help="labelled training pages (spike/train_pages)")
    ap.add_argument("out", help="output root, e.g. spike/synth_pages")
    ap.add_argument("--count", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    pool = sources(a.pages)
    if not pool:
        raise SystemExit(f"no labelled frames under {a.pages}")
    out = Path(a.out) / "modern-synth"
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(a.seed)
    stats = {"panels": 0, "balloons": 0, "captions": 0}
    for i in range(a.count):
        family = FAMILIES[i % len(FAMILIES)]
        img, lab = page(rng, pool, family)
        if len(lab["panels"]) < 2:
            continue
        cv2.imwrite(str(out / f"synth-{i:04d}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(75, 95)])
        (out / f"synth-{i:04d}.json").write_text(json.dumps(lab))
        for k in stats:
            stats[k] += len(lab[k])
    print(f"{a.count} pages from {len(pool)} source frames: {stats}")


if __name__ == "__main__":
    main()
