#!/usr/bin/env bash
# End-to-end check of resetting a comic (X) on the Linux build: read into a
# book in guided view, bookmark it, then reset it from the reader, first its
# panels only and then everything, and once more from the library's book
# details. Checks the index and the sidecar with sqlite3 after each step.
#
#   tool/e2e_reset.sh book.cbz
#
# COMICREDR_MODEL naming the trained .onnx file makes guided view use the
# model, as in e2e_linux.sh. E2E_SKIP_BUILD=1 reuses the release build.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11 headers.
# Output: build/e2e-reset/*.png and build/e2e-reset/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-reset
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
# A copy, so the sidecar written here never lands beside the original.
cp -r "$1" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$1")"
side="$(dirname "$book")/.$(basename "$book").crdb"
[[ -d "$book" ]] && side="$book/.comicredr.crdb"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
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
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$1" "$2"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.5; }
shot() { import -window root "$out/$1.png"; }
start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr --add-root "$PWD/$out/Comics" "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 8
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool mousemove 640 400; sleep 0.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
key_of() { q "$db" "select content_key from files limit 1"; }
count() { q "$db" "select count(*) from $1 where content_key = '$(key_of)'${2:+ and $2}"; }
side_count() { q "$side" "select count(*) from $1${2:+ where $2}"; }

start "$book"
# Guided view, a few panels in, then mm on page 3 and mark a.
key v; sleep 4
for _ in 1 2 3 4 5 6 7 8 9 10; do key l; done
key m m; key m a
shot 01_reading
page_before=$(count progress)
# The sidecar is written two seconds after the last change, and detection
# of the rest of the book keeps changing it for a while.
for _ in $(seq 1 90); do
  [[ -f "$side" && "$(side_count bookmarks 2>/dev/null)" = 2 ]] && break
  sleep 1
done
check "panels were detected" test "$(count analysed_pages)" -gt 0
check "the bookmark and mark are in the index" test "$(count bookmarks 'deleted_at is null')" = 2
check "the sidecar holds panels" test "$(side_count panels)" -gt 0
check "the sidecar holds the bookmarks" test "$(side_count bookmarks)" = 2
at=$(q "$db" "select page || '/' || panel from progress")
analysed_at=$(q "$db" "select max(analysed_at) from analysed_pages")

# X, then Escape: nothing changes. The first dialog takes a few seconds
# to show under Xvfb's software renderer.
key shift+x; sleep 4
shot 02_dialog
key Escape
check "Esc in the dialog leaves the panels" test "$(count analysed_pages)" -gt 0

# X, Redo panels (the button with the focus): the same spot, found again.
key shift+x; key Return; sleep 5
shot 03_redo_panels
check "redo panels keeps the position" test "$(q "$db" "select page || '/' || panel from progress")" = "$at"
check "redo panels keeps the bookmarks" test "$(count bookmarks 'deleted_at is null')" = 2
check "panels were found again" \
  test "$(q "$db" "select min(analysed_at) from analysed_pages")" -gt "$analysed_at"
sleep 3
check "the sidecar still has the bookmarks" test "$(side_count bookmarks)" = 2

# X, Reset everything (Tab to it from Redo panels): page 1, nothing kept.
key shift+x; key Tab; key Return; sleep 5
shot 04_reset_everything
check "reset everything forgets the bookmarks" test "$(count bookmarks)" = 0
check "and the history" test "$(count read_log)" = 0
check "and reopens on page 1" test "$(q "$db" "select page from progress")" = 0
sleep 3
check "the sidecar has no bookmarks" test "$(side_count bookmarks)" = 0
check "and no other position" test "$(side_count progress 'page > 0')" = 0
stop

# A restart: nothing comes back from the sidecar.
start "$book"
shot 05_after_restart
check "after a restart the book is still on page 1" test "$(q "$db" "select page from progress")" = 0
check "and has no bookmarks" test "$(count bookmarks)" = 0
# Bookmark again, go back to the library, and reset from the book's details.
key m m; sleep 3
key Escape; key Escape; sleep 2 # Out of guided view, then out of the book.
check "the new bookmark is there" test "$(count bookmarks 'deleted_at is null')" = 1
# Books tab on the rail, then the one cover.
click 43 160; click 190 200
shot 06_library_detail
key shift+x; sleep 3
shot 07_library_dialog
key Tab; key Return; sleep 3
shot 08_library_reset
check "resetting from the library forgets the bookmark" test "$(count bookmarks)" = 0
check "and the sidecar's" test "$(side_count bookmarks)" = 0
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
