#!/usr/bin/env python3
"""Panels and balloons drawn by a large vision model (Claude, Codex, ...), put
into a comic's sidecar so guided view uses them instead of the built-in
detector's, page by page.

  python3 tool/llm_panels.py library [FOLDER|BOOK ...] [--todo]  # the comics, and how many pages are done
  python3 tool/llm_panels.py pages  BOOK WORK [--batch 10] [--pages 1-10] [--all]  # pages not done, with a grid, and the prompt
  python3 tool/llm_panels.py check  BOOK WORK    # WORK/check/page-001.jpg: WORK/panels.json drawn on the pages
  python3 tool/llm_panels.py import BOOK WORK/panels.json --harness NAME --model NAME [--sidecar FILE]

`library` looks in the app's library folders (read from its index), else in
~/Comics. A page is done once panels for it were imported; `pages` leaves
done pages out unless --all, so a stopped run goes on where it was.

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
Sidecars -> In one folder the sidecar there is used (read from the app's
index; --sidecar names one by hand). It also records the run in the
sidecar's overrides row "panelImport" (harness, model, prompt version, date,
pages), which the comic's details (I) show. X (Redo panels) in the app drops
the panels and the record again.
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
import urllib.parse
import zipfile
from pathlib import Path

LONG_SIDE = 1100
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
SOURCE = "manual"
MODEL_VER = 1
# Raise when the drawing rules in PROMPT change, so a record says which rules drew a comic.
PROMPT_VERSION = 2
# panelImportField in lib/src/data/meta_edits.dart.
RECORD_FIELD = "panelImport"
RECORD_RUNS = 20
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
In this folder, page-NNN.jpg is page NNN of the comic, each with a grid
drawn over it: a line every 5% of the page's width and height, labelled
every 10%. The pages to do are {todo}.

What matters most: someone reading the comic in guided view, one panel
after another, can read it comfortably, misses no panel and no line of
text, and gets them all in the order the story is told. Every rule below
serves that; where one would get in its way, that comes first.

For every one of those pages, look at the image and write down:
- panels: every panel, in the order a reader reads them (left to right, top
  to bottom; a tall panel beside a stack is read first; where the layout
  leaves the order open, read the words and follow the story: who answers
  whom, what happens next), as
  [x0, y0, x1, y1]: its left, top, right and bottom edges in percent of the
  page. A panel with any border that is not straight across or straight
  down (diagonal, slanted, only partly slanted, a cut corner) is
  {"outline": [[x, y], ...]} instead: its corners in percent, going round
  from the top left one, with a corner wherever the border bends, so the
  outline runs along the real border on every side. Borderless art
  counts as a panel when it is a stop of its own. Where art spills over a
  border, give the border. But a balloon or caption that belongs to a panel
  and sticks out over its border is taken in: grow that panel's box (or
  outline) just enough to hold the whole balloon, even where it then
  overlaps the next panel, so the reader sees all of its words. A frame
  inside a frame (an inset, a close-up laid over a big panel): when it is
  not clear whether it is a stop of its own, give both, the big panel and
  then the inset right after it, so the reader sees the whole scene and
  then the detail. Otherwise panels should not overlap. A cover, a pin-up or a page of text gets "panels": [].
- balloons: speech and thought balloons, and speech written without a
  balloon, as [x0, y0, x1, y1] in percent.
- captions: narration boxes, kept apart from balloons.
Leave out sound effects and signs.

Write it all to panels.json in this folder, keyed by the page's number:
{"pages": {"1": {"panels": [...], "balloons": [...], "captions": [...]}, "2": ...}}

Then run `python3 {tool} check {book} {work}` and look at
check/page-NNN.jpg: green boxes are panels with their number, magenta
balloons, blue captions. Fix any box or outline that does not sit on its
border (a panel grown for a balloon: on the balloon's edge), and any balloon
that sticks out of its panel, and run check again until they all do.

Then put it in the comic's sidecar, naming yourself and your model:
`python3 {tool} import {book} panels.json --harness "Claude Code" --model claude-opus-5-5`
(in Codex: --harness Codex and the model you run as).
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


def kind_of(path):
    """What the file's first bytes say it is: zip, epub, pdf, tar, image, or
    None for anything else; a folder is "folder"."""
    if os.path.isdir(path):
        return "folder"
    try:
        with open(path, "rb") as f:
            head = f.read(512)
    except OSError:
        return None
    if head.startswith(b"PK"):
        try:
            with zipfile.ZipFile(path) as z:
                names = set(z.namelist())
                if "META-INF/container.xml" in names or (
                        "mimetype" in names and z.read("mimetype").strip() == b"application/epub+zip"):
                    return "epub"
        except (zipfile.BadZipFile, OSError):
            return None
        return "zip"
    if head.startswith(b"%PDF"):
        return "pdf"
    if len(head) >= 262 and head[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"\x89PNG") or head.startswith(b"\xff\xd8") or (head[:4] == b"RIFF" and head[8:12] == b"WEBP"):
        return "image"
    return None


def sniff(path):
    kind = kind_of(path)
    if kind in (None, "epub"):
        sys.exit(f"{path}: not a CBZ, CBT, PDF, image or folder (EPUB is not read by this tool)")
    return kind


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
    """sidecarPath in lib/src/data/sidecar.dart: beside the comic, hidden."""
    book = os.path.abspath(book).rstrip("/")
    if os.path.isdir(book):
        return os.path.join(book, ".comicredr.crdb")
    return os.path.join(os.path.dirname(book), "." + os.path.basename(book) + ".crdb")


# ---------------------------------------------------------------- the app's index

def index_path():
    """The app's index database on Linux (appDirs in lib/src/data/data_dirs.dart):
    the XDG data folder's when there is one, else ~/Comics/.comicredr's."""
    home = os.path.expanduser("~")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    for name in ("org.snonux.comicredr", "comicredr"):
        f = os.path.join(data_home, name, "comicredr.sqlite")
        if os.path.exists(f):
            return f
    f = os.path.join(home, "Comics", ".comicredr", "comicredr.sqlite")
    return f if os.path.exists(f) else None


class Index:
    """What this tool needs from the app's index, read only: the library
    folders and the "In one folder" sidecar setting. Empty without one."""

    def __init__(self, path=None):
        self.roots, self.sidecar_dir = [], None
        path = path or index_path()
        if not path or not os.path.exists(path):
            return
        try:
            db = read_only(path)
            self.roots = [(i, r) for i, r in db.execute("SELECT id, path FROM roots ORDER BY id")]
            row = db.execute("SELECT value FROM settings WHERE key = 'sidecars.dir'").fetchone()
            self.sidecar_dir = row[0] if row and row[0] else None
            db.close()
        except sqlite3.Error as e:
            print(f"(could not read the app's index {path}: {e})", file=sys.stderr)

    def sidecar(self, book):
        """Where the app keeps [book]'s sidecar: storedSidecarPath with a
        sidecar folder, else beside the comic."""
        book = os.path.abspath(book).rstrip("/")
        if not self.sidecar_dir:
            return sidecar_path(book)
        inside = [(i, r) for i, r in self.roots if book == r or book.startswith(r.rstrip("/") + "/")]
        if not inside:
            at = os.path.join(self.sidecar_dir, "elsewhere", book.lstrip("/"))
        else:
            i, r = max(inside, key=lambda ir: len(ir[1]))
            name = os.path.basename(os.path.normpath(r)) or "root"
            if sum(1 for _, o in self.roots if (os.path.basename(os.path.normpath(o)) or "root") == name) > 1:
                name = f"{name}-{i}"
            rel = os.path.relpath(book, r)
            at = os.path.join(self.sidecar_dir, name) if rel == "." else os.path.join(self.sidecar_dir, name, rel)
        if os.path.isdir(book):
            return os.path.join(at, ".comicredr.crdb")
        return os.path.join(os.path.dirname(at), "." + os.path.basename(at) + ".crdb")


def sidecar_of(book, a):
    return a.sidecar or Index(getattr(a, "index", None)).sidecar(book)


def read_only(path):
    """Opens a database read-only. The path is percent-encoded for the URI:
    a raw "#" or "?" in a comic's name (Khulan_#1.cbz) cut the path short,
    so sqlite opened, and made, an empty file named up to it."""
    return sqlite3.connect(f"file:{urllib.parse.quote(os.path.abspath(path))}?mode=ro", uri=True)


def done_pages(sidecar, key):
    """Pages (from 1) the sidecar has imported panels for, and the record of
    the runs; nothing when the sidecar is missing or another comic's."""
    if not os.path.exists(sidecar):
        return set(), []
    try:
        db = read_only(sidecar)
        have = db.execute("SELECT content_key FROM meta LIMIT 1").fetchone()
        if not have or have[0] != key:
            db.close()
            return set(), []
        done = {p + 1 for (p,) in db.execute("SELECT page FROM analysed_pages WHERE source = ?", (SOURCE,))}
        row = db.execute("SELECT value FROM overrides WHERE field = ?", (RECORD_FIELD,)).fetchone()
        db.close()
    except sqlite3.Error:
        return set(), []
    return done, read_record(row[0] if row else None)


