#!/usr/bin/env bash
# End-to-end check of the page grid (p) and the scrubber preview on the
# Linux build: opens a CBZ, picks pages in the grid by key, previews pages
# by hovering and dragging along the progress bar with the mouse, then does
# the grid on a PDF, and restarts to see the thumbnails come from disk.
# Checks the reading position in the index with sqlite3 after each jump.
#
#   tool/e2e_pages.sh book.cbz book.pdf
#
# E2E_SKIP_BUILD=1 reuses the release build.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11 headers.
# Output: build/e2e-pages/*.png and build/e2e-pages/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-pages
rm -rf "$out" && mkdir -p "$out/home"
cbz=$(realpath "$1")
pdf=$(realpath "$2")
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
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
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
shot() { import -window root -crop 1280x720+0+0 "$out/$1.png"; }
start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$1" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 8
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool mousemove 640 300; sleep 0.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
# The page the index has for the open book (the one read last), once the
# debounced save is in.
page_of() { sleep 2; q "select page from progress order by updated_at desc limit 1"; }
thumbs() { find "$out/home/.cache" -path '*covers/pages/*' -name '*.jpg' | wc -l; }

# The window is 1280x720; the status line is its bottom 60 px, and the
# progress bar's band the 28 px above it.
bar_y=648
pages=$(unzip -Z1 "$cbz" | grep -ciE '\.(jpe?g|png|webp|gif|bmp)$')

start "$cbz"
shot 01_reader
key p; sleep 3
shot 02_grid
check "the grid made thumbnails of the pages it shows" test "$(thumbs)" -gt 4
# 12G in the grid selects page 12, Enter jumps there.
key 1 2 shift+g; sleep 1
shot 03_grid_page12_selected
key Return; sleep 2
shot 04_page12
check "Enter in the grid jumps to page 12" test "$(page_of)" = 11
# The grid opens on page 12; moving and then Esc changes nothing.
key p; sleep 2
shot 05_grid_on_page12
key Right Right Down; key Escape; sleep 1
check "Esc closes the grid without jumping" test "$(page_of)" = 11
# '' goes back to before the jump.
key apostrophe apostrophe
check "'' goes back to page 1" test "$(page_of)" = 0

# Hover over the bar: a preview of the page under the pointer, no jump.
xdotool mousemove 320 "$bar_y"; sleep 0.3; xdotool mousemove 330 "$bar_y"; sleep 3
shot 06_hover_preview
check "hovering does not jump" test "$(page_of)" = 0
# Drag from a quarter of the way to three quarters: the preview follows,
# and letting go jumps there.
xdotool mousedown 1; sleep 0.3
for x in 400 500 600 700 800 900 960; do xdotool mousemove "$x" "$bar_y"; sleep 0.2; done
sleep 3
shot 07_drag_preview
xdotool mouseup 1; sleep 2
shot 08_after_drag
want=$(( 960 * pages / 1280 ))
got=$(page_of)
check "letting go jumps to the page under the pointer ($want, got $got)" test "$got" -ge $(( want - 1 )) -a "$got" -le $(( want + 1 ))
# A click on the bar jumps straight there.
xdotool mousemove 20 "$bar_y" click 1; sleep 2
xdotool mousemove 640 300
check "a click on the bar jumps to the start" test "$(page_of)" = 0
stop

# A PDF renders its thumbnails through the shared PDFium isolate.
before=$(thumbs)
start "$pdf"
key p; sleep 8
shot 09_pdf_grid
check "the PDF grid made thumbnails" test "$(thumbs)" -gt "$before"
key End; sleep 5
shot 10_pdf_grid_end
key Return; sleep 3
last=$(page_of)
check "End and Enter in the PDF grid go to the last page" test "$last" -gt 20
stop

# After a restart the thumbnails come from disk: none is made again.
stamp=$(find "$out/home/.cache" -path '*covers/pages/*' -name '*.jpg' -printf '%p %T@\n' | sort | md5sum)
count=$(thumbs)
start "$cbz"
key p; sleep 3
shot 11_grid_after_restart
check "no thumbnail was made again" test "$(find "$out/home/.cache" -path '*covers/pages/*' -name '*.jpg' -printf '%p %T@\n' | sort | md5sum)" = "$stamp"
check "and none is missing" test "$(thumbs)" = "$count"
key Escape
stop

montage -label '%t' "$out"/[01]*.png -tile 4x -geometry 480x270+4+14 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
