#!/usr/bin/env bash
# End-to-end check of symlinked comics on the Linux build under Xvfb. The
# comics live in nas/ and the library folder holds only links to them: a
# linked CBZ, a linked folder of CBZs (with a link inside it back up to the
# library, a loop), a linked folder book, and a link that points nowhere.
# Checks the scan lists the three books once each, the watcher sees a comic
# copied into the linked folder, a linked comic reads and gets its sidecar
# beside the link, and gd on it deletes the link only: the comic in nas/
# stays. Then a restart.
#
#   tool/e2e_symlinks.sh
#
# Makes its own books, so it needs no corpus. E2E_SKIP_BUILD=1 reuses the
# release build already in build/. Needs: Xvfb, xdotool, ImageMagick,
# sqlite3, Python 3, a C compiler, X11 headers.
# Output: build/e2e-symlinks/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-symlinks
rm -rf "$out" && mkdir -p "$out/nas/Hellboy" "$out/nas/Pepper" "$out/Comics" "$out/home"
nas="$PWD/$out/nas"
comics="$PWD/$out/Comics"
home="$PWD/$out/home"
for i in 1 2 3 4; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$nas/Pepper/p$i.png"
done
python3 - "$nas/Pepper" "$nas/Saga 1.cbz" "$nas/Hellboy/Hellboy 1.cbz" "$out/Hellboy 2.cbz" <<'EOF'
import sys, zipfile, pathlib
for n, target in enumerate(sys.argv[2:]):
    with zipfile.ZipFile(target, 'w') as z:
        for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
            z.write(f, 'page' + f.name[1:])
        z.writestr('note.txt', str(n))  # One content key each.
EOF
ln -s "$nas/Saga 1.cbz" "$comics/Saga 1.cbz"
ln -s "$nas/Hellboy" "$comics/Hellboy"
ln -s "$nas/Pepper" "$comics/Pepper"
ln -s "$comics" "$nas/Hellboy/up"
ln -s "$nas/missing.cbz" "$comics/Gone.cbz"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
db="$home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1" 2>/dev/null || true; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
shot() { import -window root "$out/$1.png"; }
start() {
  HOME="$home" build/linux/x64/release/bundle/comicredr --add-root "$comics" "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 8
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool mousemove 640 400; sleep 0.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
files() { q "select rel_path from files order by rel_path" | paste -sd '|'; }
wait_files() { for _ in $(seq 1 30); do [[ "$(files)" == "$1" ]] && return 0; sleep 1; done; return 1; }

start
check "the linked comic, folder and folder book are listed once each" \
  wait_files 'Hellboy/Hellboy 1.cbz|Pepper|Saga 1.cbz'
echo "  index: $(files)"
check "each has a cover" test "$(find "$home" -path '*covers*' -maxdepth 6 -name '*.jpg' | wc -l)" -ge 3
xdotool mousemove 43 100 click 1; sleep 2 # The Series tab.
shot 01_library

# A comic copied into the linked folder's real folder.
cp "$out/Hellboy 2.cbz" "$nas/Hellboy/"
check "the watcher lists a comic copied into the linked folder" \
  wait_files 'Hellboy/Hellboy 1.cbz|Hellboy/Hellboy 2.cbz|Pepper|Saga 1.cbz'
shot 02_after_copy
stop

# Open the linked comic, bookmark page 2: its sidecar goes beside the link.
start "$comics/Saga 1.cbz"
key l; key m m
side="$comics/.Saga 1.cbz.crdb"
for _ in $(seq 1 30); do [[ -f "$side" ]] && break; sleep 1; done
shot 03_reading
check "the linked comic reads (page 2)" test "$(q "select page from progress p join files f on f.content_key = p.content_key where f.rel_path = 'Saga 1.cbz'")" = 1
check "its sidecar is beside the link" test -f "$side"
check "and none beside the comic in nas/" test -z "$(find "$nas" -maxdepth 1 -name '*.crdb')"

# gd, Tab to the delete button, Enter: only the link goes.
key g d; sleep 4
shot 04_dialog
key Tab; key Return; sleep 4
shot 05_after_delete
check "the link is gone" test ! -L "$comics/Saga 1.cbz"
check "the comic it pointed to stays" test -f "$nas/Saga 1.cbz"
check "the sidecar beside the link is gone" test ! -e "$side"
check "the index forgot it" wait_files 'Hellboy/Hellboy 1.cbz|Hellboy/Hellboy 2.cbz|Pepper'
stop

start
shot 06_after_restart
check "after a restart the three other books are still listed" \
  wait_files 'Hellboy/Hellboy 1.cbz|Hellboy/Hellboy 2.cbz|Pepper'
check "and nas/ still holds every comic" test "$(find "$nas" -name '*.cbz' | wc -l)" = 3
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
