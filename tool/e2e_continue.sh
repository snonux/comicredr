#!/usr/bin/env bash
# End-to-end check of Continue (`C` and the library's Continue button) on the
# Linux release build, under Openbox in Xvfb: a comic read to page 3 and
# closed with the app comes back on page 3 with C after a restart; from
# inside another comic C goes to the one before and back; the button, tapped
# with an injected GTK touch, does the same after a restart; guided view and
# the page come back too; a comic moved within the library is found by its
# content, one deleted gets a notice and C again goes on to the one before.
#
#   tool/e2e_continue.sh
#
# Makes its own books of flat coloured pages, so the page shown is the
# colour in the middle of the screen.
#
# Needs: Xvfb, openbox, xdotool, ImageMagick, sqlite3, a C compiler and GTK
# headers (tool/close_window.c, tool/touch_inject.c), Python with Pillow.
# Output: build/e2e-continue/*.png and build/e2e-continue/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-continue
rm -rf "$out" && mkdir -p "$out/home/Comics"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

comics="$PWD/$out/home/Comics"
# Two books, each page its own colour: Amber's pages are warm, Blue's cool.
python3 - "$comics" <<'EOF2'
import io, sys, zipfile
from PIL import Image
books = {
    'Amber 1.cbz': [(200, 40, 40), (220, 120, 30), (230, 200, 40), (140, 60, 20), (250, 150, 150)],
    'Blue 1.cbz': [(40, 80, 200), (40, 170, 170), (100, 60, 200)],
}
for name, colours in books.items():
    with zipfile.ZipFile(f'{sys.argv[1]}/{name}', 'w') as z:
        for i, c in enumerate(colours):
            b = io.BytesIO()
            Image.new('RGB', (1280, 800), c).save(b, 'PNG')
            z.writestr(f'{i + 1:02d}.png', b.getvalue())
EOF2
amber="$comics/Amber 1.cbz"
blue="$comics/Blue 1.cbz"
db="$comics/.comicredr/comicredr.sqlite"

export DISPLAY=:96
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
key() { xdotool key "$@"; sleep 0.4; }
shot() { import -window root "$out/$1.png"; }
touches="$out/touches"
tap() { echo down 0 "$1" "$2" >>"$touches"; sleep 0.05; echo up 0 "$1" "$2" >>"$touches"; sleep 0.5; }

start() {
  : >"$touches"
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" 2>/dev/null || true
  sleep 1
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || { app=; return 0; }; sleep 0.25; done
  kill "$app"
  app=
}
# The colour in the middle of the screen, as r,g,b.
colour() {
  convert "$out/$1.png" -crop 1x1+640+300 +repage -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info:
}
# Whether shot $1 shows colour $2 (r,g,b) in the middle.
shows() {
  python3 - "$(colour "$1")" "$2" <<'EOF2'
import sys
a = [int(v) for v in sys.argv[1].split(',')]
b = [int(v) for v in sys.argv[2].split(',')]
sys.exit(0 if max(abs(x - y) for x, y in zip(a, b)) <= 12 else 1)
EOF2
}
expect() { # shot, colour, what it means
  sleep 1.5
  shot "$1"
  shows "$1" "$2" && ok "$3" || fail "$3: the middle is $(colour "$1"), not $2"
}
amber3=230,200,40
blue2=40,170,170

echo "== C with nothing read yet"
start
shot 01_library_empty
key C
sleep 1
shot 02_nothing_yet
shows 02_nothing_yet $amber3 && fail "C opened something with nothing read" || ok "C with nothing read opens nothing"
stop

echo "== Amber read to page 3, the app closed"
start "$amber"
key Right
key Right
expect 03_amber_p3 $amber3 "Amber open on page 3"
stop
recent=$(sqlite3 "$db" "select value from settings where key = 'reader.recent'")
[[ $recent == *"Amber 1.cbz"* ]] && ok "the index keeps Amber as the comic read last" || fail "no recent comic in the index: $recent"

echo "== a restart, C in the library"
start
shot 04_library
key C
expect 05_c_amber_p3 $amber3 "C after a restart: Amber on page 3"

echo "== Blue from inside Amber, then C back and forth"
key bracketright
sleep 1
key Right
expect 06_blue_p2 $blue2 "] opens Blue; on its page 2"
key C
expect 07_c_back_to_amber $amber3 "C in Blue: Amber on page 3"
key C
expect 08_c_to_blue $blue2 "C in Amber: Blue on page 2"

echo "== guided view kept"
key v
sleep 1
stop

echo "== a restart, the library's Continue button tapped"
start
shot 09_library_button
# The header's buttons from the right: settings, open, add folder,
# favourites, continue, 40 px apart, on the Reading tab; in the view's own
# coordinates, below Openbox's title bar.
tap 1090 28
expect 10_button_blue $blue2 "the Continue button, tapped: Blue on page 2"
view=$(sqlite3 "$db" "select view_json from progress p join files f on f.content_key = p.content_key where f.rel_path = 'Blue 1.cbz'")
[[ $view == *'"guided":true'* ]] && ok "Blue came back in guided view" || fail "guided view not kept: $view"
key Escape
key Escape
sleep 1
stop

echo "== Blue moved within the library"
mkdir -p "$comics/Moved"
mv "$blue" "$comics/Moved/"
start
sleep 2
key C
expect 11_moved_blue $blue2 "C finds Blue in its new folder, on page 2"
key Escape
key Escape
sleep 1
stop

echo "== Blue deleted"
rm "$comics/Moved/Blue 1.cbz"
start
sleep 2
key C
sleep 1
shot 12_gone_notice
shows 12_gone_notice $blue2 && fail "C opened a deleted comic" || ok "C with Blue deleted opens nothing"
key C
expect 13_then_amber $amber3 "C again: Amber on page 3"
stop

montage -label '%t' "$out"/[01][0-9]_*.png -tile 4x -geometry 400x250+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|Atk-CRITICAL|dbind|Panel detection'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
