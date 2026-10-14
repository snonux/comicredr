#!/usr/bin/env bash
# End-to-end check of fit width by touch alone, as on a phone: in
# fullscreen (no status line, so no Fit width button) a swipe down on the
# page fits it to the width; a one-finger drag aslant then scrolls it up
# and down and never sideways; a swipe sideways turns the page, which
# stays fitted to the width; a swipe down at the top of a page brings the
# whole page back; a pinch in fit width zooms further and one finger moves
# that page sideways again. Touches come from tool/touch_inject.c; the
# view (fit, zoom, the middle of the screen as a share of the page) is
# read back from the index with sqlite3.
#
#   tool/e2e_fit_width.sh
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3, a C compiler and
# GTK 3 headers.
# Output: build/e2e-fit-width/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-fit-width
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
python3 spike/make_synthetic.py --out "$out/src" --per-kind 2 >/dev/null
python3 - "$out" <<'EOF'
import glob, sys, zipfile
out = sys.argv[1]
pages = sorted(glob.glob(f"{out}/src/*.jpg"))
with zipfile.ZipFile(f"{out}/Comics/Fit 01.cbz", "w", zipfile.ZIP_STORED) as z:
    for i in range(6):
        z.write(pages[i % len(pages)], f"page{i + 1:02}.jpg")
EOF
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:91
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
touches="$out/touches"
: >"$touches"
# No session bus and no XDG folders of whoever runs it (AGENTS.md).
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent GDK_BACKEND=x11 \
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$PWD/$out/home" \
  build/linux/x64/release/bundle/comicredr --add-root "$PWD/$out/Comics" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 7

db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
shot() { import -window root -crop 1280x720+0+0 "$out/$1.png"; }
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep "${3:-1.5}"; }
# swipe x0 y0 x1 y1: one finger in 20 moves.
swipe() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 $(( $1 + ($3 - $1) * i / 20 )) $(( $2 + ($4 - $2) * i / 20 )); done
  touch up 0 "$3" "$4"
  sleep 1.5
}
# slow_drag x0 y0 x1 y1: one finger over 2 s, resting before it lifts.
slow_drag() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do
    touch move 0 $(( $1 + ($3 - $1) * i / 20 )) $(( $2 + ($4 - $2) * i / 20 )); sleep 0.084
  done
  sleep 0.3
  touch up 0 "$3" "$4"
  sleep 1.5
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

failed=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
expect() { if [[ "$1" == "$2" ]]; then ok "$3: $1"; else fail "$3: $1, expected $2"; fi; }
# The open book's saved view: 1-based page, fit, zoom, and the middle of
# the screen as a share of the page across (cx) and down (cy).
view() {
  q "select page + 1, json_extract(view_json, '$.view.fit'), json_extract(view_json, '$.view.zoom'),
     round(json_extract(view_json, '$.view.cx'), 4), round(json_extract(view_json, '$.view.cy'), 4)
     from progress order by updated_at desc limit 1"
}
field() { view | cut -d'|' -f"$1"; }
more() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b + 0.01) }'; }
differs() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; exit !(d > 0.01 || d < -0.01) }'; }

# 1. A comic opened by taps on the Books tab, then fullscreen by a tap in
# the middle: no status line, so no Fit width button.
tap 43 160; tap 190 200; tap 190 200 3; shot 01_comic
expect "$(field 1)" 1 "two taps on a cover open the comic"
tap 640 360 2; shot 02_fullscreen
expect "$(q "select value from settings where key = 'reader.fullscreen'")" true "a tap in the middle: fullscreen"

# 2. A swipe down fits the width.
swipe 640 200 640 520; shot 03_fit_width
expect "$(field 2)" width "a swipe down fits the width"
expect "$(field 1)" 1 "and turns no page"
top=$(field 5)

# 3. One finger aslant: down the page, never sideways.
cx=$(field 4) cy=$(field 5)
slow_drag 900 600 500 250; shot 04_dragged
if more "$(field 5)" "$cy"; then ok "a drag aslant scrolls down the page ($cy to $(field 5))"; else
  fail "a drag aslant did not scroll down: $cy to $(field 5)"; fi
expect "$(field 4)" "$cx" "and nothing sideways"
expect "$(field 1)" 1 "and turns no page"

# 4. A swipe sideways turns the page, still fitted to the width, and the
# next page starts at its top (the pages are all one size).
swipe 900 360 400 360; shot 05_next_page
expect "$(field 1)" 2 "a swipe left turns the page"
expect "$(field 2)" width "still fitted to the width"
expect "$(field 4)" "$cx" "and centred across"
if differs "$(field 5)" "$top"; then fail "the next page did not start at its top: $(field 5), not $top"; else
  ok "and starts at its top, the drag before it forgotten ($(field 5))"; fi

# 5. At the top of the new page a swipe down brings the whole page back.
swipe 640 200 640 520; shot 06_whole_page
expect "$(field 2)" page "a swipe down at the top: the whole page"

# 6. A pinch in fit width zooms in, and one finger moves sideways again.
swipe 640 200 640 520
expect "$(field 2)" width "a swipe down: fit width again"
pinch 640 360 100 220; shot 07_pinched
zoom=$(field 3)
if more "$zoom" 1.2; then ok "a pinch zooms in fit width ($zoom)"; else fail "the pinch did not zoom: $zoom"; fi
cx=$(field 4)
slow_drag 900 360 500 360; shot 08_sideways
if differs "$(field 4)" "$cx"; then ok "zoomed, a drag moves sideways ($cx to $(field 4))"; else
  fail "zoomed, a drag did not move sideways: $cx"; fi

echo
if (( failed )); then echo "FAILED; see $out"; exit 1; fi
echo "all passed; see $out"
