"""The labelled pages as a training set (spike/train.py).

Every page image with a label (<page>.json from spike/labelkit.py) becomes a
training sample, written in YOLO text format (class cx cy w h, normalised).
A tenth of the pages, chosen by a fixed hash of the name, is held out for
validation during training; the eval sets proper are separate corpora
(spike/evaluate.py) that training never sees.

Classes: frame (a panel), caption (narration) and balloon (speech and
thought). The app steps through frames and balloons and skips captions.
"""
import hashlib
import json
import shutil
from pathlib import Path

import cv2

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}
# The order the app reads the output classes in (model_io.dart).
CLASSES = ["frame", "caption", "balloon"]
KIND_TO_CLASS = {"panels": 0, "captions": 1, "balloons": 2}


def labelled_pages(folders):
    for folder in folders:
        for p in sorted(Path(folder).rglob("*")):
            if p.suffix.lower() in IMAGE_EXT and p.with_suffix(".json").exists() \
                    and not any(t in p.name for t in (".cv.", ".yolo.", ".show.", ".check.")):
                yield p


def is_val(page):
    return int(hashlib.sha1(page.name.encode()).hexdigest(), 16) % 10 == 0


def build_dataset(folders, root):
    if root.exists():
        shutil.rmtree(root)
    counts = {"train": 0, "val": 0}
    for page in labelled_pages(folders):
        split = "val" if is_val(page) else "train"
        lab = json.loads(page.with_suffix(".json").read_text())
        w, h = lab["w"], lab["h"]
        stem = f"{page.parent.name}__{page.stem}"
        (root / "images" / split).mkdir(parents=True, exist_ok=True)
        (root / "labels" / split).mkdir(parents=True, exist_ok=True)
        img = cv2.imread(str(page))
        cv2.imwrite(str(root / "images" / split / f"{stem}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        rows = []
        for kind, cls in KIND_TO_CLASS.items():
            for x, y, bw, bh in lab.get(kind, []):
                if bw <= 0 or bh <= 0:
                    continue
                rows.append(f"{cls} {(x + bw / 2) / w:.6f} {(y + bh / 2) / h:.6f} {bw / w:.6f} {bh / h:.6f}")
        (root / "labels" / split / f"{stem}.txt").write_text("\n".join(rows) + ("\n" if rows else ""))
        counts[split] += 1
    (root / "data.yaml").write_text(
        f"path: {root.resolve()}\ntrain: images/train\nval: images/val\nnames:\n"
        + "".join(f"  {i}: {n}\n" for i, n in enumerate(CLASSES)))
    return counts
