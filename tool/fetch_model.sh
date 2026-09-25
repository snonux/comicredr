#!/usr/bin/env bash
# Fetches the detector model from where you keep it and puts it where the
# build packs it (assets/models/). `make fetch-model URL=...` runs this.
#
#   tool/fetch_model.sh https://example.org/comicredr-panels.onnx
#   HF_TOKEN=hf_... tool/fetch_model.sh https://huggingface.co/you/private-repo/resolve/main/comicredr-panels.onnx
#   tool/fetch_model.sh ~/Downloads/comicredr-panels.onnx   # a path works too
#
# HF_TOKEN is sent to huggingface.co only, for a private repository there.
# The file is checked before it replaces the model in the checkout: it must
# be an ONNX model whose output is the detector's [1, 300, 6] rows.
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:?usage: tool/fetch_model.sh URL-or-path}"
dest=assets/models/comicredr-panels.onnx
tmp=$(mktemp --suffix=.onnx)
trap 'rm -f "$tmp"' EXIT

case "$src" in
  http://*|https://*)
    auth=()
    if [[ -n "${HF_TOKEN:-}" && "$src" =~ ^https://huggingface\.co/ ]]; then
      auth=(-H "Authorization: Bearer $HF_TOKEN")
    fi
    echo "Downloading $src"
    curl -fL --retry 3 "${auth[@]}" -o "$tmp" "$src" ;;
  *)
    cp "$src" "$tmp" ;;
esac

if python3 -c "import onnxruntime" 2>/dev/null; then
  python3 - "$tmp" <<'PY'
import sys, onnxruntime as ort
try:
    s = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
except Exception as e:
    sys.exit(f"Not an ONNX model ONNX Runtime can load: {str(e).splitlines()[0][:200]}")
shape = s.get_outputs()[0].shape
if list(shape)[-2:] != [300, 6]:
    sys.exit(f"Not the ComicRedr detector: output shape {shape}, expected [1, 300, 6]")
print(f"Checked: ONNX model, output {shape}")
PY
else
  # Without onnxruntime, at least refuse an HTML error page or a truncated file.
  size=$(stat -c %s "$tmp")
  if (( size < 1000000 )) || head -c 64 "$tmp" | grep -qi '<html\|<!doctype'; then
    echo "That doesn't look like the model ($size bytes)."; exit 1
  fi
  echo "Checked size only ($size bytes); python3 -m pip install onnxruntime checks the model itself."
fi

install -Dm644 "$tmp" "$dest"
echo "Model in $dest; the next make or make apk packs it into the app."
