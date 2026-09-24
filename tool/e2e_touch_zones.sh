#!/usr/bin/env bash
# End-to-end check of the configurable touch zones on the Linux build:
# the standard taps, gt showing the zones, the Left-handed preset picked in
# the real Settings dialog (and the zones shown on the next book opened),
# and a keys.toml [touch] section adding a zone tap, vertical swipes, a long
# press and a two-finger tap. Touches come from tool/touch_inject.c as in
# e2e_linux.sh; the page reached and the settings changed are read back from
# the index with sqlite3.
#
#   tool/e2e_touch_zones.sh
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3 + Pillow, a C
# compiler and GTK 3 and X11 headers.
# Output: build/e2e-touch-zones/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-touch-zones
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
python3 - "$out" <<'EOF'
import sys, zipfile
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
font = ImageFont.load_default(size=300)
# Two books, told apart by their paper, so they are not one content key.
for name, paper in (("Zones 01.cbz", (250, 245, 230)), ("Zones 02.cbz", (230, 240, 250))):
    with zipfile.ZipFile(f"{out}/Comics/{name}", "w", zipfile.ZIP_STORED) as z:
        for i in range(1, 13):
            im = Image.new("RGB", (1200, 1800), paper)
            d = ImageDraw.Draw(im)
            d.rectangle([40, 40, 1160, 1760], outline="black", width=12)
            d.text((380, 700), f"P{i}", fill="black", font=font)
            buf = BytesIO()
            im.save(buf, "JPEG", quality=85)
            z.writestr(f"page{i:02}.jpg", buf.getvalue())
EOF
book1="$PWD/$out/Comics/Zones 01.cbz"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
touches="$out/touches"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }

# start [args...]: the app on a fixed HOME, so one index across restarts.
start() {
  : >"$touches"
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  kill "$app"
}
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1; }
shot() { import -window root "$out/$1.png"; }
# Touch in the Flutter view's logical pixels (the view is 1280x720 above
# the status line), 16 ms between finger events as a touchscreen reports.
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 1.2; }
# vswipe x y0 y1: one finger straight up or down.
vswipe() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 "$1" $(( $2 + ($3 - $2) * i / 20 )); done
  touch up 0 "$1" "$3"
  sleep 1.2
}
hold() { touch down 0 "$1" "$2"; sleep 0.9; touch up 0 "$1" "$2"; sleep 1.2; }
two_finger_tap() {
  touch down 0 $(( $1 - 80 )) "$2"; touch down 1 $(( $1 + 80 )) "$2"
  sleep 0.08
  touch up 0 $(( $1 - 80 )) "$2"; touch up 1 $(( $1 + 80 )) "$2"
  sleep 1.2
}
# Pixels that differ between two shots.
differ() { compare -metric AE -fuzz 5% "$out/$1.png" "$out/$2.png" null: 2>&1 | cut -d' ' -f1 || true; }

failed=0
# The page saved for the open book, 1-based, as the status line shows it.
page() { q "select page + 1 from progress order by updated_at desc limit 1"; }
expect_page() {
  local got
  got=$(page)
  if [[ "$got" == "$1" ]]; then echo "ok   $2: page $got"; else echo "FAIL $2: page $got, expected $1"; failed=1; fi
}
expect() {
  if [[ "$1" == "$2" ]]; then echo "ok   $3: $1"; else echo "FAIL $3: $1, expected $2"; failed=1; fi
}

# 1. The standard preset: the edges turn pages, gt shows the zones.
start --add-root "$PWD/$out/Comics" "$book1"
shot 01_open
tap 1200 100; expect_page 2 "standard: tap top-right goes on"
tap 1200 600; expect_page 3 "standard: tap bottom-right goes on"
tap 60 340;   expect_page 2 "standard: tap left goes back"
key g t; shot 02_gt_zones
sleep 3.5; shot 03_zones_gone
d=$(differ 02_gt_zones 03_zones_gone)
if (( d > 100000 )); then echo "ok   gt draws the zones over the page ($d pixels differ)"; else echo "FAIL gt: only $d pixels differ"; failed=1; fi

