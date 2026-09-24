"""Frame outlines: the Python twin of packages/comic_analysis/lib/src/outline.dart.

The detector draws boxes; a slanted panel's box holds corners of its
neighbours. This finds each frame's real outline from the page: flood the
gutter from the paper around the boxes, give each connected piece of art to
the box holding most of it, take the convex hull of what a box owns, and let
only straight, well-backed hull edges cut the box. See the Dart file for the
reasoning behind each rule; the constants match it.

Measure on the labelled sets (pages from spike/extract_pages.py, labels in
spike/labels/<set>), with review crops of every reshaped frame:

    python3 spike/outlines.py eval PAGES_ROOT --sets modern eval train --crops out/outlines

Dump pages for the Dart port (packages/comic_analysis/tool/outlines.dart):

    python3 spike/outlines.py dump PAGES_ROOT --sets modern eval train --out /tmp/dump
"""
import argparse
import glob
import json
import os

import cv2
import numpy as np

LONG = 800          # the model's input size; thresholds are in these pixels
TOL = 30            # max channel difference from the paper colour
ERODE = 5           # snaps ink bridges this thin across a gutter
INSET = 3           # px inside/outside an edge where it is sampled
BAND = 16           # depth of solid art required inside a cut edge
SUPPORT = 0.85      # share of the edge the art must reach
GUTTER = 0.6        # share of the edge with gutter just outside
BEYOND = 0.3        # max share of walks that meet the panel's own art
MINLEN = 0.3        # cut edges at least this share of the box's short side
MINANGLE = 2.0      # degrees off the axes; less is a loose box, not a slant
MINCUT = 0.015      # a cut removes at least this share of the box
SOLID = 0.75        # art must fill this share of the outline


def aligned(a, b, w, h, tol=0.02):
    tx, ty = tol * w + 1, tol * h + 1
    return (abs(a[0]) < tx and abs(b[0]) < tx) or (abs(a[0] - w) < tx and abs(b[0] - w) < tx) or \
        (abs(a[1]) < ty and abs(b[1]) < ty) or (abs(a[1] - h) < ty and abs(b[1] - h) < ty)


def support(mask, poly, k, inset=INSET):
    """Share of points along edge k, inset px inside the polygon (outside
    when negative), where mask is set."""
    c = poly.mean(axis=0)
    h, w = mask.shape
    a, b = poly[k], poly[(k + 1) % len(poly)]
    n = max(8, int(np.linalg.norm(b - a) / 3))
    p = a + np.linspace(0.1, 0.9, n)[:, None] * (b - a)
    nrm = np.array([-(b - a)[1], (b - a)[0]]) / np.linalg.norm(b - a)
    if np.dot(c - a, nrm) < 0:
        nrm = -nrm
    p = p + inset * nrm
    ok = (p[:, 0] >= 0) & (p[:, 0] <= w - 1) & (p[:, 1] >= 0) & (p[:, 1] <= h - 1)
    if not ok.any():
        return 0.0
    p = p[ok]
    return float(mask[p[:, 1].round().astype(int), p[:, 0].round().astype(int)].mean())


def past(sub, owner, i, poly, k):
    """Share of walks outward from edge k, across the gutter, that end in
    this panel's own art (or art nobody owns): a leak, not a frame edge."""
    h, w = sub.shape
    c = poly.mean(axis=0)
    a, b = poly[k], poly[(k + 1) % len(poly)]
    nrm = np.array([-(b - a)[1], (b - a)[0]]) / np.linalg.norm(b - a)
    if np.dot(c - a, nrm) > 0:
        nrm = -nrm
    bad = 0
    for t in np.linspace(0.1, 0.9, 15):
        p = a + t * (b - a)
        for d in range(2, 2 * max(h, w)):
            x, y = int(round(p[0] + d * nrm[0])), int(round(p[1] + d * nrm[1]))
            if not (0 <= x < w and 0 <= y < h):
                break
            lab = sub[y, x]
            if lab > 0:
                bad += owner[lab] in (i, -1)
                break
    return bad / 15


def clip(poly, a, b, c):
    """Clip convex poly to the side of line a-b that holds point c."""
    nrm = np.array([-(b - a)[1], (b - a)[0]])
    if np.dot(c - a, nrm) < 0:
        nrm = -nrm
    d = (poly - a) @ nrm
    out = []
    for i in range(len(poly)):
        p, q, dp, dq = poly[i], poly[(i + 1) % len(poly)], d[i], d[(i + 1) % len(poly)]
        if dp >= 0:
            out.append(p)
        if (dp >= 0) != (dq >= 0):
            out.append(p + (q - p) * dp / (dp - dq))
    return np.array(out)


