#!/usr/bin/env python3
"""Panels and balloons drawn by a large vision model (Claude, Codex, ...), put
into a comic's sidecar so guided view uses them instead of the built-in
detector's, page by page.

  python3 tool/llm_panels.py pages  BOOK WORK    # WORK/page-001.jpg ... with a percent grid, and the prompt
  python3 tool/llm_panels.py check  BOOK WORK    # WORK/check/page-001.jpg: WORK/panels.json drawn on the pages
  python3 tool/llm_panels.py import BOOK WORK/panels.json [--sidecar FILE]

BOOK is a CBZ, CBT, PDF, a folder of page images or one image, read in the
app's page order (packages/comic_formats: natural order, junk skipped). EPUB
is not read here. Needs Pillow, and pypdfium2 for a PDF.

panels.json, every number a percent of the page's width or height:

  {"pages": {"1": {"panels": [[x0, y0, x1, y1], {"outline": [[x, y], ...]}, ...],
                   "balloons": [[x0, y0, x1, y1], ...],
                   "captions": [[x0, y0, x1, y1], ...]}}}

Pages by number from 1. Panels in reading order; a slanted panel may be given
by its outline (a convex polygon). "panels": [] says the page has no panel
layout and is shown whole. Pages left out keep what the app's detector finds.

The import writes the rows as source "manual", which the app prefers over its
detector on those pages (PanelStore.load), into the sidecar beside the comic
(`.Book.cbz.crdb`, `.comicredr.crdb` inside a folder book), merged with what
is there; the app reads it the next time the comic opens. With Settings ->
Sidecars -> In one folder, pass that sidecar with --sidecar. X (Redo panels)
in the app drops them again.
"""
import argparse
import functools
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import tarfile
import time
import zipfile
from pathlib import Path

LONG_SIDE = 1100
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
SOURCE = "manual"
MODEL_VER = 1
SCHEMA_VERSION = 3  # sidecarSchemaVersion in lib/src/data/sidecar.dart

# lib/src/data/sidecar.dart, _schema: a new sidecar is made exactly like the app's.
SCHEMA = [
    "CREATE TABLE meta (schema_version INTEGER NOT NULL, app_version TEXT, written_at INTEGER NOT NULL, "
    "content_key TEXT NOT NULL, device TEXT)",
    "CREATE TABLE book (title TEXT NOT NULL, series TEXT, number TEXT, volume INTEGER, year INTEGER, "
    "writers TEXT, artists TEXT, summary TEXT)",
    "CREATE TABLE analysed_pages (page INTEGER NOT NULL, source TEXT NOT NULL, model_ver INTEGER NOT NULL, "
    "millis INTEGER NOT NULL, analysed_at INTEGER NOT NULL, trim TEXT, PRIMARY KEY (page, source))",
    "CREATE TABLE panels (page INTEGER NOT NULL, idx INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, "
    "w REAL NOT NULL, h REAL NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, model_ver INTEGER NOT NULL, "
    "confidence REAL NOT NULL, shape TEXT, PRIMARY KEY (page, kind, idx, source))",
    "CREATE TABLE bookmarks (id TEXT PRIMARY KEY, page INTEGER NOT NULL, panel INTEGER, mark TEXT, note TEXT, "
    "created_at INTEGER NOT NULL, deleted_at INTEGER)",
    "CREATE TABLE progress (device TEXT PRIMARY KEY, device_name TEXT NOT NULL, page INTEGER NOT NULL, "
    "panel INTEGER, percent REAL NOT NULL, finished INTEGER NOT NULL, updated_at INTEGER NOT NULL, view_json TEXT)",
    "CREATE TABLE overrides (field TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "CREATE TABLE cover (image BLOB NOT NULL)",
    "CREATE TABLE collections (name TEXT PRIMARY KEY, added_at INTEGER NOT NULL, removed_at INTEGER)",
]

PROMPT = """\
You are marking up the pages of a comic for a reader app's guided view.
In this folder, page-001.jpg, page-002.jpg, ... are the pages in order, each
with a grid drawn over it: a line every 5% of the page's width and height,
labelled every 10%.

For every page, look at the image and write down:
- panels: every panel, in the order a reader reads them (left to right, top
  to bottom; a tall panel beside a stack is read first), as
  [x0, y0, x1, y1]: its left, top, right and bottom edges in percent of the
  page. A slanted or cut panel may be {"outline": [[x, y], ...]} instead,
  its corners in percent, going round from the top left one. Borderless art
  counts as a panel when it is a stop of its own. Panels should not overlap;
  where art spills over a border, give the border. A cover, a pin-up or a
  page of text gets "panels": [].
- balloons: speech and thought balloons, and speech written without a
  balloon, as [x0, y0, x1, y1] in percent.
- captions: narration boxes, kept apart from balloons.
Leave out sound effects and signs.

Write it all to panels.json in this folder:
{"pages": {"1": {"panels": [...], "balloons": [...], "captions": [...]}, "2": ...}}

Then run `python3 {tool} check {book} {work}` and look at
check/page-NNN.jpg: green boxes are panels with their number, magenta
balloons, blue captions. Fix any box that does not sit on its edge, and run
check again until they all do.
"""


