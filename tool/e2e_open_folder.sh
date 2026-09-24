#!/usr/bin/env bash
# End-to-end check of `comicredr PATH` on the Linux build: a folder of
# comics inside the library opens the Folders tab at that folder, one
# outside it is added to the library and shown, whether it holds comic
# files or image-folder comics with a loose cover.jpg, given with a
# relative path and a trailing slash; a folder of page images and a CBZ
# open in the reader. Checks the library folders with sqlite3
# and takes a screenshot of each start.
#
#   tool/e2e_open_folder.sh [corpus-dir]   # default test/corpus
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3.
# Output: build/e2e-open-folder/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
top=$PWD
out=build/e2e-open-folder
rm -rf "$out" && mkdir -p "$out/Comics/Golden Age/Old" "$out/Comics/Pepper&Carrot" "$out/Elsewhere/Silver" "$out/home"
comics="$PWD/$out/Comics"
elsewhere="$PWD/$out/Elsewhere"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
cp "$corpus"/golden-age/all-top-comics-6.cbz "$corpus"/golden-age/weird-comics-004.cbz "$comics/Golden Age/"
cp "$corpus"/golden-age/mercy-for-millions.cbz "$comics/Golden Age/Old/"
cp -r "$corpus/modern/pepper-carrot-e06" "$comics/Pepper&Carrot/"
cp "$corpus/silver-age/space-war-002.cbz" "$elsewhere/Silver/"
cp "$corpus/silver-age/reptisaurus-v2-005.cbz" "$elsewhere/"
# Image-folder comics beside a cover.jpg, as a download or a media tool
# leaves them.
pc="$PWD/$out/Pepper Episodes"
mkdir -p "$pc"
cp -r "$corpus/modern/pepper-carrot-e22" "$corpus/modern/pepper-carrot-e35" "$pc/"  # Not e06: a copy of a book shows once, where it was found first.
cp "$(ls "$corpus"/modern/pepper-carrot-e06/* | head -1)" "$pc/cover.jpg"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:98
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
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}

# The library knows Comics.
start --add-root "$comics"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from files' 2>/dev/null)" == 4 ]] && break; sleep 0.5; done
stop
check "library folders" "$(sql 'select count(*) from roots')" 1

# 1. A folder inside it: the Folders tab at Golden Age; Backspace goes up.
start "$comics/Golden Age";               shot 01_golden_age_from_cli
key BackSpace;                             shot 02_backspace_to_comics
stop
check "no folder added for one inside the library" "$(sql 'select count(*) from roots')" 1

# 2. A folder outside the library: added, and shown.
start "$elsewhere";                        shot 03_elsewhere_added
sleep 2; key Return;                       shot 04_into_silver
stop
check "folder outside the library added" "$(sql "select count(*) from roots where path = '$elsewhere'")" 1
check "its books indexed" "$(sql "select count(*) from files f join roots r on r.id = f.root_id where r.path = '$elsewhere'")" 2

# 3. Image-folder comics and a cover.jpg, by a relative path with a
# trailing slash: the Folders tab, not one book.
cd "$out"; start "Pepper Episodes/"; cd "$top"; shot 05_image_folders_relative
stop
check "image-folder comics listed one by one" \
  "$(sql "select count(*) from files f join roots r on r.id = f.root_id where r.path = '$pc'")" 3

# 4. A folder of page images is a book; so is a CBZ.
start "$comics/Pepper&Carrot/pepper-carrot-e06"; shot 06_folder_book_reads
stop
start "$comics/Golden Age/weird-comics-004.cbz";  shot 07_cbz_reads
stop
check "no folder added for a book" "$(sql 'select count(*) from roots')" 3

montage -label '%t' "$out"/shot_*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