def polyarea(p):
    x, y = p[:, 0], p[:, 1]
    return 0.5 * abs(np.dot(x, np.roll(y, 1)) - np.dot(y, np.roll(x, 1)))


def outlines(img, boxes, balloons=()):
    """img BGR at any size; boxes and balloons in its pixels as x0, y0, x1, y1.
    Returns one polygon (N x 2, same pixels) per box, or None where the
    box is already the outline."""
    H, W = img.shape[:2]
    s = LONG / max(H, W)
    sm = cv2.resize(img, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    h, w = sm.shape[:2]
    B = [[v * s for v in b] for b in boxes]
    out = np.ones((h, w), bool)
    for x0, y0, x1, y1 in B:
        out[max(0, int(y0)):int(np.ceil(y1)), max(0, int(x0)):int(np.ceil(x1))] = False
    band = np.zeros((h, w), bool)
    k = max(2, h // 60)
    band[:k] = band[-k:] = True
    band[:, :k] = band[:, -k:] = True
    seedsrc = out if out.sum() > 0.005 * h * w else band
    paper = np.median(sm[seedsrc].reshape(-1, 3), axis=0)
    dist = np.abs(sm.astype(int) - paper).max(axis=2)
    pmask = (dist < TOL).astype(np.uint8)
    _, lab = cv2.connectedComponents(pmask, connectivity=4)
    seeds = np.unique(lab[(seedsrc | band) & (pmask > 0)])
    gutter = np.isin(lab, seeds[seeds > 0])
    # Balloons often straddle a gutter and would join two panels into one
    # piece, so they are cut out; they go back in per panel below.
    ink = np.ascontiguousarray(~gutter, np.uint8)
    for bx0, by0, bx1, by1 in balloons:
        ink[max(0, int(by0 * s)):int(np.ceil(by1 * s)), max(0, int(bx0 * s)):int(np.ceil(bx1 * s))] = 0
    ink = cv2.erode(ink, np.ones((ERODE, ERODE), np.uint8))
    nc, comp, cst, _ = cv2.connectedComponentsWithStats(ink, connectivity=4)
    owner = np.full(nc, -1)
    best = np.zeros(nc)
    for i, (x0, y0, x1, y1) in enumerate(B):
        xi0, yi0 = max(0, int(x0)), max(0, int(y0))
        xi1, yi1 = min(w, int(np.ceil(x1))), min(h, int(np.ceil(y1)))
        cnt = np.bincount(comp[yi0:yi1, xi0:xi1].ravel(), minlength=nc)
        frac = cnt / np.maximum(cst[:, cv2.CC_STAT_AREA], 1)
        take = frac > best
        owner[take] = i
        best[take] = frac[take]
    res = []
    for i, (x0, y0, x1, y1) in enumerate(B):
        xi0, yi0 = max(0, int(x0)), max(0, int(y0))
        xi1, yi1 = min(w, int(np.ceil(x1))), min(h, int(np.ceil(y1)))
        if xi1 - xi0 < 8 or yi1 - yi0 < 8:
            res.append(None)
            continue
        sub = comp[yi0:yi1, xi0:xi1]
        mine = (owner == i)
        mine[0] = False
        cnt = np.bincount(sub.ravel(), minlength=nc)
        mine &= cnt > 0.002 * sub.size
        mask = cv2.dilate(np.ascontiguousarray(mine[sub], np.uint8), np.ones((ERODE, ERODE), np.uint8))
        if mask.sum() == 0:
            res.append(None)
            continue
        for bx0, by0, bx1, by1 in balloons:
            bx0, by0, bx1, by1 = [v * s for v in (bx0, by0, bx1, by1)]
            if x0 <= (bx0 + bx1) / 2 <= x1 and y0 <= (by0 + by1) / 2 <= y1:
                cv2.rectangle(mask, (int(bx0) - xi0, int(by0) - yi0), (int(np.ceil(bx1)) - xi0, int(np.ceil(by1)) - yi0), 1, -1)
        cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        pts = np.vstack([c.reshape(-1, 2) for c in cs]).astype(np.float32)
        hull = cv2.convexHull(np.ascontiguousarray(pts).reshape(-1, 1, 2))
        poly = cv2.approxPolyDP(hull, 0.01 * cv2.arcLength(hull, True), True).reshape(-1, 2).astype(np.float64)
        bw, bh = xi1 - xi0, yi1 - yi0
        gsub = gutter[yi0:yi1, xi0:xi1]
        shape = np.float64([[0, 0], [bw, 0], [bw, bh], [0, bh]])
        cuts = 0
        for k in range(len(poly)):
            a, b = poly[k], poly[(k + 1) % len(poly)]
            if aligned(a, b, bw, bh) or np.linalg.norm(b - a) < MINLEN * min(bw, bh):
                continue
            ang = np.degrees(np.arctan2(abs(b[1] - a[1]), abs(b[0] - a[0])))
            if min(ang, 90 - ang) < MINANGLE:
                continue
            inside = min(support(mask, poly, k), np.mean([support(mask, poly, k, d) for d in range(2, BAND, 2)]))
            if inside < SUPPORT or support(gsub, poly, k, -INSET) < GUTTER or past(sub, owner, i, poly, k) > BEYOND:
                continue
            cut = clip(shape, a, b, poly.mean(axis=0))
            if polyarea(shape) - polyarea(cut) > MINCUT * bw * bh:
                shape = cut
                cuts += 1
        if not cuts or polyarea(shape) < 0.5 * bw * bh:
            res.append(None)
            continue
        inpoly = np.zeros_like(mask)
        cv2.fillPoly(inpoly, [shape.astype(np.int32)], 1)
        if mask[inpoly > 0].mean() < SOLID:  # borderless art on paper
            res.append(None)
            continue
        res.append((shape + [xi0, yi0]) / s)
    return res


def labelled(pages_root, sets):
    """(set, name, jpg, boxes, balloons) for every labelled page with frames;
    labels are x, y, w, h in page pixels."""
    here = os.path.dirname(os.path.abspath(__file__))
    for st in sets:
        for f in sorted(glob.glob(f'{here}/labels/{st}/**/*.json', recursive=True)):
            d = json.load(open(f))
            if not d['panels']:
                continue
            rel = os.path.relpath(f, f'{here}/labels/{st}')[:-5]
            xyxy = lambda b: [b[0], b[1], b[0] + b[2], b[1] + b[3]]
            yield st, rel, f'{pages_root}/{st}/{rel}.jpg', [xyxy(b) for b in d['panels']], [xyxy(b) for b in d['balloons']]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['eval', 'dump'])
    ap.add_argument('pages_root', help='folder holding <set>/<style>/<page>.jpg')
    ap.add_argument('--sets', nargs='+', default=['modern', 'eval', 'train'])
    ap.add_argument('--crops', help='eval: write a review crop of every reshaped frame here')
    ap.add_argument('--out', help='dump: folder for <page>.rgba, <page>.json and python.json')
    a = ap.parse_args()
    if a.cmd == 'dump':
        os.makedirs(a.out, exist_ok=True)
        py = {}
    per = {}
    for st, rel, jpg, P, Bl in labelled(a.pages_root, a.sets):
        img = cv2.imread(jpg)
        got = outlines(img, P, Bl)
        n = per.setdefault(st, [0, 0, 0])
        n[0] += 1
        n[1] += len(P)
        n[2] += sum(p is not None for p in got)
        H, W = img.shape[:2]
        if a.cmd == 'dump':
            s = LONG / max(H, W)
            sm = cv2.resize(img, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
            name = st + '__' + rel.replace('/', '__')
            cv2.cvtColor(sm, cv2.COLOR_BGR2RGBA).tofile(f'{a.out}/{name}.rgba')
            norm = lambda b: [b[0] / W, b[1] / H, (b[2] - b[0]) / W, (b[3] - b[1]) / H]
            json.dump({'w': sm.shape[1], 'h': sm.shape[0], 'frames': [norm(b) for b in P],
                       'balloons': [norm(b) for b in Bl]}, open(f'{a.out}/{name}.json', 'w'))
            py[name] = [None if p is None else (p / [W, H]).ravel().tolist() for p in got]
        elif a.crops:
            os.makedirs(a.crops, exist_ok=True)
            for i, p in enumerate(got):
                if p is None:
                    continue
                x0, y0, x1, y1 = map(int, P[i])
                m = int(0.05 * max(x1 - x0, y1 - y0))
                v = img.copy()
                dim = np.zeros((H, W), np.uint8)
                cv2.rectangle(dim, (x0, y0), (x1, y1), 1, -1)
                cv2.fillPoly(dim, [p.astype(np.int32)], 0)
                v[dim > 0] = (v[dim > 0] * 0.35 + np.array([0, 0, 160]) * 0.65).astype(np.uint8)
                cv2.rectangle(v, (x0, y0), (x1, y1), (255, 120, 0), 2)
                cv2.polylines(v, [p.astype(np.int32)], True, (0, 0, 255), 2)
                c = v[max(0, y0 - m):y1 + m, max(0, x0 - m):x1 + m]
                cv2.imwrite(f'{a.crops}/{st}__{os.path.basename(rel)}__{i + 1}.jpg', c)
    if a.cmd == 'dump':
        json.dump(py, open(f'{a.out}/python.json', 'w'))
    for st, (pages, frames, shaped) in per.items():
        print(f'{st}: {pages} pages, {frames} frames, {shaped} reshaped')


if __name__ == '__main__':
    main()