def read_record(raw):
    """The runs in an overrides row of RECORD_FIELD (a MetaEdit whose value
    is JSON), or [] for none, an undone one or one that does not read."""
    try:
        edit = json.loads(raw) if raw else None
        if not edit or edit.get("fromFile") or not edit.get("value"):
            return []
        return list(json.loads(edit["value"]).get("runs", []))
    except (ValueError, AttributeError, TypeError):
        return []


def page_ranges(pages):
    """[1, 2, 3, 5] as "1-3, 5"."""
    out, run = [], []
    for n in sorted(pages):
        if run and n != run[-1] + 1:
            out.append(run)
            run = []
        run.append(n)
    if run:
        out.append(run)
    return ", ".join(str(r[0]) if len(r) == 1 else f"{r[0]}-{r[-1]}" for r in out)


def parse_ranges(text, count):
    pages = set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        lo, _, hi = part.partition("-")
        lo, hi = int(lo), int(hi or lo)
        if not 1 <= lo <= hi <= count:
            sys.exit(f"--pages {text}: the comic has pages 1 to {count}")
        pages.update(range(lo, hi + 1))
    return pages


# ---------------------------------------------------------------- the library

COMIC_KINDS = {"zip", "pdf", "tar", "epub"}


def find_books(roots):
    """The comics under [roots] as the library finds them (findBooks in
    comic_formats): comic files by their first bytes, folder books (page
    images and no comic file anywhere under them), loose PNG/JPEG/WebP files
    as one-page comics; dot folders skipped, each real folder once."""
    seen, out = set(), []

    def has_comic(d):
        for sub, dirs, files in os.walk(d, followlinks=True):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            if any(not f.startswith(".") and kind_of(os.path.join(sub, f)) in COMIC_KINDS for f in files):
                return True
        return False

    def walk(d):
        real = os.path.realpath(d)
        if real in seen:
            return
        seen.add(real)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            return
        files = [n for n in names if not n.startswith(".") and os.path.isfile(os.path.join(d, n))]
        if any(is_page_entry(f) for f in files) and not has_comic(d):
            out.append((d, "folder"))
            return
        for n in names:
            if n.startswith("."):
                continue
            path = os.path.join(d, n)
            if os.path.isdir(path):
                walk(path)
            elif os.path.isfile(path):
                kind = kind_of(path)
                if kind in COMIC_KINDS or kind == "image":
                    out.append((path, kind))

    for r in roots:
        if os.path.isdir(r):
            walk(os.path.abspath(r))
        elif os.path.isfile(r):
            out.append((os.path.abspath(r), kind_of(r)))
    return out


