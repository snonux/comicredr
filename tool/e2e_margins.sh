#!/usr/bin/env bash
# End-to-end check of guided view on pages scanned with wide margins: builds
# a CBZ from labelled eval pages (spike/eval_pages, see the README) padded
# with a 12% blank margin, paper-coloured or a dark scanner bed, plus one
# page as scanned, opens it in the release build under Xvfb with the trained
# model, and steps into each page's panels with real key presses. The model
# detects on the trimmed page, so every page should get panels, not the
# whole page; the index must record the trim for the padded pages only.
#
#   COMICREDR_MODEL=comicredr-panels.onnx tool/e2e_margins.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick (import, montage), sqlite3, python3
# with OpenCV.
# Output: build/e2e-margins/p<page>_<step>.png and build/e2e-margins/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${COMICREDR_MODEL:=$PWD/assets/models/comicredr-panels.onnx}"
export COMICREDR_MODEL

out=build/e2e-margins
rm -rf "$out" && mkdir -p "$out/books" "$out/home"
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release

book="$out/books/wide-margins.cbz"
python3 - "$book" <<'EOF'
import sys, zipfile
import cv2
sys.path.insert(0, "spike")
from evaluate import add_margin

pages = [  # page, margin colour (None: its own paper)
    ("silver-age/space-war-002_cbz__p009.jpg", None),
    ("golden-age-grid/all-top-comics-6_cbz__p005.jpg", None),
    ("modern-painted/pepper-carrot-e35__p000.jpg", "30,30,30"),
    ("golden-age-grid/mercy-for-millions_cbz__p002.jpg", False),  # as scanned
]
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for i, (page, colour) in enumerate(pages):
        img = cv2.imread(f"spike/eval_pages/{page}")
        assert img is not None, f"extract the eval pages first: {page}"
        if colour is not False:
            img = add_margin(img, {}, 0.12, colour)[0]
        z.writestr(f"{i + 1:03d}.jpg", cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 90])[1].tobytes())
EOF

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
trap 'kill $xvfb 2>/dev/null || true' EXIT
sleep 1

HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >"$out/app.log" 2>&1 &
app=$!
sleep 5
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowactivate --sync "$win" 2>/dev/null || true
xdotool mousemove 640 400
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
shot() { import -window root "$out/$1.png"; }
key 1 shift+g
key v
for page in 1 2 3 4; do
  key "$page" shift+g
  sleep 4
  shot "p${page}_0_whole"
  key l
  shot "p${page}_1_panel1"
  key l
  shot "p${page}_2_panel2"
done
kill "$app"; wait "$app" 2>/dev/null || true

grep -q 'Panel detector: model' "$out/app.log" || { echo "the model did not load"; exit 1; }
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log" && exit 1
fi
index=$(find "$out/home" -name '*.sqlite' | head -1)
trims=$(sqlite3 "$index" "SELECT page, trim IS NOT NULL FROM analysed_pages WHERE source = 'model' ORDER BY page" | tr '\n' ' ')
echo "trimmed per page: $trims"
[[ "$trims" == "0|1 1|1 2|1 3|0 " ]] || { echo "expected pages 1-3 trimmed and page 4 not"; exit 1; }

montage -label '%t' "$out"/p*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
echo "Screenshots in $out/, overview in $out/contact.png"
