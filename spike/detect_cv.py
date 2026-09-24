#!/usr/bin/env python3
"""Classic computer-vision panel detection, with the confidence gate.

Throwaway M1 spike (design plan section 9). The pipeline:

  1. downscale so the long side is 1200 px
  2. foreground = anything that is not paper-coloured gutter, plus dilated
     Canny edges so thin panel borders close
  3. fill holes, then connected components -> candidate boxes
  4. recursively split big boxes along full-length gutter or rule lines,
     which rescues full-bleed pages separated by thin black rules
  5. western reading order: group into rows, left to right within a row
  6. confidence gate: 2..20 panels, no real overlap, >= 60% page coverage,
     every panel a plausible size. Fail the gate and the reader pages normally.

Boxes are returned normalised to the page (x, y, w, h in 0..1), which is how
the app stores them.
"""
from dataclasses import dataclass, field

import cv2
import numpy as np

WORK_LONG_SIDE = 1200
MIN_PANEL_FRAC = 0.012      # of page area
SPLIT_LINE_FRAC = 0.93      # a row/column is a separator if this share of it is gutter or rule
MIN_SPLIT_PART = 0.12       # each side of a split must be at least this share of the box
BRIDGE_FRAC = 0.5           # ...or if the component covers at most this share of it


@dataclass
class Result:
    panels: list                        # normalised [x, y, w, h], reading order
    passed: bool
    reasons: list = field(default_factory=list)
    coverage: float = 0.0


def _foreground(gray):
    border = np.concatenate([gray[:8].ravel(), gray[-8:].ravel(), gray[:, :8].ravel(), gray[:, -8:].ravel()])
    paper = np.percentile(border, 90)
    # Only treat bright borders as paper; a dark border means full-bleed art.
    thresh = paper - 28 if paper > 200 else 250
    fg = (gray < thresh).astype(np.uint8) * 255
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 0), 60, 160)
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=2)
    fg = cv2.bitwise_or(fg, edges)
    fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    # Fill holes: flood the background from the border, everything unreached is inside a panel.
    h, w = fg.shape
    flood = fg.copy()
    mask = np.zeros((h + 2, w + 2), np.uint8)
    for x, y in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if flood[y, x] == 0:
            cv2.floodFill(flood, mask, (x, y), 128)
    return np.where(flood == 128, 0, 255).astype(np.uint8), paper


def _separator_runs(profile, lo, hi):
    """Indices where profile is True, grouped into (start, end) runs within [lo, hi)."""
    runs, start = [], None
    for i in range(lo, hi):
        if profile[i] and start is None:
            start = i
        elif not profile[i] and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, hi))
    return runs


def _split(gray, paper, mask, box, depth=0):
    """Recursively cut a box along gutters, black rules, or narrow bridges.

    A row (or column) is a separator when nearly all of it is paper-white or
    rule-black, or when the component itself barely spans it: that is the
    signature of two panels glued together by a balloon crossing the gutter.
    """
    x0, y0, x1, y1 = box
    if depth > 6 or (x1 - x0) < 60 or (y1 - y0) < 60:
        return [box]
    roi = gray[y0:y1, x0:x1]
    comp = mask[y0:y1, x0:x1]
    line = (roi < 55) | (roi > paper - 14 if paper > 200 else roi > 248)
    for axis in (0, 1):  # 0: horizontal cut (rows), 1: vertical cut (columns)
        other = 1 - axis
        prof = (line.mean(axis=other) >= SPLIT_LINE_FRAC) | (comp.mean(axis=other) <= BRIDGE_FRAC)
        n = prof.shape[0]
        lo, hi = int(n * MIN_SPLIT_PART), int(n * (1 - MIN_SPLIT_PART))
        runs = _separator_runs(prof, lo, hi)
        if runs:
            a, b = max(runs, key=lambda r: r[1] - r[0])
            if axis == 0:
                parts = [(x0, y0, x1, y0 + a), (x0, y0 + b, x1, y1)]
            else:
                parts = [(x0, y0, x0 + a, y1), (x0 + b, y0, x1, y1)]
            parts = [_tighten(mask, p) for p in parts]
            return [q for p in parts if p for q in _split(gray, paper, mask, p, depth + 1)]
    return [box]


def _tighten(mask, box):
    """Shrink a box to the component pixels it actually contains."""
    x0, y0, x1, y1 = box
    ys, xs = np.nonzero(mask[y0:y1, x0:x1])
    if len(xs) == 0:
        return None
    return (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)


def _drop_nested(boxes):
    """Remove boxes that sit almost entirely inside a bigger one."""
    keep = []
    for i, a in enumerate(boxes):
        area = (a[2] - a[0]) * (a[3] - a[1])
        inside = False
        for j, b in enumerate(boxes):
            if i == j or (b[2] - b[0]) * (b[3] - b[1]) <= area:
                continue
            ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
            iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            if ix * iy > 0.8 * area:
                inside = True
        if not inside:
            keep.append(a)
    return keep


def _reading_order(boxes):
    """Western order: rows top to bottom, left to right inside a row."""
    boxes = sorted(boxes, key=lambda b: b[1])
    rows = []
    for b in boxes:
        for row in rows:
            ry0 = min(r[1] for r in row)
            ry1 = max(r[3] for r in row)
            overlap = min(ry1, b[3]) - max(ry0, b[1])
            if overlap > 0.5 * min(b[3] - b[1], ry1 - ry0):
                row.append(b)
                break
        else:
            rows.append([b])
    rows.sort(key=lambda r: min(b[1] for b in r))
    return [b for row in rows for b in sorted(row, key=lambda b: b[0])]


def gate(boxes, w, h):
    reasons = []
    page = w * h
    n = len(boxes)
    if n < 2:
        reasons.append(f"{n} panel(s): nothing to guide through")
    if n > 20:
        reasons.append(f"{n} panels: implausibly many")
    for i in range(n):
        for j in range(i + 1, n):
            a, b = boxes[i], boxes[j]
            ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
            iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            small = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
            if ix * iy > 0.15 * small:
                reasons.append(f"panels {i + 1} and {j + 1} overlap")
    mask = np.zeros((h, w), np.uint8)
    for x0, y0, x1, y1 in boxes:
        mask[y0:y1, x0:x1] = 1
    coverage = float(mask.mean())
    if coverage < 0.6:
        reasons.append(f"covers {coverage:.0%} of page (< 60%)")
    for i, (x0, y0, x1, y1) in enumerate(boxes):
        if (x1 - x0) * (y1 - y0) > 0.92 * page and n > 1:
            reasons.append(f"panel {i + 1} is the whole page")
    return not reasons, reasons, coverage


def detect(img_bgr):
    h0, w0 = img_bgr.shape[:2]
    scale = WORK_LONG_SIDE / max(h0, w0)
    img = cv2.resize(img_bgr, (round(w0 * scale), round(h0 * scale)), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    fg, paper = _foreground(gray)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(fg, connectivity=8)
    boxes = []
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if bw * bh >= MIN_PANEL_FRAC * w * h:
            comp = (labels == i).astype(np.uint8)
            boxes.extend(_split(gray, paper, comp, (x, y, x + bw, y + bh)))
    boxes = [b for b in boxes if (b[2] - b[0]) * (b[3] - b[1]) >= MIN_PANEL_FRAC * w * h]
    boxes = _drop_nested(boxes)
    boxes = _reading_order(boxes)
    passed, reasons, coverage = gate(boxes, w, h)
    norm = [[x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h] for x0, y0, x1, y1 in boxes]
    return Result(norm, passed, reasons, coverage)
