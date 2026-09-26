#!/usr/bin/env python3
"""Train the panel, caption and balloon detector the app ships, on CPU.

  python3 spike/train.py PAGES_DIR [PAGES_DIR ...] --out spike/out/train \
      [--weights ustc-community/dfine-small-coco] [--epochs 30] [--imgsz 800]
  python3 spike/train.py --export spike/out/train/best --out-onnx comicredr-panels.onnx

The model is D-FINE-S (Apache-2.0 code and weights), fine-tuned from its
COCO-only checkpoint through the Hugging Face transformers port. Never
start from the Objects365 checkpoints (their data is academic-use only) or
from anything trained on Manga109: the result is published inside the app.

Samples, held-out split and classes (frame, caption, balloon) come from
spike/dataset.py. --export writes the ONNX graph with the app's interface:
one float32 image [1, 3, 800, 800] (RGB 0..1, letterboxed to the top-left,
grey 114 padding) in, [1, 300, 6] out (x0, y0, x1, y1 in input pixels,
score, class). The graph resizes to the model's own size inside when
--imgsz is not 800. Needs torch, transformers (>= 4.52) and onnxslim.
"""
import argparse
import json
import math
import random
import sys
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).parent))
from dataset import CLASSES, build_dataset  # noqa: E402

APP_INPUT = 800


def letterbox(img, size, scale=1.0):
    """Page scaled so its long side is [scale] * [size], top-left on grey 114."""
    h, w = img.shape[:2]
    s = size * scale / max(h, w)
    nw, nh = max(1, round(w * s)), max(1, round(h * s))
    canvas = np.full((size, size, 3), 114, np.uint8)
    canvas[:nh, :nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)
    return canvas, nw / size, nh / size


class Pages(torch.utils.data.Dataset):
    def __init__(self, root, split, size, train):
        self.images = sorted((root / "images" / split).glob("*.jpg"))
        self.root, self.split, self.size, self.train = root, split, size, train

    def __len__(self):
        return len(self.images)

    def __getitem__(self, i):
        p = self.images[i]
        img = cv2.imread(str(p))
        rows = [r.split() for r in (self.root / "labels" / self.split / f"{p.stem}.txt").read_text().splitlines() if r]
        scale = random.uniform(0.7, 1.0) if self.train else 1.0
        if self.train:
            # Yellowed and faded scans: brightness, contrast and a little saturation.
            img = cv2.convertScaleAbs(img, alpha=random.uniform(0.8, 1.2), beta=random.uniform(-25, 25))
            if random.random() < 0.3:
                hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
                hsv[..., 1] *= random.uniform(0.5, 1.3)
                img = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
        canvas, sx, sy = letterbox(img, self.size, scale)
        x = torch.from_numpy(canvas[:, :, ::-1].copy()).permute(2, 0, 1).float() / 255
        cls = torch.tensor([int(r[0]) for r in rows], dtype=torch.long)
        boxes = torch.tensor([[float(r[1]) * sx, float(r[2]) * sy, float(r[3]) * sx, float(r[4]) * sy] for r in rows],
                             dtype=torch.float32).reshape(-1, 4)
        return x, {"class_labels": cls, "boxes": boxes}


def collate(batch):
    return torch.stack([b[0] for b in batch]), [b[1] for b in batch]


