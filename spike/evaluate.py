#!/usr/bin/env python3
"""Score panel and balloon detectors against the labelled eval set (M5).

  python3 spike/evaluate.py PAGES_DIR --out spike/out/eval \
      [--pretrained test/corpus/models/best.pt] [--trained model.onnx|model.pt] [--overlays]

PAGES_DIR holds page images in one folder per style, each with its label
(<page>.json, from spike/labelkit.py). Up to three detectors run on every
page:

  cv          classic CV, the detector the app ships since M4
  pretrained  the Manga109 checkpoint, as downloaded
  trained     the western fine-tune (an .onnx file is run exactly the way
              the app runs it: same letterbox, same thresholds)

Panels and balloons are scored as F1 at IoU 0.5. Guided view is scored per
page, because a wrong camera move is worse than none (design plan section 5):

  right   the gate passed and the panels match the labels one for one, in
          reading order; or the page has no story layout and is shown whole
  whole   a story page shown whole because the gate failed (a lost chance,
          not a mistake)
  wrong   the gate passed with panels that don't match, or a non-story page
          (cover, text, ad) got a camera

Writes results.json and report.md into --out, and with --overlays one
<page>.<detector>.jpg per page.
"""
import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np

import detect_cv

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}
PANEL_CONF = 0.5
# Wider than this (width over height) and a page is a two-page spread.
SPREAD_ASPECT = 1.2
BALLOON_CONF = 0.4


# ---------------------------------------------------------------- geometry

def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    return inter / (aw * ah + bw * bh - inter + 1e-12)


def match(pred, gt, thr=0.5):
    """Greedy one-to-one matching by IoU. Returns [(pred_i, gt_j)]."""
    pairs = sorted(((iou(p, g), i, j) for i, p in enumerate(pred) for j, g in enumerate(gt)), reverse=True)
    used_p, used_g, out = set(), set(), []
    for v, i, j in pairs:
        if v < thr:
            break
        if i not in used_p and j not in used_g:
            used_p.add(i)
            used_g.add(j)
            out.append((i, j))
    return out


def reading_order(boxes, tol=0.01, aspect=1.0):
    """Western reading order by recursive XY-cut over normalised [x, y, w, h].

    [aspect] is the page's width over its height. A landscape page is a
    two-page spread: when no box crosses the spine, the left page reads
    before the right one.

    Cut the set by a horizontal gutter no box crosses (rows, top to bottom);
    failing that, peel off the leftmost column by a vertical one; recurse. A
    tall panel beside a grid reads first, then the grid row by row. When nothing
    can be cut, fall back to rows by vertical overlap, the M4 rule. [tol] lets
    boxes overlap a cut by that share of the page. Mirrors readingOrder() in
    packages/comic_analysis.
    """
    def cut(items, axis):
        lo, hi = (1, 3) if axis == "y" else (0, 2)
        s = sorted(items, key=lambda b: b[lo])
        groups, cur, end = [], [s[0]], s[0][lo] + s[0][hi]
        for b in s[1:]:
            if b[lo] >= end - tol:
                groups.append(cur)
                cur = [b]
            else:
                cur.append(b)
            end = max(end, b[lo] + b[hi])
        groups.append(cur)
        return groups

    def rec(items):
        if len(items) <= 1:
            return list(items)
        groups = cut(items, "y")
        if len(groups) > 1:
            return [b for g in groups for b in rec(g)]
        # Peel off only the leftmost column: what is to its right may still
        # read in rows (a tall panel beside a 2x2 grid reads first, then the
        # grid row by row).
        groups = cut(items, "x")
        if len(groups) > 1:
            return rec(groups[0]) + rec([b for g in groups[1:] for b in g])
        return rows(items)

    def rows(items):
        out = []
        for b in sorted(items, key=lambda b: b[1]):
            for row in out:
                top, bottom = min(r[1] for r in row), max(r[1] + r[3] for r in row)
                overlap = min(bottom, b[1] + b[3]) - max(top, b[1])
                if overlap > 0.5 * min(b[3], bottom - top):
                    row.append(b)
                    break
            else:
                out.append([b])
        out.sort(key=lambda r: min(b[1] for b in r))
        return [b for row in out for b in sorted(row, key=lambda b: b[0])]

    boxes = [list(b) for b in boxes]
    if aspect > SPREAD_ASPECT and boxes:
        left = [b for b in boxes if b[0] + b[2] <= 0.5 + tol]
        right = [b for b in boxes if b[0] >= 0.5 - tol]
        if left and right and len(left) + len(right) == len(boxes):
            return rec(left) + rec(right)
    return rec(boxes)


