#!/usr/bin/env python3
"""Pull a sample of pages out of the fetched corpus for the spike.

  python3 spike/extract_pages.py test/corpus spike/pages [--per-book 12]

Opens every CBZ/ZIP (natural-sorted image entries, junk skipped) and PDF
(rendered at 1600 px on the long side) and writes an evenly spaced sample of
pages, skipping the cover, as <book>__p<NNN>.jpg.
"""
import argparse
import io
import re
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("out")
    ap.add_argument("--per-book", type=int, default=12)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for p in sorted(Path(a.corpus).rglob("*")):
        try:
            if p.suffix.lower() in (".cbz", ".zip", ".cbr") and zipfile.is_zipfile(p):
                n = from_zip(p, out, a.per_book)
            elif p.suffix.lower() == ".pdf":
                n = from_pdf(p, out, a.per_book)
            else:
                continue
            print(f"{p.name}: {n} pages")
        except Exception as e:
            print(f"skipped {p.name}: {e}")


if __name__ == "__main__":
    main()
