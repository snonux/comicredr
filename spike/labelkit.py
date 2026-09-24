#!/usr/bin/env python3
"""Label panels and balloons on page images, for the M5 eval and training sets.

  python3 spike/labelkit.py candidates PAGES_DIR [--weights best.pt]
  python3 spike/labelkit.py show PAGE [--out img.jpg]
  python3 spike/labelkit.py set PAGE --panels SPEC --balloons SPEC [--captions SPEC]
  python3 spike/labelkit.py check PAGE [--out img.jpg]
  python3 spike/labelkit.py sheet PAGES_DIR OUT.jpg

`candidates` runs classic CV and the pretrained detector over every page and
writes <page>.cand.json beside it. `show` draws them, numbered, over the page
with a percentage grid: C1.. are classic-CV panels, F1.. model frames, B1..
model balloons, T1.. model text boxes.

`set` writes the label, <page>.json, which run_spike.py and evaluate.py read.
A SPEC is a comma-separated list, in reading order, of:

  C3            a candidate as it is
  F1+F2         the union of candidates (merges an over-split panel)
  10 5 48 30    a box typed as x0 y0 x1 y1 in percent of the page

Typed boxes are snapped: a panel edge moves to the nearest gutter within
1.5% of the page, a balloon to the light region it sits on. Put `!` in front
of a typed box to keep it exactly as typed. An empty SPEC means none.

What counts, so every labeller draws the same thing:
  panel    one frame of story art, border included. A splash is one panel.
           Borderless art gets the box of the art. Covers, text pages and
           ads without comic panels get no panels at all.
  balloon  speech, thought and whisper balloons, tail excluded, and speech
           with no outline (the box of its text). Not captions, sound
           effects, signs or title lettering.
  caption  boxed narration ("Meanwhile...", a narrator's voice), usually a
           rectangle on or near a panel edge. Kept apart from balloons so
           balloon mode stops only on what characters say or think.

`check` draws the saved label so it can be verified. `sheet` makes a contact
sheet of every labelled page in a folder.

  python3 spike/labelkit.py crops OUT_DIR PAGES_DIR... [--guess]
  python3 spike/labelkit.py flip OUT_DIR/map.json 12,40,41 [--drop 7,9]
  python3 spike/labelkit.py review OUT_DIR/map.json REVIEW.txt...

`crops` cuts every balloon and caption out of the labels into numbered
contact sheets, so a reviewer can sort speech from narration quickly
(purple S = balloon, orange N = caption). `--guess` first moves boxes that
look like rectangles filled edge to edge into captions. `flip` moves the
given crop numbers to the other kind and `--drop` deletes boxes that are
neither (sound effects, signs). `review` applies reviewers' files, one line
per sheet: `sheet_007 flip=12,40 drop=55`.

  python3 spike/labelkit.py export PAGES_DIR spike/labels/eval
  python3 spike/labelkit.py import spike/labels/eval PAGES_DIR

`export` copies every label into a committed folder, one sub-folder per
style; `import` puts them back beside freshly extracted pages, so a new
clone can train and evaluate without labelling again.
"""
import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import detect_cv  # noqa: E402

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}
COLOURS = {"C": (60, 170, 40), "F": (200, 120, 20), "B": (160, 40, 180), "T": (0, 150, 230),
           "P": (40, 40, 220), "L": (160, 40, 180), "N": (0, 140, 255)}
SNAP = 0.015


def pages_in(folder):
    return sorted(p for p in Path(folder).rglob("*") if p.suffix.lower() in IMAGE_EXT
                  and not any(t in p.name for t in (".cv.", ".yolo.", ".show.", ".check.")))


def cand_path(page):
    return page.with_suffix(".cand.json")


def label_path(page):
    return page.with_suffix(".json")


# ---------------------------------------------------------------- candidates

def candidates(folder, weights):
    from ultralytics import YOLO
    model = YOLO(weights) if weights else None
    for p in pages_in(folder):
        img = cv2.imread(str(p))
        h, w = img.shape[:2]
        out = {"w": w, "h": h, "C": detect_cv.detect(img).panels, "F": [], "B": [], "T": []}
        if model:
            r = model.predict(str(p), imgsz=1024, device="cpu", verbose=False, conf=0.25)[0]
            key = {"frame": "F", "balloon": "B", "text": "T"}
            rows = sorted(zip(r.boxes.xyxy.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist()),
                          key=lambda t: (t[0][1], t[0][0]))
            for (x0, y0, x1, y1), c, conf in rows:
                k = key.get(r.names[int(c)])
                if k:
                    out[k].append([x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h])
        cand_path(p).write_text(json.dumps(out))
        print(f"{p.name}: C{len(out['C'])} F{len(out['F'])} B{len(out['B'])} T{len(out['T'])}")


