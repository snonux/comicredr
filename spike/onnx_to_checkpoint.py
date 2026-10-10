#!/usr/bin/env python3
"""Turn a D-FINE-S ONNX file made by spike/train.py --export back into a
checkpoint that spike/train.py --weights can train further.

  python3 spike/onnx_to_checkpoint.py assets/models/comicredr-panels.onnx RUN_DIR/last \
      --pages spike/train_pages spike/synth_pages

Use it when the checkpoint of the run that made a model is lost: the ONNX
file holds every weight the model uses to find panels, so a run can go on
from the shipped model itself.

How: the same architecture is exported once with a unique random value in
every weight, which shows which ONNX tensor each weight became (a batch
norm folded into the convolution before it, a linear layer's matrix
transposed, `up` and `reg_scale` folded into constants). The model's own
tensors are then put back in those places, each folded batch norm as an
identity norm after its convolution. Exported again, the result must give
the same tensors as the file it came from, or nothing is written.

Two things the export leaves out are made up, and training settles them
in its first steps: the class and quality heads of decoder layers 0 and 1,
which only the training losses read (copied from layer 2, which the export
has), and the denoising label embedding (as the COCO start has it). The
trainable batch norms get running statistics measured on --pages, so that
in training they act as they did when the model was made.
"""
import argparse
import json
import random
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
import onnx
import torch
from onnx import numpy_helper

sys.path.insert(0, str(Path(__file__).parent))
from dataset import CLASSES  # noqa: E402
from train import export, letterbox  # noqa: E402

BASE = "ustc-community/dfine-small-coco"


def tensors(path):
    return {t.name: numpy_helper.to_array(t) for t in onnx.load(str(path)).graph.initializer}


def export_to(model, folder, imgsz):
    """ONNX tensors of [model], exported exactly as spike/train.py --export does."""
    model.save_pretrained(folder)
    (folder / "comicredr.json").write_text(json.dumps({"imgsz": imgsz}))
    onnx_path = folder / "model.onnx"
    export(argparse.Namespace(export=str(folder), out_onnx=str(onnx_path), imgsz=imgsz))
    return tensors(onnx_path)


def norms(model):
    return {n: m for n, m in model.named_modules() if hasattr(m, "running_mean") and hasattr(m, "running_var")}


def mark(model):
    """Every weight random and unique; every batch norm the identity with a random bias."""
    torch.manual_seed(1)
    bns = norms(model)
    params = dict(model.named_parameters())
    sd = model.state_dict()
    for k, v in sd.items():
        pre, _, leaf = k.rpartition(".")
        if pre in bns and leaf in ("weight", "running_mean", "running_var"):
            sd[k] = torch.ones_like(v) if leaf == "weight" else torch.zeros_like(v) if leaf == "running_mean" \
                else torch.full_like(v, 1 - getattr(bns[pre], "eps", 1e-5))
        elif pre in bns and leaf == "bias":
            sd[k] = torch.randn_like(v)
        elif k in params and v.is_floating_point():
            sd[k] = torch.randn_like(v)
    model.load_state_dict(sd)


def where_weights_go(marked_model, marked):
    """ONNX tensor name -> (state dict key, transposed) for every weight found."""
    sd = {k: v.detach().numpy() for k, v in marked_model.state_dict().items() if v.is_floating_point()}
    by_size = {}
    for k, v in sd.items():
        by_size.setdefault(v.size, []).append(k)
    found = {}
    for name, t in marked.items():
        for k in by_size.get(t.size, []):
            v = sd[k]
            if np.allclose(v.reshape(t.shape), t, rtol=1e-4, atol=1e-6):
                found[name] = (k, False)
                break
            if v.ndim == 2 and v.T.shape == t.shape and np.allclose(v.T, t, rtol=1e-4, atol=1e-6):
                found[name] = (k, True)
                break
    return found


