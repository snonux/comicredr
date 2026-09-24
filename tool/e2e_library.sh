#!/usr/bin/env bash
# End-to-end check of the library on the Linux build, over real comics from
# the test corpus (spike/fetch_corpus.py fetches them into test/corpus/).
# Builds a comics folder from the corpus plus a two-issue series whose
# ComicInfo.xml numbers run against the file names and a genuine RAR,
# starts the release build on it with --add-root, and drives it with real
# keys, mouse clicks and injected touches. Screenshots after each step;
# the index is checked with sqlite3 along the way.
#
#   tool/e2e_library.sh [corpus-dir]   # default test/corpus
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3, a C compiler, GTK 3 headers.
# Output: build/e2e-library/shot_*.png and build/e2e-library/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
out=build/e2e-library
rm -rf "$out" && mkdir -p "$out/Comics/Golden Age" "$out/Comics/Pepper&Carrot" "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Hard links where possible: the scan does not follow symlinks.
add() { cp -l "$1" "$2" 2>/dev/null || cp -r "$1" "$2"; }
for f in "$corpus"/golden-age/*.cbz; do add "$f" "$comics/Golden Age/"; done
add "$corpus/silver-age/reptisaurus-v2-005.cbz" "$comics/"
for f in "$corpus"/golden-age-pdf/*.pdf "$corpus"/bw-indie/*.pdf "$corpus"/modern-indie/*.pdf; do add "$f" "$comics/"; done
for d in "$corpus"/modern/pepper-carrot-*; do cp -r "$d" "$comics/Pepper&Carrot/"; done
python3 - "$comics" <<'EOF'
import sys, zipfile, glob
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
font = ImageFont.load_default(size=150)
# Files named a and b, but ComicInfo says b is #1: the library must follow
# ComicInfo, and ] must go #1 -> #2.
for name, number in (("spirit-a.cbz", "2"), ("spirit-b.cbz", "1")):
    with zipfile.ZipFile(f"{out}/{name}", "w", zipfile.ZIP_STORED) as z:
        for i in range(1, 5):
            im = Image.new("RGB", (1000, 1500), "#f4e9d0")
            d = ImageDraw.Draw(im)
            d.rectangle([60, 60, 940, 1440], outline="black", width=10)
            d.text((180, 500), f"#{number} p{i}", fill="black", font=font)
            im.save(f"{out}/.p.jpg", quality=85)
            z.write(f"{out}/.p.jpg", f"page{i}.jpg")
        z.writestr("ComicInfo.xml", f"<ComicInfo><Series>The Spirit</Series><Number>{number}</Number>"
                   f"<Title>Test issue {number}</Title><Year>1946</Year><Writer>Will Eisner</Writer></ComicInfo>")
import os; os.remove(f"{out}/.p.jpg")
open(f"{out}/real.cbr", "wb").write(b"Rar!\x1a\x07\x00" + b"\0" * 64)
open(f"{out}/README.txt", "w").write("not a comic")
EOF
echo "Comics folder:"; (cd "$comics" && find . -maxdepth 2 | sort | sed 's/^/  /')

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

touches="$out/touches"
: >"$touches"
start() {
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 4
  win=$(xdotool search --name ComicRedr | tail -1)
  # No window manager under Xvfb: a click on the tab title gives the new
  # window the keyboard.
  xdotool windowactivate --sync "$win" mousemove 60 24 click 1 2>/dev/null || true
  sleep 0.5
}
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
type() { xdotool type --delay 60 "$1" 2>/dev/null; sleep 0.8; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
touch_() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch_ down 0 "$1" "$2"; touch_ up 0 "$1" "$2"; sleep 0.8; }

# 4 golden age CBZ + Reptisaurus + 4 PDFs + 3 Pepper&Carrot folders + 2 Spirit.
expected=14
t0=$(date +%s.%N)
start --add-root "$comics"
for _ in $(seq 1 120); do
  [[ -f "$db" ]] && [[ "$(sql 'select count(*) from books' 2>/dev/null)" == "$expected" ]] && break
  sleep 0.5
done
t1=$(date +%s.%N)
sleep 1.5 # The last cover lands on screen.
echo "first scan: $(python3 -c "print(round($t1 - $t0, 1))") s from launch to $expected books indexed"
shot 01_series
check "books indexed" "$(sql 'select count(*) from books')" $expected
check "series" "$(sql 'select count(*) from series')" 11
check "Spirit #1 is spirit-b.cbz" "$(sql "select f.rel_path from books b join files f using (content_key) where b.title = 'The Spirit #1'")" spirit-b.cbz
check "covers" "$(ls "$out"/home/.cache/org.snonux.comicredr/covers/*.jpg 2>/dev/null | wc -l)" $expected

# Keys: move through the covers; the detail pane follows the selection.
key l;                   shot 02_select_first
key l l;                 shot 03_select_third
key j;                   shot 04_down_a_row
# The Books tab, a search, and reading a result.
key Tab;                 shot 05_books_tab
key slash; type weird;   shot 06_search_typed
key Return;              shot 07_search_results
key Return; sleep 2;     shot 08_reading_weird_comics
key l l;                 shot 09_page_3
key m m;                 shot 10_bookmarked
key Escape; sleep 1;     shot 11_back_in_library
check "bookmark saved" "$(sql 'select count(*) from bookmarks where mark is null')" 1
check "progress saved" "$(sql "select p.page from progress p join books b using (content_key) where b.title like 'Weird Comics%'")" 2
key Escape;              shot 12_search_cleared
# Series: into Pepper&Carrot, open the first episode, ] to the next.
key shift+Tab;           shot 13_series_tab
key slash; type pepper; key Return
key Return;              shot 14_in_series
key Return; sleep 2;     shot 15_reading_e06
key bracketright; sleep 2; shot 16_bracket_next_e22
key Escape; sleep 1;     shot 17_back_in_series
# The Spirit, by ComicInfo: #1 then ] to #2 though the files sort b after a.
key Escape; key Escape
key slash; type spirit; key Return; key Return; key Return; sleep 2; shot 18_spirit_1
key bracketright; sleep 2; shot 19_spirit_2
key bracketright;        shot 20_spirit_last_in_series
key Escape; key Escape; key Escape
# The Reading tab shows what was opened, the last one first. Six tabs:
# Reading, Series, Books, Collections, History, Folders.
key Tab Tab Tab Tab Tab; shot 21_reading_tab
key Tab Tab Tab Tab Tab; shot 22_folders_tab
# Folders: walk into the comics folder and its sub-folders and back out.
key l;                   shot 22a_folders_root_selected
key Return;              shot 22b_in_comics
key Return;              shot 22c_in_golden_age
key Escape;              shot 22d_back_in_comics
key l Return;            shot 22e_in_pepper_carrot
key Return; sleep 2;     shot 22f_reading_from_folder
key Escape; sleep 1;     shot 22g_back_in_pepper_carrot
key Escape Escape;       shot 22h_folders_top
# Mouse, on the Series tab: click a cover to select it, click again to read.
key Tab Tab; sleep 0.5
xdotool mousemove 190 200 click 1; sleep 1; shot 23_click_selects
xdotool click 1; sleep 2;                  shot 24_click_again_reads
key Escape; sleep 1

# A book copied into the folder while the app runs shows up by itself.
add "$corpus/silver-age/space-war-002.cbz" "$comics/Golden Age/"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books')" == "$((expected + 1))" ]] && break; sleep 0.5; done
sleep 1.5;                                 shot 25_new_book_appeared
check "book added while running" "$(sql 'select count(*) from books')" $((expected + 1))
rm "$comics/Pepper&Carrot/pepper-carrot-e35/"*
rmdir "$comics/Pepper&Carrot/pepper-carrot-e35"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books')" == "$expected" ]] && break; sleep 0.5; done
sleep 1.5;                                 shot 26_deleted_book_gone
check "book deleted while running" "$(sql 'select count(*) from books')" $expected

# Restart: the library is there at once, nothing is read again.
kill "$app"; wait "$app" 2>/dev/null || true
start
shot 27_restarted
grep -q 'Library scan failed' "$out/app.log" && { echo "FAIL  scan error in the log"; failed=1; }

# A phone-sized window: bottom tabs, and touch. A tap on a cover shows the
# book's page, a tap on Read opens it, taps turn pages, Esc comes back.
xdotool windowsize "$win" 420 860; sleep 1.5; shot 28_phone_layout
tap 108 230;                               shot 29_touch_detail
tap 210 514; sleep 1.5;                    shot 30_touch_read # Read, under the cover and title
tap 400 400;                               shot 31_touch_next_page
# Without a window manager keys go to the window under the pointer.
xdotool mousemove 200 300; key Escape; sleep 1; shot 32_back_to_phone_library

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
