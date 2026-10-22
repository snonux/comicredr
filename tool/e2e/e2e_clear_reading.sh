#!/usr/bin/env bash
# End-to-end check of the Reading list (snonux, 2026-10-17) on the Linux
# build, by the keyboard: a comic open for less than five minutes keeps its
# place but stays off the Reading tab (its position saved as a peek), one
# open for at least five minutes goes on it; a second install reads one of
# them too. gR asks, Enter (Cancel) clears nothing, Alt+L
# clears every place and completed mark, writing the clearing into the
# sidecars; gR again only says the list is empty. The second install then
# opens the comic it had read and starts it on page 1: the clearing came
# to it in the sidecar. Checks the index and the sidecars with sqlite3 and
# takes screenshots.
#
#   tool/e2e/e2e_clear_reading.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/. Takes some
# seven minutes, five of them waiting out the threshold.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-clear-reading/shot_*.png.
set -euo pipefail
cd "$(dirname "$0")/../.."

top=$PWD
out=build/e2e-clear-reading
rm -rf "$out" && mkdir -p "$out/pages" "$out/home" "$out/home2" "$out/Comics"
comics="$top/$out/Comics"
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
export DISPLAY=:94
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
home="$top/$out/home"
sql() { sqlite3 -batch -noheader -cmd '.timeout 5000' "$home/.local/share/org.snonux.comicredr/comicredr.sqlite" "$1"; }
# place Alpha: that comic's saved page and whether it is a peek, "2 peek",
# "0 started", or nothing without a position.
place() {
  sql "select p.page || case when instr(p.view_json, '\"peek\":true') > 0 then ' peek' else ' started' end
       from progress p join files f on f.content_key = p.content_key where f.rel_path = '$1 1.cbz'"
}
mark() {
  sql "select case when json_extract(o.value, '\$.fromFile') then 'undone'
                   when json_extract(o.value, '\$.value') = '1' then 'yes' else 'no' end
       from overrides o join files f on f.content_key = o.content_key
       where o.field = 'completed' and f.rel_path = '$1 1.cbz'"
}
started_mark() {
  sql "select json_extract(o.value, '$.value') from overrides o
       join files f on f.content_key = o.content_key
       where field = 'readingStarted' and f.rel_path = '$1 1.cbz'"
}
cleared_in_sidecar() { sqlite3 -batch -noheader "$comics/.$1 1.cbz.crdb" \
  "select count(*) from overrides where field = 'readingCleared'"; }
start() {
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" \
    "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowfocus "$win" mousemove 640 450
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1; }
wait_books() { for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 3 ]] && break; sleep 0.5; done; }
# open N: from the top of the Folders tab, into Comics and the Nth comic.
open() {
  key l; key Return
  for _ in $(seq 2 "$1"); do key l; done
  key Return; sleep 2
}
close() { key Escape; sleep 1.5; key BackSpace; }

# 1. The first install: Alpha looked at for a few seconds (a page turned),
# Bravo read for five minutes, Charlie looked at and marked completed.
start --add-root "$comics"
wait_books
check "books indexed" "$(sql 'select count(*) from books')" 3
click 43 355 # The Folders tab (the rail, left).
open 1; key l; shot 01_alpha_peek
close
check "a look keeps the place, as a peek" "$(place Alpha)" "1 peek"
# Manual start in the reader, removal in the library; both keep the place.
open 1; key g b
close
check "gb starts Alpha immediately" "$(started_mark Alpha)" 1
# Select Alpha inside its folder, without opening it.
key l; key Return; key g b
check "library gb removes the start" "$(started_mark Alpha)" 0
check "manual removal keeps the page" "$(place Alpha | cut -d' ' -f1)" 1
# Reopen and close: the override keeps it off Reading, and saves a peek.
key Return; sleep 2
close
check "removal survives reopen" "$(place Alpha)" "1 peek"
open 2; sleep 302; shot 02_bravo_five_minutes
close
check "five minutes on one page start it" "$(place Bravo)" "0 started"
open 3; key g C
close
check "Charlie marked" "$(mark Charlie)" yes
click 43 120; shot 03_reading_tab # The Reading tab: Bravo alone.
stop
# The Reading tab's covers are not read off the screen: the index says it.
check "only Bravo on the Reading tab" \
  "$(sql "select f.rel_path from progress p join files f on f.content_key = p.content_key
          left join overrides o on o.content_key=p.content_key and o.field='readingStarted'
          where coalesce(case when json_extract(o.value, '$.fromFile') then null
                         else json_extract(o.value, '$.value') = '1' end,
                         instr(coalesce(p.view_json, ''), '\"peek\":true') = 0)")" "Bravo 1.cbz"

# 2. A second install on the same comics opens Bravo: it takes up the first
# install's place from the sidecar (so it counts as started at once), turns
# a page, and its own place goes into Bravo's sidecar too.
home="$top/$out/home2"
start --add-root "$comics"
wait_books
click 43 355
open 2; key l
close
check "second install: Bravo started, on page 2" "$(place Bravo)" "1 started"
stop

# 3. Back on the first: Alpha opens where the look left it. Then gR.
home="$top/$out/home"
start --add-root "$comics"
click 43 355
open 1
check "Alpha reopened on its page (still a peek)" "$(place Alpha)" "1 peek"
close
key g R; sleep 3; shot 04_question
key Return
check "Enter is Cancel: nothing cleared" "$(sql 'select count(*) from progress')" 3
key g R
key alt+l; sleep 2; shot 05_cleared
check "every place gone" "$(sql 'select count(*) from progress')" 0
check "Charlie's mark has no say" "$(mark Charlie)" undone
check "a clearing row for each" "$(sql "select count(*) from overrides where field = 'readingCleared'")" 3
for name in Alpha Bravo Charlie; do
  check "$name's sidecar has it" "$(cleared_in_sidecar "$name")" 1
done
sleep 4
key g R; shot 06_empty_already
check "gR again changes nothing" "$(sql "select count(*) from overrides where field = 'readingCleared'")" 3
stop

# 4. The second install opens Bravo: the clearing came in its sidecar, so
# its own place went and the comic starts on page 1, as a peek.
home="$top/$out/home2"
start --add-root "$comics"
click 43 355
open 2; shot 07_second_starts_over
close
check "second install: Bravo starts over" "$(place Bravo)" "0 peek"
stop

[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
