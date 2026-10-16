#!/usr/bin/env python3
"""Which comics of a library to give to a large model for drawing panels
(tool/llm_panels.py): those whose frames are not straight and whose speech
is not in obvious balloons, where the built-in detector does worst.

  python3 tool/triage_panels.py [FOLDER|BOOK ...] [--out DIR] [--samples 8] [--sheets 40] [--jobs 6]

Looks in the app's library folders (read from its index), else in ~/Comics,
like `llm_panels.py library`. For each comic it samples --samples pages from
the middle (10% to 90%, so covers and back matter mostly stay out), runs the
detector built into the app (assets/models/comicredr-panels.onnx, the way
detector/evaluate.py runs it) and notes per page the frames, balloons and
captions, the frames whose outline is not a rectangle (detector/outlines.py)
and whether the app's confidence gate passes and why not. Writes into --out
(default /tmp/comicredr-triage):

  results.jsonl    one line a comic: its pages, what was found on each, pages done
  ranking.txt      every comic, best candidate first, with the numbers
  sheets/NN.jpg    the sampled pages of the --sheets best candidates, three
                   comics a sheet, eight pages a row, for a person or an agent
                   to look at
  pages/N/PPPP.jpg the sampled pages, 500 px

The score is a lead, not a verdict: it rewards pages with frames (two or
more found) that are slanted or overlap (the gate refuses them), and is
divided down by the balloons found a page. Cover galleries and pin-up books
score high too (one frame, refused) and are not comics to draw; looking at
the sheets tells them apart. Comics whose pages are all done already
(imported panels in the sidecar) are listed as done and get no sheet.

Needs numpy, OpenCV (opencv-python-headless), onnxruntime and Pillow, and
pypdfium2 for PDFs. About ten seconds a comic on 4 cores with --jobs 6.
"""
import argparse
import io
import json
import os
import sys
import tarfile
import zipfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(REPO / "detector"), str(REPO / "tool")]
import llm_panels as lp  # noqa: E402

MODEL = REPO / "assets/models/comicredr-panels.onnx"
THUMB = 500
DETECT_SIDE = 1600
_detector = None


def sample(count, samples):
    """Page indexes (from 0) to look at: all but the first and last when
    there are few, else [samples] spread over 10% to 90% of the comic."""
    if count <= samples + 2:
        return list(range(1, count - 1)) or list(range(count))
    lo, hi = int(count * 0.1), int(count * 0.9)
    step = (hi - lo) / samples
    return sorted({lo + int(i * step) for i in range(samples)})


def load_pages(book, kind, wanted):
    """Yields (index, PIL image) for the [wanted] pages only, in the app's
    page order (lp.pages reads every page, too slow for a 1,000-page book)."""
    from PIL import Image

    if kind == "pdf":
        import pypdfium2 as pdfium
        doc = pdfium.PdfDocument(book)
        for i in wanted:
            w, h = doc[i].get_size()
            yield i, doc[i].render(scale=DETECT_SIDE / max(w, h)).to_pil().convert("RGB")
        return
    if kind == "image":
        yield 0, Image.open(book).convert("RGB")
        return
    if kind == "folder":
        names = lp.folder_pages(book)
        for i in wanted:
            yield i, Image.open(os.path.join(book, names[i])).convert("RGB")
        return
    if kind == "zip":
        with zipfile.ZipFile(book) as z:
            names = lp.natural_sorted([n for n in z.namelist() if not n.endswith("/") and lp.is_page_entry(n)])
            for i in wanted:
                yield i, Image.open(io.BytesIO(z.read(names[i]))).convert("RGB")
        return
    with tarfile.open(book) as t:
        members = {m.name: m for m in t.getmembers() if m.isfile() and lp.is_page_entry(m.name)}
        names = lp.natural_sorted(list(members))
        for i in wanted:
            yield i, Image.open(io.BytesIO(t.extractfile(members[names[i]]).read())).convert("RGB")


def look(im):
    """What the built-in detector makes of one page: the counts, the frames
    that are not rectangles, and the gate's verdict as the app judges it."""
    global _detector
    import cv2
    import numpy as np
    import evaluate
    import outlines

    if _detector is None:
        _detector = evaluate.Onnx(MODEL)
    bgr = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    H, W = bgr.shape[:2]
    frames, balloons = _detector(bgr)

    def px(b):
        return [b[0] * W, b[1] * H, (b[0] + b[2]) * W, (b[1] + b[3]) * H]

    shapes = outlines.outlines(bgr, [px(b) for b in frames], [px(b) for b in balloons])
    ok, why = evaluate.gate(frames, [None if s is None else np.asarray(s) / [W, H] for s in shapes])
    return {"frames": len(frames), "balloons": len(balloons), "captions": len(_detector.captions),
            "nonrect": sum(1 for s in shapes if s is not None), "gate": ok, "why": why}


def scan(job):
    """One comic: its sampled pages looked at, the thumbnails kept."""
    n, book, kind, samples, out, sidecar = job
    rec = {"n": n, "book": book, "kind": kind, "pages": []}
    try:
        count = lp.page_count(book)
        done, _ = lp.done_pages(sidecar, lp.content_key(book))
        rec.update(count=count, done=len(done & set(range(1, count + 1))))
        if rec["done"] == count:
            return rec
        thumbs = Path(out) / "pages" / str(n)
        thumbs.mkdir(parents=True, exist_ok=True)
        for i, im in load_pages(book, kind, sample(count, samples)):
            im.thumbnail((DETECT_SIDE, DETECT_SIDE))
            rec["pages"].append({"page": i + 1, **look(im)})
            im.thumbnail((THUMB, THUMB))
            im.save(thumbs / f"{i + 1:04d}.jpg", quality=80)
    except Exception as e:  # A broken comic: say so in its line and go on.
        rec["error"] = repr(e)
    return rec


