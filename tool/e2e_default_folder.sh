#!/usr/bin/env bash
# End-to-end check of the default library folder on the Linux build, each
# case with a fresh HOME: ~/Comics holding two comics joins the library by
# itself; without ~/Comics the library is empty (and Settings opens from
# it), and a ~/Comics made later is picked up at the next start; taken out
# of the library, ~/Comics stays out after a restart; a library folder of
# one's own keeps ~/Comics out. Checks the library folders with sqlite3
# and takes screenshots.
#
#   tool/e2e_default_folder.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-default-folder/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-default-folder
rm -rf "$out" && mkdir -p "$out/pages"
pages="$top/$out/pages"
for i in 1 2 3; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$pages/p$i.png"
done
# ~/Comics for a HOME: a CBZ and a folder book.
comics_in() {
  mkdir -p "$1/Comics/Indie/Folder Book"
  cp "$pages"/*.png "$1/Comics/Indie/Folder Book/"
  python3 - "$pages" "$1/Comics/Indie/Test Comic 1.cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
        z.write(f, 'page' + f.name[1:])
EOF
}

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# A HOME that had ~/Comics at its first start keeps its database there.
db() {
  local c="$top/$out/$1/Comics/.comicredr/comicredr.sqlite"
  [[ -f "$c" ]] && echo "$c" || echo "$top/$out/$1/.local/share/org.snonux.comicredr/comicredr.sqlite"
}
sql() { sqlite3 -batch -noheader "$(db "$1")" "$2"; }
start() { # start home [args...]
  local home=$1; shift
  HOME="$top/$out/$home" "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
files() { sql "$1" 'select count(*) from files'; }
wait_files() { for _ in $(seq 1 40); do [[ "$(files "$1" 2>/dev/null)" == "$2" ]] && break; sleep 0.5; done; }

# 1. ~/Comics with two comics: in the library at the first start.
mkdir -p "$out/with"; comics_in "$out/with"
start with
wait_files with 2
sleep 2; shot 01_with_comics_library
key Tab Tab Tab Tab; shot 02_with_comics_folders_tab
stop
check "~/Comics is the library folder" "$(sql with 'select path from roots')" "$top/$out/with/Comics"
check "both comics indexed" "$(files with)" 2

# 2. No ~/Comics: the library stays empty, Settings opens from it.
mkdir -p "$out/without"
start without
shot 03_without_comics_empty
check "no library folder" "$(sql without 'select count(*) from roots')" 0
# The empty library's Settings button, right of "Open a folder" in the
# 1280x720 window. Under Xvfb the first click on it only brings the window
# forward, as it has no window manager.
xdotool mousemove "${SETTINGS_X:-815}" "${SETTINGS_Y:-374}"; sleep 0.5
click "${SETTINGS_X:-815}" "${SETTINGS_Y:-374}"
click "${SETTINGS_X:-815}" "${SETTINGS_Y:-374}"
shot 04_without_comics_settings
key Escape
stop
# ... and a ~/Comics made later joins at the next start.
comics_in "$out/without"
start without
wait_files without 2
shot 05_comics_made_later
stop
check "a ~/Comics made later is added" "$(sql without 'select path from roots')" "$top/$out/without/Comics"

# 3. Taken out of the library, ~/Comics stays out after a restart.
start with
click 640 650
# The Folders tab, its one folder, then the pane's "Take out of the
# library" button.
key Tab Tab Tab Tab; key Right
shot 06_comics_selected
click "${REMOVE_X:-1080}" "${REMOVE_Y:-528}"
shot 07_comics_taken_out
stop
check "taken out" "$(sql with 'select count(*) from roots')" 0
check "remembered" "$(sql with "select value from settings where key = 'library.defaultFolderRemoved'")" true
start with
shot 08_restart_stays_out
stop
check "still out after a restart" "$(sql with 'select count(*) from roots')" 0

# 4. A library folder of one's own keeps ~/Comics out.
mkdir -p "$out/own"; comics_in "$out/own"; mkdir -p "$out/Elsewhere"
cp "$out/own/Comics/Indie/Test Comic 1.cbz" "$out/Elsewhere/"
start own --add-root "$top/$out/Elsewhere"
stop
start own
stop
check "only the folder added" "$(sql own 'select path from roots')" "$top/$out/Elsewhere"

montage -label '%t' "$out"/0*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
