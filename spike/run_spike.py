#!/usr/bin/env python3
"""Run the M1 detection spike over a folder of pages and write overlays.

  python3 spike/run_spike.py PAGES_DIR OUT_DIR [--weights model.pt]

PAGES_DIR holds page images (jpg/png/webp). A page with a sibling
<name>.json carrying {"panels": [[x,y,w,h], ...]} in pixels is scored
against it: panel F1 at IoU 0.5, and whether the reading order matches.

For every page OUT_DIR gets <name>.cv.jpg (classic CV: green boxes when the
confidence gate passes, red when it fails, with the reason) and, with
--weights, <name>.yolo.jpg from the pretrained detector. It also writes
results.json, a summary table on stdout, and contact.jpg, a contact sheet of
all the overlays.
"""
import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np

import detect_cv

GREEN, RED, BLUE, MAGENTA, YELLOW = (60, 170, 40), (40, 40, 220), (200, 120, 20), (160, 40, 180), (0, 170, 230)
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}


def iou(a, b):
    ax0, ay0, aw, ah = a
    bx0, by0, bw, bh = b
    ix = max(0, min(ax0 + aw, bx0 + bw) - max(ax0, bx0))
    iy = max(0, min(ay0 + ah, by0 + bh) - max(ay0, by0))
    inter = ix * iy
    return inter / (aw * ah + bw * bh - inter + 1e-9)


def score(pred, gt):
    """Greedy one-to-one matching at IoU >= 0.5. Returns (tp, fp, fn, order_ok)."""
    used, pairs = set(), []
    for pi, p in enumerate(pred):
        best, bj = 0.5, None
        for gj, g in enumerate(gt):
            if gj not in used and iou(p, g) >= best:
                best, bj = iou(p, g), gj
        if bj is not None:
            used.add(bj)
            pairs.append((pi, bj))
    tp = len(pairs)
    order_ok = tp == len(gt) == len(pred) and all(pi == gj for pi, gj in pairs)
    return tp, len(pred) - tp, len(gt) - tp, order_ok


def draw_boxes(img, boxes, colour, label_prefix="", thickness=6):
    h, w = img.shape[:2]
    for i, (x, y, bw, bh) in enumerate(boxes):
        p0, p1 = (int(x * w), int(y * h)), (int((x + bw) * w), int((y + bh) * h))
        cv2.rectangle(img, p0, p1, colour, thickness)
        tag = f"{label_prefix}{i + 1}"
        (tw, th), _ = cv2.getTextSize(tag, cv2.FONT_HERSHEY_SIMPLEX, 1.6, 4)
        cv2.rectangle(img, (p0[0], p0[1]), (p0[0] + tw + 16, p0[1] + th + 16), colour, -1)
        cv2.putText(img, tag, (p0[0] + 8, p0[1] + th + 8), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 255), 4)


def banner(img, lines, colour):
    h, w = img.shape[:2]
    bar = np.full((60 * len(lines) + 20, w, 3), 255, np.uint8)
    for i, line in enumerate(lines):
        cv2.putText(bar, line, (20, 55 + 60 * i), cv2.FONT_HERSHEY_SIMPLEX, 1.5, colour, 3)
    return np.vstack([bar, img])


def load_yolo(weights):
    from ultralytics import YOLO
    return YOLO(weights)


def run_yolo(model, path):
    """Returns {class_name: [normalised boxes]} from the pretrained detector."""
    r = model.predict(str(path), imgsz=1024, device="cpu", verbose=False, conf=0.35)[0]
    out = {}
    names = r.names
    for (x0, y0, x1, y1), c in zip(r.boxes.xyxyn.tolist(), r.boxes.cls.tolist()):
        out.setdefault(names[int(c)], []).append([x0, y0, x1 - x0, y1 - y0])
    if "frame" in out:
        out["frame"] = [[b[0], b[1], b[2], b[3]] for b in _order_norm(out["frame"])]
    return out


def _order_norm(boxes):
    px = [(b[0], b[1], b[0] + b[2], b[1] + b[3]) for b in boxes]
    return [[x0, y0, x1 - x0, y1 - y0] for x0, y0, x1, y1 in detect_cv._reading_order(px)]


