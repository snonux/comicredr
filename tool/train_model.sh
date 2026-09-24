#!/usr/bin/env bash
# Rebuilds the detector model, comicredr-panels.onnx, from scratch on the
# CPU: fetches the free training comics (test/train.manifest.toml) and the
# ShadowB Manga109 checkpoint it starts from, extracts the pages the
# committed labels in spike/labels/train/ belong to, fine-tunes and exports
# the float ONNX model. `make train-model` runs this, then `make model`.
#
#   tool/train_model.sh            # 45 epochs, as the shipped model
#   EPOCHS=1 tool/train_model.sh   # a quick check that the pipeline runs
#
# Needs python3 with the packages below and the network (archive.org,
# peppercarrot.com, huggingface.co). Downloads and pages go to git-ignored
# test/corpus-train/, test/corpus/models/ and spike/; nothing is committed.
# Output: spike/out/comicredr-panels.onnx.
set -euo pipefail
cd "$(dirname "$0")/.."

EPOCHS="${EPOCHS:-45}"
OUT="${OUT:-spike/out}"
PIP="opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics onnx onnxruntime onnxslim"

if ! python3 -c "import cv2, numpy, PIL, pypdfium2, huggingface_hub, ultralytics, onnx, onnxruntime, onnxslim" 2>/dev/null; then
  echo "Missing Python packages. Install them once with:"
  echo "  python3 -m pip install --user $PIP"
  exit 1
fi

echo "== Fetching the ShadowB base model"
python3 spike/fetch_corpus.py --skip-books
echo "== Fetching the training comics"
# archive.org sometimes answers 500; a retry fetches only what is missing.
for try in 1 2 3; do
  python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train --skip-model && break
  [[ $try == 3 ]] && { echo "Some comics could not be fetched; run make train-model again later."; exit 1; }
  echo "Retrying the ones that failed in 30 s"; sleep 30
done
echo "== Extracting the labelled pages"
python3 spike/extract_pages.py test/corpus-train spike/train_pages --per-book 400 --manifest test/train.manifest.toml
python3 spike/labelkit.py import spike/labels/train spike/train_pages
echo "== Training for $EPOCHS epochs (about 2.5 minutes an epoch on 4 cores)"
rm -rf "$OUT/train"
python3 spike/train.py spike/train_pages --out "$OUT/train" --epochs "$EPOCHS" --weights test/corpus/models/best.pt
echo "== Exporting to ONNX"
python3 spike/export_onnx.py "$OUT/train/run/weights/best.pt" --out "$OUT/comicredr-panels.onnx"
echo "Model in $OUT/comicredr-panels.onnx"