def train(a):
    from transformers import DFineForObjectDetection

    torch.set_num_threads(a.threads)
    random.seed(0)
    torch.manual_seed(0)
    out = Path(a.out)
    counts = build_dataset(a.pages, out / "dataset")
    print(f"dataset: {counts['train']} train, {counts['val']} val pages", flush=True)
    names = dict(enumerate(CLASSES))
    model = DFineForObjectDetection.from_pretrained(
        a.weights, num_labels=len(CLASSES), id2label=names, label2id={v: k for k, v in names.items()},
        ignore_mismatched_sizes=True)
    data = torch.utils.data.DataLoader(Pages(out / "dataset", "train", a.imgsz, True), batch_size=a.batch,
                                       shuffle=True, num_workers=2, collate_fn=collate, drop_last=True)
    val = torch.utils.data.DataLoader(Pages(out / "dataset", "val", a.imgsz, False), batch_size=a.batch,
                                      num_workers=1, collate_fn=collate)
    backbone = [p for n, p in model.named_parameters() if ".backbone." in n]
    rest = [p for n, p in model.named_parameters() if ".backbone." not in n]
    opt = torch.optim.AdamW([{"params": backbone, "lr": a.lr * 0.5}, {"params": rest, "lr": a.lr}],
                            weight_decay=1e-4)
    steps = a.epochs * len(data)
    warm = min(200, steps // 10)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, steps - warm))) * 0.95 + 0.05)
    ema = torch.optim.swa_utils.AveragedModel(model, multi_avg_fn=torch.optim.swa_utils.get_ema_multi_avg_fn(0.998))
    best = float("inf")
    for epoch in range(a.epochs):
        model.train()
        total = 0.0
        for x, targets in data:
            loss = model(pixel_values=x, labels=targets).loss
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 0.1)
            opt.step()
            sched.step()
            ema.update_parameters(model)
            total += loss.item()
        # Validation loss of the EMA weights, in train mode for the loss terms
        # but without gradients; picks the checkpoint kept as best.
        ema.module.train()
        with torch.no_grad():
            vloss = sum(ema.module(pixel_values=x, labels=t).loss.item() for x, t in val) / max(1, len(val))
        print(f"epoch {epoch + 1}/{a.epochs} train {total / len(data):.3f} val {vloss:.3f}", flush=True)
        save(ema.module, out / "last", a.imgsz)
        if vloss < best:
            best = vloss
            save(ema.module, out / "best", a.imgsz)


def save(model, folder, imgsz):
    model.save_pretrained(folder)
    (folder / "comicredr.json").write_text(json.dumps({"imgsz": imgsz}))


class AppGraph(torch.nn.Module):
    """The app's interface around the model: 800 px letterbox in, [1, 300, 6] out."""

    def __init__(self, model, size, top=300):
        super().__init__()
        self.model, self.size, self.top = model, size, top

    def forward(self, images):
        x = images if self.size == APP_INPUT else F.interpolate(
            images, size=(self.size, self.size), mode="bilinear", align_corners=False, antialias=False)
        o = self.model(pixel_values=x)
        logits, boxes = o.logits, o.pred_boxes  # [1, Q, C], [1, Q, 4] cx, cy, w, h in 0..1
        c = logits.shape[-1]
        scores, idx = logits.sigmoid().flatten(1).topk(self.top, dim=1)
        q, cls = idx // c, idx % c
        b = boxes.gather(1, q.unsqueeze(-1).expand(-1, -1, 4))
        cx, cy, w, h = b.unbind(-1)
        xyxy = torch.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], -1).clamp(0, 1) * APP_INPUT
        return torch.cat([xyxy, scores.unsqueeze(-1), cls.unsqueeze(-1).float()], -1)


def export(a):
    import onnx
    from transformers import DFineForObjectDetection

    model = DFineForObjectDetection.from_pretrained(a.export).eval()
    meta = Path(a.export) / "comicredr.json"
    size = json.loads(meta.read_text())["imgsz"] if meta.exists() else a.imgsz
    graph = AppGraph(model, size).eval()
    dummy = torch.rand(1, 3, APP_INPUT, APP_INPUT)
    torch.onnx.export(graph, dummy, a.out_onnx, input_names=["images"], output_names=["output0"],
                      opset_version=17, dynamo=False)
    # Fold the constant position embeddings (Cos on doubles), which the
    # ONNX Runtime 1.15 in the app has no kernel for.
    import onnxslim
    m = onnxslim.slim(onnx.load(a.out_onnx))
    for k, v in {"names": str(dict(enumerate(CLASSES))), "imgsz": f"[{APP_INPUT}, {APP_INPUT}]",
                 "description": f"ComicRedr panels: D-FINE-S fine-tune ({size} px inside), COCO init, Apache-2.0"}.items():
        m.metadata_props.add(key=k, value=v)
    onnx.save(m, a.out_onnx)
    print(f"wrote {a.out_onnx}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pages", nargs="*")
    ap.add_argument("--out", default="spike/out/train")
    ap.add_argument("--weights", default="ustc-community/dfine-small-coco")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--export", metavar="CHECKPOINT_DIR")
    ap.add_argument("--out-onnx")
    a = ap.parse_args()
    export(a) if a.export else train(a)


if __name__ == "__main__":
    main()
