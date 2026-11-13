#!/usr/bin/env bash
# End-to-end check of editing a book's metadata on the Linux build: `e` on
# a book edits its issue, year and title; a restart and a rescan keep the
# edits; a second install reading the same folder picks them up from the
# sidecars; the reader's title follows. Checks the index and the sidecars
# with sqlite3 and takes screenshots. (There is no series to edit any
# more: the folder the comic is in names it; renaming that folder on disk
# is the way to rename what the book is called.)
#
#   tool/e2e/e2e_edit.sh a.cbz [more books]
#
# The first book is the one edited. E2E_SKIP_BUILD=1 reuses the release
# build. Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11
# headers. Output: build/e2e-edit/*.png.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/e2e-edit
rm -rf "$out" && mkdir -p "$out/laptop" "$out/phone" "$out/Comics"
# Copies, so the sidecars written here never land beside the originals.
for b in "$@"; do cp -r "$b" "$out/Comics/"; done
first="$PWD/$out/Comics/$(basename "$1")"
side() { if [[ -d "$1" ]]; then echo "$1/.comicredr.crdb"; else echo "$(dirname "$1")/.$(basename "$1").crdb"; fi; }
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/e2e/close_window.c -lX11

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# Wait for the display: the app started before Xvfb is up dies with
# "cannot open display" and the window is never found.
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$1" "$2"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
type() { xdotool type --delay 60 "$1" 2>/dev/null; sleep 0.6; }
shot() { import -window root "$out/$1.png"; }
home=
start() {
  home="$PWD/$out/$1"
  HOME="$home" build/linux/x64/release/bundle/comicredr --add-root "$PWD/$out/Comics" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 10
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool mousemove 640 400; sleep 0.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
db() { echo "$home/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
key_of() { q "$(db)" "select content_key from files where rel_path = '$(basename "$1")'"; }
edit() { q "$(db)" "select json_extract(value, '\$.value') from overrides where content_key = '$(key_of "$1")' and field = '$2'"; }
side_edit() { q "$(side "$1")" "select json_extract(value, '\$.value') from overrides where field = '$2'" 2>/dev/null || true; }
wait_for() { for _ in $(seq 1 20); do "$@" && return 0; sleep 1; done; return 1; }

# The laptop. Books tab, first cover, e: the edit dialog opens on Issue.
start laptop
shot 01_library
key Tab; key b; key Return
key l
key e; sleep 3
shot 02_edit_dialog
key ctrl+a; type 7         # Issue
key Tab; key Tab; key ctrl+a; type 1962   # Year, past Volume
key Tab; key ctrl+a; type "Edited in the app"   # Title
shot 03_edit_filled
key Return; sleep 3
shot 04_after_edit
check "the issue, year and title edits are in the index" \
  test "$(edit "$first" number)/$(edit "$first" year)/$(edit "$first" title)" = "7/1962/Edited in the app"
check "the sidecar beside the book holds the edits" wait_for test "$(side_edit "$first" title)" = "Edited in the app"
# A folder book holds its own sidecar; the pages are what must not change.
check "the comic itself is unchanged" diff -rq --exclude=.comicredr.crdb "$1" "$first"

# Open the edited book: the reader's title follows the issue and title.
key Return; sleep 8
shot 05_reader
key Escape; sleep 2

# A restart rescans: the edits stay.
stop
start laptop
key R; sleep 6
shot 06_after_restart
check "a restart and a rescan keep the edits" \
  test "$(edit "$first" number)/$(edit "$first" title)" = "7/Edited in the app"
stop

# The phone: a second install on the same folder reads the sidecars.
start phone
sleep 5
shot 07_phone
check "the second install took the edits from the sidecars" \
  test "$(edit "$first" number)/$(edit "$first" year)/$(edit "$first" title)" = "7/1962/Edited in the app"
stop

exit $failed