# ---------------------------------------------------------------- drawing

def _grid(img):
    h, w = img.shape[:2]
    for i in range(1, 20):
        major = i % 2 == 0
        col = (0, 0, 255) if major else (120, 120, 255)
        x, y = round(w * i / 20), round(h * i / 20)
        cv2.line(img, (x, 0), (x, h), col, 1 if not major else 2)
        cv2.line(img, (0, y), (w, y), col, 1 if not major else 2)
        if major:
            for pos in ((x + 3, 22), (x + 3, h - 6)):
                cv2.putText(img, str(i * 5), pos, cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 200), 2)
            for pos in ((3, y - 4), (w - 34, y - 4)):
                cv2.putText(img, str(i * 5), pos, cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 200), 2)


def _boxes(img, boxes, prefix, colour, thick=3):
    h, w = img.shape[:2]
    for i, (x, y, bw, bh) in enumerate(boxes):
        p0, p1 = (int(x * w), int(y * h)), (int((x + bw) * w), int((y + bh) * h))
        cv2.rectangle(img, p0, p1, colour, thick)
        tag = f"{prefix}{i + 1}"
        (tw, th), _ = cv2.getTextSize(tag, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
        o = (p0[0] + 2, p0[1] + 2) if prefix not in ("B", "L", "N") else (p1[0] - tw - 8, p1[1] - th - 8)
        cv2.rectangle(img, o, (o[0] + tw + 6, o[1] + th + 6), colour, -1)
        cv2.putText(img, tag, (o[0] + 3, o[1] + th + 3), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)


def _canvas(page, long_side=1300):
    img = cv2.imread(str(page))
    s = long_side / max(img.shape[:2])
    return cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)


def show(page, out):
    c = json.loads(cand_path(page).read_text())
    panels, balloons = _canvas(page), _canvas(page)
    _grid(panels)
    _grid(balloons)
    _boxes(panels, c["C"], "C", COLOURS["C"], 4)
    _boxes(panels, c["F"], "F", COLOURS["F"], 2)
    _boxes(balloons, c["B"], "B", COLOURS["B"])
    _boxes(balloons, c["T"], "T", COLOURS["T"], 2)
    cv2.imwrite(str(out), np.hstack([panels, np.full((panels.shape[0], 12, 3), 255, np.uint8), balloons]),
                [cv2.IMWRITE_JPEG_QUALITY, 85])
    print(out)