def gate(panels):
    """The app's confidence gate (packages/comic_analysis/lib/src/gate.dart)."""
    reasons, n = [], len(panels)
    if n < 2:
        reasons.append(f"{n} panel(s)")
    if n > 20:
        reasons.append(f"{n} panels")
    for i in range(n):
        for j in range(i + 1, n):
            a, b = panels[i], panels[j]
            ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
            iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
            if ix * iy > 0.15 * min(a[2] * a[3], b[2] * b[3]):
                reasons.append(f"panels {i + 1} and {j + 1} overlap")
        if n > 1 and panels[i][2] * panels[i][3] > 0.92:
            reasons.append(f"panel {i + 1} is the whole page")
    if sum(1 for p in panels if p[2] * p[3] < 0.02) > 4:
        reasons.append("scraps")
    g = 200
    ys, xs = np.mgrid[0:g, 0:g]
    xs, ys = (xs + 0.5) / g, (ys + 0.5) / g
    cover = np.zeros((g, g), bool)
    for x, y, w, h in panels:
        cover |= (xs >= x) & (xs < x + w) & (ys >= y) & (ys < y + h)
    if cover.mean() < 0.6:
        reasons.append(f"covers {cover.mean():.0%}")
    return not reasons, reasons


# ---------------------------------------------------------------- detectors

class ClassicCv:
    name = "cv"

    def __call__(self, img):
        return detect_cv.detect(img).panels, []


class Ultralytics:
    """A .pt checkpoint through Ultralytics, classes by name."""

    def __init__(self, weights, name):
        from ultralytics import YOLO
        self.model, self.name = YOLO(weights), name

    def __call__(self, img):
        r = self.model.predict(img, imgsz=1024, device="cpu", verbose=False, conf=min(PANEL_CONF, BALLOON_CONF))[0]
        h, w = img.shape[:2]
        panels, balloons = [], []
        for (x0, y0, x1, y1), c, conf in zip(r.boxes.xyxy.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist()):
            box = [x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h]
            kind = r.names[int(c)]
            if kind == "frame" and conf >= PANEL_CONF:
                panels.append(box)
            elif kind == "balloon" and conf >= BALLOON_CONF:
                balloons.append(box)
        return panels, balloons