# ---------------------------------------------------------------- the book

def _tokens(s):
    return re.findall(r"[0-9]+|[^0-9]+", s)


def natural_sorted(names):
    """Sorted by naturalCompare in comic_formats: folder by folder, case
    ignored, digit runs by value and then by length, the rest as text."""

    def cmp_name(a, b):
        ta, tb = _tokens(a), _tokens(b)
        for x, y in zip(ta, tb):
            if x[0] in "0123456789" and y[0] in "0123456789":
                sx, sy = x.lstrip("0"), y.lstrip("0")
                c = (len(sx) > len(sy)) - (len(sx) < len(sy)) or (sx > sy) - (sx < sy) or (len(x) > len(y)) - (len(x) < len(y))
            else:
                c = (x > y) - (x < y)
            if c:
                return c
        return (len(ta) > len(tb)) - (len(ta) < len(tb))

    def cmp(a, b):
        pa, pb = a.lower().split("/"), b.lower().split("/")
        for x, y in zip(pa, pb):
            c = cmp_name(x, y)
            if c:
                return c
        return (len(pa) > len(pb)) - (len(pa) < len(pb))

    return sorted(names, key=functools.cmp_to_key(cmp))


def is_page_entry(path):
    """isPageEntry in comic_formats."""
    normal = path.replace("\\", "/")
    if "__MACOSX/" in normal:
        return False
    name = normal.split("/")[-1]
    if not name or name.startswith("."):
        return False
    dot = name.rfind(".")
    return dot > 0 and name[dot:].lower() in IMAGE_EXT


def sniff(path):
    if os.path.isdir(path):
        return "folder"
    with open(path, "rb") as f:
        head = f.read(512)
    if head.startswith(b"PK"):
        return "zip"
    if head.startswith(b"%PDF"):
        return "pdf"
    if len(head) >= 262 and head[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"\x89PNG") or head.startswith(b"\xff\xd8") or (head[:4] == b"RIFF" and head[8:12] == b"WEBP"):
        return "image"
    sys.exit(f"{path}: not a CBZ, CBT, PDF, image or folder (EPUB is not read by this tool)")


def folder_pages(root):
    out = []
    for d, _, files in os.walk(root, followlinks=True):
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/")
            if is_page_entry(rel):
                out.append(rel)
    return natural_sorted(out)


def pages(book):
    """Yields each page as a PIL image, in the app's order."""
    from PIL import Image

    kind = sniff(book)
    if kind == "pdf":
        import pypdfium2 as pdfium
        doc = pdfium.PdfDocument(book)
        for i in range(len(doc)):
            page = doc[i]
            w, h = page.get_size()
            yield page.render(scale=LONG_SIDE / max(w, h)).to_pil().convert("RGB")
        return
    if kind == "image":
        yield Image.open(book).convert("RGB")
        return
    if kind == "folder":
        for name in folder_pages(book):
            yield Image.open(os.path.join(book, name)).convert("RGB")
        return
    if kind == "zip":
        with zipfile.ZipFile(book) as z:
            names = natural_sorted([n for n in z.namelist() if not n.endswith("/") and is_page_entry(n)])
            for n in names:
                yield Image.open(io.BytesIO(z.read(n))).convert("RGB")
        return
    with tarfile.open(book) as t:
        members = {m.name: m for m in t.getmembers() if m.isfile() and is_page_entry(m.name)}
        for n in natural_sorted(list(members)):
            yield Image.open(io.BytesIO(t.extractfile(members[n]).read())).convert("RGB")


def page_count(book):
    kind = sniff(book)
    if kind == "pdf":
        import pypdfium2 as pdfium
        return len(pdfium.PdfDocument(book))
    if kind == "image":
        return 1
    if kind == "folder":
        return len(folder_pages(book))
    if kind == "zip":
        with zipfile.ZipFile(book) as z:
            return sum(1 for n in z.namelist() if not n.endswith("/") and is_page_entry(n))
    with tarfile.open(book) as t:
        return sum(1 for m in t.getmembers() if m.isfile() and is_page_entry(m.name))


