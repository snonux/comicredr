#!/usr/bin/env bash
# End-to-end check that panels are found only for the open comic, ahead of
# the reader, on the Linux release build over real comics from the test
# corpus (spike/fetch_corpus.py). Checks with sqlite3 that:
#
#   1. with no comic open, nothing is analysed after the library scan;
#   2. a comic opened on its first page, guided view off, has every page
#      analysed in the end, and no other comic has any;
#   3. a comic opened and moved to page 10 has pages from 9 on analysed,
#      and none before once it moved, and closing it stops the work;
#   4. guided view in the first comic has its panels, and its sidecar
#      carries them;
#   5. after a restart, with no comic open, nothing more is analysed.
#
#   tool/e2e_ahead.sh [corpus-dir]
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3.
# Output: build/e2e-ahead/shot_*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
out=build/e2e-ahead
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Copies, not links: the reader writes a sidecar beside each book.
cp "$corpus"/silver-age/reptisaurus-v2-005.cbz "$corpus"/golden-age/all-top-comics-6.cbz "$comics/"
cp "$corpus"/golden-age/mercy-for-millions.cbz "$comics/"
books=3

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 4
  win=$(xdotool search --name "^ComicRedr$" | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
analysed() { sql "select count(*) from analysed_pages" 2>/dev/null || echo 0; }
# of TITLE [where]: pages of the book whose title starts with TITLE.
of() {
  sql "select count(*) from analysed_pages a join books b using (content_key) where b.title like '$1%' ${2:-}" 2>/dev/null ||
    echo 0
}
pages() { sql "select page_count from books where title like '$1%'"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
wait_for() { # wait_for seconds condition...
  local t=$1; shift
  for _ in $(seq 1 $((t * 2))); do eval "$@" && return 0; sleep 0.5; done
  return 1
}
# open TITLE: finds a book on the Books tab with the library search and
# opens it.
open() {
  xdotool mousemove 43 160 click 1 mousemove 640 400; sleep 0.8
  key slash; key ctrl+a; xdotool type --delay 60 "$1"; key Return; key Return; sleep 2
}

# 1. The scan, and nothing else with no comic open.
start --add-root "$comics"
wait_for 60 '[[ -f "$db" && "$(sql "select count(*) from books" 2>/dev/null)" == $books ]]'
sleep 15
shot 01_library
check "nothing analysed with no comic open" "$(analysed)" 0

# 2. Reptisaurus on its cover, guided view off: the whole comic, and only it.
open reptisaurus
shot 02_open_plain
n=$(pages Reptisaurus)
t0=$(date +%s)
wait_for 300 '(( $(of Reptisaurus) >= n ))' || true
echo "reptisaurus: $n pages in $(( $(date +%s) - t0 )) s with the reader on page 1"
check "every page of the open comic" "$(of Reptisaurus)" "$n"
check "other comics untouched" "$(analysed)" "$n"
key Escape; sleep 1

# 3. All Top Comics on page 10: from page 9 on, then closed half way.
open 'All Top'
key 1 0 shift+g
jumped=$(( $(date +%s) + 1 )) # A page under way at the jump may still land.
sleep 1
shot 03_page_10
wait_for 60 '(( $(of "All Top" "and a.page >= 12") >= 2 ))' || true
key Escape; sleep 1
shot 04_closed
check "page 10 and the one behind analysed" "$(of 'All Top' 'and a.page in (8, 9, 10, 11)')" 4
check "nothing before page 9 after the jump" "$(of 'All Top' "and a.page < 8 and a.analysed_at > $jumped")" 0
held=$(analysed)
check "the comic not finished when closed" "$(( $(of 'All Top') < $(pages 'All Top') ))" 1
sleep 10
check "closing stops the work" "$(analysed)" "$held"

# 4. Guided view in Reptisaurus has its panels; its sidecar carries them.
open reptisaurus
key l; key l; key l; key l # Page 5: past the cover and the ads.
key v; sleep 1.5
shot 05_guided
key l; sleep 1
shot 06_guided_next_panel
check "page 5 has frames" "$(sql "select count(*) > 1 from panels p join books b using (content_key) where b.title like 'Reptisaurus%' and p.page = 4 and p.kind = 'frame'")" 1
key v; key Escape; sleep 3 # The sidecar's debounce fires.
side="$comics/.reptisaurus-v2-005.cbz.crdb"
check "sidecar carries every page" \
  "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(distinct page) from analysed_pages").fetchone()[0])' "$side" 2>/dev/null || echo none)" "$n"
stop

# 5. A restart with no comic open: nothing more.
held=$(analysed)
start
sleep 15
shot 07_restart
check "nothing analysed after a restart" "$(analysed)" "$held"
stop

echo "screenshots in $out/"
exit $failed
