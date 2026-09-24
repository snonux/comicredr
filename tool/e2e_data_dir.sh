#!/usr/bin/env bash
# End-to-end check of where the Linux build keeps its data, each case with
# a fresh HOME:
#   1. ~/Comics exists at the first start: the index database, covers,
#      page thumbnails and keys.toml are all in ~/Comics/.comicredr, nothing
#      of the app's lands in ~/.local/share, ~/.cache or ~/.config, and the
#      library (index, Folders tab, watcher) never shows .comicredr. A comic
#      copied in while it runs still arrives; a restart keeps the place.
#   2. No ~/Comics: the XDG folders, as before.
#   3. A database in the XDG folder already, then ~/Comics appears: the
#      database stays where it is, ~/Comics joins it, no .comicredr is made.
#   4. ~/Comics a symlink to a folder elsewhere: as 1, through the link,
#      and taken out of the library it stays out after a restart.
#   5. A dangling ~/Comics symlink: as if there were no ~/Comics.
# Checks the files on disk and the index with sqlite3, and takes screenshots
# (the ? overlay names the folder).
#
#   tool/e2e_data_dir.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-data-dir/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-data-dir
rm -rf "$out" && mkdir -p "$out/pages"
pages="$top/$out/pages"
for i in 1 2 3; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$pages/p$i.png"
done
cbz() { # cbz file
  mkdir -p "$(dirname "$1")"
  python3 - "$pages" "$1" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
        z.write(f, 'page' + f.name[1:])
EOF
}
# A folder book and a CBZ under $1/Comics.
comics_in() {
  mkdir -p "$1/Comics/Indie/Folder Book"
  cp "$pages"/*.png "$1/Comics/Indie/Folder Book/"
  cbz "$1/Comics/Indie/Test Comic 1.cbz"
}
# A keys.toml naming an action that doesn't exist, so the log shows which
# file was read.
keys_at() { mkdir -p "$(dirname "$1")"; printf '[keys]\n%s = ["F12"]\n' "$2" >"$1"; }

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:94
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
log=
start() { # start home [args...]
  local home=$1; shift
  log="$top/$out/$home.log"
  HOME="$top/$out/$home" "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
sql() { sqlite3 -batch -noheader "$1" "$2"; }
wait_files() { for _ in $(seq 1 40); do [[ "$(sql "$1" 'select count(*) from files' 2>/dev/null)" == "$2" ]] && break; sleep 0.5; done; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
# What the app wrote under HOME outside ~/Comics, by path; GTK's and
# Mesa's own caches aside.
outside() {
  (cd "$top/$out/$1" && find . -path ./Comics -prune -o -type f -print | grep -i comicredr || true) | sort | tr '\n' ' '
}

# 1. ~/Comics at the first start: everything in ~/Comics/.comicredr.
h="$top/$out/comics"
comics_in "$h"
keys_at "$h/Comics/.comicredr/keys.toml" fromComicsFolder
data="$h/Comics/.comicredr"
start comics
wait_files "$data/comicredr.sqlite" 2
sleep 2; shot 01_comics_library
key Tab Tab Tab Tab; shot 02_comics_folders_tab
key shift+slash; shot 03_comics_help_names_folder
key Escape
# A comic copied in while the app runs still arrives.
cbz "$h/Comics/Indie/Test Comic 2.cbz"
wait_files "$data/comicredr.sqlite" 3
stop
check "database in ~/Comics/.comicredr" "$(exists "$data/comicredr.sqlite")" yes
check "all three comics indexed" "$(sql "$data/comicredr.sqlite" 'select count(*) from files')" 3
check "~/Comics is the library folder" "$(sql "$data/comicredr.sqlite" 'select path from roots')" "$h/Comics"
check "nothing from .comicredr in the index" \
  "$(sql "$data/comicredr.sqlite" "select count(*) from files where rel_path like '%.comicredr%'")" 0
# The two CBZs hold the same pages, so they share one cover.
check "covers in .comicredr/cache" "$(find "$data/cache/covers" -maxdepth 1 -name '*.jpg' | wc -l)" \
  "$(sql "$data/comicredr.sqlite" 'select count(*) from books')"
check "keys.toml read from .comicredr" "$(grep -c 'no action called "fromComicsFolder"' "$log")" 1
# A book opened by itself, then its page grid: thumbnails.
start comics "$h/Comics/Indie/Test Comic 1.cbz"
key p; sleep 2; shot 04_comics_page_grid
key Escape
stop
check "page thumbnails in .comicredr/cache" "$(find "$data/cache/covers/pages" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')" 3
# A restart stays in ~/Comics/.comicredr.
start comics; stop
check "nothing of the app's outside ~/Comics" "$(outside comics)" ""
check "no XDG database" "$(exists "$h/.local/share/org.snonux.comicredr")" no
check "no XDG cache" "$(exists "$h/.cache/org.snonux.comicredr")" no

# 2. No ~/Comics: the XDG folders.
h="$top/$out/plain"
mkdir -p "$h" "$top/$out/Elsewhere"
cbz "$top/$out/Elsewhere/Elsewhere 1.cbz"
keys_at "$h/.config/comicredr/keys.toml" fromConfig
start plain --add-root "$top/$out/Elsewhere"
xdg="$h/.local/share/org.snonux.comicredr/comicredr.sqlite"
wait_files "$xdg" 1
key shift+slash; shot 05_plain_help_names_folder
stop
check "database in ~/.local/share" "$(exists "$xdg")" yes
check "covers in ~/.cache" "$(find "$h/.cache/org.snonux.comicredr/covers" -maxdepth 1 -name '*.jpg' | wc -l)" 1
check "keys.toml read from ~/.config" "$(grep -c 'no action called "fromConfig"' "$log")" 1
check "no ~/Comics made" "$(exists "$h/Comics")" no

# 3. An XDG database already (an empty library), then ~/Comics appears:
# the database stays, and ~/Comics joins it as the default folder.
h="$top/$out/existing"
mkdir -p "$h"
xdg="$h/.local/share/org.snonux.comicredr/comicredr.sqlite"
start existing; stop
check "first start without ~/Comics: XDG database" "$(exists "$xdg")" yes
comics_in "$h"
start existing
wait_files "$xdg" 2
shot 06_existing_database_library
stop
check "no .comicredr made" "$(exists "$h/Comics/.comicredr")" no
check "~/Comics joined the old database" "$(sql "$xdg" 'select path from roots')" "$h/Comics"
check "both comics in the old database" "$(sql "$xdg" 'select count(*) from files')" 2

# 4. ~/Comics a symlink to a folder elsewhere: .comicredr goes in the
# real folder, the library folder keeps the link's path, the watcher sees
# comics copied in through the link, and taken out it stays out.
h="$top/$out/linked"
real="$top/$out/Real Comics"
mkdir -p "$h" "$real"
comics_in "$real/.."; mv "$real/../Comics"/* "$real/"; rmdir "$real/../Comics"
ln -s "$real" "$h/Comics"
data="$real/.comicredr"
start linked
wait_files "$data/comicredr.sqlite" 2
key Tab Tab Tab Tab; shot 07_linked_folders_tab
cbz "$h/Comics/Indie/Linked 2.cbz"
wait_files "$data/comicredr.sqlite" 3
stop
check "linked: database in the real folder's .comicredr" "$(exists "$data/comicredr.sqlite")" yes
check "linked: library folder is the link's path" "$(sql "$data/comicredr.sqlite" 'select path from roots')" "$h/Comics"
check "linked: comic copied in through the link indexed" "$(sql "$data/comicredr.sqlite" 'select count(*) from files')" 3
check "linked: nothing from .comicredr in the index" \
  "$(sql "$data/comicredr.sqlite" "select count(*) from files where rel_path like '%.comicredr%'")" 0
check "linked: nothing of the app's outside ~/Comics" "$(outside linked)" ""
# Taken out of the library (the Folders tab, its one folder, the pane's
# "Take out of the library" button, as in e2e_default_folder.sh).
start linked
click 640 650
key Tab Tab Tab Tab; key Right
click "${REMOVE_X:-1080}" "${REMOVE_Y:-528}"
shot 08_linked_taken_out
stop
check "linked: taken out" "$(sql "$data/comicredr.sqlite" 'select count(*) from roots')" 0
start linked; stop
check "linked: still out after a restart" "$(sql "$data/comicredr.sqlite" 'select count(*) from roots')" 0

# 5. A dangling ~/Comics symlink is no ~/Comics.
h="$top/$out/dangling"
mkdir -p "$h"
ln -s "$top/$out/gone" "$h/Comics"
start dangling; stop
check "dangling: XDG database" "$(exists "$h/.local/share/org.snonux.comicredr/comicredr.sqlite")" yes
check "dangling: no library folder" \
  "$(sql "$h/.local/share/org.snonux.comicredr/comicredr.sqlite" 'select count(*) from roots')" 0
check "dangling: link left alone" "$(exists "$top/$out/gone")" no

montage -label '%t' "$out"/0*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
cat "$out"/*.log | grep -v XGetInputFocus | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
