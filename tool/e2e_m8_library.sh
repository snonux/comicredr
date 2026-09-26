#!/usr/bin/env bash
# End-to-end check of M8's library pieces on the Linux build: collections,
# reading history and the settings dialog, over real comics from the test
# corpus, driven by keys and mouse clicks under Xvfb. Checks the index and
# the sidecars with sqlite3 along the way.
#
#   tool/e2e_m8_library.sh [corpus-dir]   # default test/corpus
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11 headers.
# Output: build/e2e-m8/*.png and build/e2e-m8/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
out=build/e2e-m8
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
cp "$corpus"/silver-age/reptisaurus-v2-005.cbz "$corpus"/silver-age/space-war-002.cbz "$comics/"
cp -r "$corpus/modern/pepper-carrot-e06" "$comics/"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:93
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
type() { xdotool type --delay 60 "$1" 2>/dev/null; sleep 0.6; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr --add-root "$comics" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name ComicRedr | tail -1)
  # Keys go to the window under the pointer; a click on the tab title
  # gives the keyboard to the app, not the search field.
  xdotool mousemove 60 24 click 1; sleep 1.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}

start
# The shelf opens on Series, one cover per series (Tab puts the keyboard
# in the grid); the second is Reptisaurus #5.
key Tab; key l; key l
shot 01_book_detail
# Its details on the right: Add to a collection, a new one called Charlton.
click 1008 535; type Charlton; key Return
shot 02_in_collection
key l # Space War #2, into the same collection.
click 1008 535; type Charlton; key Return
check "both books are in Charlton" \
  test "$(q "$db" "select count(*) from collection_books where name = 'Charlton' and removed_at is null")" = 2
# The Collections tab (the rail on the left): one collection; a click on
# it shows its two books.
click 43 225
shot 03_collections
click 190 200
shot 04_collection_books

# Read Space War for a bit, then back to the library: a sitting.
key l; key Return; sleep 3
key Next; key Next; key Next; sleep 4
shot 05_reading
key Escape; sleep 2
check "the sitting is in the history" \
  test "$(q "$db" "select pages from read_log")" -ge 4
check "the Reptisaurus sidecar carries the collection" \
  test "$(q "$comics/.reptisaurus-v2-005.cbz.crdb" "select name from collections where removed_at is null")" = Charlton
click 43 290 # History
shot 06_history

# Settings (the gear, top right when no book is selected): turn
# whole-page steps off.
click 1258 28
shot 07_settings
click 870 307 # "Show each page whole before and after its panels"
shot 08_settings_changed
check "whole-page steps saved off" \
  test "$(q "$db" "select value from settings where key = 'guided.wholePageSteps'")" = false
key Escape
stop

# A restart keeps it all.
start
click 43 225 # Collections
shot 09_after_restart
stop
check "history survives a restart" test "$(q "$db" "select count(*) from read_log")" -ge 1

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
