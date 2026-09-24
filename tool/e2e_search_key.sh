#!/usr/bin/env bash
# End-to-end check of `/` in the library on the Linux build: on the Folders
# tab `/` puts the cursor in the search box, a click that opens a folder
# while the cursor is there leaves the keys working (they used to go dead),
# `/` again selects the last search so typing replaces it, Enter goes to the
# first result, Esc leaves the box and keeps the search. Opens the books it
# finds and checks which ones were read with sqlite3.
#
#   tool/e2e_search_key.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3. Makes its own books.
# Output: build/e2e-search-key/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-search-key
rm -rf "$out" && mkdir -p "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Four three-page books, each cover a colour: Comics/Golden Age/{Weird
# Tales, Space Ranger, Old/Mystery Men} and Comics/Modern/Weird Future.
book() { # book path colour
  local tmp
  tmp=$(mktemp -d)
  for i in 1 2 3; do
    convert -size 800x1200 xc:white -fill "$2" -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -fill white -draw 'rectangle 40,620 760,1160' "$tmp/p$i.jpg"
  done
  mkdir -p "$(dirname "$1")"
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for f in sys.argv[2:]: z.write(f, f.rsplit("/", 1)[1])' "$1" "$tmp"/p*.jpg
  rm -r "$tmp"
}
book "$comics/Golden Age/weird-tales.cbz" red
book "$comics/Golden Age/space-ranger.cbz" blue
book "$comics/Golden Age/Old/mystery-men.cbz" green
book "$comics/Modern/weird-future.cbz" yellow

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

start() {
  HOME="$top/$out/home" "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
type() { xdotool type --delay 60 "$1"; sleep 0.8; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
read_() { sql "select count(*) from progress p join books b using (content_key) where b.title = '$1'"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}

start --add-root "$comics"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 4 ]] && break; sleep 0.5; done
check "books indexed" "$(sql 'select count(*) from books')" 4

# The Folders tab (the rail, left), / and a search.
click 43 355;                         shot 01_folders
key slash; type weird;                shot 02_slash_weird
# A click opens the Comics folder while the cursor is in the box.
click 190 200;                        shot 03_clicked_into_comics
# / again: the box, with "weird" selected, so typing replaces it.
key slash;                            shot 04_slash_again_selected
type future;                          shot 05_future
# Enter: the first result (Modern) is selected; Enter goes in, Enter reads.
key Return;                           shot 06_enter_to_grid
key Return; key Return; sleep 1;      shot 07_reading_weird_future
key Escape
check "Weird Future opened from the search" "$(read_ 'Weird Future')" 1

# Esc leaves the box and keeps the search: the keys move through what it found.
key BackSpace;                        shot 08_back_in_comics
key slash; type ranger; key Escape;   shot 09_esc_keeps_search
key l; key Return;                    shot 10_golden_age_filtered
key Return; sleep 1;                  shot 11_reading_space_ranger
key Escape
check "Space Ranger opened after Esc" "$(read_ 'Space Ranger')" 1
check "nothing else opened" "$(sql 'select count(*) from progress')" 2
# Esc on the covers clears the search.
key Escape;                           shot 12_esc_clears
stop

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