def content_key(book):
    """contentKey in comic_formats: SHA-1 of the first 64 KiB, and the size."""
    if os.path.isdir(book):
        names = folder_pages(book)
        size = sum(os.path.getsize(os.path.join(book, n)) for n in names)
        with open(os.path.join(book, names[0]), "rb") as f:
            head = f.read(64 * 1024)
        # The Dart side hashes the names' UTF-16 code units as bytes: their low bytes.
        return f"{hashlib.sha1(head + chr(10).join(names).encode('utf-16-le')[::2]).hexdigest()}-{size}"
    with open(book, "rb") as f:
        head = f.read(64 * 1024)
    return f"{hashlib.sha1(head).hexdigest()}-{os.path.getsize(book)}"


def sidecar_path(book):
    book = os.path.abspath(book).rstrip("/")
    if os.path.isdir(book):
        return os.path.join(book, ".comicredr.crdb")
    return os.path.join(os.path.dirname(book), "." + os.path.basename(book) + ".crdb")


# ---------------------------------------------------------------- pages

def scaled(img):
    s = LONG_SIDE / max(img.size)
    return img.resize((round(img.width * s), round(img.height * s))) if s < 1 else img


def draw_grid(img):
    from PIL import ImageDraw
    img = img.copy()
    d = ImageDraw.Draw(img)
    w, h = img.size
    for k in range(1, 20):
        c = (220, 0, 0) if k % 2 == 0 else (0, 150, 255)
        x, y = round(w * k / 20), round(h * k / 20)
        d.line([(x, 0), (x, h)], fill=c, width=1)
        d.line([(0, y), (w, y)], fill=c, width=1)
        if k % 2 == 0:
            for px, py in ((x + 2, 2), (2, y - 12)):
                d.text((px, py), str(k * 5), fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    return img


def cmd_pages(a):
    work = Path(a.work)
    work.mkdir(parents=True, exist_ok=True)
    n = 0
    for n, img in enumerate(pages(a.book), 1):
        draw_grid(scaled(img)).save(work / f"page-{n:03d}.jpg", quality=85)
    prompt = PROMPT.replace("{tool}", os.path.abspath(__file__)).replace("{book}", _quote(os.path.abspath(a.book)))
    prompt = prompt.replace("{work}", ".")
    (work / "PROMPT.md").write_text(prompt)
    print(f"{n} pages in {work}/, the prompt in {work}/PROMPT.md")


def _quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- panels.json

def _box(v, where):
    if not (isinstance(v, list) and len(v) == 4 and all(isinstance(x, (int, float)) for x in v)):
        raise ValueError(f"{where}: a box is [x0, y0, x1, y1], not {v!r}")
    x0, y0, x1, y1 = (min(100.0, max(0.0, float(x))) / 100 for x in v)
    if x1 <= x0 or y1 <= y0:
        raise ValueError(f"{where}: {v!r} has no area")
    return x0, y0, x1 - x0, y1 - y0


def _panel(v, where):
    """(x, y, w, h, shape) in page shares; shape is None or [x, y, x, y, ...]."""
    if isinstance(v, dict):
        pts = v.get("outline")
        if not (isinstance(pts, list) and len(pts) >= 3 and all(isinstance(p, list) and len(p) == 2 for p in pts)):
            raise ValueError(f"{where}: an outline is three or more [x, y] points")
        pts = [(min(100.0, max(0.0, float(x))) / 100, min(100.0, max(0.0, float(y))) / 100) for x, y in pts]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        if max(xs) <= min(xs) or max(ys) <= min(ys):
            raise ValueError(f"{where}: outline has no area")
        return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys), [c for p in pts for c in p]
    return (*_box(v, where), None)


def read_panels(path, page_count):
    data = json.loads(Path(path).read_text())
    out = {}
    for key, page in (data.get("pages") or {}).items():
        n = int(key)
        if not 1 <= n <= page_count:
            raise ValueError(f"page {key}: the comic has {page_count} pages")
        where = f"page {n}"
        out[n] = {
            "panels": [_panel(v, f"{where} panel {i + 1}") for i, v in enumerate(page.get("panels", []))],
            "balloons": [_box(v, f"{where} balloon {i + 1}") for i, v in enumerate(page.get("balloons", []))],
            "captions": [_box(v, f"{where} caption {i + 1}") for i, v in enumerate(page.get("captions", []))],
        }
    return out


