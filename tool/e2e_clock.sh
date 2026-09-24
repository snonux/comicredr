#!/usr/bin/env bash
# End-to-end check of the reader clock (`T`) on the Linux release build,
# under Openbox in Xvfb: off at first, T puts the time in the top-left
# corner on a white page and on a black one, it stays in two-page mode,
# guided view and f fullscreen, a finger tap on it still turns the page
# back (it takes no taps), T takes it off, and a restart remembers it.
# Checks the setting in the index with sqlite3.
#
#   tool/e2e_clock.sh
#
# Makes its own book: flat white, black and coloured pages, so the clock is
# the only thing in the corner that is not the page.
#
# Needs: Xvfb, openbox, xdotool, xprop, ImageMagick, sqlite3, a C compiler
# and GTK headers (tool/touch_inject.c), Python with Pillow.
# Output: build/e2e-clock/*.png and build/e2e-clock/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-clock
rm -rf "$out" && mkdir -p "$out/home"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

python3 - "$out/Clock.cbz" <<'EOF2'
import io, sys, zipfile
from PIL import Image
colours = [(255, 255, 255), (0, 0, 0), (40, 80, 200), (220, 180, 30), (250, 250, 250), (10, 10, 10)]
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for i, c in enumerate(colours):
        b = io.BytesIO()
        Image.new('RGB', (1280, 800), c).save(b, 'PNG')
        z.writestr(f'{i + 1:02d}.png', b.getvalue())
EOF2

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
wm=
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
sleep 1
openbox >/dev/null 2>&1 &
wm=$!
sleep 1

touches="$out/touches"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@"; sleep 1; }
shot() { import -window root "$out/$1.png"; }
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 1.2; }

start() {
  : >"$touches"
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$PWD/$out/Clock.cbz" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || { app=; return 0; }; sleep 0.25; done
  kill "$app"
  app=
}

# The page's top-left corner on screen: below the title bar in a window,
# the screen's corner in fullscreen.
corner() {
  local x y
  x=$(xwininfo -id "$win" | awk '/Absolute upper-left X/ {print $NF}')
  y=$(xwininfo -id "$win" | awk '/Absolute upper-left Y/ {print $NF}')
  echo "160x50+$x+$y"
}
# How many pixels in the page's corner are not the page colour $2 (a hex
# like ffffff), and the brightest and darkest of them.
marks() {
  convert "$out/$1.png" -crop "$(corner)" +repage -fuzz 3% -fill black -opaque "#$2" \
    -fill white +opaque black -format '%[fx:mean*w*h]' info: | cut -d. -f1
}
# Brightest pixel in the corner, 0-255.
brightest() {
  convert "$out/$1.png" -crop "$(corner)" +repage -colorspace gray -format '%[fx:int(255*maxima)]' info:
}
# The colour in the middle of the screen, as hex.
centre() { convert "$out/$1.png" -crop 1x1+640+400 +repage -format '%[hex:u.p{0,0}]' info:; }
clock_shown() {
  local n
  n=$(marks "$1" "$2")
  echo "  ($1: $n px not the page in $(corner))"
  [[ $n -gt 40 ]]
}

echo "== reader clock"
start
# Zoomed in, so the white page and not the black around it fills the corner.
key plus plus plus
shot 01_off_white
clock_shown 01_off_white ffffff && fail "a clock shows before T" || ok "no clock at first"

key T
shot 02_on_white
if clock_shown 02_on_white ffffff; then ok "T: the clock shows top left on a white page ($(marks 02_on_white ffffff) px)"; else fail "no clock after T"; fi
[[ $(q "select value from settings where key = 'reader.clock'") == true ]] && ok "the index has reader.clock = true" \
  || fail "reader.clock not saved"
# Discreet: the rest of the screen's top band is the page, and the clock is
# small.
[[ $(marks 02_on_white ffffff) -lt 1500 ]] && ok "the clock is small" || fail "the clock is too big"

key equal
key Right # page 2, black
shot 03_on_black
b=$(brightest 03_on_black)
if clock_shown 03_on_black 000000; then ok "shows on a black page too"; else fail "no clock on a black page"; fi
[[ $b -lt 240 && $b -gt 90 ]] && ok "semi-transparent: brightest pixel $b of 255" || fail "brightest pixel $b, not faint"

key d # two-page mode: pages 2 and 3
shot 04_two_page
clock_shown 04_two_page 000000 && ok "stays in two-page mode" || fail "gone in two-page mode"
key d
key v # guided view (a flat page: shown whole)
shot 05_guided
clock_shown 05_guided 000000 && ok "stays in guided view" || fail "gone in guided view"
key v

key f
sleep 2
shot 06_fullscreen
xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN && ok "f: fullscreen" || fail "f did not go fullscreen"
clock_shown 06_fullscreen 000000 && ok "the clock shows in fullscreen" || fail "no clock in fullscreen"

key Right Right # page 4
# A finger on the clock: the top-left tap zone goes back a page, so the
# clock let the tap through.
tap 30 20
shot 07_tapped_clock
[[ $(centre 07_tapped_clock) == 2850C8 ]] \
  && ok "a tap on the clock turned back to page 3" || fail "the tap on the clock did not reach the page"

key T
shot 08_off_fullscreen
clock_shown 08_off_fullscreen 2850c8 && fail "the clock stayed after T" || ok "T takes it off, in fullscreen"
[[ $(q "select value from settings where key = 'reader.clock'") == false ]] && ok "the index has reader.clock = false" \
  || fail "reader.clock not saved as off"
key T
key f
stop

start
sleep 1
shot 09_restart
clock_shown 09_restart 2850c8 && ok "a restart comes back with the clock" || fail "a restart forgot the clock"
stop

montage -label '%t' "$out"/0*.png -tile 3x -geometry 480x300+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
