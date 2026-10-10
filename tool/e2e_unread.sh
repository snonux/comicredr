#!/usr/bin/env bash
# End-to-end check of the Unread collection on the Linux build, with a fresh
# HOME whose ~/Comics holds two comics. The first scan puts neither in
# Unread. Then, with the app running, a new comic is copied in and one of
# the two is moved into a sub-folder: the watcher's scan puts the new one
# in Unread and not the moved one. The Collections tab shows Unread;
# opening the comic from there takes it out (index and sidecar). After a
# restart a copy of a comic seen before is not new, and a second new comic
# in a new sub-folder is. Checks the index and the sidecar with sqlite3.
#
#   tool/e2e_unread.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-unread/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-unread
rm -rf "$out" && mkdir -p "$out/pages" "$out/new" "$out/home/Comics"
home="$top/$out/home"
book() { # book NAME DIR: a three-page CBZ called "NAME 1.cbz" in DIR
  for i in 1 2 3; do
    convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
      -fill black -stroke none -pointsize 80 -annotate +120+400 "$1 $i" "$out/pages/p$i.png"
  done
  python3 - "$out/pages" "$2/$1 1.cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
        z.write(f, 'page' + f.name[1:])
EOF
}
book Alpha "$home/Comics"
book Bravo "$home/Comics"
book Delta "$out/new"
book Echo "$out/new"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
sql() { sqlite3 -batch -noheader "$home/Comics/.comicredr/comicredr.sqlite" "$1"; }
unread() {
  sql "select coalesce(group_concat(rel_path, ', '), '') from (select f.rel_path from collection_books c
       join files f on f.content_key = c.content_key
       where c.name = 'Unread' and c.removed_at is null order by f.rel_path)"
}
sidecar() { # sidecar book: its Unread row, "in", "out" or nothing
  sqlite3 -batch -noheader "$home/Comics/.$1.crdb" \
    "select case when removed_at is null then 'in' else 'out' end from collections where name = 'Unread'"
}
start() { # As e2e_favourites: no session bus, no XDG folders of the caller.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" "$@" \
    >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
wait_for() { # wait_for SQL VALUE: until the index answers VALUE, 40 s at most
  for _ in $(seq 1 80); do [[ "$(sql "$1" 2>/dev/null)" == "$2" ]] && return; sleep 0.5; done
}
paths="select group_concat(rel_path, ', ') from (select rel_path from files order by rel_path)"

# 1. The first scan of ~/Comics: what it holds is not new.
start
wait_for "$paths" "Alpha 1.cbz, Bravo 1.cbz"
wait_for "select count(*) from roots where scanned_at is not null" 1
click 640 450
shot 01_first_scan
check "first scan: in Unread" "$(unread)" ""
check "first scan: seen" "$(sql 'select count(*) from seen_books')" 2

# 2. While it runs, a new comic comes in and an old one moves.
cp "$out/new/Delta 1.cbz" "$home/Comics/"
mkdir "$home/Comics/Old"
mv "$home/Comics/Alpha 1.cbz" "$home/Comics/Old/"
wait_for "$paths" "Bravo 1.cbz, Delta 1.cbz, Old/Alpha 1.cbz"
wait_for "select count(*) from seen_books" 3
sleep 1
check "a comic copied in goes in Unread, a moved one does not" "$(unread)" "Delta 1.cbz"

# 3. The Collections tab shows Unread; Right selects it, Enter opens it,
# Right and Enter the comic.
# The library starts on Series; Tab goes on to Books, then Collections.
key Tab
key Tab
shot 02_collections
key Right; key Return
shot 03_unread
key Right; key Return
sleep 2
shot 04_opened
wait_for "select count(*) from collection_books where name = 'Unread' and removed_at is not null" 1
check "opened: in Unread" "$(unread)" ""
for _ in $(seq 1 30); do [[ "$(sidecar 'Delta 1.cbz' 2>/dev/null)" == out ]] && break; sleep 0.5; done
check "opened: the sidecar says out" "$(sidecar 'Delta 1.cbz' 2>/dev/null)" "out"
key Escape
stop

# 4. A copy of a comic seen before is not new; a comic in a new folder is.
cp "$home/Comics/Bravo 1.cbz" "$home/Comics/Bravo copy.cbz"
mkdir "$home/Comics/Later"
cp "$out/new/Echo 1.cbz" "$home/Comics/Later/"
start
wait_for "select count(*) from files" 5
wait_for "select count(*) from seen_books" 4
sleep 1
key Escape
shot 05_after_restart
check "after a restart: in Unread" "$(unread)" "Later/Echo 1.cbz"
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
echo "Screenshots in $out/"
exit $failed
