#!/usr/bin/env bash
# End-to-end check of completed comics (task 273) on the Linux build, by
# the keyboard: gC in the reader marks the open comic and takes the mark
# off again; reading on to the last page marks a comic by itself, a jump
# there (G) does not; gC on a cover marks it and u undoes that; the Folders
# tab's filter (F) hides the completed ones, then shows only them, each
# proved by the comic that opens first, and is kept across a restart; a
# comic that leaves the filtered tab on gC hands the selection to the cover
# next to it, which Enter opens; Clear all takes the filter off; X with
# Reset everything forgets the mark. A second install with nothing but the
# comics and their sidecars then knows the marks. Checks the index and the
# sidecars with sqlite3 and takes screenshots.
#
#   tool/e2e_completed.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-completed/shot_*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-completed
rm -rf "$out" && mkdir -p "$out/pages" "$out/home" "$out/home2" "$out/Comics"
comics="$top/$out/Comics"
home="$top/$out/home"
for name in Alpha Bravo Charlie; do
  for i in 1 2 3; do
    convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
      -fill black -stroke none -pointsize 80 -annotate +120+400 "$name $i" "$out/pages/p$i.png"
  done
  python3 - "$out/pages" "$comics/$name 1.cbz" <<'EOF'
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
# Xvfb takes a moment to listen, and with GDK_BACKEND=x11 the app dies on
# a display that is not there yet.
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# What an overrides row of the completed mark says: yes, no, or undone (a
# row that has no say any more). No row prints nothing.
says="case when json_extract(o.value, '\$.fromFile') then 'undone'
           when json_extract(o.value, '\$.value') = '1' then 'yes' else 'no' end"
sql() { sqlite3 -batch -noheader "$home/.local/share/org.snonux.comicredr/comicredr.sqlite" "$1"; }
mark() { # mark Alpha: the mark of that comic in the index
  sql "select $says from overrides o join files f on f.content_key = o.content_key
       where o.field = 'completed' and f.rel_path = '$1 1.cbz'"
}
sidecar() { # sidecar Alpha: the mark in the sidecar beside that comic
  sqlite3 -batch -noheader "$comics/.$1 1.cbz.crdb" "select $says from overrides o where o.field = 'completed'"
}
filter() { sql "select value from settings where key = 'library.folderFilter'"; }
# The comic opened last: the first of the Continue list.
last_read() {
  sql "select value from settings where key = 'reader.recent'" | python3 -c '
import json, os, sys
v = json.loads(sys.stdin.read() or "[]")
v = json.loads(v) if isinstance(v, str) else v
print(os.path.basename(v[0]["path"]) if v else "")'
}
start() {
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys and clicks go. No
  # session bus and no XDG folders of whoever runs this: the app then
  # cannot reach their keyring or their own data. The bus address names a
  # socket that is not there, rather than being unset: unset, D-Bus falls
  # back to $XDG_RUNTIME_DIR/bus, which on a desktop is the real session's.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" \
    "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1; }
wait_books() { for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 3 ]] && break; sleep 0.5; done; }
# chip N: in the filter window, the Nth control from the first type (Tab N
# times) pressed with Space. With CBZ the only type here: CBZ (0), the
# five sizes (1-5), the six dates (6-11), Completed or not, Completed
# only, Not completed (12-14), the five lengths (15-19), then Clear all
# (20).
chip() { for _ in $(seq 1 "$1"); do xdotool key Tab; sleep 0.15; done; key space; }
# first_in_comics: from the top of the Folders tab into Comics, and reads
# the first comic shown there; then back out to the top.
first_in_comics() {
  key l; key Return; key Return; sleep 2; shot "$1"; key Escape; sleep 1
  key BackSpace
}

start --add-root "$comics"
wait_books
check "books indexed" "$(sql 'select count(*) from books')" 3
click 43 355; shot 01_folders # The Folders tab (the rail, left).

# 1. In the reader: Alpha (the first in Comics) open, gC marks it, gC again
# marks it not completed, and once more completed. The comic stays open.
key l; key Return; key Return; sleep 2
check "nothing marked to begin with" "$(sql "select count(*) from overrides where field = 'completed'")" 0
key g C; shot 02_reader_marked
check "gC in the reader" "$(mark Alpha)" yes
key g C
check "gC again takes it off" "$(mark Alpha)" no
key g C
check "and on again" "$(mark Alpha)" yes
check "one row for it, rewritten" "$(sql "select count(*) from overrides where field = 'completed'")" 1
key Escape; sleep 1.5
check "Alpha's sidecar says so" "$(sidecar Alpha)" yes