# 2. Left-handed, picked in the real Settings dialog from the library; the
# next book opened shows its zones, and the left edge now goes on.
key Escape; sleep 1
click 1251 28; shot 04_settings
# The Touch heading is below the fold: scroll the dialog down to it.
xdotool mousemove 640 450 click 5 click 5 click 5 click 5 click 5 click 5 click 5 click 5 click 5 click 5; sleep 1
shot 05_settings_touch
# Where the Touch presets are: the segmented button just above the preview
# grid, found by their outlines so a Settings section added above them does
# not move the click.
read -r lx ly < <(python3 - "$out/05_settings_touch.png" 1 <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
def light(x, y):
    r, g, b = px[x, y]
    return min(r, g, b) > 100 and max(r, g, b) - min(r, g, b) < 40
runs = []  # Light horizontal lines starting at the dialog's left margin.
for y in range(im.size[1]):
    for x in range(370, 400):
        if light(x, y) and not light(x - 1, y):
            e = x
            while e < im.size[0] and light(e, y):
                e += 1
            if e - x > 150:
                runs.append((y, x, e))
            break
grid = next(y for y, x, e in runs if x < 386 and 230 < e - x < 250)  # The preview's top edge.
bottom, top = [r for r in runs if r[0] < grid and r[1] >= 386][-1], None
top = [r for r in runs if r[0] < bottom[0] - 20 and r[1] == bottom[1] and r[2] == bottom[2]][-1]
left, right = bottom[1] - 12, bottom[2] + 12  # The rounded ends start 12 px in.
i = int(sys.argv[2])
print((left * (5 - 2 * i) + right * (2 * i + 1)) // 6, (top[0] + bottom[0]) // 2)
PY
)
click "$lx" "$ly"; shot 06_settings_left_handed
expect "$(q "select value from settings where key = 'touch.preset'")" '"leftHanded"' "Settings saved the preset"
click 868 656
# The Books tab lists both; the second one opens with a click and Enter.
click 43 160; shot 07_books
click 400 205; key Return; sleep 1; shot 08_zones_on_open
sleep 3.5; shot 09_zones_on_open_gone
d=$(differ 08_zones_on_open 09_zones_on_open_gone)
if (( d > 100000 )); then echo "ok   the next book opened shows the zones ($d pixels differ)"; else echo "FAIL zones on open: only $d pixels differ"; failed=1; fi
start_page=$(page)
tap 60 340;   expect_page $(( start_page + 1 )) "left-handed: tap left goes on"
tap 1200 600; expect_page "$start_page" "left-handed: tap right goes back"
stop

# 3. A keys.toml [touch] section over the Left-handed preset, with one bad
# line that is named in the log and skipped.
cat >"$out/keys.toml" <<'TOML'
[touch]
tap = [
  "firstPage", "fullscreen", "lastPage",
  "prevStep",  "fullscreen", "nextStep",
  "prevStep",  "fullscreen", "nextStep",
]
longPress = "nightFilter"
swipeUp = "nextPage"
swipeDown = "prevPage"
twoFingerTap = "autoTrim"
pinch = "zoomIn"
TOML
COMICREDR_KEYS="$PWD/$out/keys.toml" start "$book1"
shot 10_keys_toml
tap 1200 100; expect_page 12 "[touch] tap top-right: last page"
tap 60 100;   expect_page 1 "[touch] tap top-left: first page"
vswipe 640 500 150; expect_page 2 "[touch] swipe up: next page"
vswipe 640 150 500; expect_page 1 "[touch] swipe down: previous page"
tap 1200 340; expect_page 2 "[touch] middle-right tap, listed again: next"
hold 640 340; shot 11_long_press_night
expect "$(q "select value from settings where key = 'reader.night'")" true "[touch] long press: night filter"
two_finger_tap 640 340; shot 12_two_finger_trim
expect "$(q "select value from settings where key = 'reader.autoTrim'")" true "[touch] two-finger tap: auto-trim"
expect_page 2 "neither the long press nor the two-finger tap turned the page"
if grep -qF 'keys.toml: [touch] has no gesture called "pinch"' "$out/app.log"; then
  echo "ok   the bad [touch] line is reported"
else
  echo "FAIL the bad [touch] line was not reported"; failed=1
fi
key g t; shot 13_gt_keys_toml
key Escape; sleep 1; click 1251 28
xdotool mousemove 640 450 click 5 click 5 click 5 click 5 click 5; sleep 1; shot 14_settings_keys_toml
key Escape
stop

montage -label '%t' "$out"/*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit "$failed"
