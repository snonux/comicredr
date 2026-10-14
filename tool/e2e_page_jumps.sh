#!/usr/bin/env bash
# End-to-end check of the keys that go to a page, keyboard alone: gg and
# Home to page 1, G, ge and End to the last page, G and a number to that
# page (ended by Enter, by a pause, or by the next key), Esc dropping a
# number half typed. Each page is read back from the index with sqlite3.
# Then the ? help, searched for "page", is shot with the First page and
# Last page lines naming gg, G, ge and G12.
#
#   tool/e2e_page_jumps.sh
#
# Needs: Xvfb, openbox, xdotool, ImageMagick, sqlite3, python3.
# Output: build/e2e-page-jumps/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-page-jumps
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
python3 - "$out" <<'EOF'
import io, sys, zipfile
from PIL import Image, ImageDraw
out = sys.argv[1]
with zipfile.ZipFile(f"{out}/Comics/Jumps 01.cbz", "w", zipfile.ZIP_STORED) as z:
    for i in range(12):
        im = Image.new("RGB", (800, 1200), (40 + 17 * i, 200 - 13 * i, 90 + 11 * i))
        ImageDraw.Draw(im).text((60, 60), f"page {i + 1}", fill=(0, 0, 0))
        b = io.BytesIO()
        im.save(b, "JPEG")
        z.writestr(f"page{i + 1:02}.jpg", b.getvalue())
EOF
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release

export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
openbox >/dev/null 2>&1 &
wm=$!
# No session bus and no XDG folders of whoever runs it (AGENTS.md).
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent GDK_BACKEND=x11 \
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$PWD/$out/home" \
  build/linux/x64/release/bundle/comicredr "$PWD/$out/Comics/Jumps 01.cbz" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
sleep 7

db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
shot() { import -window root -crop 1280x900+0+0 "$out/$1.png"; }
win=$(xdotool search --sync --name ComicRedr | tail -1)
xdotool windowactivate --sync "$win" 2>/dev/null || true
sleep 1
key() { xdotool key --delay 120 "$@"; }
page() { q "select page + 1 from progress order by updated_at desc limit 1"; }

failed=0
expect() { if [[ "$1" == "$2" ]]; then echo "ok   $3: page $1"; else echo "FAIL $3: page $1, expected $2"; failed=1; fi; }

# The comic, named on the command line, opens on page 1; l and h save a
# position to read.
xdotool mousemove 640 899
key l; sleep 1; key h; sleep 1.5; shot 01_open
expect "$(page)" 1 "the comic opens"

key g e; sleep 1.5; shot 02_ge
expect "$(page)" 12 "ge: the last page"
key g g; sleep 1.5
expect "$(page)" 1 "gg: page 1"
key End; sleep 1.5
expect "$(page)" 12 "End: the last page"
key Home; sleep 1.5
expect "$(page)" 1 "Home: page 1"
key G; sleep 1.5
expect "$(page)" 12 "G alone, after the pause: the last page"
key G 5 Return; sleep 1.5; shot 03_G5
expect "$(page)" 5 "G5 Enter: page 5"
key G 1 0; sleep 1.5
expect "$(page)" 10 "G10 and a pause: page 10"
key G 7 l; sleep 1.5
expect "$(page)" 8 "G7 then l: page 7, then the next page"
key G 3 Escape; sleep 1.5
expect "$(page)" 8 "G3 then Esc: no jump"
key G 9 9 Return; sleep 1.5
expect "$(page)" 12 "G99 Enter in a 12-page comic: the last page"

# The ? help, searched for "page": the lines that name these keys.
key question; sleep 1.5
key slash; sleep 0.5
xdotool type --delay 80 "last page"; sleep 1; shot 04_help_last_page
key Escape; sleep 0.5; key Escape; sleep 1
key question; sleep 1.5; key slash; sleep 0.5
xdotool type --delay 80 "first page"; sleep 1; shot 05_help_first_page

echo
if (( failed )); then echo "FAILED; see $out"; exit 1; fi
echo "all passed; see $out"
