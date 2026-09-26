#!/usr/bin/env bash
# Rebuilds the detector model built into the app, comicredr-panels.onnx,
# from scratch on the CPU: fetches the free training comics
# (test/train.manifest.toml: public domain, CC0 and CC BY only), extracts
# the pages the committed labels in spike/labels/train/ belong to,
# fine-tunes D-FINE-S from its COCO checkpoint (Apache-2.0) and exports the
# ONNX model. `make train-model` runs this, then tool/fetch_model.sh puts
# the result in assets/models/.
#
#   tool/train_model.sh            # EPOCHS epochs, as the shipped model
#   EPOCHS=1 tool/train_model.sh   # a quick check that the pipeline runs
#   LOCAL=1 tool/train_model.sh    # also the NC/ND/SA books, for a model
#                                  # kept at home (never committed)
#
# The whole recipe, and how to add books and labels: docs/training.md.
#
# Needs python3 with the packages below and the network (archive.org,
# peppercarrot.com, huggingface.co). Downloads and pages go to git-ignored
# test/corpus-train/ and spike/; nothing is committed.
# Output: spike/out/comicredr-panels.onnx.
set -euo pipefail
cd "$(dirname "$0")/.."

EPOCHS="${EPOCHS:-30}"
IMGSZ="${IMGSZ:-640}"
LOCAL="${LOCAL:-}"
OUT="${OUT:-spike/out}"
[[ -n "$LOCAL" ]] && OUT="$OUT/local"

if ! python3 -c "import cv2, numpy, PIL, pypdfium2, torch, transformers, onnx, onnxruntime, onnxslim" 2>/dev/null; then
  echo "Missing Python packages. Install them once with:"
  echo "  python3 -m pip install --user -r spike/requirements-train.txt"
  exit 1
fi

echo "== Fetching the training comics"
# archive.org sometimes answers 500; a retry fetches only what is missing.
for try in 1 2 3; do
  python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train && break
  [[ $try == 3 ]] && { echo "Some comics could not be fetched; run make train-model again later."; exit 1; }
  echo "Retrying the ones that failed in 30 s"; sleep 30
done
echo "== Extracting the labelled pages"
python3 spike/extract_pages.py test/corpus-train spike/train_pages --per-book 400 --manifest test/train.manifest.toml
# Only the committed labels: a label left from an earlier set would train too.
find spike/train_pages -name '*.json' ! -name '*.cand.json' -delete
python3 spike/labelkit.py import spike/labels/train spike/train_pages
pages=(spike/train_pages)
if [[ -n "$LOCAL" ]]; then
  echo "== LOCAL=1: the books only a model kept at home may learn from"
  for try in 1 2 3; do
    python3 spike/fetch_corpus.py --manifest test/train-local.manifest.toml --out test/corpus-train-local && break
    [[ $try == 3 ]] && { echo "Some comics could not be fetched; run it again later."; exit 1; }
    sleep 30
  done
  python3 spike/extract_pages.py test/corpus-train-local spike/train_pages_local --per-book 400 --manifest test/train-local.manifest.toml
  find spike/train_pages_local -name '*.json' ! -name '*.cand.json' -delete
  python3 spike/labelkit.py import spike/labels/train-local spike/train_pages_local
  pages+=(spike/train_pages_local)
fi
echo "== Making 400 synthetic modern pages from the labelled art"
rm -rf spike/synth_pages
python3 spike/synth_modern.py spike/train_pages spike/synth_pages --count 400 --seed 1
echo "== Training for $EPOCHS epochs at $IMGSZ px (about 11 minutes an epoch on 4 cores)"
rm -rf "$OUT/train"
python3 spike/train.py "${pages[@]}" spike/synth_pages --out "$OUT/train" --epochs "$EPOCHS" --imgsz "$IMGSZ"
echo "== Exporting to ONNX"
# The last epoch, not the lowest validation loss: it guides more test pages right.
python3 spike/train.py --export "$OUT/train/last" --out-onnx "$OUT/comicredr-panels.onnx"
echo "Model in $OUT/comicredr-panels.onnx"
