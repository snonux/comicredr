#!/usr/bin/env bash
# Native Linux touchscreen double-taps toggle fullscreen in every reader
# zone, with no single-tap page turn or zoom. Openbox verifies the actual
# window state; sqlite3 verifies the reader state after delayed taps settle.
# Needs the release bundle, Xvfb, Openbox, GTK 3 headers, a C compiler,
# xdotool, wmctrl, xprop, sqlite3, ImageMagick and Python with Pillow.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/e2e-double-tap
binary=${COMICREDR_E2E_BUNDLE:-build/linux/x64/release/bundle}/comicredr
[[ -x "$binary" ]] || { echo "Build the Linux release first" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out/home" "$out/config" "$out/data" "$out/Comics"
python3 - "$out/Comics/Touch.cbz" <<'PY'
import io, sys, zipfile
from PIL import Image
with zipfile.ZipFile(sys.argv[1], 'w') as book:
    for i, colour in enumerate(['red', 'green', 'blue']):
        page = io.BytesIO()
        Image.new('RGB', (800, 1200), colour).save(page, 'JPEG')
        book.writestr(f'{i + 1:02}.jpg', page.getvalue())
PY
# pkg-config emits separate compiler and linker arguments.
# shellcheck disable=SC2046
cc -shared -fPIC -o "$out/touch_inject.so" tool/e2e/touch_inject.c \
  $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:104
export GDK_BACKEND=x11
export DBUS_SESSION_BUS_ADDRESS="unix:path=$PWD/$out/no-session-bus"
Xvfb "$DISPLAY" -screen 0 1280x800x24 >"$out/xvfb.log" 2>&1 &
xvfb=$!
wm=
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
for _ in {1..50}; do
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.1
done
openbox >"$out/openbox.log" 2>&1 &
wm=$!
sleep 1
touches="$PWD/$out/touches"
: >"$touches"
HOME="$PWD/$out/home" XDG_CONFIG_HOME="$PWD/$out/config" \
  XDG_DATA_HOME="$PWD/$out/data" COMICREDR_MODEL=none \
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
  "$binary" "$PWD/$out/Comics/Touch.cbz" >"$out/app.log" 2>&1 &
app=$!
win=
for _ in {1..100}; do
  win=$(xdotool search --onlyvisible --pid "$app" --name ComicRedr | tail -1) || true
  [[ -n "$win" ]] && break
  sleep 0.1
done
[[ -n "$win" ]] || { echo "No reader window appeared" >&2; exit 1; }
wmctrl -i -r "$win" -b add,maximized_vert,maximized_horz
sleep 5

db="$PWD/$out/data/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd '.timeout 10000' "$db" "$1"; }
touch_event() { echo "$*" >>"$touches"; sleep 0.025; }
tap() { touch_event down 0 "$1" "$2"; touch_event up 0 "$1" "$2"; }
double_tap() { tap "$1" "$2"; sleep 0.1; tap "$1" "$2"; sleep 1; }
fullscreen() {
  xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN
}
failed=0
expect() {
  if [[ "$1" == "$2" ]]; then
    echo "ok   $3"
  else
    echo "FAIL $3: got $1, expected $2"
    failed=1
  fi
}

for y in 90 320 560; do
  for x in 90 640 1190; do
    double_tap "$x" "$y"
    expect "$(q "select value from settings where key='reader.fullscreen'")" \
      true "double-tap $x,$y enters fullscreen once"
    if fullscreen; then echo 'ok   window manager fullscreen'; else
      echo 'FAIL window manager did not enter fullscreen'; failed=1
    fi
    double_tap "$x" "$y"
    expect "$(q "select value from settings where key='reader.fullscreen'")" \
      false "double-tap $x,$y leaves fullscreen once"
    if fullscreen; then
      echo 'FAIL window manager did not leave fullscreen'; failed=1
    fi
    expect "$(q 'select page from progress limit 1')" 0 \
      "double-taps $x,$y keep the page"
    expect "$(q "select coalesce(json_extract(view_json, '$.view.zoom'), 1.0) from progress limit 1")" \
      1.0 "double-taps $x,$y keep the zoom"
  done
done
grep -q 'touch_inject: the Flutter view selects touch events' "$out/app.log"
tap 1190 320
sleep 1
expect "$(q 'select page from progress limit 1')" 1 \
  'single tap still turns the page'
import -window root "$out/finished.png"
echo "Results in $out/"
exit "$failed"
