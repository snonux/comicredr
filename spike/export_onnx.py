#!/usr/bin/env python3
"""Export the trained detector to ONNX for the app, optionally INT8 (M5).

  python3 spike/export_onnx.py best.pt --out comicredr-panels.onnx [--imgsz 800] \
      [--int8 CALIBRATION_PAGES_DIR]

The graph takes one float32 image [1, 3, S, S] (RGB, 0..1, letterboxed to
the top-left, grey 114 padding) and returns [1, 300, 6]: x0, y0, x1, y1 in
input pixels, score, class. YOLO26 is NMS-free, so there is no suppression
step to reimplement in Dart. Opset 17 keeps it loadable by the ONNX Runtime
1.15 that the `onnxruntime` Dart package bundles.

--int8 adds static QDQ quantisation calibrated on real pages (per-channel
weights, activations from ~50 pages), written beside the float model as
<out>.int8.onnx. spike/evaluate.py scores either file.
"""
import argparse
import shutil
from pathlib import Path

import cv2
import numpy as np

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp"}


def letterbox(img, size):
    h, w = img.shape[:2]
    s = size / max(h, w)
    nw, nh = round(w * s), round(h * s)
    canvas = np.full((size, size, 3), 114, np.uint8)
    canvas[:nh, :nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    return canvas[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255


def quantise(src, dest, pages, size, n=50):
    from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static
    from onnxruntime.quantization.shape_inference import quant_pre_process

    files = sorted(p for p in Path(pages).rglob("*") if p.suffix.lower() in IMAGE_EXT
                   and not any(t in p.name for t in (".cv.", ".yolo.", ".show.", ".check.")))
    files = files[:: max(1, len(files) // n)][:n]

    class Reader(CalibrationDataReader):
        def __init__(self):
            self.it = iter(files)

        def get_next(self):
            p = next(self.it, None)
            return None if p is None else {"images": letterbox(cv2.imread(str(p)), size)}

    pre = dest.with_suffix(".pre.onnx")
    quant_pre_process(str(src), str(pre))
    # Leave the head's final box and class convolutions in float: boxes need
    # the precision, and they are a sliver of the compute.
    import onnx
    g = onnx.load(str(pre)).graph
    head = [nd.name for nd in g.node if nd.op_type == "Conv" and "/model.23/" in nd.name
            and ("cv2" in nd.name or "cv3" in nd.name) and nd.name.endswith(("2/Conv",))]
    quantize_static(str(pre), str(dest), Reader(), quant_format=QuantFormat.QDQ, per_channel=True,
                    weight_type=QuantType.QInt8, activation_type=QuantType.QUInt8, nodes_to_exclude=head,
                    # Only the convolutions: the top-k decode after the head stays float.
                    op_types_to_quantize=["Conv"])
    pre.unlink()
    # Newer quantisation tooling stamps opset imports that ONNX Runtime 1.15
    # refuses; keep only the domains the graph actually uses, at versions 1.15 knows.
    m = onnx.load(str(dest))
    used = {nd.domain or "" for nd in m.graph.node}
    keep = [o for o in m.opset_import if (o.domain or "") in used or o.domain in ("", "ai.onnx")]
    del m.opset_import[:]
    m.opset_import.extend(keep)
    onnx.save(m, str(dest))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights")
    ap.add_argument("--out", required=True)
    ap.add_argument("--imgsz", type=int, default=800)
    ap.add_argument("--int8", metavar="PAGES")
    a = ap.parse_args()
    from ultralytics import YOLO

    model = YOLO(a.weights)
    path = Path(model.export(format="onnx", imgsz=a.imgsz, opset=17, simplify=True, dynamic=False, device="cpu",
                             nms=False))  # nms=False keeps the NMS-free end-to-end head
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(path, out)
    print(f"float: {out} ({out.stat().st_size / 1e6:.1f} MB)")
    if a.int8:
        q = out.with_suffix(".int8.onnx")
        quantise(out, q, a.int8, a.imgsz)
        print(f"int8:  {q} ({q.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