def score(rec):
    """Higher for slanted or overlapping frames, lower for many balloons;
    None when nothing was looked at (done, broken or empty)."""
    ps = rec["pages"]
    if not ps:
        return None
    n = len(ps)
    story = sum(1 for p in ps if p["frames"] >= 2) / n
    balloons = sum(p["balloons"] for p in ps) / n
    nonrect = sum(1 for p in ps if p["nonrect"]) / n
    overlap = sum(1 for p in ps if any("overlap" in w for w in p["why"])) / n
    refused = sum(1 for p in ps if not p["gate"]) / n
    rec["stats"] = dict(story=story, balloons=balloons, nonrect=nonrect, overlap=overlap, refused=refused)
    return story * (nonrect + overlap + 0.5 * refused) / (1 + balloons / 3)


def write_ranking(recs, out, root):
    lines = [f"{'score':>5} {'story':>5} {'bal/p':>5} {'slant':>5} {'ovl':>4} {'gate✗':>5} {'done':>9}  comic"]
    for r in recs:
        name = os.path.relpath(r["book"], root) if root else r["book"]
        done = f"{r.get('done', 0)}/{r.get('count', '?')}"
        if r["score"] is None:
            why = r.get("error") or ("all done" if r.get("done") == r.get("count") else "no pages")
            lines.append(f"{'-':>5} {'':>5} {'':>5} {'':>5} {'':>4} {'':>5} {done:>9}  {name}  ({why})")
            continue
        s = r["stats"]
        lines.append(f"{r['score']:5.2f} {s['story']:5.2f} {s['balloons']:5.1f} {s['nonrect']:5.2f} "
                     f"{s['overlap']:4.2f} {s['refused']:5.2f} {done:>9}  {name}")
    (Path(out) / "ranking.txt").write_text("\n".join(lines) + "\n")


def write_sheets(recs, out, root, count):
    """Three comics a sheet, a row of eight sampled pages each, titled with
    the comic's number in ranking.txt order and its name."""
    from PIL import Image, ImageDraw

    tw, th, title = 200, 290, 22
    ranked = [r for r in recs if r["score"] is not None][:count]
    sheets = Path(out) / "sheets"
    sheets.mkdir(parents=True, exist_ok=True)
    for k in range(0, len(ranked), 3):
        group = ranked[k:k + 3]
        sheet = Image.new("RGB", (tw * 8, (th + title) * len(group)), "white")
        draw = ImageDraw.Draw(sheet)
        for row, r in enumerate(group):
            y = row * (th + title)
            name = os.path.relpath(r["book"], root) if root else r["book"]
            draw.text((4, y + 4), f"{k + row + 1}. {name}", fill="black")
            for col, page in enumerate(sorted((Path(out) / "pages" / str(r["n"])).glob("*.jpg"))[:8]):
                im = Image.open(page)
                im.thumbnail((tw - 4, th - 4))
                sheet.paste(im, (col * tw + 2, y + title))
        sheet.save(sheets / f"{k // 3 + 1:02d}.jpg", quality=85)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", help="folders or comics (default: the app's library folders, else ~/Comics)")
    ap.add_argument("--out", default="/tmp/comicredr-triage")
    ap.add_argument("--samples", type=int, default=8, help="pages looked at per comic")
    ap.add_argument("--sheets", type=int, default=40, help="best candidates put on contact sheets")
    ap.add_argument("--jobs", type=int, default=max(1, min(6, (os.cpu_count() or 2) - 2)))
    ap.add_argument("--index", help="the app's comicredr.sqlite, when it is not in the usual place")
    a = ap.parse_args()
    index = lp.Index(a.index)
    roots = a.paths or [r for _, r in index.roots] or [os.path.expanduser("~/Comics")]
    books = [(p, k) for p, k in lp.find_books(roots) if k in ("pdf", "zip", "tar", "folder")]
    Path(a.out).mkdir(parents=True, exist_ok=True)
    jobs = [(n, p, k, a.samples, a.out, index.sidecar(p)) for n, (p, k) in enumerate(books)]
    recs = []
    print(f"Looking at {len(books)} comics in {', '.join(roots)}", flush=True)
    with open(Path(a.out) / "results.jsonl", "w") as f, ProcessPoolExecutor(a.jobs) as ex:
        for rec in ex.map(scan, jobs):
            f.write(json.dumps(rec) + "\n")
            recs.append(rec)
            print(f"  {len(recs)}/{len(books)}  {rec['book']}{'  ' + rec['error'] if 'error' in rec else ''}",
                  flush=True)
    for r in recs:
        r["score"] = score(r)
    recs.sort(key=lambda r: -(r["score"] if r["score"] is not None else -1))
    root = roots[0] if len(roots) == 1 and os.path.isdir(roots[0]) else None
    write_ranking(recs, a.out, root)
    write_sheets(recs, a.out, root, a.sheets)
    print(f"Ranking in {a.out}/ranking.txt, sheets of the best {a.sheets} in {a.out}/sheets/")


if __name__ == "__main__":
    main()