def cmd_check(a):
    from PIL import ImageDraw
    work = Path(a.work)
    found = read_panels(work / "panels.json", page_count(a.book))
    (work / "check").mkdir(exist_ok=True)
    for n, img in enumerate(pages(a.book), 1):
        if n not in found:
            continue
        page = found[n]
        img = scaled(img)
        d = ImageDraw.Draw(img)
        w, h = img.size
        px = lambda b: [b[0] * w, b[1] * h, (b[0] + b[2]) * w, (b[1] + b[3]) * h]
        for colour, boxes in (((200, 0, 200), page["balloons"]), ((0, 90, 255), page["captions"])):
            for b in boxes:
                d.rectangle(px(b), outline=colour, width=3)
        for i, p in enumerate(page["panels"]):
            if p[4]:
                pts = [(p[4][k] * w, p[4][k + 1] * h) for k in range(0, len(p[4]), 2)]
                d.polygon(pts, outline=(0, 190, 0), width=4)
            else:
                d.rectangle(px(p), outline=(0, 190, 0), width=4)
            # An outline's number goes by its first corner, which is the top left one asked for.
            x, y = (p[4][0], p[4][1]) if p[4] else (p[0], p[1])
            d.text((x * w + 8, y * h + 6), str(i + 1), fill=(0, 190, 0), stroke_width=3,
                   stroke_fill=(255, 255, 255), font_size=28)
        img.save(work / "check" / f"page-{n:03d}.jpg", quality=85)
    print(f"{len(found)} pages drawn in {work}/check/")


# ---------------------------------------------------------------- the sidecar

def cmd_import(a):
    book = a.book.rstrip("/")
    found = read_panels(a.panels, page_count(book))
    key = content_key(book)
    path = a.sidecar or sidecar_path(book)
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    if os.path.exists(tmp):
        os.remove(tmp)
    now = int(time.time() * 1000)
    if os.path.exists(path):
        with open(path, "rb") as src, open(tmp, "wb") as dst:
            dst.write(src.read())
        db = sqlite3.connect(tmp)
        have, schema = db.execute("SELECT content_key, schema_version FROM meta LIMIT 1").fetchone()
        if have != key:
            db.close()
            os.remove(tmp)
            sys.exit(f"{path} belongs to another comic ({have}, this one is {key})")
        if schema > SCHEMA_VERSION:
            db.close()
            os.remove(tmp)
            sys.exit(f"{path} was written by a newer ComicRedr; update this tool")
        db.execute("UPDATE meta SET written_at = ?", (now,))
    else:
        db = sqlite3.connect(tmp)
        db.execute("PRAGMA journal_mode = OFF")
        for s in SCHEMA:
            db.execute(s)
        db.execute("INSERT INTO meta VALUES (?, ?, ?, ?, ?)", (SCHEMA_VERSION, "llm_panels.py", now, key, "llm_panels"))
    with db:
        for n, page in found.items():
            p = n - 1
            db.execute("DELETE FROM panels WHERE page = ? AND source = ?", (p, SOURCE))
            db.execute("INSERT OR REPLACE INTO analysed_pages VALUES (?, ?, ?, ?, ?, NULL)", (p, SOURCE, MODEL_VER, 0, now))
            rows = [(i, *f[:4], "frame", f[4]) for i, f in enumerate(page["panels"])]
            rows += [(i, *b, "balloon", None) for i, b in enumerate(page["balloons"])]
            rows += [(i, *c, "caption", None) for i, c in enumerate(page["captions"])]
            for i, x, y, w, h, kind, shape in rows:
                db.execute("INSERT INTO panels VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (p, i, x, y, w, h, kind, SOURCE, MODEL_VER, 1.0,
                            None if shape is None else ",".join(f"{v:.5f}" for v in shape)))
    db.close()
    os.replace(tmp, path)
    print(f"{len(found)} pages of panels written to {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pages", help="write the pages with a percent grid, and the prompt")
    p.add_argument("book")
    p.add_argument("work")
    p.set_defaults(run=cmd_pages)
    p = sub.add_parser("check", help="draw WORK/panels.json on the pages, into WORK/check/")
    p.add_argument("book")
    p.add_argument("work")
    p.set_defaults(run=cmd_check)
    p = sub.add_parser("import", help="write panels.json into the comic's sidecar")
    p.add_argument("book")
    p.add_argument("panels")
    p.add_argument("--sidecar", help="the sidecar to write, when it is not beside the comic")
    p.set_defaults(run=cmd_import)
    a = ap.parse_args()
    try:
        a.run(a)
    except ValueError as e:
        sys.exit(f"panels.json: {e}")


if __name__ == "__main__":
    main()