def put_back(model, places, source):
    """The source's tensors into the model; folded batch norms become identities."""
    sd = model.state_dict()
    for name, (k, transposed) in places.items():
        t = source[name].T if transposed else source[name]
        sd[k] = torch.from_numpy(np.array(t, copy=True)).reshape(sd[k].shape).to(sd[k].dtype)
    for pre, m in norms(model).items():
        sd[pre + ".weight"] = torch.ones_like(sd[pre + ".weight"])
        sd[pre + ".running_mean"] = torch.zeros_like(sd[pre + ".running_mean"])
        sd[pre + ".running_var"] = torch.full_like(sd[pre + ".running_var"], 1 - getattr(m, "eps", 1e-5))
    # Trained, and folded into constants by the export: |reg_scale| is
    # Abs_1, and the integral's first bin is -2 |up| |reg_scale|.
    reg = float(source["/model/model/decoder/Abs_1_output_0"][0])
    up = float(-source["/model/model/decoder/integral/Identity_output_0"][0] / 2 / reg)
    sd["model.decoder.reg_scale"] = torch.tensor([reg])
    sd["model.decoder.up"] = torch.tensor([up])
    last = model.config.decoder_layers
    for k in list(sd):
        for head in ("model.decoder.class_embed.", "model.decoder.lqe_layers."):
            if k.startswith(head):
                i, _, rest = k[len(head):].partition(".")
                if int(i) < last - 1:
                    sd[k] = sd[f"{head}{last - 1}.{rest}"].clone()
    model.load_state_dict(sd)


def calibrate(model, folders, imgsz, count=300):
    """Running statistics for the trainable batch norms from the pages, set
    so the model's output stays what it was: weight sqrt(var + eps), bias
    the folded bias plus the mean."""
    live = {n: m for n, m in norms(model).items() if type(m) is torch.nn.BatchNorm2d}
    sums = {n: [0, 0, 0] for n in live}

    def hook(name):
        def f(_, inputs):
            x = inputs[0].detach().double()
            s = sums[name]
            s[0], s[1], s[2] = s[0] + x.mean((0, 2, 3)), s[1] + (x * x).mean((0, 2, 3)), s[2] + 1
        return f

    hooks = [m.register_forward_pre_hook(hook(n)) for n, m in live.items()]
    pages = sorted(p for d in folders for p in Path(d).rglob("*.jpg") if p.with_suffix(".json").exists())
    random.Random(0).shuffle(pages)
    model.eval()
    with torch.no_grad():
        for p in pages[:count]:
            canvas, _, _ = letterbox(cv2.imread(str(p)), imgsz)
            model(pixel_values=torch.from_numpy(canvas[:, :, ::-1].copy()).permute(2, 0, 1).float()[None] / 255)
    for h in hooks:
        h.remove()
    for n, m in live.items():
        s, s2, k = sums[n]
        mean = (s / k).float()
        var = (s2 / k - (s / k) ** 2).clamp_min(1e-6).float()
        with torch.no_grad():
            m.running_mean.copy_(mean)
            m.running_var.copy_(var)
            m.bias.add_(mean)
            m.weight.copy_(torch.sqrt(var + m.eps))
    return len(live), min(count, len(pages))


def main():
    from transformers import DFineForObjectDetection

    ap = argparse.ArgumentParser()
    ap.add_argument("onnx", help="a model made by spike/train.py --export")
    ap.add_argument("out", help="the checkpoint folder to write, e.g. RUN_DIR/last")
    ap.add_argument("--pages", nargs="+", required=True, help="labelled page folders for the batch norm statistics")
    ap.add_argument("--imgsz", type=int, default=640, help="the size it was trained at (640 for the shipped model)")
    ap.add_argument("--base", default=BASE, help="the checkpoint it was trained from, for the architecture")
    a = ap.parse_args()
    names = dict(enumerate(CLASSES))

    def fresh():
        return DFineForObjectDetection.from_pretrained(
            a.base, num_labels=len(CLASSES), id2label=names, label2id={v: k for k, v in names.items()},
            ignore_mismatched_sizes=True)

    source = tensors(a.onnx)
    with tempfile.TemporaryDirectory() as tmp:
        marked_model = fresh()
        mark(marked_model)
        marked = export_to(marked_model, Path(tmp) / "marked", a.imgsz)
        if set(marked) != set(source):
            sys.exit(f"{a.onnx} is not an export of {a.base} by spike/train.py: its tensors differ")
        places = where_weights_go(marked_model, marked)
        model = fresh()
        put_back(model, places, source)
        bns, pages = calibrate(model, a.pages, a.imgsz)
        again = export_to(model, Path(tmp) / "again", a.imgsz)
    worst = max(float(np.abs(again[n].astype(np.float64) - source[n]).max()) for n in source)
    print(f"{len(places)} of {len(source)} ONNX tensors are weights; {bns} batch norms measured on {pages} pages; "
          f"largest difference after a new export {worst:.2g}")
    if worst > 1e-4:
        sys.exit("the rebuilt checkpoint does not give the same model; nothing written")
    out = Path(a.out)
    model.save_pretrained(out)
    (out / "comicredr.json").write_text(json.dumps({"imgsz": a.imgsz, "from_onnx": str(a.onnx)}))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
