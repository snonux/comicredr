#!/usr/bin/env bash
# End-to-end check of the reader clock (`T`) on the Linux release build,
# under Openbox in Xvfb: off at first, T puts the time on the status line
# and it stays there in guided view, fullscreen at rest shows only the page
# (no clock) until the mouse brings the status line back, T takes it off,
# and a restart remembers it. Checks the setting in the index with sqlite3.
#
#   tool/e2e_clock.sh
#
# Makes its own book of flat pages, so "only the page" is a pixel count.
#
# Needs: Xvfb, openbox, xdotool, xprop, xwininfo, ImageMagick, sqlite3, a C
# compiler (tool/close_window.c), Python with Pillow.
# Output: build/e2e-clock/*.png and build/e2e-clock/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-clock
rm -rf "$out" && mkdir -p "$out/home"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

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

db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@"; sleep 1; }
shot() { import -window root "$out/$1.png"; }

start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$PWD/$out/Clock.cbz" >>"$out/app.log" 2>&1 &
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
# The status line: the window's bottom 44 rows, left of the file name and
# buttons, where the clock goes.
status_band() {
  local x y w h
  x=$(xwininfo -id "$win" | awk '/Absolute upper-left X/ {print $NF}')
  y=$(xwininfo -id "$win" | awk '/Absolute upper-left Y/ {print $NF}')
  w=$(xwininfo -id "$win" | awk '/Width:/ {print $NF}')
  h=$(xwininfo -id "$win" | awk '/Height:/ {print $NF}')
  echo "$((w / 2))x44+$((x + w / 4))+$((y + h - 44))"
}
# Pixels that differ between two shots in the status line.
changed() { compare -metric AE -fuzz 5% -extract "$(status_band)" "$out/$1.png" "$out/$2.png" null: 2>&1 | cut -d' ' -f1 || true; }
# Whether the screen is page colour $2 (hex) nearly everywhere.
only_page() {
  local m
  m=$(convert "$out/$1.png" -fuzz 6% -fill black -opaque "#$2" -fill white +opaque black -colorspace gray -format '%[fx:mean]' info:)
  python3 -c "import sys; sys.exit(0 if $m < 0.001 else 1)"
}

echo "== reader clock"
start
shot 01_off
key T
sleep 2 # the "Clock on" notice goes with the next change; turn a page
key Right
key Left
shot 02_on
n=$(changed 01_off 02_on)
[[ $n -gt 60 ]] && ok "T: something new on the status line ($n px)" || fail "nothing new on the status line after T ($n px)"
[[ $(q "select value from settings where key = 'reader.clock'") == true ]] && ok "the index has reader.clock = true" \
  || fail "reader.clock not saved"

key v # guided view (a flat page: shown whole)
shot 03_guided
key v

key f
xdotool mousemove 640 300
sleep 3
shot 04_fullscreen
xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN && ok "f: fullscreen" || fail "f did not go fullscreen"
only_page 04_fullscreen 2850c8 && ok "fullscreen at rest: only the page, no clock" || fail "something over the page in fullscreen"
xdotool mousemove 640 790
sleep 0.8
shot 05_fullscreen_bottom
only_page 05_fullscreen_bottom 2850c8 && fail "the mouse at the bottom brought nothing" \
  || ok "the mouse along the bottom brings the status line and its clock"
xdotool mousemove 640 300
key f
sleep 1

key T
sleep 1
key Right
key Left
shot 06_off_again
n=$(changed 01_off 06_off_again)
[[ $n -lt 60 ]] && ok "T again: the status line is as it was ($n px)" || fail "the status line still differs after T ($n px)"
[[ $(q "select value from settings where key = 'reader.clock'") == false ]] && ok "the index has reader.clock = false" \
  || fail "reader.clock not saved as off"
key T
stop

start
shot 07_restart
n=$(changed 01_off 07_restart)
[[ $n -gt 60 ]] && ok "a restart comes back with the clock ($n px)" || fail "a restart forgot the clock ($n px)"
stop

montage -label '%t' "$out"/0*.png -tile 3x -geometry 480x300+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
