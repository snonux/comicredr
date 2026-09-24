#!/usr/bin/env bash
# End-to-end check of favourites on the Linux build, with a fresh HOME
# whose ~/Comics holds three comics: * in the reader adds the open comic,
# gf there goes to the Favourites; * on a cover in the library adds a
# second; the header's star opens the Favourites; x takes one out there;
# after a restart gf still lists the one left. Checks the index and the
# sidecars with sqlite3 and takes screenshots.
#
#   tool/e2e_favourites.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-favourites/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-favourites
rm -rf "$out" && mkdir -p "$out/pages" "$out/home/Comics"
home="$top/$out/home"
for name in Alpha Bravo Charlie; do
  for i in 1 2 3; do
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
export DISPLAY=:94
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
sql() { sqlite3 -batch -noheader "$home/.local/share/org.snonux.comicredr/comicredr.sqlite" "$1"; }
favourites() {
  sql "select group_concat(rel_path, ', ') from (select f.rel_path from collection_books c
       join files f on f.content_key = c.content_key
       where c.name = 'Favourites' and c.removed_at is null order by f.rel_path)"
}
sidecar() { # sidecar book: its Favourites row, "in" or "out"
  sqlite3 -batch -noheader "$home/Comics/.$1.crdb" \
    "select case when removed_at is null then 'in' else 'out' end from collections where name = 'Favourites'"
}
start() {
  HOME="$home" "$top/build/linux/x64/release/bundle/comicredr" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
wait_files() { for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from files' 2>/dev/null)" == "$1" ]] && break; sleep 0.5; done; }

start
wait_files 3
sleep 2
# Under Xvfb, with no window manager, the first click only brings the
# window forward.
click 640 450
shot 01_library

# 1. From the reader: open Alpha, * adds it, gf goes to the Favourites.
key l; key Return
sleep 2
key asterisk
shot 02_reader_star
check "* in the reader" "$(favourites)" "Alpha 1.cbz"
key g f
sleep 1
shot 03_gf_from_reader

# 2. From the library: back to the collections, the Books tab, Bravo's
# cover, *.
key Escape
key shift+Tab
key l; key l
key asterisk
shot 04_library_star
check "* on a cover" "$(favourites)" "Alpha 1.cbz, Bravo 1.cbz"

# 3. The header's star opens the Favourites, from the Books tab.
click "${STAR_X:-751}" "${STAR_Y:-28}"
shot 05_star_menu

# 4. x takes the selected one (Alpha, the first) out; it leaves the list.
key x
sleep 1
shot 06_taken_out
check "x in the Favourites" "$(favourites)" "Bravo 1.cbz"
stop
check "Alpha's sidecar says out" "$(sidecar 'Alpha 1.cbz')" out
check "Bravo's sidecar says in" "$(sidecar 'Bravo 1.cbz')" in

# 5. After a restart the list is the same.
start
click 640 450
key g f
sleep 1
shot 07_after_restart
stop
check "after a restart" "$(favourites)" "Bravo 1.cbz"

montage -label '%t' "$out"/0*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
