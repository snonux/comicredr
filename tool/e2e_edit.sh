#!/usr/bin/env bash
# End-to-end check of editing a book's metadata on the Linux build: `e` on
# a book edits its series, issue, year and title so it joins another
# series; `e` on that series renames it; a restart and a rescan keep the
# edits; a second install reading the same folder picks them up from the
# sidecars; the reader's title follows. Checks the index and the sidecars
# with sqlite3 and takes screenshots.
#
#   tool/e2e_edit.sh a.cbz b.cbz [more books]
#
# The first two books must be in different series, with the second book the
# second cover in the Series tab and the first book's series the last. E2E_SKIP_BUILD=1 reuses the release
# build. Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11
# headers. Output: build/e2e-edit/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-edit
rm -rf "$out" && mkdir -p "$out/laptop" "$out/phone" "$out/Comics"
# Copies, so the sidecars written here never land beside the originals.
for b in "$@"; do cp -r "$b" "$out/Comics/"; done
first="$PWD/$out/Comics/$(basename "$1")"
second="$PWD/$out/Comics/$(basename "$2")"
side() { if [[ -d "$1" ]]; then echo "$1/.comicredr.crdb"; else echo "$1.crdb"; fi; }
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

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

# The laptop. Series tab, second cover, e: the edit dialog opens on Series.
start laptop
shot 01_library
target=$(q "$(db)" "select s.name from books b join series s on s.id = b.series_id where b.content_key = '$(key_of "$first")'")
key l; key l
key e; sleep 3
shot 02_edit_dialog
key ctrl+a; type "$target"
key Tab; key ctrl+a; type 7         # Issue
key Tab; key Tab; key ctrl+a; type 1962   # Year, past Volume
key Tab; key ctrl+a; type "Edited in the app"   # Title
shot 03_edit_filled
key Return; sleep 3
shot 04_after_edit
check "the series edit is in the index" test "$(edit "$second" series)" = "$target"
check "the issue, year and title edits are in the index" \
  test "$(edit "$second" number)/$(edit "$second" year)/$(edit "$second" title)" = "7/1962/Edited in the app"
check "the sidecar beside the book holds the edits" wait_for test "$(side_edit "$second" title)" = "Edited in the app"
check "the comic file itself is unchanged" cmp -s "$2" "$second"

# e on the series cover, now holding both books, renames it.
key G; key e; sleep 3
shot 05_rename_dialog
key ctrl+a; type "Renamed Series"; key Return; sleep 3
shot 06_after_rename
check "the rename is an edit to both books" \
  test "$(edit "$first" series)/$(edit "$second" series)" = "Renamed Series/Renamed Series"
check "both sidecars hold the rename" \
  wait_for test "$(side_edit "$first" series)/$(side_edit "$second" series)" = "Renamed Series/Renamed Series"

# Into the series and open the edited book: the reader's title follows.
key Return; sleep 3; key l; sleep 1; key Return; sleep 8
shot 07_reader
key Escape; sleep 2

# A restart rescans: the edits stay.
stop
start laptop
key R; sleep 6
shot 08_after_restart
check "a restart and a rescan keep the edits" \
  test "$(edit "$second" series)/$(edit "$second" number)" = "Renamed Series/7"
stop

# The phone: a second install on the same folder reads the sidecars.
start phone
sleep 5
shot 09_phone
check "the second install took the edits from the sidecars" \
  test "$(edit "$first" series)/$(edit "$second" series)/$(edit "$second" title)" = "Renamed Series/Renamed Series/Edited in the app"
stop

exit $failed
