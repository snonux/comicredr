#!/usr/bin/env bash
# End-to-end check of bookmarks on the Linux build: mm on and off, a
# panel bookmark in guided view, } and { between bookmarks, the list (M)
# with a note written in it, the marker on the page and the progress bar,
# the library's Bookmarks tab across two books, the sidecar, a restart and
# the phone-sized layout. Checks the index and the sidecar with sqlite3.
#
#   tool/e2e_bookmarks.sh book.cbz
#
# E2E_SKIP_BUILD=1 reuses the release build.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, zip, a C compiler, X11 headers.
# Output: build/e2e-bookmarks/*.png and build/e2e-bookmarks/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-bookmarks
rm -rf "$out" && mkdir -p "$out/home" "$out/lib/tmp"
src=$(realpath "$1")
lib="$PWD/$out/lib"
cbz="$lib/$(basename "$src")"
cp "$src" "$cbz"
# A second, shorter book: the first six pages of the first.
(cd "$out/lib/tmp" && unzip -qj "$cbz" && ls | sort | head -6 | zip -q ../short.cbz -@)
rm -rf "$out/lib/tmp"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
side="$(dirname "$cbz")/.$(basename "$cbz").crdb"
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
shot() { import -window root -crop "${2:-1280x720}+0+0" "$out/$1.png"; }
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
# The first book's live bookmarks, as page:panel:note.
live() {
  q "select page || ':' || ifnull(panel, '-') || ':' || ifnull(note, '') from bookmarks
     where deleted_at is null and mark is null
       and content_key = (select content_key from files where rel_path = '$(basename "$cbz")' limit 1)
     order by page, panel"
}
# The ribbon is drawn in the theme's primary colour at the page's top
# right; a bookmarked page has it, others show the page there.
ribbon() {
  local c
  c=$(convert "$out/$1.png" -crop 20x20+1230+8 -resize 1x1 -format '%[fx:int(255*b)] %[fx:int(255*r)]' info:)
  [[ ${c% *} -gt 150 && ${c#* } -lt 190 ]]
}
no_ribbon() { ! ribbon "$1"; }

start --add-root "$lib" "$cbz"
shot 01_reader
key m m
shot 02_bookmarked
check "mm bookmarks page 1" test "$(live)" = "0:-:"
check "the ribbon shows on a bookmarked page" ribbon 02_bookmarked
key l; shot 03_next_page
check "and not on the next one" no_ribbon 03_next_page
key h
key m m
check "mm again takes it off" test -z "$(live)"
check "kept as a removal for the sidecar" test "$(q 'select count(*) from bookmarks where deleted_at is not null')" = 1

# Page 1 whole; page 10 in guided view, which enters on the whole page,
# so l goes to panel 1.
key m m
key 1 0 shift+g
key v; sleep 6
key l
key m m
shot 04_guided_panel_bookmark
check "a guided-view bookmark keeps its panel" test "$(live | tr '\n' ' ')" = "0:-: 9:0: "
key v

# } and { step between them.
key Home
key braceright
check "} goes to the next bookmark" test "$(page_of)" = 9
key braceleft
check "{ goes back to the first" test "$(page_of)" = 0
key braceleft
shot 05_no_bookmark_before

# The list: open it, write a note on the second, jump to it from page 1.
key shift+m; sleep 2
shot 06_list
key j e; sleep 1
xdotool type --delay 60 'Space battle starts'; key Return; sleep 1
shot 07_list_with_note
check "the note is saved" test "$(live | tr '\n' ' ')" = "0:-: 9:0:Space battle starts "
key Return; sleep 2
check "Enter in the list jumps to the bookmark" test "$(page_of)" = 9
check "on its panel" test "$(q 'select panel from progress order by updated_at desc limit 1')" = 0
shot 08_jumped_from_list
# The progress bar's notches.
shot 09_progress_bar_notches 1280x720
convert "$out/09_progress_bar_notches.png" -crop 1280x40+0+630 -scale 100%x300% "$out/09b_notches_zoomed.png"

# A bookmark in the second book, then the library's Bookmarks tab.
key Escape; sleep 1
stop
start "$lib/short.cbz"
key l l
key m m
key Escape; sleep 2
key shift+m; sleep 2
shot 10_library_bookmarks_tab
check "the library has three bookmarks in two books" test "$(q 'select count(distinct content_key) || '"'/'"' || count(*) from bookmarks where deleted_at is null')" = "2/3"
# Back into the first book at the noted bookmark, found by its note.
key slash; xdotool type --delay 60 'battle'; key Return; sleep 1
shot 11_library_search_note
key Return; sleep 4
check "a row in the Bookmarks tab opens the book there" test "$(page_of)" = 9
shot 12_opened_from_library
stop

# The sidecar beside the book carries the bookmarks, the note and the removal.
check "the sidecar has both bookmarks and the note" test \
  "$(sqlite3 "$side" "select page || ':' || ifnull(panel, '-') || ':' || ifnull(note, '') from bookmarks where deleted_at is null order by page" | tr '\n' ' ')" \
  = "0:-: 9:0:Space battle starts "
check "and the removed ones as removals" test "$(sqlite3 "$side" 'select count(*) from bookmarks where deleted_at is not null')" -ge 2

# A fresh install (another laptop) reads them from the sidecar.
mv "$out/home" "$out/home-first"; mkdir -p "$out/home"
start --add-root "$lib" "$cbz"
check "a fresh install reads the bookmarks from the sidecar" test "$(live | tr '\n' ' ')" = "0:-: 9:0:Space battle starts "
key shift+m; sleep 3
shot 13_fresh_install_list

# Phone-sized: the status line's buttons and the library's tabs.
key Escape
xdotool windowsize "$win" 420 860; sleep 2
xdotool windowactivate --sync "$win" 2>/dev/null || xdotool windowfocus "$win"; sleep 0.5
key Home; sleep 1
shot 14_phone_reader 420x860
key Escape; sleep 1
key shift+m; sleep 2
shot 15_phone_library_bookmarks 420x860
stop

montage -label '%t' "$out"/[01]*.png -tile 4x -geometry 480x270+4+14 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
