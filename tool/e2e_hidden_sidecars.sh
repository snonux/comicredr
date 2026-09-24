#!/usr/bin/env bash
# End-to-end check of hidden sidecars on the Linux build under Xvfb: a
# comic's sidecar is written as `.book.cbz.crdb`, and one an older app left
# under the visible name `book.cbz.crdb` is renamed when a fresh install
# scans the library, keeping bookmarks and position; when both names exist
# the two are merged.
#
#   tool/e2e_hidden_sidecars.sh
#
# Makes its own two small CBZs, so it needs no corpus. E2E_SKIP_BUILD=1
# reuses the release build already in build/. Needs: Xvfb, xdotool,
# ImageMagick, sqlite3, Python 3, a C compiler, X11 headers. Output:
# build/e2e-hidden-sidecars/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-hidden-sidecars
rm -rf "$out" && mkdir -p "$out/Comics" "$out/pages" "$out/home" "$out/home2"
comics="$PWD/$out/Comics"
one="$comics/Test Comic 1.cbz"
two="$comics/Other Book.cbz"
hidden() { echo "$(dirname "$1")/.$(basename "$1").crdb"; }
visible() { echo "$1.crdb"; }
for i in 1 2 3 4; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$out/pages/p$i.png"
done
python3 - "$out/pages" "$one" "$two" <<'EOF'
import sys, zipfile, pathlib
for n, book in enumerate(sys.argv[2:]):
    with zipfile.ZipFile(book, 'w') as z:
        for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
            z.write(f, 'page' + f.name[1:])
        z.writestr('extra.txt', str(n))  # Different bytes, so a different content key.
EOF

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
q() { sqlite3 -batch -noheader "$1" "$2"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
db() { echo "$PWD/$out/$1/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
start() { # start home
  HOME="$PWD/$out/$1" build/linux/x64/release/bundle/comicredr --add-root "$comics" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name "^ComicRedr$" | tail -1)
  xdotool mousemove 60 24 click 1; sleep 1.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
bookmarks() { q "$1" "select count(*) from bookmarks where deleted_at is null"; }
# Opens the selected book, turns [pages] pages, bookmarks the page (m m) and
# goes back to the library, which writes the sidecar.
read_and_mark() {
  key Return; sleep 2
  for _ in $(seq 1 "$1"); do key Next; done
  key m m
  key Escape; sleep 3
}

# The laptop: reads both books, which writes their sidecars.
start home
click 43 100 # Series, on the rail: the two books side by side.
click 190 200
read_and_mark 2
click 390 200
read_and_mark 1
shot 01_laptop
stop
check "the first sidecar is hidden" test "$(bookmarks "$(hidden "$one")")" = 1
check "the second sidecar is hidden" test "$(bookmarks "$(hidden "$two")")" = 1
check "no visible sidecar was written" test -z "$(ls "$comics" | grep crdb || true)"

# As an older app left them: the first only under the visible name, the
# second under both, the visible one holding a bookmark the hidden lacks.
mv "$(hidden "$one")" "$(visible "$one")"
cp "$(hidden "$two")" "$(visible "$two")"
q "$(visible "$two")" "insert into bookmarks (id, page, created_at) select 'old-app-1', 3, created_at from bookmarks limit 1"
check "set up: the old names are listed" test "$(ls "$comics" | grep -c 'crdb$')" = 2

# The phone: a fresh install scans the folder.
start home2
sleep 3
shot 02_phone_library
check "the first sidecar was renamed" test ! -e "$(visible "$one")" -a -e "$(hidden "$one")"
check "the second pair was merged into the hidden one" test ! -e "$(visible "$two")"
check "the merged sidecar holds both bookmarks" test "$(bookmarks "$(hidden "$two")")" = 2
check "the fresh install took the laptop's bookmarks" \
  test "$(q "$(db home2)" "select count(*) from bookmarks where deleted_at is null")" = 3
positions() { q "$(db "$1")" "select f.rel_path, p.page from files f join progress p using (content_key) order by 1"; }
check "the fresh install took the laptop's positions" test "$(positions home2)" = "$(positions home)"
check "which were on two different pages" test "$(positions home | cut -d'|' -f2 | sort -u | wc -l)" = 2
click 43 100
click 190 200
key Return; sleep 3
shot 03_phone_resumed
key Escape; sleep 2
stop
check "the folder lists no sidecar" test -z "$(ls "$comics" | grep crdb || true)"
check "and holds exactly the two hidden ones" test "$(ls -A "$comics" | grep -c '^\..*\.crdb$')" = 2

ls -lA "$comics"
exit $failed
