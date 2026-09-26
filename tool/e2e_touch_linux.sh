#!/usr/bin/env bash
# End-to-end check that the Linux build does everything by touch that the
# phone does, with no key or mouse at all: a comic opened from the library
# by taps, every default reader gesture (edge taps, swipes, double-tap zoom,
# pinch, the middle tap for fullscreen, a long press for the time), the
# progress bar dragged, the page grid opened, pinched, scrolled and a page
# tapped, guided view turned on and stepped, the status line's back button
# out of guided view and then out of the comic (Android's back gesture),
# and a long press on a cover. Touches come from tool/touch_inject.c, which
# also reports whether the Flutter view asks the window system for touch
# events at all: without that a real touchscreen's fingers would arrive as
# mouse clicks, which the reader ignores. Results are read back from the
# index with sqlite3 and from screenshots.
#
#   tool/e2e_touch_linux.sh
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3 + Pillow, a C
# compiler and GTK 3 headers.
# Output: build/e2e-touch-linux/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-touch-linux
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
python3 spike/make_synthetic.py --out "$out/src" --per-kind 2 >/dev/null
python3 - "$out" <<'EOF'
import glob, sys, zipfile
out = sys.argv[1]
# Synthetic pages, with panels for guided view to step through; the index
# says which page is up.
pages = sorted(glob.glob(f"{out}/src/*.jpg"))
for name, first in (("Touch 01.cbz", 0), ("Touch 02.cbz", 4)):
    with zipfile.ZipFile(f"{out}/Comics/{name}", "w", zipfile.ZIP_STORED) as z:
        for i in range(12):
            z.write(pages[(first + i) % len(pages)], f"page{i + 1:02}.jpg")
EOF
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:94
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
touches="$out/touches"
: >"$touches"
TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr --add-root "$PWD/$out/Comics" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 7

db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
shot() { import -window root -crop 1280x720+0+0 "$out/$1.png"; }
# Touch in the Flutter view's logical pixels (the window is 1280x720, its
# status line at the bottom), 16 ms between finger events as a
# touchscreen reports.
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 1.2; }
double_tap() {
  touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 0.1
  touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 1.5
}
hold() { touch down 0 "$1" "$2"; sleep 0.9; touch up 0 "$1" "$2"; sleep 0.3; }
# swipe x0 y0 x1 y1: one finger in 20 moves.
swipe() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 $(( $1 + ($3 - $1) * i / 20 )) $(( $2 + ($4 - $2) * i / 20 )); done
  touch up 0 "$3" "$4"
  sleep 1.2
}
# pinch cx y from to: two fingers from cx±from to cx±to.
pinch() {
  touch down 0 $(( $1 - $3 )) "$2"; touch down 1 $(( $1 + $3 )) "$2"
  for i in $(seq 1 12); do
    d=$(( $3 + ($4 - $3) * i / 12 ))
    touch move 0 $(( $1 - d )) "$2"; touch move 1 $(( $1 + d )) "$2"
  done
  touch up 0 $(( $1 - $4 )) "$2"; touch up 1 $(( $1 + $4 )) "$2"
  sleep 1.5
}
# Pixels that differ between two shots.
differ() { compare -metric AE -fuzz 5% "$out/$1.png" "$out/$2.png" null: 2>&1 | cut -d' ' -f1 || true; }

failed=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
expect() { if [[ "$1" == "$2" ]]; then ok "$3: $1"; else fail "$3: $1, expected $2"; fi; }
# The open book's saved place: 1-based page, panel, guided, zoom.
view() { q "select page + 1, panel, json_extract(view_json, '$.guided'), json_extract(view_json, '$.view.zoom') from progress order by updated_at desc limit 1"; }
page() { view | cut -d'|' -f1; }
panel() { view | cut -d'|' -f2; }
guided() { view | cut -d'|' -f3; }
zoom() { view | cut -d'|' -f4; }
zoomed() { awk -v z="$(zoom)" 'BEGIN { exit !(z > 1.2) }'; }
changed() {
  local d
  d=$(differ "$1" "$2")
  if (( d > $3 )); then ok "$4 ($d pixels differ)"; else fail "$4: only $d pixels differ"; fi
}

