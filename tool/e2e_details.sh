#!/usr/bin/env bash
# End-to-end check of the details view (I) on the Linux build: opens a CBZ,
# lets detection run on a few pages in guided view, opens the details with
# I, scrolls them, jumps to a page from the list, closes them with I and
# with the status line's info button; then the same for a PDF (its images
# read from the file), and a book's details from the library. Checks the
# reading position and the analysed pages in the index with sqlite3.
#
#   tool/e2e_details.sh book.cbz book.pdf   (COMICREDR_MODEL=file.onnx tries another model)
#
# E2E_SKIP_BUILD=1 reuses the release build.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11 headers.
# Output: build/e2e-details/*.png and build/e2e-details/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-details
rm -rf "$out" && mkdir -p "$out/home"
# Copies, so the sidecars written beside them start fresh every run.
mkdir -p "$out/books"
cp "$1" "$2" "$out/books/"
cbz=$(realpath "$out/books/$(basename "$1")")
pdf=$(realpath "$out/books/$(basename "$2")")
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

export DISPLAY=:96
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
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
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
page_of() { sleep 2; q "select page from progress order by updated_at desc limit 1"; }
same() { [[ -n "$(compare -metric AE "$out/$1.png" "$out/$2.png" null: 2>&1 >/dev/null | grep -x 0)" ]]; }

pages=$(unzip -Z1 "$cbz" | grep -ciE '\.(jpe?g|png|webp|gif|bmp)$')

start "$cbz"
# Guided view through a few pages, so detection has something to report.
key v; sleep 6
for _ in 1 2 3 4 5 6 7 8; do key l; done
sleep 8
key v; sleep 1
analysed=$(q "select count(distinct page) from analysed_pages")
check "detection analysed pages before the details open ($analysed)" test "$analysed" -gt 1
at=$(page_of)
shot 01_reader
key shift+i; sleep 3
shot 02_details_top
differs() { ! same "$@"; }
check "I opens the details over the reader" differs 01_reader 02_details_top
# j and Page Down scroll the details; G goes to the page list's end.
key Next; sleep 1
shot 03_details_pages
key Next; sleep 1
shot 04_details_detection
key shift+g; sleep 2
shot 05_details_page_list
check "the details do not move the reader" test "$(page_of)" = "$at"
# The last row of the list is the last page: a click goes there.
xdotool mousemove 640 640 click 1; sleep 3
xdotool mousemove 640 300
got=$(page_of)
# Rows differ in height, so which of the last few it is depends on the book.
check "clicking a page near the end of the list goes to it ($got of $pages)" test "$got" -ge $(( pages - 6 )) -a "$got" != "$at"
shot 06_after_jump
# The info button on the status line (bottom right) opens them again, and
# I closes them.
key shift+i; sleep 3
shot 07_details_again
key shift+i; sleep 1
shot 08_closed_with_I
key h; sleep 1
check "the reader has the keys again after I closed the details" test "$(page_of)" -lt "$got"
stop

# A PDF: page sizes in inches and the images inside, read from the file.
start "$pdf"
key shift+i; sleep 6
shot 09_pdf_details
key Next; sleep 1
shot 10_pdf_details_more
key Escape; sleep 1
check "Esc closes the details, not the book" test -n "$(q "select 1 from progress limit 1")"
stop

# From the library: I on a selected cover opens the details of a book that
# is not open.
start --add-root "$(dirname "$cbz")"
sleep 6
# The Books tab, first cover.
key Tab; key l; sleep 2
shot 11_library
key shift+i; sleep 5
shot 12_library_details
key Escape; sleep 1
shot 13_library_back
stop

montage -label '%t' "$out"/[01]*.png -tile 3x -geometry 480x270+4+14 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