class Onnx:
    """The exported model, run the way lib/src/reader/model_detector.dart runs it.

    Letterbox: scale the long side to the input size, keep the aspect, pad
    right and bottom with grey 114. Input float32 NCHW RGB in 0..1. Output
    [1, N, 6]: x0, y0, x1, y1 in input pixels, score, class.
    """

    def __init__(self, path, name="trained"):
        import onnxruntime as ort
        self.sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        inp = self.sess.get_inputs()[0]
        self.input, self.size = inp.name, inp.shape[2]
        meta = self.sess.get_modelmeta().custom_metadata_map
        self.names = eval(meta.get("names", "{0: 'frame', 1: 'text', 2: 'balloon'}"))
        self.name = name

    def __call__(self, img):
        h, w = img.shape[:2]
        s = self.size / max(h, w)
        nw, nh = round(w * s), round(h * s)
        canvas = np.full((self.size, self.size, 3), 114, np.uint8)
        canvas[:nh, :nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
        x = canvas[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255
        out = self.sess.run(None, {self.input: x})[0][0]
        found = {"frame": ([], []), "balloon": ([], [])}
        for x0, y0, x1, y1, conf, c in out:
            kind = self.names.get(int(c))
            if kind in found and conf >= (PANEL_CONF if kind == "frame" else BALLOON_CONF):
                found[kind][0].append([float(v) for v in (x0 / s / w, y0 / s / h, (x1 - x0) / s / w, (y1 - y0) / s / h)])
                found[kind][1].append(float(conf))
        return drop_containers(dedupe(*found["frame"])), dedupe(*found["balloon"])


def dedupe(boxes, scores, thr=0.7):
    """Fold near-duplicates into the higher-scoring box, as decodeDetections() does."""
    kept = []
    for i in sorted(range(len(boxes)), key=lambda i: -scores[i]):
        if all(iou(boxes[i], boxes[k]) <= thr for k in kept):
            kept.append(i)
    return [boxes[i] for i in kept]


def drop_containers(boxes, inside=0.85, cover=0.6):
    """Drop a frame that wraps two or more smaller ones, as dropContainers() does.

    Mirrors packages/comic_analysis: each smaller frame at least [inside]
    within it, together filling at least [cover] of it (a 50 x 50 grid).
    """
    def inter(a, b):
        ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
        iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
        return ix * iy

    out = []
    for i, a in enumerate(boxes):
        kids = [b for j, b in enumerate(boxes)
                if j != i and b[2] * b[3] < a[2] * a[3] and inter(a, b) >= inside * b[2] * b[3]]
        if len(kids) >= 2:
            g = 50
            gx = a[0] + (np.arange(g) + 0.5) / g * a[2]
            gy = a[1] + (np.arange(g) + 0.5) / g * a[3]
            xs, ys = np.meshgrid(gx, gy)
            hit = np.zeros((g, g), bool)
            for x, y, w, h in kids:
                hit |= (xs >= x) & (xs < x + w) & (ys >= y) & (ys < y + h)
            if hit.sum() >= cover * g * g:
                continue
        out.append(a)
    return out


def load_trained(path):
    return Onnx(path) if str(path).endswith(".onnx") else Ultralytics(path, "trained")


# ---------------------------------------------------------------- scoring

def clip(boxes):
    out = []
    for x, y, w, h in boxes:
        x0, y0 = max(0.0, x), max(0.0, y)
        x1, y1 = min(1.0, x + w), min(1.0, y + h)
        if x1 > x0 and y1 > y0:
            out.append([x0, y0, x1 - x0, y1 - y0])
    return out


def score_page(panels, balloons, gt_panels, gt_balloons, aspect=1.0):
    panels = reading_order(clip(panels), aspect=aspect)
    pm = match(panels, gt_panels)
    bm = match(clip(balloons), gt_balloons)
    passed, reasons = gate(panels)
    story = len(gt_panels) >= 2
    exact = len(pm) == len(panels) == len(gt_panels) and all(i == j for i, j in pm)
    if not story:
        outcome = "wrong" if passed else "right"
    elif passed:
        outcome = "right" if exact else "wrong"
    else:
        outcome = "whole"
    return {
        "panels": panels, "balloons": balloons, "gate": passed, "reasons": reasons, "outcome": outcome,
        "p_tp": len(pm), "p_fp": len(panels) - len(pm), "p_fn": len(gt_panels) - len(pm),
        "b_tp": len(bm), "b_fp": len(balloons) - len(bm), "b_fn": len(gt_balloons) - len(bm),
    }


def f1(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else 1.0
    r = tp / (tp + fn) if tp + fn else 1.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def summarise(rows):
    s = {k: sum(r[k] for r in rows) for k in ("p_tp", "p_fp", "p_fn", "b_tp", "b_fp", "b_fn")}
    out = {"pages": len(rows)}
    out["panel_p"], out["panel_r"], out["panel_f1"] = f1(s["p_tp"], s["p_fp"], s["p_fn"])
    out["balloon_p"], out["balloon_r"], out["balloon_f1"] = f1(s["b_tp"], s["b_fp"], s["b_fn"])
    for o in ("right", "whole", "wrong"):
        out[o] = sum(r["outcome"] == o for r in rows)
    out["ms"] = sum(r["ms"] for r in rows) / max(1, len(rows))
    return out


# ---------------------------------------------------------------- output

def overlay(img, gt, res, dest):
    img = img.copy()
    h, w = img.shape[:2]
    t = max(2, round(w / 400))

    def draw(boxes, colour, thick, label):
        for i, (x, y, bw, bh) in enumerate(boxes):
            p0, p1 = (int(x * w), int(y * h)), (int((x + bw) * w), int((y + bh) * h))
            cv2.rectangle(img, p0, p1, colour, thick)
            if label:
                cv2.putText(img, str(i + 1), (p0[0] + 6, p0[1] + 12 * t), cv2.FONT_HERSHEY_SIMPLEX, t / 2, colour, t)

    draw(gt["panels"], (160, 160, 160), t, False)
    draw(res["panels"], (60, 170, 40) if res["gate"] else (40, 40, 220), t * 2, True)
    draw(res["balloons"], (160, 40, 180), t, True)
    cv2.putText(img, res["outcome"] + (" " + "; ".join(res["reasons"]) if res["reasons"] else ""),
                (10, 20 * t), cv2.FONT_HERSHEY_SIMPLEX, t / 2, (0, 0, 200), t)
    s = 900 / max(h, w)
    cv2.imwrite(str(dest), cv2.resize(img, None, fx=s, fy=s), [cv2.IMWRITE_JPEG_QUALITY, 80])


def report(summary, out):
    lines = ["# M5 detector evaluation", ""]
    dets = list(summary["all"].keys())
    lines += ["| Detector | Pages | Panel F1 | Balloon F1 | Guided right | Whole page | Wrong camera | ms/page |",
              "|---|---|---|---|---|---|---|---|"]
    for d in dets:
        s = summary["all"][d]
        lines.append(f"| {d} | {s['pages']} | {s['panel_f1']:.3f} | {s['balloon_f1']:.3f} | {s['right']} | "
                     f"{s['whole']} | {s['wrong']} | {s['ms']:.0f} |")
    lines += ["", "## Per style", "", "| Style | Detector | Pages | Panel F1 | Balloon F1 | Right | Whole | Wrong |",
              "|---|---|---|---|---|---|---|---|"]
    for style, per in summary["styles"].items():
        for d, s in per.items():
            lines.append(f"| {style} | {d} | {s['pages']} | {s['panel_f1']:.3f} | {s['balloon_f1']:.3f} | "
                         f"{s['right']} | {s['whole']} | {s['wrong']} |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    global PANEL_CONF, BALLOON_CONF
    ap = argparse.ArgumentParser()
    ap.add_argument("pages")
    ap.add_argument("--out", default="spike/out/eval")
    ap.add_argument("--pretrained")
    ap.add_argument("--trained")
    ap.add_argument("--no-cv", action="store_true")
    ap.add_argument("--overlays", action="store_true")
    ap.add_argument("--panel-conf", type=float, default=PANEL_CONF)
    ap.add_argument("--balloon-conf", type=float, default=BALLOON_CONF)
    a = ap.parse_args()
    PANEL_CONF, BALLOON_CONF = a.panel_conf, a.balloon_conf
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    dets = [] if a.no_cv else [ClassicCv()]
    if a.pretrained:
        dets.append(Ultralytics(a.pretrained, "pretrained"))
    if a.trained:
        dets.append(load_trained(a.trained))

    pages = sorted(p for p in Path(a.pages).rglob("*") if p.suffix.lower() in IMAGE_EXT
                   and p.with_suffix(".json").exists()
                   and not any(t in p.name for t in (".cv.", ".yolo.", ".show.", ".check.")))
    results = []
    for page in pages:
        lab = json.loads(page.with_suffix(".json").read_text())
        W, H = lab["w"], lab["h"]
        gt = {k: [[x / W, y / H, w / W, h / H] for x, y, w, h in lab[k]] for k in ("panels", "balloons")}
        img = cv2.imread(str(page))
        row = {"page": str(page.relative_to(a.pages)), "style": page.parent.name,
               "gt_panels": len(gt["panels"]), "gt_balloons": len(gt["balloons"]), "det": {}}
        for d in dets:
            t0 = time.perf_counter()
            panels, balloons = d(img)
            ms = (time.perf_counter() - t0) * 1000
            res = score_page(panels, balloons, gt["panels"], gt["balloons"], W / H)
            res["ms"] = ms
            row["det"][d.name] = res
            if a.overlays:
                (out / "overlays").mkdir(exist_ok=True)
                overlay(img, gt, res, out / "overlays" / f"{page.parent.name}__{page.stem}.{d.name}.jpg")
        results.append(row)
        print(page.name, " ".join(f"{k}:{v['outcome']}" for k, v in row["det"].items()), flush=True)

    summary = {"all": {}, "styles": {}}
    for d in dets:
        summary["all"][d.name] = summarise([r["det"][d.name] for r in results])
    for style in sorted({r["style"] for r in results}):
        summary["styles"][style] = {d.name: summarise([r["det"][d.name] for r in results if r["style"] == style])
                                    for d in dets}
    (out / "results.json").write_text(json.dumps({"summary": summary, "pages": results}, indent=1))
    report(summary, out)


if __name__ == "__main__":
    main()