def contact_sheet(paths, out, cols=6, thumb_w=360):
    thumbs = []
    for p in paths:
        im = cv2.imread(str(p))
        s = thumb_w / im.shape[1]
        thumbs.append(cv2.resize(im, (thumb_w, int(im.shape[0] * s)), interpolation=cv2.INTER_AREA))
    th = max(t.shape[0] for t in thumbs)
    thumbs = [np.vstack([t, np.full((th - t.shape[0], thumb_w, 3), 255, np.uint8)]) for t in thumbs]
    while len(thumbs) % cols:
        thumbs.append(np.full((th, thumb_w, 3), 255, np.uint8))
    rows = [np.hstack(thumbs[i:i + cols]) for i in range(0, len(thumbs), cols)]
    cv2.imwrite(str(out), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 82])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pages")
    ap.add_argument("out")
    ap.add_argument("--weights")
    a = ap.parse_args()
    pages = sorted(p for p in Path(a.pages).rglob("*") if p.suffix.lower() in IMAGE_EXT)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    model = load_yolo(a.weights) if a.weights else None

    results, overlays = [], []
    totals = {"cv": [0, 0, 0, 0, 0], "yolo": [0, 0, 0, 0, 0]}  # tp fp fn order_ok scored
    for p in pages:
        img = cv2.imread(str(p))
        if img is None:
            continue
        name = p.relative_to(a.pages).with_suffix("").as_posix().replace("/", "__")
        gt_path = p.with_suffix(".json")
        gt = None
        if gt_path.exists():
            h, w = img.shape[:2]
            gt = [[x / w, y / h, bw / w, bh / h] for x, y, bw, bh in json.loads(gt_path.read_text())["panels"]]

        t = time.perf_counter()
        res = detect_cv.detect(img)
        cv_ms = (time.perf_counter() - t) * 1000
        row = {"page": name, "cv": {"panels": res.panels, "passed": res.passed, "reasons": res.reasons,
                                    "coverage": round(res.coverage, 3), "ms": round(cv_ms, 1)}}
        ov = img.copy()
        draw_boxes(ov, res.panels, GREEN if res.passed else RED)
        verdict = "GATE PASS -> guided" if res.passed else "GATE FAIL -> page mode"
        lines = [f"classic CV  {len(res.panels)} panels  {cv_ms:.0f} ms  {verdict}"]
        lines += [f"  {r}" for r in res.reasons[:2]]
        if gt is not None:
            s = score(res.panels, gt)
            row["cv"]["score"] = s
            for i in range(4):
                totals["cv"][i] += s[i]
            totals["cv"][4] += 1
            lines.append(f"  vs truth: {s[0]}/{len(gt)} matched, {s[1]} extra, order {'ok' if s[3] else 'WRONG'}")
        ov = banner(ov, lines, GREEN if res.passed else RED)
        cv2.imwrite(str(out / f"{name}.cv.jpg"), ov, [cv2.IMWRITE_JPEG_QUALITY, 80])
        overlays.append(out / f"{name}.cv.jpg")

        if model is not None:
            t = time.perf_counter()
            det = run_yolo(model, p)
            y_ms = (time.perf_counter() - t) * 1000
            frames = det.get("frame", [])
            h, w = img.shape[:2]
            passed, reasons, _ = detect_cv.gate(
                [(int(x * w), int(y * h), int((x + bw) * w), int((y + bh) * h)) for x, y, bw, bh in frames], w, h)
            row["yolo"] = {"detections": det, "passed": passed, "reasons": reasons, "ms": round(y_ms, 1)}
            ov = img.copy()
            draw_boxes(ov, frames, BLUE)
            draw_boxes(ov, det.get("balloon", []), MAGENTA, "b", 4)
            draw_boxes(ov, det.get("text", []), YELLOW, "t", 3)
            lines = [f"pretrained  {len(frames)} frames  {len(det.get('balloon', []))} balloons  {y_ms:.0f} ms  "
                     f"{'GATE PASS' if passed else 'GATE FAIL'}"]
            if gt is not None:
                s = score(frames, gt)
                row["yolo"]["score"] = s
                for i in range(4):
                    totals["yolo"][i] += s[i]
                totals["yolo"][4] += 1
                lines.append(f"  vs truth: {s[0]}/{len(gt)} matched, {s[1]} extra, order {'ok' if s[3] else 'WRONG'}")
            ov = banner(ov, lines, BLUE)
            cv2.imwrite(str(out / f"{name}.yolo.jpg"), ov, [cv2.IMWRITE_JPEG_QUALITY, 80])
            overlays.append(out / f"{name}.yolo.jpg")

        results.append(row)
        yolo_note = f"  yolo={len(row['yolo']['detections'].get('frame', []))}" if model else ""
        print(f"{name:40s} cv={len(res.panels):2d} {'PASS' if res.passed else 'fail'} {cv_ms:6.0f}ms"
              f"{yolo_note}  {'; '.join(res.reasons[:1])}")

    summary = {}
    for k, (tp, fp, fn, ok, n) in totals.items():
        if n:
            prec, rec = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
            summary[k] = {"pages_scored": n, "precision": round(prec, 3), "recall": round(rec, 3),
                          "f1": round(2 * prec * rec / max(prec + rec, 1e-9), 3), "order_ok": ok}
    passed = sum(r["cv"]["passed"] for r in results)
    summary["cv_gate_pass"] = f"{passed}/{len(results)}"
    (out / "results.json").write_text(json.dumps({"summary": summary, "pages": results}, indent=1))
    if overlays:
        contact_sheet(overlays, out / "contact.jpg")
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
