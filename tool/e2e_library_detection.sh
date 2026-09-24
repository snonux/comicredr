#!/usr/bin/env bash
# End-to-end check of the whole-library panel pass on the Linux build, over
# real comics from the test corpus (spike/fetch_corpus.py) and the trained
# model. Starts the release build on a library it has never seen, and
# checks with sqlite3 that:
#
#   1. the pass starts by itself after the scan and shows on the status line;
#   2. killed half way and started again, it goes on where it stopped
#      (pages analysed before the kill are not analysed again);
#   3. a book opened in the reader while the pass runs has guided view;
#   4. in the end every page of every book has panels, and each book's
#      sidecar carries them;
#   5. switched off in the settings table, a new pass does nothing.
#
#   tool/e2e_library_detection.sh [corpus-dir] [model]
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3.
# Output: build/e2e-library-detection/shot_*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="${1:-test/corpus}"
export COMICREDR_MODEL="${2:-${COMICREDR_MODEL:-$HOME/.local/share/org.snonux.comicredr/models/comicredr-panels.onnx}}"
[[ -f "$COMICREDR_MODEL" ]] || { echo "No model at $COMICREDR_MODEL"; exit 2; }
out=build/e2e-library-detection
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Copies, not links: the pass writes a sidecar beside each book.
cp "$corpus"/golden-age/mercy-for-millions.cbz "$corpus"/golden-age/all-top-comics-6.cbz "$comics/"
cp "$corpus"/silver-age/reptisaurus-v2-005.cbz "$corpus"/bw-indie/next-stop-ghost-town-promo.pdf "$comics/"
cp -r "$corpus"/modern/pepper-carrot-e06 "$comics/"
books=5

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:97
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
analysed() { sql "select count(*) from analysed_pages where source = 'model'" 2>/dev/null || echo 0; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
wait_for() { # wait_for seconds condition...
  local t=$1; shift
  for _ in $(seq 1 $((t * 2))); do eval "$@" && return 0; sleep 0.5; done
  return 1
}

# 1. First launch: the scan, then the pass, with nothing opened.
start --add-root "$comics"
wait_for 60 '[[ -f "$db" && "$(sql "select count(*) from books" 2>/dev/null)" == $books ]]'
total=$(sql 'select sum(page_count) from books')
echo "library: $books books, $total pages"
wait_for 60 '(( $(analysed) >= 3 ))'
sleep 1
shot 01_pass_running
t0=$(date +%s.%N) a0=$(analysed)
sleep 10
a1=$(analysed) t1=$(date +%s.%N)
echo "pass speed: $(python3 -c "print(round(($a1 - $a0) / ($t1 - $t0), 2))") pages/s with the reader idle"

# 2. Killed half way: note what was done and when, then start again.
stop
before=$(analysed)
stamp=$(sql "select max(analysed_at) from analysed_pages")
echo "killed after $before of $total pages"
start
wait_for 30 '(( $(analysed) > before ))'
check "pages analysed before the kill not redone" \
  "$(sql "select count(*) from analysed_pages where analysed_at <= $stamp")" "$before"

# The pause button on the status line holds the pass until pressed again.
xdotool mousemove 1130 694 click 1; sleep 2
held=$(analysed); sleep 6
shot 01b_paused
check "paused: nothing analysed" "$(analysed)" "$held"
xdotool mousemove 1130 694 click 1
wait_for 30 '(( $(analysed) > held ))'
check "resumed" "$(( $(analysed) > held ))" 1
xdotool mousemove 640 400

# 3. Open a book while the pass runs: guided view has its panels.
key Tab; key slash; xdotool type --delay 60 reptisaurus; key Return; key Return
sleep 2
key l; key l; key l; key l # Page 5: past the cover and the ads.
key v; sleep 2
shot 02_guided_during_pass
key l; sleep 1
shot 03_guided_next_panel
check "reader found page 5's panels" "$(sql "select count(*) > 1 from panels p join books b using (content_key) where b.title like 'Reptisaurus%' and p.page = 4 and p.kind = 'frame'")" 1
key v; key Escape; key Escape; sleep 1

# 4. Every page of every book, and the sidecars.
wait_for 900 '(( $(analysed) >= total ))' || true
sleep 3 # The status line settles, the sidecars' debounce fires.
shot 04_pass_done
check "every page analysed" "$(analysed)" "$total"
check "pages per book match" \
  "$(sql "select count(*) from books b where b.page_count = (select count(*) from analysed_pages a where a.content_key = b.content_key)")" \
  "$books"
check "frames found" "$(sql "select count(*) > $total from panels where kind = 'frame'")" 1
sidecars=0
for f in "$comics"/*.cbz "$comics"/*.pdf "$comics"/pepper-carrot-e06/.comicredr.crdb; do
  s="$f"; [[ "$f" == *.crdb ]] || s="$(dirname "$f")/.$(basename "$f").crdb"
  [[ -f "$s" ]] || { echo "no sidecar $s"; continue; }
  n=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(distinct page) from panels").fetchone()[0])' "$s")
  [[ "$n" -gt 0 ]] && sidecars=$((sidecars + 1))
done
check "sidecars with panels" "$sidecars" "$books"
stop

# 5. Switched off: a new library folder gets scanned but not analysed.
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("insert or replace into settings(key, value) values (?, ?)", ("detect.library", "false")); c.commit()' "$db"
mkdir -p "$out/More"
cp "$corpus"/silver-age/space-war-002.cbz "$out/More/"
start --add-root "$PWD/$out/More"
wait_for 60 '[[ "$(sql "select count(*) from books")" == $((books + 1)) ]]'
sleep 8
shot 05_switched_off
check "nothing analysed while switched off" "$(analysed)" "$total"
stop

echo "screenshots in $out/"
exit $failed
