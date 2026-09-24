#!/usr/bin/env bash
# End-to-end check of the Linux build: launches the release bundle under a
# virtual X display, drives it with real key presses, and saves a screenshot
# after each step so a person can look at what actually happened.
#
#   tool/e2e_linux.sh [book.cbz]   # default: a generated 12-page fixture
#
# Needs: Xvfb, xdotool, ImageMagick (import, montage), python3 + Pillow.
# Output: build/e2e/shot_*.png and build/e2e/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home"

if [[ $# -gt 0 ]]; then
  book="$1"
else
  python3 spike/make_synthetic.py --out "$out/src" --per-kind 2 >/dev/null
  python3 - "$out" <<'EOF'
import glob, sys, zipfile
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
font = ImageFont.load_default(size=160)
for name, n in (("Fixture 01.cbz", 12), ("Fixture 02.cbz", 4)):
    with zipfile.ZipFile(f"{out}/Comics/{name}", "w", zipfile.ZIP_STORED) as z:
        for i, src in enumerate(sorted(glob.glob(f"{out}/src/*.jpg"))[:n], 1):
            im = Image.open(src).convert("RGB")
            d = ImageDraw.Draw(im)  # A big page number, so screenshots show which page is up.
            d.rectangle([420, 820, 880, 1180], fill="white", outline="black", width=8)
            d.text((470, 880), f"P{i}", fill="black", font=font)
            im.save(f"{out}/p.jpg", quality=85)
            z.write(f"{out}/p.jpg", f"Book/page{i}.jpg")
        z.writestr("__MACOSX/Book/._page1.jpg", b"junk")
        z.writestr("ComicInfo.xml", f"<ComicInfo><Series>Fixture</Series><Number>{name[-6:-4]}</Number></ComicInfo>")
EOF
  book="$out/Comics/Fixture 01.cbz"
fi

flutter build linux --release
export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
# A fresh HOME gives the app a fresh database, so resume starts empty.
HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 5

win=$(xdotool search --name ComicRedr | head -1)
xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }

shot 01_open
key l;               shot 02_next
key 3 Right;         shot 03_count
key d;               shot 04_spread
key shift+d;         shot 05_shift_pairing
key d; key plus plus; shot 06_zoom
key j j;             shot 07_pan
key equal; key z w;  shot 08_fit_width
key z z; key G;      shot 09_last
key i;               shot 10_night
key i; key bracketright; sleep 1.5; shot 11_next_book
key bracketleft; sleep 1.5;         shot 12_resumed
key question;        shot 13_keymap
key Escape; key Escape; shot 14_closed

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  exit 1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
