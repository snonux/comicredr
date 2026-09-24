#!/usr/bin/env bash
# End-to-end check of shuffle on the Folders tab (S, gs) in the Linux
# build: a folder holding two CBZs, a PDF and a folder of page images.
# S shows a random page of each book instead of its cover (never page 1,
# the cover), made through the page thumbnails' cache; moving around the
# grid keeps the picks, gs picks others, a book still opens on its first
# page, and shuffle is remembered across a restart until S turns it off.
# Checks the thumbnail files, the screen and the settings with sqlite3.
#
#   tool/e2e_shuffle.sh [corpus-dir]   # default test/corpus
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3.
# Output: build/e2e-shuffle/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
top=$PWD
out=build/e2e-shuffle
rm -rf "$out" && mkdir -p "$out/Comics/Mixed" "$out/home"
mixed="$PWD/$out/Comics/Mixed"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
cp "$corpus/silver-age/reptisaurus-v2-005.cbz" "$corpus/silver-age/space-war-002.cbz" "$mixed/"
cp "$corpus/golden-age-pdf/first-love-illustrated-078.pdf" "$mixed/"
cp -r "$corpus/modern/pepper-carrot-e06" "$mixed/"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:97
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
sql() { python3 -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone(); print(r[0] if r else "")' "$db" "$1"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
pages() { find "$top/$out/home/.cache" -path '*/covers/pages/*' -name '*.jpg' 2>/dev/null | sort; }
# Waits until [n] books have a page made, up to 30 s.
made() {
  for _ in $(seq 1 60); do
    [[ $(pages | xargs -rn1 dirname | sort -u | wc -l) -ge $1 ]] && return
    sleep 0.5
  done
}
# How different two screenshots are over the grid (the middle of the
# window, header and status line left out), as ImageMagick's RMSE 0..1.
differ() {
  compare -metric RMSE <(convert "$top/$out/shot_$1.png" -crop 700x640+90+100 png:-) \
    <(convert "$top/$out/shot_$2.png" -crop 700x640+90+100 png:-) null: 2>&1 | sed 's/.*(\(.*\))/\1/' || true
}

start --add-root "$top/$out/Comics"
for _ in $(seq 1 60); do [[ "$(sql 'select count(*) from files' 2>/dev/null)" == 4 ]] && break; sleep 0.5; done
check "books indexed" "$(sql 'select count(*) from files')" 4

# Folders tab (four Tabs on from Series), into Comics, into Mixed.
key Tab Tab Tab Tab
key l Return; key Return
sleep 1;                                     shot 01_covers
check "no pages made before shuffle" "$(pages | wc -l)" 0

# S: a random page of each book, never page 1.
key S; made 4; sleep 1;                      shot 02_shuffled
check "a page made for each book (CBZ, PDF, folder)" "$(pages | xargs -rn1 dirname | sort -u | wc -l)" 4
check "no pick is the cover" "$(pages | grep -c '/1\.jpg$' || true)" 0
check "the PDF's page came through" \
  "$(pages | grep -c "/$(sql "select content_key from books where format = 'pdf'")/" || true)" 1
check "shuffle saved" "$(sql "select value from settings where key = 'library.shuffle'")" true
d=$(differ 01_covers 02_shuffled)
python3 -c "import sys; sys.exit(0 if float('$d') > 0.05 else 1)" && echo "ok    tiles differ from the covers: RMSE $d" ||
  { echo "FAIL  tiles look like the covers: RMSE $d"; failed=1; }
first=$(pages)

# Moving around the grid keeps the picks.
key l l l; key h h h;                        shot 03_moved
check "moving keeps the picks" "$(pages | md5sum | cut -c1-8)" "$(echo "$first" | md5sum | cut -c1-8)"
d=$(differ 02_shuffled 03_moved)
python3 -c "import sys; sys.exit(0 if float('$d') < 0.05 else 1)" && echo "ok    same pages after moving: RMSE $d" ||
  { echo "FAIL  pages changed while moving: RMSE $d"; failed=1; }

# gs: other pages. Books of 36 and 52 pages rarely pick the same again.
key g s; sleep 3;                            shot 04_reshuffled
check "gs picked other pages" "$([[ $(pages | wc -l) -gt $(echo "$first" | wc -l) ]] && echo more || echo same)" more
d=$(differ 02_shuffled 04_reshuffled)
python3 -c "import sys; sys.exit(0 if float('$d') > 0.02 else 1)" && echo "ok    reshuffled tiles differ: RMSE $d" ||
  { echo "FAIL  reshuffle changed nothing on screen: RMSE $d"; failed=1; }

# A book opens where it was left: never read, so its first page.
key Return; sleep 3;                         shot 05_opened
check "opened on the first page" "$(sql 'select page from progress limit 1')" "0"
key Escape; sleep 1;                         shot 06_back
stop

# Restart: still on; S turns it off. A book was opened, so the library
# starts on Reading: five Tabs to Folders.
start
key Tab Tab Tab Tab Tab
key l Return; key Return
sleep 3;                                     shot 07_after_restart
d=$(differ 01_covers 07_after_restart)
python3 -c "import sys; sys.exit(0 if float('$d') > 0.05 else 1)" && echo "ok    still shuffled after a restart: RMSE $d" ||
  { echo "FAIL  shuffle lost on restart: RMSE $d"; failed=1; }
key S; sleep 1;                              shot 08_covers_again
check "shuffle off saved" "$(sql "select value from settings where key = 'library.shuffle'")" false
d=$(differ 01_covers 08_covers_again)
python3 -c "import sys; sys.exit(0 if float('$d') < 0.05 else 1)" && echo "ok    covers back: RMSE $d" ||
  { echo "FAIL  covers not back: RMSE $d"; failed=1; }
stop

montage -label '%t' "$out"/shot_*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
