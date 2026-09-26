#!/usr/bin/env bash
# End-to-end check of guided view on modern layouts: opens real modern
# comics from test/corpus-modern (spike/fetch_corpus.py --manifest
# test/modern.manifest.toml) in the release build under Xvfb, with the
# trained model, jumps to a page with slanted, inset or spread panels, and
# steps through its panels with real key presses, one screenshot a step.
#
#   tool/e2e_modern.sh   (COMICREDR_MODEL=file.onnx tries another model than the built-in one)
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick (import, montage).
# Output: build/e2e-modern/<book>_<step>.png and build/e2e-modern/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${COMICREDR_MODEL:=$PWD/assets/models/comicredr-panels.onnx}"
export COMICREDR_MODEL

out=build/e2e-modern
rm -rf "$out" && mkdir -p "$out"
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release

corpus=test/corpus-modern
# book, page (1-based), panel steps
books=(
  "$corpus/modern/pepper-carrot-e29|3|6"
  "$corpus/modern-digital/first-woman-001.pdf|39|6"
  "$corpus/modern-digital/zombie-pandemic.pdf|30|5"
  "$corpus/modern-indie/stigkland-locked-up.pdf|10|5"
  "$corpus/modern-indie/i-villain.pdf|17|6"
  # Two slanted panels, dimmed along their outlines
  "$corpus/modern-indie/wolfs-head-003.pdf|20|2"
)

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
# A failed step exits early: the app goes too, not just Xvfb.
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1

for entry in "${books[@]}"; do
  IFS='|' read -r book page steps <<<"$entry"
  name=$(basename "$book" .pdf)
  # A fresh HOME and a copy of the book each time: nothing cached, no
  # sidecar left beside the corpus, the model detects every page.
  home="$out/home-$name"
  mkdir -p "$home" "$out/books"
  copy="$out/books/$(basename "$book")"
  cp -r "$book" "$copy"
  HOME="$PWD/$home" build/linux/x64/release/bundle/comicredr "$copy" >"$out/$name.log" 2>&1 &
  app=$!
  sleep 5
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" 2>/dev/null || true
  xdotool mousemove 640 400
  key() { xdotool key "$@" 2>/dev/null; sleep 1; }
  shot() { import -window root "$out/${name}_$1.png"; }
  key $(echo "$page" | sed 's/./& /g') shift+g
  sleep 2
  shot 00_page
  key v
  sleep 3
  shot 01_guided
  for i in $(seq 1 "$steps"); do
    key l
    shot "$(printf '%02d' $((i + 1)))_step$i"
  done
  kill "$app"; wait "$app" 2>/dev/null || true
  grep -q 'Panel detector: model' "$out/$name.log" || { echo "$name: the model did not load"; exit 1; }
  if grep -v XGetInputFocus "$out/$name.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
    echo "Errors in $out/$name.log" && exit 1
  fi
done

montage -label '%t' "$out"/*_[0-9]*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
echo "Screenshots in $out/, overview in $out/contact.png"