# 1. The library, by touch: the Books tab, a tap selects a cover and a
# second tap opens it.
shot 01_library
tap 43 160;  shot 02_books_tab
tap 190 200; shot 03_cover_selected
tap 190 200; sleep 1; shot 04_opened
expect "$(page)" 1 "two taps on a cover open the comic"
if grep -q 'touch_inject: the Flutter view selects touch events' "$out/app.log"; then
  ok "the Flutter view asks the window system for touch events"
else
  fail "the Flutter view does not ask for touch events: $(grep touch_inject "$out/app.log" || echo no report)"
fi

# 2. Reader gestures, the standard layout.
tap 1200 340;              expect "$(page)" 2 "tap the right edge: next page"
tap 1200 600;              expect "$(page)" 3 "tap the bottom right: next page"
tap 60 340;                expect "$(page)" 2 "tap the left edge: back"
swipe 900 340 400 340;     expect "$(page)" 3 "swipe left: next page"
swipe 400 340 900 340;     expect "$(page)" 2 "swipe right: back"
double_tap 640 340; shot 05_double_tap_zoom
if zoomed; then ok "double-tap the middle zooms in (zoom $(zoom))"; else fail "double-tap: zoom $(zoom)"; fi
swipe 800 340 500 340;     expect "$(page)" 2 "a drag on a zoomed page pans, no page turn"
double_tap 640 340;        expect "$(zoom)" 1.0 "double-tap again zooms back out"
pinch 640 340 60 260; shot 06_pinch
if zoomed; then ok "pinch zooms (zoom $(zoom))"; else fail "pinch: zoom $(zoom)"; fi
double_tap 640 340;        expect "$(zoom)" 1.0 "double-tap resets the pinch"
tap 640 340; shot 07_fullscreen
expect "$(q "select value from settings where key = 'reader.fullscreen'")" true "tap the middle: fullscreen"
tap 640 340; shot 08_windowed
expect "$(q "select value from settings where key = 'reader.fullscreen'")" false "tap the middle again: back in the window"
shot 09_before_time
hold 640 340; shot 10_long_press_time
changed 09_before_time 10_long_press_time 2000 "hold a finger on the middle: the time"
sleep 3
expect "$(page)" 2 "the long press turned no page"

# 3. The progress bar: drag along it and let go to jump.
swipe 100 666 900 666;     expect "$(page)" 9 "drag along the progress bar jumps"

# 4. The page grid from its status-line button: pinch, scroll, tap a page.
tap 1088 693; shot 11_grid
cols=$(q "select value from settings where key = 'grid.zoom'")
pinch 640 400 60 300; shot 12_grid_pinched
bigger=$(q "select value from settings where key = 'grid.zoom'")
if [[ "$bigger" != "$cols" ]]; then ok "pinch in the page grid resizes it ($cols -> $bigger)"; else fail "grid pinch: grid.zoom stayed $cols"; fi
swipe 640 600 640 150; shot 13_grid_scrolled
changed 12_grid_pinched 13_grid_scrolled 20000 "a finger scrolls the page grid"
pinch 640 400 300 50; shot 14_grid_small
tap 500 160;               expect "$(page)" 4 "tap a page in the grid opens it"

# 5. Guided view from its button, stepped by taps and swipes; the back
# button leaves guided view, then the comic.
tap 1048 693; sleep 3; shot 15_guided
expect "$(guided)" 1 "the guided view button"
tap 1200 340; shot 16_guided_panel
expect "$(panel)" 0 "tap the right edge in guided view: the first panel"
swipe 900 340 400 340; shot 17_guided_swipe
expect "$(panel)" 1 "swipe left in guided view: the next panel"
tap 32 693; shot 18_back_out_of_guided
expect "$(guided)" 0 "the back button leaves guided view"
tap 32 693; sleep 1; shot 19_back_to_library
changed 18_back_out_of_guided 19_back_to_library 200000 "the back button again: the library"
before=$(page)
tap 1200 340
expect "$(page)" "$before" "the library is showing: a tap on the right turns no page"

# 6. A long press on the other cover selects it and shows its details.
hold 360 200; sleep 1; shot 20_long_press_cover
changed 19_back_to_library 20_long_press_cover 5000 "a long press on a cover shows its details"

montage -label '%t' "$out"/*.png -tile 4x -geometry 480x270+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit "$failed"
