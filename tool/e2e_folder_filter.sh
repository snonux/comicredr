#!/usr/bin/env bash
# End-to-end check of the Folders tab's filter (`F`) on the Linux build:
# by type, by size, by the file's modification date and by length, each picked in the
# filter window with Tab and Space, then a comic opened from what is left
# to prove which ones it let through; the filter kept across a restart;
# the filter line's part x and button clicked with the mouse, and the
# window's Clear all. Checks
# the index with sqlite3.
#
#   tool/e2e_folder_filter.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3 with Pillow. Makes its own books.
# Output: build/e2e-folder-filter/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-folder-filter
rm -rf "$out" && mkdir -p "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Comics/Golden Age: Mystery Men (CBZ, 2 years old), Space Ranger (CBZ,
# over 10 MB), Strip (one PNG) and Zeppelin (PDF); Comics/Modern/Pepper
# (a folder of pages) and Saga (a CBZ of 30 pages, the only long one).
# File order puts the PDF last.
pages() { # dir colour
  for i in 1 2 3; do
    convert -size 800x1200 xc:white -fill "$2" -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -fill white -draw 'rectangle 40,620 760,1160' "$1/p$i.jpg"
  done
}
cbz() { # path dir
  mkdir -p "$(dirname "$1")"
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for f in sys.argv[2:]: z.write(f, f.rsplit("/", 1)[1])' "$1" "$2"/*.jpg
}
tmp=$(mktemp -d)
mkdir -p "$tmp/a" "$tmp/b" "$tmp/c" "$comics/Golden Age" "$comics/Modern/Pepper"
pages "$tmp/a" red; cbz "$comics/Golden Age/mystery-men.cbz" "$tmp/a"
pages "$tmp/b" blue
python3 -c 'import os, sys; from PIL import Image
Image.frombytes("RGB", (2400, 3600), os.urandom(2400 * 3600 * 3)).save(sys.argv[1], quality=95)' "$tmp/b/p4.jpg"
cbz "$comics/Golden Age/space-ranger.cbz" "$tmp/b"
pages "$tmp/c" green
python3 -c 'import sys; from PIL import Image
ims = [Image.open(f).convert("RGB") for f in sys.argv[2:]]
ims[0].save(sys.argv[1], save_all=True, append_images=ims[1:])' "$comics/Golden Age/zeppelin.pdf" "$tmp"/c/*.jpg
convert -size 800x1200 xc:orange "$comics/Golden Age/strip.png"
pages "$comics/Modern/Pepper" purple
mkdir -p "$tmp/d"
for i in $(seq -w 1 30); do convert -size 400x600 xc:yellow -fill black -pointsize 60 -annotate +150+300 "$i" "$tmp/d/p$i.jpg"; done
cbz "$comics/Modern/saga.cbz" "$tmp/d"
rm -r "$tmp"
touch -d '2 years ago' "$comics/Golden Age/mystery-men.cbz"
ls -l "$comics/Golden Age"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# Xvfb takes a moment to listen, and with GDK_BACKEND=x11 the app dies on
# a display that is not there yet.
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

start() {
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys and clicks go. No
  # session bus and no XDG folders of whoever runs this: the app then
  # cannot reach their keyring or their own data. The bus address names a
  # socket that is not there, rather than being unset: unset, D-Bus falls
  # back to $XDG_RUNTIME_DIR/bus, which on a desktop is the real session's.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    HOME="$top/$out/home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" \
    "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
read_() { sql "select count(*) from progress p join books b using (content_key) where b.title = '$1'"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# chip N: in the filter window, the Nth chip from the first type (Tab N
# times) toggled with Space. Chips: CBZ, Image folder, PDF, Single image
# (0-3), Any size, Under 10, 10 to 50, 50 to 200, Over 200 MB (4-8), Any
# time, 24 hours, 7 days, 30 days, 12 months, Over a year (9-14),
# Completed or not, Completed only, Not completed (15-17; tool/e2e_completed.sh
# picks those), Any length, Under 24, 24 to 64, 64 to 200, Over 200 pages
# (18-22), then Clear all (23).
chip() { for _ in $(seq 1 "$1"); do xdotool key Tab; sleep 0.15; done; key space; }
# first_in_golden_age: from the top of the Folders tab, into Comics, then
# Golden Age (the first folder there), and reads the first comic in it.
first_in_golden_age() {
  key l; key Return; key Return; key Return; sleep 2; shot "$1"; key Escape; sleep 1
  key BackSpace; key BackSpace
}

start --add-root "$comics"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 6 ]] && break; sleep 0.5; done
check "books indexed" "$(sql 'select count(*) from books')" 6

click 43 355; shot 01_folders # The Folders tab (the rail, left).

# By type: F, the PDF chip. Only Zeppelin passes; Modern has none and goes.
key l; key Return; key Return
key shift+f; sleep 1; shot 02_filter_window
chip 2; shot 03_pdf_picked
key Escape; sleep 1; shot 04_golden_age_pdf_only
key BackSpace; shot 05_comics_modern_gone
key BackSpace
first_in_golden_age 06_read_zeppelin
check "the PDF opened first" "$(read_ 'Zeppelin')" 1
check "the filter is saved" "$(sql "select value like '%pdf%' from settings where key = 'library.folderFilter'")" 1
stop

# A restart keeps it; then by size: PDF off, 10 to 50 MB on.
start --add-root "$comics" # In the library: the comic read last would open otherwise.
click 43 355; shot 07_restart_filtered
key shift+f; sleep 1; chip 2; key Escape
key shift+f; sleep 1; chip 6; shot 08_size_picked; key Escape
first_in_golden_age 09_read_space_ranger
check "the big CBZ opened" "$(read_ 'Space Ranger')" 1

# By date: size back to any, Over a year ago.
key shift+f; sleep 1; chip 4; key Escape
key shift+f; sleep 1; chip 14; key Escape; shot 10_date_older
first_in_golden_age 11_read_mystery_men
check "the two-year-old CBZ opened" "$(read_ 'Mystery Men')" 1
check "the filter says so" "$(sql "select value like '%older%' from settings where key = 'library.folderFilter'")" 1

# The mouse, in Comics: the date part's x on the filter line takes it off.
key l; key Return; shot 12_comics_older
click 431 69; shot 13_x_clicked
check "the x cleared the filter" "$(sql "select count(*) from settings where key = 'library.folderFilter'")" 0
# The filter line's button opens the window; its Clear all (after the 23
# chips) clears it.
key shift+f; sleep 1; chip 14; key Escape
click 150 69; sleep 1; shot 14_window_by_click
chip 23; sleep 0.5; shot 15_clear_all; key Escape
check "Clear all cleared it" "$(sql "select count(*) from settings where key = 'library.folderFilter'")" 0

# By length, from the top: 24 to 64 pages leaves only Saga, so Modern is
# the first folder and Saga its first comic.
key BackSpace
key shift+f; sleep 1; chip 20; shot 16_length_picked; key Escape; sleep 1; shot 17_length_top
key l; key Return; key Return; key Return; sleep 2; shot 18_read_saga; key Escape; sleep 1
check "the 30-page comic opened" "$(read_ 'Saga')" 1
check "the filter says so" "$(sql "select value like '%to64%' from settings where key = 'library.folderFilter'")" 1
stop

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