def cmd_library(a):
    index = Index(a.index)
    roots = a.paths or [r for _, r in index.roots] or [os.path.expanduser("~/Comics")]
    books = find_books(roots)
    print(f"Looking in {', '.join(roots)}" + (f"; sidecars in {index.sidecar_dir}" if index.sidecar_dir else ""))
    total = todo = 0
    for path, kind in books:
        if kind == "epub" or kind is None:
            if not a.todo:
                print(f"  -      {path}  (EPUB: not read by this tool)")
            continue
        try:
            count = page_count(path)
            key = content_key(path)
        except Exception as e:  # A broken file: say so and go on.
            print(f"  ?      {path}  (could not read it: {e})")
            continue
        done, runs = done_pages(index.sidecar(path), key)
        left = count - len(done & set(range(1, count + 1)))
        total += count
        todo += left
        if a.todo and left == 0:
            continue
        by = f"  by {runs[-1].get('harness')} ({runs[-1].get('model')})" if runs else ""
        state = "done" if left == 0 else f"{count - left}/{count}"
        print(f"  {state:>7}  {path}{by}")
    print(f"{len(books)} comics, {total} pages, {todo} pages not done")


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
    count = page_count(a.book)
    wanted = parse_ranges(a.pages, count) if a.pages else set(range(1, count + 1))
    if not a.all:
        wanted -= done_pages(sidecar_of(a.book, a), content_key(a.book))[0]
    if a.batch:
        wanted = set(sorted(wanted)[:a.batch])
    for old in work.glob("page-*.jpg"):  # Pages of an earlier batch would be marked up again.
        old.unlink()
    if not wanted:
        (work / "PROMPT.md").unlink(missing_ok=True)
        print("Every page asked for is done already (--all draws them again)")
        return
    for n, img in enumerate(pages(a.book), 1):
        if n in wanted:
            draw_grid(scaled(img)).save(work / f"page-{n:03d}.jpg", quality=85)
    prompt = PROMPT.replace("{tool}", os.path.abspath(__file__)).replace("{book}", _quote(os.path.abspath(a.book)))
    prompt = prompt.replace("{work}", ".").replace("{todo}", page_ranges(wanted))
    (work / "PROMPT.md").write_text(prompt)
    print(f"{len(wanted)} of {count} pages ({page_ranges(wanted)}) in {work}/, the prompt in {work}/PROMPT.md")


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
    if not found:
        sys.exit("panels.json has no pages")
    key = content_key(book)
    path = sidecar_of(book, a)
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
        record(db, now, {"harness": a.harness, "model": a.model, "prompt": PROMPT_VERSION,
                         "pages": page_ranges(found), "at": now})
    db.close()
    os.replace(tmp, path)
    print(f"{len(found)} page{'s' if len(found) != 1 else ''} of panels written to {path}")