# 2. Bravo read to its last page is marked by that; Charlie, opened and
# closed on page 1, is not. A jump to the last page (G) is a look at the
# end, not reading to it: nothing is marked until a step arrives there.
key l; key Return; sleep 2
key shift+g; sleep 1
check "G shows the last page" "$(sql "select p.page from progress p join files f on f.content_key = p.content_key
                                     where f.rel_path = 'Bravo 1.cbz'")" 2
check "a jump to the last page marks nothing" "$(mark Bravo)" ""
key g g
key l
check "not on the way to the last page" "$(mark Bravo)" ""
key l; sleep 1; shot 03_last_page
check "reading on to the last page marks it" "$(mark Bravo)" yes
key Escape; sleep 1.5
check "Bravo's sidecar says so" "$(sidecar Bravo)" yes
shot 04_two_ticks

# 3. On a cover: Charlie, gC, and u undoes it (a row with no say).
key l
key g C; shot 05_cover_marked
check "gC on a cover" "$(mark Charlie)" yes
key u; shot 06_undone
check "u undoes it" "$(mark Charlie)" undone

# 4. The filter: Not completed leaves Charlie alone, so it opens first.
key BackSpace
key shift+f; sleep 1; shot 07_filter_window
chip 14; shot 08_not_completed_picked
key Escape; sleep 1
check "the filter is saved" "$(filter | grep -c '"completed\\*":\\*"hide')" 1
first_in_comics 09_read_charlie
check "Not completed: Charlie opened first" "$(last_read)" "Charlie 1.cbz"
check "opening Charlie marked nothing" "$(mark Charlie)" undone
stop

# 5. A restart keeps the filter. Then Completed only: Alpha and Bravo.
# Alpha marked not completed there leaves the view and the cover next to
# it, Bravo, is selected: Enter opens it (the comic read last before was
# Charlie). And Bravo opens first when the folder is walked into again.
start
click 43 355; shot 10_restart_filtered
check "kept across a restart" "$(filter | grep -c '"completed\\*":\\*"hide')" 1
key shift+f; sleep 1; chip 13; key Escape; sleep 1
check "Completed only is saved" "$(filter | grep -c '"completed\\*":\\*"only')" 1
key l; key Return; shot 11_completed_only
key g C; shot 12_alpha_unmarked_gone
check "gC on Alpha's cover takes the mark off" "$(mark Alpha)" no
check "before Enter the comic read last is still Charlie" "$(last_read)" "Charlie 1.cbz"
key Return; sleep 2; shot 12b_neighbour_opened
check "Enter after gC opens the cover next to it" "$(last_read)" "Bravo 1.cbz"
key Escape; sleep 1.5
key BackSpace
first_in_comics 13_read_bravo
check "Completed only: Bravo opened first" "$(last_read)" "Bravo 1.cbz"

# 6. Clear all in the filter window (the 21st control) takes the filter off.
key shift+f; sleep 1; chip 20; key Escape; sleep 1
check "Clear all cleared it" "$(sql "select count(*) from settings where key = 'library.folderFilter'")" 0

# 7. Charlie marked, to travel; Bravo reset (X, Alt+R is Reset everything):
# its mark is forgotten, in the index and in its sidecar.
key l; key Return; key l; key l
key g C
check "Charlie marked" "$(mark Charlie)" yes
key h
key shift+x; sleep 1; shot 14_reset_question
key alt+r; sleep 2; shot 15_bravo_reset
check "Reset everything forgets Bravo's mark" "$(mark Bravo)" ""
check "and its place" "$(sql "select count(*) from progress p join files f on f.content_key = p.content_key
                               where f.rel_path = 'Bravo 1.cbz'")" 0
stop
check "Alpha's sidecar: not completed" "$(sidecar Alpha)" no
check "Bravo's sidecar: no mark" "$(sidecar Bravo)" ""
check "Charlie's sidecar: completed" "$(sidecar Charlie)" yes

# 8. Another install, with only the comics and the sidecars beside them.
home="$top/$out/home2"
start --add-root "$comics"
wait_books
# The scan reads each sidecar after it lists the comic, in no promised
# order: wait (20 s at most) for every mark the sidecars bring, Alpha's and
# Charlie's, rather than a fixed time or the one that happened to come last.
# Bravo's sidecar has none, which no wait can tell from "not read yet"; its
# check below is good once the other two are in.
for _ in $(seq 1 40); do
  [[ "$(mark Alpha 2>/dev/null)" == no && "$(mark Charlie 2>/dev/null)" == yes ]] && break
  sleep 0.5
done
click 43 355; key l; key Return; shot 16_second_install
check "the second install: Alpha not completed" "$(mark Alpha)" no
check "the second install: Bravo unmarked" "$(mark Bravo)" ""
check "the second install: Charlie completed" "$(mark Charlie)" yes
stop

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