def check(page, out):
    lab = json.loads(label_path(page).read_text())
    img = _canvas(page)
    _grid(img)
    norm = lambda bs: [[x / lab["w"], y / lab["h"], bw / lab["w"], bh / lab["h"]] for x, y, bw, bh in bs]
    _boxes(img, norm(lab["panels"]), "P", COLOURS["P"], 4)
    _boxes(img, norm(lab["balloons"]), "L", COLOURS["L"])
    _boxes(img, norm(lab.get("captions", [])), "N", COLOURS["N"])
    cv2.imwrite(str(out), img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    print(out)


def sheet(folder, out, cols=5, thumb=420):
    tiles = []
    for p in pages_in(folder):
        if not label_path(p).exists():
            continue
        lab = json.loads(label_path(p).read_text())
        img = cv2.imread(str(p))
        s = thumb / img.shape[1]
        img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        _boxes(img, [[x / lab["w"], y / lab["h"], w / lab["w"], h / lab["h"]] for x, y, w, h in lab["panels"]],
               "P", COLOURS["P"], 3)
        _boxes(img, [[x / lab["w"], y / lab["h"], w / lab["w"], h / lab["h"]] for x, y, w, h in lab["balloons"]],
               "L", COLOURS["L"], 2)
        _boxes(img, [[x / lab["w"], y / lab["h"], w / lab["w"], h / lab["h"]] for x, y, w, h in lab.get("captions", [])],
               "N", COLOURS["N"], 2)
        cv2.putText(img, p.stem[-28:], (4, img.shape[0] - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3)
        cv2.putText(img, p.stem[-28:], (4, img.shape[0] - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        tiles.append(img)
    if not tiles:
        return
    th = max(t.shape[0] for t in tiles)
    tiles = [np.vstack([t, np.full((th - t.shape[0], thumb, 3), 255, np.uint8)]) for t in tiles]
    while len(tiles) % cols:
        tiles.append(np.full((th, thumb, 3), 255, np.uint8))
    rows = [np.hstack(tiles[i:i + cols]) for i in range(0, len(tiles), cols)]
    cv2.imwrite(str(out), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 80])
    print(out)


# ---------------------------------------------------------------- snapping

def _snap_panel(fg, box):
    """Move each edge of (x0, y0, x1, y1) px to the art boundary of the nearest gutter."""
    h, w = fg.shape
    x0, y0, x1, y1 = box
    mx, my = round(SNAP * w), round(SNAP * h)

    def edge(profile_at, lo, hi, forward):
        # Scan the band; the edge sits just past the last empty line on the outside.
        rng = range(lo, hi) if forward else range(hi - 1, lo - 1, -1)
        last_empty = None
        for i, c in enumerate(rng):
            if profile_at(c) < 0.03:
                last_empty = c
            elif last_empty is not None and i > (hi - lo) * 0.75:
                break
        if last_empty is None:
            return None
        return last_empty + 1 if forward else last_empty

    col = lambda c: fg[y0:y1, c].mean() / 255 if 0 <= c < w else 0
    row = lambda r: fg[r, x0:x1].mean() / 255 if 0 <= r < h else 0
    nx0 = edge(col, max(0, x0 - mx), min(w, x0 + mx), True)
    nx1 = edge(col, max(0, x1 - mx), min(w, x1 + mx), False)
    ny0 = edge(row, max(0, y0 - my), min(h, y0 + my), True)
    ny1 = edge(row, max(0, y1 - my), min(h, y1 + my), False)
    return (x0 if nx0 is None else nx0, y0 if ny0 is None else ny0,
            x1 if nx1 is None else nx1, y1 if ny1 is None else ny1)


def _snap_balloon(gray, box):
    """Bounding box of the light region under the typed box's centre, if it fits the box."""
    x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    h, w = gray.shape
    ex0, ey0 = max(0, x0 - bw // 2), max(0, y0 - bh // 2)
    ex1, ey1 = min(w, x1 + bw // 2), min(h, y1 + bh // 2)
    crop = gray[ey0:ey1, ex0:ex1]
    light = (crop > 190).astype(np.uint8)
    light = cv2.morphologyEx(light, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(light, connectivity=4)
    # Take the component covering most of the typed box.
    inner = lab[y0 - ey0:y1 - ey0, x0 - ex0:x1 - ex0]
    if inner.size == 0:
        return box
    counts = np.bincount(inner.ravel(), minlength=n)
    counts[0] = 0
    k = int(counts.argmax())
    if counts[k] < 0.25 * inner.size:
        return box
    sx, sy, sw, sh, _ = stats[k]
    snapped = (ex0 + sx, ey0 + sy, ex0 + sx + sw, ey0 + sy + sh)
    # Reject a region much bigger than the typed box (a white background, not a balloon).
    if sw * sh > 1.8 * bw * bh or sw < 0.6 * bw or sh < 0.6 * bh:
        return box
    return snapped


def _parse(spec, cand, w, h, kind, fg, gray):
    out = []
    for item in [s.strip() for s in spec.split(",") if s.strip()]:
        exact = item.startswith("!")
        item = item.lstrip("!")
        parts = item.split()
        if len(parts) == 4:
            x0, y0, x1, y1 = (float(v) / 100 for v in parts)
            box = (round(x0 * w), round(y0 * h), round(x1 * w), round(y1 * h))
            if not exact:
                box = _snap_panel(fg, box) if kind == "panel" else _snap_balloon(gray, box)
        else:
            xs = []
            for ref in item.split("+"):
                k, i = ref[0].upper(), int(ref[1:]) - 1
                x, y, bw, bh = cand[k][i]
                xs.append((x * w, y * h, (x + bw) * w, (y + bh) * h))
            box = (round(min(b[0] for b in xs)), round(min(b[1] for b in xs)),
                   round(max(b[2] for b in xs)), round(max(b[3] for b in xs)))
        x0, y0, x1, y1 = box
        out.append([int(x0), int(y0), int(x1 - x0), int(y1 - y0)])
    return out


def set_label(page, panels, balloons, captions=""):
    img = cv2.imread(str(page))
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    fg, _ = detect_cv._foreground(gray)
    cp = cand_path(page)
    cand = json.loads(cp.read_text()) if cp.exists() else {}
    lab = {"w": w, "h": h,
           "panels": _parse(panels, cand, w, h, "panel", fg, gray),
           "balloons": _parse(balloons, cand, w, h, "balloon", fg, gray),
           "captions": _parse(captions, cand, w, h, "balloon", fg, gray)}
    label_path(page).write_text(json.dumps(lab))
    print(f"{page.name}: {len(lab['panels'])} panels, {len(lab['balloons'])} balloons, "
          f"{len(lab['captions'])} captions")


# ---------------------------------------------------------------- captions

def looks_like_caption(img, box):
    """A caption is a rectangle filled edge to edge: its four corners share the
    fill of its middle band, where a balloon's corners fall outside its oval."""
    x, y, w, h = box
    crop = img[max(y, 0):y + h, max(x, 0):x + w]
    if crop.shape[0] < 12 or crop.shape[1] < 12:
        return False
    ch, cw = crop.shape[:2]
    band = np.vstack([crop[:, :max(cw // 12, 2)].reshape(-1, 3), crop[:, -max(cw // 12, 2):].reshape(-1, 3)])
    fill = np.median(band, axis=0)
    k = max(min(ch, cw) // 10, 3)
    corners = [crop[2:2 + k, 2:2 + k], crop[2:2 + k, -2 - k:-2], crop[-2 - k:-2, 2:2 + k], crop[-2 - k:-2, -2 - k:-2]]
    same = sum(np.abs(np.median(c.reshape(-1, 3), axis=0) - fill).max() < 30 for c in corners if c.size)
    return same >= 4


def crops(out, folders, guess, per_sheet=30, cols=6, tile=260):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    items, tiles = [], []
    for folder in folders:
        for page in pages_in(folder):
            lp = label_path(page)
            if not lp.exists():
                continue
            lab = json.loads(lp.read_text())
            lab.setdefault("captions", [])
            img = cv2.imread(str(page))
            if guess:
                keep = []
                for b in lab["balloons"]:
                    (lab["captions"] if looks_like_caption(img, b) else keep).append(b)
                lab["balloons"] = keep
            lp.write_text(json.dumps(lab))
            for kind in ("balloons", "captions"):
                for b in lab[kind]:
                    x, y, w, h = b
                    px, py = int(w * 0.25) + 8, int(h * 0.25) + 8
                    c = img[max(y - py, 0):y + h + py, max(x - px, 0):x + w + px].copy()
                    cv2.rectangle(c, (x - max(x - px, 0), y - max(y - py, 0)),
                                  (x - max(x - px, 0) + w, y - max(y - py, 0) + h),
                                  (160, 40, 180) if kind == "balloons" else (0, 140, 255), 2)
                    s = tile / max(c.shape[:2])
                    c = cv2.resize(c, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
                    t = np.full((tile + 28, tile, 3), 255, np.uint8)
                    t[:c.shape[0], :c.shape[1]] = c
                    n = len(items)
                    tag = f"{n} {'S' if kind == 'balloons' else 'N'}"
                    col = (160, 40, 180) if kind == "balloons" else (0, 140, 255)
                    cv2.rectangle(t, (0, tile), (tile, tile + 28), col, -1)
                    cv2.putText(t, tag, (6, tile + 21), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (255, 255, 255), 2)
                    items.append({"page": str(page), "box": b, "kind": kind})
                    tiles.append(t)
    for i in range(0, len(tiles), per_sheet):
        chunk = tiles[i:i + per_sheet]
        while len(chunk) % cols:
            chunk.append(np.full_like(tiles[0], 255))
        rows = [np.hstack([np.pad(t, ((3, 3), (3, 3), (0, 0))) for t in chunk[j:j + cols]])
                for j in range(0, len(chunk), cols)]
        cv2.imwrite(str(out / f"sheet_{i // per_sheet:03d}.jpg"), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 82])
    (out / "map.json").write_text(json.dumps(items))
    print(f"{len(items)} crops on {(len(tiles) + per_sheet - 1) // per_sheet} sheets in {out}")


def flip(map_path, ids, drop=()):
    items = json.loads(Path(map_path).read_text())
    for i in drop:
        it = items[i]
        lp = label_path(Path(it["page"]))
        lab = json.loads(lp.read_text())
        kind = next((k for k in ("balloons", "captions") if it["box"] in lab.get(k, [])), None)
        if kind is None:
            print(f"{i}: box no longer in {lp.name}, skipped")
            continue
        lab[kind].remove(it["box"])
        lp.write_text(json.dumps(lab))
        print(f"{i}: {Path(it['page']).name} dropped from {kind}")
    for i in ids:
        it = items[i]
        lp = label_path(Path(it["page"]))
        lab = json.loads(lp.read_text())
        lab.setdefault("captions", [])
        # The kind shown on the sheet decides, so applying a review twice is harmless.
        src = it.get("kind") or ("balloons" if it["box"] in lab["balloons"] else "captions")
        dst = "captions" if src == "balloons" else "balloons"
        if it["box"] not in lab[src]:
            print(f"{i}: box not in {lp.name} {src} (already applied?), skipped")
            continue
        lab[src].remove(it["box"])
        lab[dst].append(it["box"])
        lp.write_text(json.dumps(lab))
        print(f"{i}: {Path(it['page']).name} {src} -> {dst}")


def export(folder, dest):
    n = 0
    for p in pages_in(folder):
        if label_path(p).exists():
            out = Path(dest) / p.parent.name / label_path(p).name
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(label_path(p).read_text())
            n += 1
    print(f"exported {n} labels to {dest}")


def import_labels(src, folder):
    pages = {(p.parent.name, p.stem): p for p in pages_in(folder)}
    n, missing = 0, []
    for lab in sorted(Path(src).rglob("*.json")):
        page = pages.get((lab.parent.name, lab.stem))
        if page is None:
            missing.append(f"{lab.parent.name}/{lab.stem}")
            continue
        label_path(page).write_text(lab.read_text())
        n += 1
    print(f"imported {n} labels into {folder}")
    if missing:
        print(f"no extracted page for {len(missing)} labels, e.g. {missing[:3]}")


def _ids(text):
    return [int(v) for v in text.replace(" ", "").split(",") if v]


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("candidates"); c.add_argument("folder"); c.add_argument("--weights")
    s = sub.add_parser("show"); s.add_argument("page"); s.add_argument("--out")
    k = sub.add_parser("check"); k.add_argument("page"); k.add_argument("--out")
    t = sub.add_parser("set"); t.add_argument("page"); t.add_argument("--panels", default="")
    t.add_argument("--balloons", default="")
    t.add_argument("--captions", default="")
    r = sub.add_parser("crops"); r.add_argument("out"); r.add_argument("folders", nargs="+")
    r.add_argument("--guess", action="store_true")
    f = sub.add_parser("flip"); f.add_argument("map"); f.add_argument("ids"); f.add_argument("--drop", default="")
    v = sub.add_parser("review"); v.add_argument("map"); v.add_argument("files", nargs="+")
    h = sub.add_parser("sheet"); h.add_argument("folder"); h.add_argument("out")
    e = sub.add_parser("export"); e.add_argument("folder"); e.add_argument("dest")
    i = sub.add_parser("import"); i.add_argument("src"); i.add_argument("folder")
    a = ap.parse_args()
    if a.cmd == "candidates":
        candidates(a.folder, a.weights)
    elif a.cmd == "show":
        page = Path(a.page)
        show(page, a.out or page.with_suffix(".show.jpg"))
    elif a.cmd == "check":
        page = Path(a.page)
        check(page, a.out or page.with_suffix(".check.jpg"))
    elif a.cmd == "set":
        set_label(Path(a.page), a.panels, a.balloons, a.captions)
    elif a.cmd == "sheet":
        sheet(a.folder, a.out)
    elif a.cmd == "export":
        export(a.folder, a.dest)
    elif a.cmd == "import":
        import_labels(a.src, a.folder)
    elif a.cmd == "crops":
        crops(a.out, a.folders, a.guess)
    elif a.cmd == "flip":
        flip(a.map, _ids(a.ids), _ids(a.drop))
    elif a.cmd == "review":
        flips, drops = [], []
        for f in a.files:
            for line in Path(f).read_text().splitlines():
                for part in line.split()[1:]:
                    key, _, val = part.partition("=")
                    (flips if key == "flip" else drops if key == "drop" else []).extend(_ids(val))
        flip(a.map, sorted(set(flips) - set(drops)), sorted(set(drops)))


if __name__ == "__main__":
    main()
