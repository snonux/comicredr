#!/usr/bin/env bash
# End-to-end check that a pan by hand in guided view or on a part of a page
# lights what it brings on screen, on the Linux release build under Xvfb,
# driven by real keys and a real mouse drag. The book is made here: white
# portrait pages with four bordered panels in a 2x2 grid, so the dimmed
# page shows as mid-grey pixels that can be counted.
#
#   tool/e2e_pan_dim.sh
#
# Checks: on H1 the lower half shows dimmed below the part, and two `↓`
# leave nothing on screen dimmed; `→` frames H2 dimmed around again and `k`
# lights it; on a quarter a mouse drag does the same; in guided view `j`
# lights what it brings in below a panel and `→` dims around the next one.
#
# Needs: Xvfb, xdotool, ImageMagick, Python with Pillow and a C compiler
# with X11 headers (tool/close_window.c).
# Output: build/e2e-pan-dim/*.png and build/e2e-pan-dim/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-pan-dim
rm -rf "$out" && mkdir -p "$out/home" "$out/books"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

python3 - "$out/books" <<'EOF2'
import io, sys, zipfile
from PIL import Image, ImageDraw
colours = [(220, 40, 40), (40, 170, 60), (40, 80, 220), (230, 200, 30)]
def page():
    im = Image.new('RGB', (600, 900), 'white')
    d = ImageDraw.Draw(im)
    for k, (x, y) in enumerate([(30, 30), (310, 30), (30, 460), (310, 460)]):
        d.rectangle([x, y, x + 259, y + 409], fill=colours[k], outline='black', width=6)
        for yy in range(y + 40, y + 380, 60):  # Something inside for classic CV to see as art.
            d.line([x + 30, yy, x + 230, yy + 20], fill='black', width=3)
    b = io.BytesIO()
    im.save(b, 'PNG')
    return b.getvalue()
with zipfile.ZipFile(f'{sys.argv[1]}/Pan.cbz', 'w') as z:
    for i in range(3):
        z.writestr(f'{i + 1:02d}.png', page())
EOF2
book="$PWD/$out/books/Pan.cbz"

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1

# Flat colour panels, which classic CV finds exactly; this checks the dim,
# not the detector.
export COMICREDR_MODEL="${COMICREDR_MODEL:-none}"
failed=0
key() { xdotool key "$@" 2>/dev/null; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
# The page's white paper seen through the dim: grey around 115, in patches
# at least 7 px across (the eroded mask), so the soft edges of the
# enlarged black borders don't count.
dimmed() {
  python3 - "$out/$1.png" <<'EOF2'
import sys
from PIL import Image, ImageFilter
im = Image.open(sys.argv[1]).convert('RGB')
mask = Image.new('L', im.size)
mask.putdata([255 if 95 <= r <= 135 and abs(r - g) < 6 and abs(r - b) < 6 else 0 for r, g, b in im.getdata()])
print(sum(1 for v in mask.filter(ImageFilter.MinFilter(7)).getdata() if v))
EOF2
}
expect_dim() {
  local n; n=$(dimmed "$1")
  if [[ $n -gt 1000 ]]; then echo "ok    $1: page dimmed around the focus ($n px)"
  else echo "FAIL  $1: expected dimmed page on screen, $n px"; failed=1; fi
}
expect_lit() {
  local n; n=$(dimmed "$1")
  if [[ $n -lt 100 ]]; then echo "ok    $1: nothing on screen dimmed ($n px)"
  else echo "FAIL  $1: $n dimmed px left on screen"; failed=1; fi
}

HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >>"$out/app.log" 2>&1 &
app=$!
sleep 6
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowmove "$win" 0 0 windowsize --sync "$win" 1280 800 windowactivate --sync "$win" 2>/dev/null || true
xdotool mousemove 640 400 click 1 2>/dev/null || true
sleep 3

# A part outside guided view: H1, then Down twice, then H2 and k.
key shift+h 1
shot 01_h1
expect_dim 01_h1
key Down
key Down
shot 02_h1_down
expect_lit 02_h1_down
key Right
shot 03_h2
expect_dim 03_h2
key k
shot 04_h2_k
expect_lit 04_h2_k

# A quarter, then a drag up and left.
key Escape
key shift+q 1
shot 05_q1
expect_dim 05_q1
xdotool mousemove 900 600 mousedown 1 2>/dev/null
for p in 850,560 800,520 750,480 700,440 650,400; do
  xdotool mousemove "${p%,*}" "${p#*,}" 2>/dev/null
  sleep 0.05
done
xdotool mouseup 1 2>/dev/null
sleep 1.5
shot 06_q1_drag
expect_lit 06_q1_drag

# Guided view: the page whole, the first panel, then j twice, then the next panel.
key Escape
key v
key Right
shot 07_panel1
expect_dim 07_panel1
key j
key j
shot 08_panel1_j
expect_lit 08_panel1_j
key Right
shot 09_panel2
expect_dim 09_panel2

"$out/close_window" "$win"
for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || { app=; break; }; sleep 0.25; done

montage "$out"/0*.png -tile 3x -geometry 426x266+4+4 -background '#222' "$out/contact.png" 2>/dev/null || true
if [[ $failed -eq 0 ]]; then echo "e2e_pan_dim: all checks passed"; else echo "e2e_pan_dim: FAILED"; exit 1; fi
