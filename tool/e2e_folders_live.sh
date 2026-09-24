#!/usr/bin/env bash
# End-to-end check that the Folders tab follows the disk while it is open:
# with the library shown inside a folder, adds and removes a CBZ, a PDF and
# a folder of pages, makes a new sub-folder (empty first, and one with a
# comic dropped in at once), renames and moves a comic, deletes a
# sub-folder, and finally deletes the folder being shown. The index is
# checked with sqlite3 after each step, and a screenshot shows the screen.
#
#   tool/e2e_folders_live.sh [corpus-dir]   # default test/corpus
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3.
# Output: build/e2e-folders-live/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
out=build/e2e-folders-live
rm -rf "$out" && mkdir -p "$out/Comics/Golden Age" "$out/home" "$out/spare"
comics="$PWD/$out/Comics"
ga="$comics/Golden Age"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
cp "$corpus"/golden-age/all-top-comics-6.cbz "$corpus"/golden-age/weird-comics-004.cbz "$ga/"
cp "$corpus/silver-age/reptisaurus-v2-005.cbz" "$comics/"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
books() { sql "select count(*) from files"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# Waits for the index to hold $1 files: the watch waits for 2 s of quiet,
# then scans.
await() {
  for _ in $(seq 1 40); do [[ "$(books)" == "$1" ]] && break; sleep 0.5; done
  sleep 1.5 # The grid redraws.
}
has() { sql "select count(*) from files where rel_path = '$1'"; }

HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr --add-root "$comics" >>"$out/app.log" 2>&1 &
app=$!
sleep 4
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowactivate --sync "$win" mousemove 60 24 click 1 2>/dev/null || true
await 3
check "first scan" "$(books)" 3

# Series is the first tab on a fresh library; Folders is two back.
xdotool mousemove 640 450; sleep 0.3
key shift+Tab shift+Tab
key l Return                  # Into Comics.
key Return;                   shot 01_in_golden_age

add_step() { # add_step name expected-count
  await "$2"; shot "$1"; check "$1" "$(books)" "$2"
}
cp "$corpus/silver-age/space-war-002.cbz" "$ga/";                        add_step 02_cbz_added 4
cp "$corpus/golden-age-pdf/first-love-illustrated-078.pdf" "$ga/";       add_step 03_pdf_added 5
cp -r "$corpus/modern/pepper-carrot-e06" "$ga/";                         add_step 04_folder_book_added 6
mkdir "$ga/New Arc"; sleep 4
cp "$corpus/golden-age/mercy-for-millions.cbz" "$ga/New Arc/";           add_step 05_comic_in_new_subfolder 7
mkdir "$ga/Quick" && cp "$corpus/golden-age/international-comics-004.cbz" "$ga/Quick/"
                                                                          add_step 06_new_subfolder_with_comic_at_once 8
mv "$ga/weird-comics-004.cbz" "$ga/Weird Comics 004 renamed.cbz"
for _ in $(seq 1 40); do [[ "$(has 'Golden Age/Weird Comics 004 renamed.cbz')" == 1 ]] && break; sleep 0.5; done
sleep 1.5; shot 07_renamed
check "renamed" "$(has 'Golden Age/Weird Comics 004 renamed.cbz')$(books)" 18
mv "$ga/space-war-002.cbz" "$ga/New Arc/"
for _ in $(seq 1 40); do [[ "$(has 'Golden Age/New Arc/space-war-002.cbz')" == 1 ]] && break; sleep 0.5; done
sleep 1.5; shot 08_moved_into_subfolder
check "moved" "$(has 'Golden Age/New Arc/space-war-002.cbz')$(books)" 18
rm "$ga/first-love-illustrated-078.pdf";                                  add_step 09_pdf_removed 7
rm -r "$ga/pepper-carrot-e06";                                            add_step 10_folder_book_removed 6
rm -r "$ga/New Arc";                                                      add_step 11_subfolder_deleted 4
# Into Quick, then delete it while it is shown: the view goes up to Golden Age.
key g g; key Return; sleep 0.5;                                           shot 12_in_quick
rm -r "$ga/Quick";                                                        add_step 13_shown_folder_deleted 3

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
