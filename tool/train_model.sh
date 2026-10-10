#!/usr/bin/env bash
# Trains the panel detector on the CPU, from scratch or on top of a kept
# checkpoint, keeps the run's checkpoint and scores the result. The one way
# models are trained; `make train-model` runs it. The whole recipe, and how
# to add books and labels: docs/training.md.
#
#   tool/train_model.sh                  # from COCO, 30 epochs: the shipped recipe
#   EPOCHS=1 tool/train_model.sh         # a quick check that the pipeline runs
#   FROM=shipped tool/train_model.sh     # on top of the model in assets/models/,
#                                        # 8 epochs at 3e-5 (checkpoint rebuilt from the ONNX)
#   FROM=DIR tool/train_model.sh         # on top of a kept checkpoint (a run's last/)
#   LOCAL=1 tool/train_model.sh          # also the NC/ND/SA books, and the fake pages
#                                        # in MORE when they are there: a model kept
#                                        # at home, never committed
#   LOCAL=more tool/train_model.sh       # the fake pages but not those books
#   RUN=NAME tool/train_model.sh         # names the run; the same NAME again resumes it
#
# Every run is a folder $CHECKPOINTS/$RUN (default
# ../comicredr-training-assets/checkpoints/DATE-KIND, else
# spike/out/checkpoints/): last/ and best/ (checkpoints to train on top
# of), state.pt (to resume), run.json (the data, the command, the loss per
# epoch), comicredr-panels.onnx and scores/summary.md (against the shipped
# model). It is copied there after every epoch, so a killed run started
# again with the same RUN loses one epoch at most. SCORE=0 skips scoring.
#
# Needs python3 with spike/requirements-train.txt and the network
# (archive.org, peppercarrot.com, huggingface.co). Downloads, pages and
# checkpoints are git-ignored; nothing is committed. The model also goes
# to spike/out/comicredr-panels.onnx (spike/out/local/ with LOCAL=1), where
# `make train-model` looks for it.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL="${LOCAL:-}"
FROM="${FROM:-}"
if [[ -n "$FROM" ]]; then EPOCHS="${EPOCHS:-8}"; LR="${LR:-3e-5}"; else EPOCHS="${EPOCHS:-30}"; LR="${LR:-1e-4}"; fi
IMGSZ="${IMGSZ:-640}"
OUT="${OUT:-spike/out}"
MORE="${MORE:-../comicredr-training-assets/moredata}"
SCORE="${SCORE:-1}"
[[ -n "$LOCAL" ]] && OUT="$OUT/local"
if [[ -z "${CHECKPOINTS:-}" ]]; then
  if [[ -d ../comicredr-training-assets/.git ]]; then CHECKPOINTS=../comicredr-training-assets/checkpoints
  else CHECKPOINTS=spike/out/checkpoints; fi
fi
kind=$([[ -n "$FROM" ]] && echo on-top || echo fresh)$([[ -n "$LOCAL" ]] && echo "-local$([[ $LOCAL == more ]] && echo -more)" || true)
RUN="${RUN:-$(date +%Y-%m-%d)-$kind}"
keep="$CHECKPOINTS/$RUN"
work="spike/out/runs/$RUN"

if ! python3 -c "import cv2, numpy, PIL, pypdfium2, scipy, torch, transformers, onnx, onnxruntime, onnxslim" \
    2>/dev/null; then
  echo "Missing Python packages. Install them once with:"
  echo "  python3 -m pip install --user -r spike/requirements-train.txt"
  exit 1
fi
echo "== Run $RUN: $EPOCHS epochs at lr $LR, ${FROM:-from COCO}; kept in $keep"
# FROM=shipped and the scores go by the file in assets/models/, which a
# fresh run without LOCAL replaces (make train-model): say so when it is
# not the committed one.
if ! git diff --quiet HEAD -- assets/models/comicredr-panels.onnx 2>/dev/null; then
  echo "Note: assets/models/comicredr-panels.onnx is not the committed model; FROM=shipped and the"
  echo "      scores use it as it is (git checkout -- assets/models/comicredr-panels.onnx puts it back)."
fi

