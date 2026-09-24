#!/usr/bin/env python3
"""Pull a sample of pages out of the fetched corpus for the spike.

  python3 spike/extract_pages.py test/corpus spike/pages [--per-book 12]

Opens every CBZ/ZIP (natural-sorted image entries, junk skipped), PDF
(rendered at 1600 px on the long side) and folder of page images, and writes
an evenly spaced sample of pages, skipping the cover, as
<style>/<book>__p<NNN>.jpg. The style comes from the manifest entry the file
was fetched by, so the spike can report results per style.
"""
import argparse
import io
import re
import tomllib
import zipfile
from pathlib import Path

from PIL import Image

IMG = (".jpg", ".jpeg", ".png", ".webp", ".gif")


def natural(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def sample(n, k):
    if n <= 1:
        return list(range(n))
    idx = sorted({1 + round(i * (n - 2) / max(k - 1, 1)) for i in range(k)})
    return [i for i in idx if i < n]


def save(img, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    img = img.convert("RGB")
    s = 1600 / max(img.size)
    if s < 1:
        img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    img.save(dest, quality=88)


def from_zip(path, out, k):
    with zipfile.ZipFile(path) as z:
        names = sorted((n for n in z.namelist()
                        if n.lower().endswith(IMG) and "__MACOSX" not in n and not Path(n).name.startswith(".")),
                       key=natural)
        for i in sample(len(names), k):
            save(Image.open(io.BytesIO(z.read(names[i]))), out / f"{path.name.replace('.', '_')}__p{i:03d}.jpg")
        return len(names)


def from_pdf(path, out, k):
    import pypdfium2 as pdfium
    doc = pdfium.PdfDocument(str(path))
    for i in sample(len(doc), k):
        page = doc[i]
        w, h = page.get_size()
        save(page.render(scale=1600 / max(w, h)).to_pil(), out / f"{path.name.replace('.', '_')}__p{i:03d}.jpg")
    return len(doc)


def from_folder(path, out, k):
    names = sorted((p for p in path.iterdir() if p.suffix.lower() in IMG), key=lambda p: natural(p.name))
    # A folder fetched page by page is already a sample: keep every page.
    for i, p in enumerate(names[:k]):
        save(Image.open(p), out / f"{path.name}__p{i:03d}.jpg")
    return len(names)


def styles(manifest, corpus):
    """Map each fetched book (file, or folder for page-by-page books) to its style."""
    m = tomllib.loads(Path(manifest).read_text()) if Path(manifest).exists() else {}
    out = {}
    for b in m.get("book", []):
        p = corpus / b["name"]
        out[p.parent if p.suffix.lower() in IMG else p] = b.get("style", "unsorted")
    for s in m.get("search", []):
        out[corpus / s["group"]] = s.get("style", "unsorted")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("out")
    ap.add_argument("--per-book", type=int, default=12)
    ap.add_argument("--manifest", default="test/corpus.manifest.toml")
    a = ap.parse_args()
    corpus = Path(a.corpus)
    style_of = styles(a.manifest, corpus)
    for p in sorted(corpus.rglob("*")):
        if "models" in p.relative_to(corpus).parts:
            continue
        style = style_of.get(p) or style_of.get(p.parent, "unsorted")
        out = Path(a.out) / style
        try:
            if p.suffix.lower() in (".cbz", ".zip", ".cbr") and zipfile.is_zipfile(p):
                n = from_zip(p, out, a.per_book)
            elif p.suffix.lower() == ".pdf":
                n = from_pdf(p, out, a.per_book)
            elif p.is_dir() and p in style_of:
                n = from_folder(p, out, a.per_book)
            else:
                continue
            print(f"{style:22s} {p.name}: {n} pages")
        except Exception as e:
            print(f"skipped {p.name}: {e}")


if __name__ == "__main__":
    main()
