#!/usr/bin/env bash
# End-to-end check of where comic data is kept, on the Linux build under
# Xvfb: sidecars beside each comic by default, then Settings → "In one
# folder" with the GTK folder picker, the offer to move them there, a fresh
# install that reads them from that folder, and the way back.
#
#   tool/e2e_sidecar_dir.sh
#
# Makes its own two small books (a CBZ and a folder of pages), so it needs
# no corpus. E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, Python 3, a C compiler, X11
# headers. Output: build/e2e-sidecar-dir/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-sidecar-dir
rm -rf "$out" && mkdir -p "$out/Comics/Indie" "$out/Comics/Folder Book" "$out/home" "$out/home2"
comics="$PWD/$out/Comics"
side="$PWD/$out/Stash"
cbz="$comics/Indie/Test Comic 1.cbz"
cbzside="$comics/Indie/.Test Comic 1.cbz.crdb"
book="$comics/Folder Book"
for i in 1 2 3 4; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$book/p$i.png"
done
python3 - "$book" "$cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
        z.write(f, 'page' + f.name[1:])
EOF

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:94
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
q() { sqlite3 -batch -noheader "$1" "$2"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
db() { echo "$PWD/$out/$1/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
start() { # start home [--no-root]
  local add=(--add-root "$comics")
  [[ ${2:-} == --no-root ]] && add=()
  HOME="$PWD/$out/$1" build/linux/x64/release/bundle/comicredr "${add[@]}" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name "^ComicRedr$" | tail -1)
  xdotool mousemove 60 24 click 1; sleep 1.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
# The Sidecars section sits near the bottom of the Settings dialog, below
# the fold in a 720 px window: scroll there first.
# Back up, below it, takes the last screenful: two notches back up.
settings_bottom() { xdotool mousemove 640 400 click --repeat 15 --delay 50 5 click --repeat 2 --delay 50 4; sleep 1; }
bookmarks() { q "$1" "select count(*) from bookmarks where deleted_at is null"; }
# Opens the selected book, turns a page, bookmarks it (m m) and goes back
# to the library, which writes the sidecar.
read_and_mark() {
  key Return; sleep 2
  key Next; key m m
  key Escape; sleep 3
}

start home
# Series (on the rail): a click selects a cover; the two books sit side
# by side.
click 43 100
click 190 200
read_and_mark
click 390 200
read_and_mark
shot 01_beside
check "the CBZ's sidecar is beside it" test "$(bookmarks "$cbzside")" = 1
check "the folder book's sidecar is inside it" test "$(bookmarks "$book/.comicredr.crdb")" = 1
[[ -n "${E2E_STOP:-}" ]] && { stop; exit; }

# Settings (the gear), "In one folder": the GTK picker takes a typed path
# after Ctrl+L. With a book selected the gear sits left of its details.
mkdir -p "$side"
click 870 28
settings_bottom
shot 02_settings
click "${PLACE_X:-660}" "${PLACE_Y:-146}"
sleep 1.5
click 150 59 # Home, out of Recent, which takes no path.
shot 03_picker
key ctrl+l
# GTK completes a typed path inline: another build/e2e-* folder beside this
# one turns "e" into "e2e-" and garbles the path, so run this one alone.
xdotool type --delay 80 "$side" 2>/dev/null; sleep 0.5
key Return # Into the folder; with the path field empty the picker takes it.
key ctrl+a BackSpace
click 1090 798
sleep 1
shot 04_move_offer
click 1047 406 # Move
sleep 2
shot 05_moved
check "the setting names the folder" \
  test "$(q "$(db home)" "select value from settings where key = 'sidecars.dir'")" = "\"$side\""
check "nothing is left beside the comics" \
  test ! -e "$cbzside" -a ! -e "$book/.comicredr.crdb"
check "the CBZ's sidecar moved, laid out like the library" \
  test "$(bookmarks "$side/Comics/Indie/.Test Comic 1.cbz.crdb")" = 1
check "the folder book's sidecar moved" \
  test "$(bookmarks "$side/Comics/Folder Book/.comicredr.crdb")" = 1
key Escape

# Reading on writes to the folder only.
click 390 200
read_and_mark
check "a new bookmark lands in the folder" \
  test "$(bookmarks "$side/Comics/Indie/.Test Comic 1.cbz.crdb")" = 2
check "still nothing beside the comics" test ! -e "$cbzside"
stop

# A fresh install pointed at the same folder before its first scan gets
# the bookmarks from it.
start home2 --no-root
stop
q "$(db home2)" "insert or replace into settings (key, value) values ('sidecars.dir', '\"$side\"')"
start home2
shot 06_fresh_install
check "a fresh install reads the folder's sidecars" test "$(bookmarks "$(db home2)")" = 3
stop

# Back to "Beside each comic", moving them back.
start home
click 43 100
click 390 200
click 870 28
settings_bottom
click "${BESIDE_X:-473}" "${PLACE_Y:-146}"
sleep 1
shot 07_move_back_offer
click 1047 406 # Move
sleep 2
shot 08_moved_back
check "the setting is cleared" \
  test -z "$(q "$(db home)" "select value from settings where key = 'sidecars.dir'")"
check "the sidecars are beside the comics again" \
  test "$(bookmarks "$cbzside")" = 2 -a "$(bookmarks "$book/.comicredr.crdb")" = 1
check "the folder no longer holds them" test ! -e "$side/Comics/Indie/.Test Comic 1.cbz.crdb"
check "and nothing is written there any more" test -z "$(find "$side" -name '*.crdb')"
key Escape
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
