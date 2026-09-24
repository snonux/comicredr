#!/usr/bin/env python3
"""Fine-tune the panel and balloon detector for western comics, on CPU (M5).

  python3 spike/train.py PAGES_DIR [PAGES_DIR ...] --out spike/out/train \
      [--weights test/corpus/models/best.pt] [--epochs 40] [--imgsz 800]

Every page image with a label (<page>.json from spike/labelkit.py) becomes a
training sample. A tenth of the pages, chosen by a fixed hash of the name,
is held out for validation during training; the eval set proper is a
separate corpus (spike/evaluate.py) that training never sees.

The starting point is the ShadowB Manga109 YOLO26s-seg checkpoint, loaded
into the same network with a plain detection head: guided view needs boxes,
not masks. The head keeps its three classes so every pretrained weight
carries over; western labels map panel -> frame, speech balloon -> balloon
and narration caption -> the checkpoint's text class, renamed caption. The
app stops only on balloons, so narration no longer passes for speech.

CPU only (design plan section 9). On 4 cores an epoch over ~200 pages at
800 px takes a few minutes; the backbone is frozen for speed, which is
usually enough when adapting a pretrained detector.
"""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

import cv2

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}
# The checkpoint's own class order, so its class head carries over unchanged.
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


def detection_cfg(name, out):
    """The stock YOLO26 config at this scale with the checkpoint's 3 classes."""
    import yaml
    from ultralytics.utils import ROOT

    scale = re.match(r"yolo26([nslmx])", name).group(1)
    cfg = yaml.safe_load((ROOT / "cfg" / "models" / "26" / "yolo26.yaml").read_text())
    cfg.update(nc=len(CLASSES), scale=scale)
    path = out / f"yolo26{scale}-comics.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(cfg, sort_keys=False))
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pages", nargs="+")
    ap.add_argument("--out", default="spike/out/train")
    ap.add_argument("--weights", default="test/corpus/models/best.pt")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--imgsz", type=int, default=800)
    ap.add_argument("--freeze", type=int, default=10, help="backbone layers to freeze")
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--model", default="yolo26s.yaml")
    a = ap.parse_args()

    from ultralytics import YOLO

    out = Path(a.out)
    counts = build_dataset(a.pages, out / "dataset")
    print(f"dataset: {counts['train']} train, {counts['val']} val pages")

    # A detection network of the same size and class count, initialised from
    # the seg checkpoint: backbone, neck and the box/class branches of the head
    # all transfer; only the mask branch is left behind.
    model = YOLO(str(detection_cfg(a.model, out))).load(a.weights)
    model.train(
        data=str(out / "dataset" / "data.yaml"),
        epochs=a.epochs, imgsz=a.imgsz, batch=a.batch, device="cpu", workers=2,
        freeze=a.freeze, project=str(out.resolve()), name="run", exist_ok=True,
        # Comics are not photos: no left-right flips (reading order), no mosaics
        # of four pages, mild colour jitter for yellowed scans.
        fliplr=0.0, mosaic=0.0, hsv_h=0.01, hsv_s=0.4, hsv_v=0.3, scale=0.25, translate=0.05,
        patience=15, plots=False, verbose=False,
    )
    best = out / "run" / "weights" / "best.pt"
    print(f"best weights: {best}")


if __name__ == "__main__":
    main()
