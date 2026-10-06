#!/usr/bin/env bash
# End-to-end check of gc and * on the open comic, on the Linux build with a
# fresh HOME whose ~/Comics holds two comics. In the reader: gc with Esc
# changes nothing, gc with a typed name adds the comic to a new collection.
# Over the page grid (p): * adds it to the Favourites and * again takes it
# out, gc adds it to a second collection, and l Enter still picks a page,
# so the keys went back to the grid. Over the bookmark list (M): gc with a
# collection it is in already adds no row, * adds the favourite. The other
# comic is never touched. After a restart the index says the same. Checks
# the index and the sidecar with sqlite3 and takes screenshots.
#
#   tool/e2e_open_comic_collections.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-open-comic-collections/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-open-comic-collections
rm -rf "$out" && mkdir -p "$out/pages" "$out/home/Comics"
home="$top/$out/home"
for name in Alpha Bravo; do
  for i in 1 2 3 4; do
    convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
      -fill black -stroke none -pointsize 80 -annotate +120+400 "$name $i" "$out/pages/p$i.png"
  done
  python3 - "$out/pages" "$home/Comics/$name 1.cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
        z.write(f, 'page' + f.name[1:])
EOF
done

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
# The index lives in ~/Comics/.comicredr when ~/Comics exists.
sql() { sqlite3 -batch -noheader "$home/Comics/.comicredr/comicredr.sqlite" "$1"; }
collections() { # collections book.cbz: the collections it is in, by name
  sql "select coalesce(group_concat(name, ', '), '') from (select c.name from collection_books c
       join files f on f.content_key = c.content_key
       where f.rel_path = '$1' and c.removed_at is null order by c.name)"
}
rows() { sql "select count(*) from collection_books"; }
page() { # page book.cbz: the page the index has it on, from 0
  sql "select p.page from progress p join files f on f.content_key = p.content_key where f.rel_path = '$1'"
}
sidecar() { # sidecar book.cbz: the collections its sidecar has it in
  sqlite3 -batch -noheader "$home/Comics/.$1.crdb" \
    "select coalesce(group_concat(name, ', '), '') from (select name from collections where removed_at is null order by name)"
}
start() {
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys go.
  HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
# Both keys of a sequence in one go, well inside the resolver's time-out.
gc() { xdotool key g c 2>/dev/null; sleep 1.2; }
say() { xdotool type --delay 40 "$1" 2>/dev/null; sleep 0.5; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
wait_files() { for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from files' 2>/dev/null)" == "$1" ]] && break; sleep 0.5; done; }

start
wait_files 2
sleep 2
# Under Xvfb, with no window manager, the first click only brings the
# window forward.
click 640 450

# 1. In the reader: open Alpha. gc then Esc writes nothing and keeps the
# comic open; gc with a name makes the collection.
key l; key Return
sleep 2
gc
shot 01_reader_gc_dialog
key Escape
check "gc then Esc in the reader" "$(rows)" 0
gc
say "To read next"
key Return
shot 02_reader_added
check "gc in the reader" "$(collections 'Alpha 1.cbz')" "To read next"

# 2. Over the page grid: * in and out, gc, and the grid still has the keys.
key p
key asterisk
shot 03_grid_star
check "* over the page grid" "$(collections 'Alpha 1.cbz')" "Favourites, To read next"
key asterisk
check "* again over the page grid" "$(collections 'Alpha 1.cbz')" "To read next"
gc
shot 04_grid_gc_dialog
say "Grid picks"
key Return
shot 05_grid_added
check "gc over the page grid" "$(collections 'Alpha 1.cbz')" "Grid picks, To read next"
key l; key Return
sleep 1.5
shot 06_grid_picked_page
check "l Enter in the grid after gc goes to page 2" "$(page 'Alpha 1.cbz')" 1

# 3. Over the bookmark list: a collection it is in already adds no row;
# * makes it a favourite.
key M
before=$(rows)
gc
say "Grid picks"
key Return
shot 07_list_already
check "gc with a collection it is in adds no row" "$(rows)" "$before"
key asterisk
shot 08_list_star
check "* over the bookmark list" "$(collections 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"
check "the other comic is untouched" "$(collections 'Bravo 1.cbz')" ""
key Escape
key Escape
sleep 1
stop
check "Alpha's sidecar" "$(sidecar 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"

# 4. After a restart the index says the same.
start
click 640 450
shot 09_after_restart
stop
check "after a restart" "$(collections 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"

montage -label '%t' "$out"/0*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