def record(db, now, run):
    """Adds [run] to the sidecar's record of imports: an overrides row, as the
    app's completed mark is, so the app keeps it, it travels with the
    sidecar, and the later record wins when two copies meet."""
    row = db.execute("SELECT value FROM overrides WHERE field = ?", (RECORD_FIELD,)).fetchone()
    runs = (read_record(row[0] if row else None) + [run])[-RECORD_RUNS:]
    value = json.dumps({"runs": runs}, separators=(",", ":"))
    db.execute("INSERT OR REPLACE INTO overrides VALUES (?, ?)",
               (RECORD_FIELD, json.dumps({"value": value, "at": now}, separators=(",", ":"))))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("library", help="list the comics and how many of their pages are done")
    p.add_argument("paths", nargs="*", help="folders or comics; the app's library folders, else ~/Comics")
    p.add_argument("--todo", action="store_true", help="only comics with pages not done")
    p.add_argument("--index", help="the app's comicredr.sqlite, when it is not in the usual place")
    p.set_defaults(run=cmd_library)
    p = sub.add_parser("pages", help="write the pages not done yet with a percent grid, and the prompt")
    p.add_argument("book")
    p.add_argument("work")
    p.add_argument("--pages", help="only these pages, e.g. 1-10 or 3,5,7-9")
    p.add_argument("--all", action="store_true", help="done pages too")
    p.add_argument("--batch", type=int, help="only the first N of the pages left")
    p.add_argument("--sidecar", help="the sidecar, when it is not where the app keeps it")
    p.add_argument("--index", help="the app's comicredr.sqlite, when it is not in the usual place")
    p.set_defaults(run=cmd_pages)
    p = sub.add_parser("check", help="draw WORK/panels.json on the pages, into WORK/check/")
    p.add_argument("book")
    p.add_argument("work")
    p.set_defaults(run=cmd_check)
    p = sub.add_parser("import", help="write panels.json into the comic's sidecar")
    p.add_argument("book")
    p.add_argument("panels")
    p.add_argument("--harness", required=True, help='what drew them, e.g. "Claude Code" or Codex')
    p.add_argument("--model", required=True, help="the model's name, e.g. claude-opus-5-5")
    p.add_argument("--sidecar", help="the sidecar to write, when it is not where the app keeps it")
    p.add_argument("--index", help="the app's comicredr.sqlite, when it is not in the usual place")
    p.set_defaults(run=cmd_import)
    a = ap.parse_args()
    try:
        a.run(a)
    except ValueError as e:
        sys.exit(f"panels.json: {e}")


if __name__ == "__main__":
    main()
