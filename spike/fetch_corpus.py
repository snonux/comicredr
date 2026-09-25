#!/usr/bin/env python3
"""Fetch the M1 spike corpus and the pretrained detector.

  python3 spike/fetch_corpus.py [--manifest test/corpus.manifest.toml] [--out test/corpus]

Reads the manifest (design plan section 10) and downloads into the
git-ignored test/corpus/. Two kinds of entry:

  [[book]]    a fixed url, with sha256 once pinned
  [[search]]  an Internet Archive query; the first `count` items that carry
              a file matching `formats` are downloaded. Their urls and
              sha256 are printed so they can be pinned as [[book]] entries.

With --manga109-model it also downloads the pretrained panel/balloon/text
model named by [model] into test/corpus/models/, for comparisons only: it
was trained on Manga109 (academic use only) and nothing the app ships
starts from it any more. Nothing fetched here is ever committed.
"""
import argparse
import hashlib
import json
import sys
import tomllib
import urllib.parse
import urllib.request
from pathlib import Path

UA = {"User-Agent": "comicredr-spike/0.1 (personal test corpus)"}


def get(url, timeout=120):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout)


def download(url, dest: Path, sha256=None):
    if dest.exists() and (not sha256 or _sha(dest) == sha256):
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with get(url, timeout=600) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    if sha256 and _sha(tmp) != sha256:
        tmp.unlink()
        raise ValueError(f"sha256 mismatch for {url}")
    tmp.rename(dest)
    return dest


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def ia_search(query, count, formats, max_mb):
    """Yield (identifier, filename, size) for the first `count` matching items."""
    q = urllib.parse.urlencode({"q": query, "fl[]": "identifier", "rows": count * 4, "output": "json"})
    with get(f"https://archive.org/advancedsearch.php?{q}") as r:
        docs = json.load(r)["response"]["docs"]
    found = 0
    for d in docs:
        ident = d["identifier"]
        with get(f"https://archive.org/metadata/{ident}") as r:
            files = json.load(r).get("files", [])
        for f in files:
            name, size = f["name"], int(f.get("size", 0) or 0)
            if any(name.lower().endswith(ext) for ext in formats) and size <= max_mb * 1e6:
                yield ident, name, size
                found += 1
                break
        if found >= count:
            return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="test/corpus.manifest.toml")
    ap.add_argument("--out", default="test/corpus")
    ap.add_argument("--manga109-model", action="store_true",
                    help="also fetch the Manga109 model in [model], for comparisons")
    ap.add_argument("--skip-model", action="store_true", help="the default; kept for old scripts")
    ap.add_argument("--skip-books", action="store_true", help="only the pretrained model")
    a = ap.parse_args()
    m = tomllib.loads(Path(a.manifest).read_text())
    out = Path(a.out)
    failures = 0

    for b in [] if a.skip_books else m.get("book", []):
        dest = out / b["name"]
        try:
            download(b["url"], dest, b.get("sha256") or None)
            print(f"ok      {b['name']}  sha256={_sha(dest)}")
        except Exception as e:  # keep going: one dead link must not stop the corpus
            failures += 1
            print(f"FAILED  {b['name']}: {e}", file=sys.stderr)

    for s in [] if a.skip_books else m.get("search", []):
        try:
            for ident, name, size in ia_search(s["query"], s["count"], s["formats"], s.get("max_mb", 200)):
                url = f"https://archive.org/download/{ident}/{urllib.parse.quote(name)}"
                dest = out / s["group"] / f"{ident}{Path(name).suffix.lower()}"
                download(url, dest)
                print(f"ok      {dest.relative_to(out)}  ({size / 1e6:.0f} MB)\n        url={url}\n        sha256={_sha(dest)}")
        except Exception as e:
            failures += 1
            print(f"FAILED  search {s['group']!r}: {e}", file=sys.stderr)

    model = m.get("model")
    if model and a.manga109_model and not a.skip_model:
        try:
            from huggingface_hub import hf_hub_download, list_repo_files
            files = [f for f in list_repo_files(model["repo"]) if f.endswith((".pt", ".onnx"))]
            print(f"model files: {files}")
            for f in files:
                p = hf_hub_download(model["repo"], f, local_dir=out / "models")
                print(f"ok      model {p}")
        except Exception as e:
            failures += 1
            print(f"FAILED  model {model['repo']}: {e}", file=sys.stderr)

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