# archive.org sometimes answers 500 for a while; a retry fetches only what
# is missing, waiting longer each time (about 15 minutes in all).
fetch() {
  local wait=30
  for try in 1 2 3 4 5; do
    python3 spike/fetch_corpus.py --manifest "$1" --out "$2" && return 0
    [[ $try == 5 ]] && break
    echo "Retrying the ones that failed in $wait s"; sleep "$wait"; wait=$((wait * 2))
  done
  echo "Some comics could not be fetched; run make train-model again later: it keeps what it has."
  exit 1
}
# manifest, corpus folder, pages folder, labels folder
prepare() {
  fetch "$1" "$2"
  python3 spike/extract_pages.py "$2" "$3" --per-book 400 --manifest "$1"
  # Only the committed labels: a label left from an earlier set would train too.
  find "$3" -name '*.json' ! -name '*.cand.json' -delete
  python3 spike/labelkit.py import "$4" "$3"
}

echo "== The training comics and their labelled pages"
prepare test/train.manifest.toml test/corpus-train spike/train_pages spike/labels/train
pages=(spike/train_pages)
if [[ -n "$LOCAL" ]]; then
  if [[ "$LOCAL" != more ]]; then
    echo "== LOCAL=$LOCAL: the books only a model kept at home may learn from"
    prepare test/train-local.manifest.toml test/corpus-train-local spike/train_pages_local spike/labels/train-local
    pages+=(spike/train_pages_local)
  fi
  # Fake pages on the layouts of your own comics, when they are there. They
  # are made and kept outside this repository, in comicredr-training-assets
  # (MORE). They hold no art, but the layouts come from books that are not
  # in the training manifest, so they go with the model kept at home.
  if [[ -f "$MORE/index.tsv" ]]; then
    echo "== LOCAL=$LOCAL: also the fake pages in $MORE ($(($(wc -l < "$MORE/index.tsv") - 1)) pages)"
    pages+=("$MORE")
  fi
fi
echo "== Making 400 synthetic modern pages from the labelled art"
rm -rf spike/synth_pages
python3 spike/synth_modern.py spike/train_pages spike/synth_pages --count 400 --seed 1
pages+=(spike/synth_pages)

# A run started again goes on from its last finished epoch, also on
# another machine: the kept state comes back into the working folder.
if [[ -f "$keep/state.pt" && ! -f "$work/state.pt" ]]; then
  mkdir -p "$work"
  cp "$keep/state.pt" "$keep/run.json" "$work/"
fi
weights=ustc-community/dfine-small-coco
if [[ -n "$FROM" ]]; then
  weights="$FROM"
  if [[ "$FROM" == shipped || "$FROM" == *.onnx ]]; then
    model=$([[ "$FROM" == shipped ]] && echo assets/models/comicredr-panels.onnx || echo "$FROM")
    weights="$keep/start"
    if [[ ! -f "$weights/model.safetensors" ]]; then
      echo "== Rebuilding a checkpoint from $model"
      python3 spike/onnx_to_checkpoint.py "$model" "$weights" --pages spike/train_pages spike/synth_pages
    fi
  fi
fi

echo "== Training for $EPOCHS epochs at $IMGSZ px (about 12 minutes an epoch per 1,000 pages on 4 cores)"
python3 spike/train.py "${pages[@]}" --weights "$weights" --out "$work" --copy-to "$keep" \
  --epochs "$EPOCHS" --lr "$LR" --imgsz "$IMGSZ"
echo "== Exporting to ONNX"
# The last epoch, not the lowest validation loss: it guides more test pages right.
python3 spike/train.py --export "$keep/last" --out-onnx "$keep/comicredr-panels.onnx"
mkdir -p "$OUT"
cp "$keep/comicredr-panels.onnx" "$OUT/comicredr-panels.onnx"
if [[ "$SCORE" != 0 ]]; then
  echo "== Scoring it against the shipped model"
  tool/score_model.sh "$keep/scores" shipped=assets/models/comicredr-panels.onnx "$RUN=$keep/comicredr-panels.onnx"
fi
echo "Model in $OUT/comicredr-panels.onnx; the run is kept in $keep"
