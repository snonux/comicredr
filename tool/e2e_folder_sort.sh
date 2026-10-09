#!/usr/bin/env bash
# End-to-end check of the Folders tab's sort on the Linux build: gS and an
# Alt+letter in its window (pages, size, modified, last read), gO to turn
# an order round, go to step to the next one, each proved by the comic
# that opens first; the order kept across a restart; the sort button on
# the filter line clicked with the mouse. Checks the index with sqlite3.
#
#   tool/e2e_folder_sort.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3 with Pillow. Makes its own books.
# Output: build/e2e-folder-sort/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-folder-sort
rm -rf "$out" && mkdir -p "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Comics: Alpha (3 pages, changed 3 days ago), Beta (12 pages and over
# 10 MB, changed a year ago) and Gamma (6 pages, changed just now). By name
# Alpha is first, by pages and size Beta, by date Gamma.
pages() { # dir colour count
  for i in $(seq -w 1 "$3"); do
    convert -size 400x600 xc:"$2" -fill black -pointsize 60 -annotate +150+300 "$i" "$1/p$i.jpg"
  done
}
cbz() { # path dir
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for f in sys.argv[2:]: z.write(f, f.rsplit("/", 1)[1])' "$1" "$2"/*.jpg
}
tmp=$(mktemp -d)
mkdir -p "$tmp/a" "$tmp/b" "$tmp/c" "$comics"
pages "$tmp/a" red 3; cbz "$comics/alpha.cbz" "$tmp/a"
pages "$tmp/b" blue 11
python3 -c 'import os, sys; from PIL import Image
Image.frombytes("RGB", (2400, 3600), os.urandom(2400 * 3600 * 3)).save(sys.argv[1], quality=95)' "$tmp/b/p99.jpg"
cbz "$comics/beta.cbz" "$tmp/b"
pages "$tmp/c" green 6; cbz "$comics/gamma.cbz" "$tmp/c"
rm -r "$tmp"
touch -d '3 days ago' "$comics/alpha.cbz"
touch -d '1 year ago' "$comics/beta.cbz"
ls -l "$comics"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

start() {
  # As in e2e_folder_filter.sh: X11 in Xvfb, no session bus, no XDG folders
  # of whoever runs this.
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
sort_() { sql "select coalesce((select value from settings where key = 'library.folderSort'), 'unset')"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# first NAME: from the top of the Folders tab, into Comics, opens the
# first comic there and back; prints the title of the comic read last.
first() {
  key l; key Return; key Return; sleep 2; shot "$1"; key Escape; sleep 1
  key BackSpace
  # Closing the comic writes its sidecar and the index; a read of the index
  # in the middle of that makes the app's write fail as locked.
  sleep 2
  sql "select b.title from progress p join books b using (content_key) order by p.updated_at desc limit 1"
}
# window LETTER: gS, then Alt and the order's letter, then Alt+D.
window() { key g shift+s; sleep 1; key alt+"$1"; key alt+d; }

start --add-root "$comics"
for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 3 ]] && break; sleep 0.5; done
check "books indexed" "$(sql 'select count(*) from books')" 3
click 43 355; shot 01_folders # The Folders tab (the rail, left).

check "by name, at first" "$(first 02_name)" Alpha
check "nothing saved for the usual order" "$(sort_)" unset

key g shift+s; sleep 1; shot 03_window
key alt+p; key alt+d
check "the window saves Pages" "$(sort_)" '"pages"'
check "most pages first" "$(first 04_pages)" Beta
key g shift+o; sleep 0.5; shot 05_reversed_notice
check "gO saves it reversed" "$(sort_)" '"pages:reversed"'
check "fewest pages first" "$(first 06_pages_reversed)" Alpha
key g shift+o # Back to most first.

window s
check "biggest first" "$(first 07_size)" Beta
window m
check "the newest file first" "$(first 08_modified)" Gamma
window l
check "last read first" "$(first 09_read)" Gamma
key g shift+o
# Read so far: Alpha, Beta, Alpha, Beta, Gamma, Gamma; Alpha's last is the earliest.
check "earliest read first" "$(first 10_read_reversed)" Alpha
check "saved" "$(sort_)" '"read:reversed"'
stop

# A restart keeps it: Alpha was read last now, so Beta is the earliest.
start --add-root "$comics" # In the library: the comic read last would open otherwise.
click 43 355; shot 11_restart
check "the order is kept across a restart" "$(first 12_restart_read_reversed)" Beta
# go steps to the next order, the way round kept: Modified, oldest first.
key g o; sleep 0.5; shot 13_go_notice
check "go saves the next order" "$(sort_)" '"modified:reversed"'
check "the oldest file first" "$(first 14_modified_reversed)" Beta

# The mouse: the sort button at the end of the filter line (its text ends
# left of the details pane, which starts at x 900 in this 1280 px window)
# opens the window; Alt+N there picks Name, the way round kept, and Esc
# closes it.
click 800 68; sleep 1; shot 15_window_by_click
key alt+n; key Escape
check "Name picked after a click on the button" "$(sort_)" '"name:reversed"'
check "Z to A: Gamma first" "$(first 16_name_reversed)" Gamma
stop

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
