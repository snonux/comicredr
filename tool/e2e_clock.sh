#!/usr/bin/env bash
# End-to-end check of the time at a glance (`T`) on the Linux release
# build, under Openbox in Xvfb: in fullscreen T shows the time large in the
# middle, it is gone again about 2.6 s later (2 s, then the fade), T while
# it shows starts the 2 s again, a long press in the middle (an injected
# GTK touch) shows it too, and it works in the windowed reader and in the
# library.
#
#   tool/e2e_clock.sh
#
# Makes its own book of flat pages, so "only the page" is a pixel count.
#
# Needs: Xvfb, openbox, xdotool, xprop, ImageMagick, a C compiler and GTK
# headers (tool/close_window.c, tool/touch_inject.c), Python with Pillow.
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
colours = [(40, 80, 200), (220, 180, 30), (40, 160, 60), (160, 50, 170)]
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

failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@"; }
shot() { import -window root "$out/$1.png"; }
touches="$out/touches"
touch() { echo "$@" >>"$touches"; sleep 0.016; }
hold() { touch down 0 "$1" "$2"; sleep 0.9; touch up 0 "$1" "$2"; }

start() {
  : >"$touches"
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 300 click 1 2>/dev/null || true
  sleep 1
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || { app=; return 0; }; sleep 0.25; done
  kill "$app"
  app=
}
# Share of the middle of the screen (a 600x240 box) that is not page
# colour $2: the clock covers much of it, a bare page none.
middle() {
  convert "$out/$1.png" -crop 600x240+340+280 +repage -fuzz 6% -fill black -opaque "#$2" \
    -fill white +opaque black -colorspace gray -format '%[fx:mean]' info:
}
shown() { python3 -c "import sys; sys.exit(0 if $(middle "$1" "$2") > 0.15 else 1)"; }
blue=2850c8

echo "== the time at a glance"
start
shot 01_library_before
key T
sleep 0.5
shot 02_library_time
compare -metric AE -fuzz 5% -extract 600x240+340+280 "$out/01_library_before.png" "$out/02_library_time.png" null: \
  >"$out/diff" 2>&1 || true
[[ $(cut -d' ' -f1 <"$out/diff") -gt 5000 ]] && ok "T in the library: the time shows" || fail "T in the library showed nothing"
stop

start "$PWD/$out/Clock.cbz"
key f
xdotool mousemove 640 300
sleep 3
shot 03_fullscreen
xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN && ok "f: fullscreen" || fail "f did not go fullscreen"
shown 03_fullscreen $blue && fail "a clock shows before T" || ok "fullscreen at rest: only the page"

key T
sleep 0.5
shot 04_fullscreen_time
shown 04_fullscreen_time $blue && ok "T: the time, large in the middle ($(middle 04_fullscreen_time $blue) of the box)" \
  || fail "T showed no time in fullscreen"
b=$(convert "$out/04_fullscreen_time.png" -crop 600x240+340+280 +repage -colorspace gray -format '%[fx:int(255*maxima)]' info:)
[[ $b -lt 245 ]] && ok "soft letters, brightest pixel $b of 255" || fail "brightest pixel $b: glaring white"
sleep 1.2
shot 05_fullscreen_1s7
shown 05_fullscreen_1s7 $blue && ok "still there after 1.7 s" || fail "gone before 2 s"
sleep 1.5
shot 06_fullscreen_gone
shown 06_fullscreen_gone $blue && fail "still there after 3.2 s" || ok "gone after 3.2 s: faded away"

key T
sleep 1.5
key T # starts the 2 s again
sleep 1.5
shot 07_restarted
shown 07_restarted $blue && ok "T again while it shows: still there 3 s after the first T" \
  || fail "the second T did not start the 2 s again"
sleep 2.5

hold 640 360
sleep 0.3
shot 08_long_press
shown 08_long_press $blue && ok "a long press in the middle shows the time" || fail "the long press showed nothing"
sleep 3
xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN && ok "still fullscreen after the long press" \
  || fail "the long press left fullscreen"

key f
sleep 1
key T
sleep 0.5
shot 09_window_time
shown 09_window_time $blue && ok "T in the windowed reader" || fail "no time in the windowed reader"
sleep 3
stop

montage -label '%t' "$out"/0[2-9]*.png -tile 3x -geometry 480x300+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
