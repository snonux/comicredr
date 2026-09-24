#!/usr/bin/env bash
# End-to-end check of deleting a comic (gd, Shift+Delete) on the Linux
# build under Xvfb: open a comic, bookmark it and make its page
# thumbnails, then ask to delete it and cancel with Enter and with Esc,
# then confirm. Checks the comic and its sidecar are in the desktop trash,
# and the index rows, cover and thumbnails are gone. Then deletes a folder
# book from the library's Series tab, checks the next cover took the
# selection, and that the third book is untouched.
#
#   tool/e2e_delete.sh
#
# Makes its own books, so it needs no corpus. E2E_SKIP_BUILD=1 reuses the
# release build already in build/. Needs: Xvfb, xdotool, ImageMagick,
# sqlite3, Python 3, gio (glib2), a C compiler, X11 headers.
# Output: build/e2e-delete/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-delete
rm -rf "$out" && mkdir -p "$out/Comics/Folder Book" "$out/home"
comics="$PWD/$out/Comics"
home="$PWD/$out/home"
trash="$home/.local/share/Trash"
doomed="$comics/Delete Me 1.cbz"
folder="$comics/Folder Book"
keep="$comics/Keep Me 2.cbz"
for i in 1 2 3 4; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$folder/p$i.png"
done
python3 - "$folder" "$doomed" "$keep" <<'EOF'
import sys, zipfile, pathlib
for n, target in enumerate(sys.argv[2:]):
    with zipfile.ZipFile(target, 'w') as z:
        for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
            z.write(f, 'page' + f.name[1:])
        z.writestr('note.txt', str(n))  # Two books, two content keys.
EOF

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:94
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
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
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
key_of() { q "select content_key from files where rel_path = '$1'"; }
rows() { q "select count(*) from $1 where content_key = '$2'"; }
# Sidecars are found by name pattern, so the check holds whatever they are called.
sidecar_beside() { find "$(dirname "$1")" -maxdepth 1 -name "*$(basename "$1")*.crdb" | head -1; }

start "$doomed"
for _ in $(seq 1 30); do [[ -n "$(key_of 'Delete Me 1.cbz')" ]] && break; sleep 1; done
k=$(key_of 'Delete Me 1.cbz')
kk=$(key_of 'Keep Me 2.cbz')
check "the three books are in the index" test "$(q 'select count(*) from files')" = 3
key l; key m m
# The page grid makes the thumbnails.
key p; sleep 4; key Escape
for _ in $(seq 1 30); do [[ -n "$(sidecar_beside "$doomed")" ]] && break; sleep 1; done
side=$(sidecar_beside "$doomed")
covers=$(dirname "$(find "$home" -path '*covers*' -name "$k.jpg" | head -1)")
check "the comic has a sidecar" test -n "$side"
check "the comic has a bookmark" test "$(q "select count(*) from bookmarks where content_key = '$k' and deleted_at is null")" = 1
check "the comic has a cover" test -f "$covers/$k.jpg"
check "the comic has page thumbnails" test -n "$(ls "$covers/pages/$k" 2>/dev/null)"
shot 01_reading

# gd, then Enter: Cancel has the focus, nothing goes. The first dialog
# takes a few seconds under Xvfb's software renderer.
key g d; sleep 4
shot 02_dialog
key Return; sleep 2
check "Enter in the dialog keeps the comic" test -f "$doomed"
check "and its sidecar" test -f "$side"
shot 03_after_enter
# Shift+Delete, then Esc.
key shift+Delete; sleep 3
shot 04_dialog_shift_delete
key Escape; sleep 2
check "Esc in the dialog keeps the comic" test -f "$doomed"
check "and the index row" test "$(rows files "$k")" = 1

# gd, Tab to the delete button, Enter.
key g d; sleep 3
key Tab; key Return; sleep 4
shot 05_after_delete
check "the comic is gone from its folder" test ! -e "$doomed"
check "the comic is in the trash" test -f "$trash/files/Delete Me 1.cbz"
check "with a trashinfo saying where it was" grep -q "Delete%20Me%201.cbz" "$trash/info/Delete Me 1.cbz.trashinfo"
check "the sidecar is gone from beside it" test ! -e "$side"
check "the sidecar is in the trash too" test -f "$trash/files/$(basename "$side")"
check "the index forgot the file" test "$(rows files "$k")" = 0
check "and the book" test "$(rows books "$k")" = 0
check "and the bookmark" test "$(rows bookmarks "$k")" = 0
check "and the position" test "$(rows progress "$k")" = 0
check "the cover is gone" test ! -e "$covers/$k.jpg"
check "the page thumbnails are gone" test ! -e "$covers/pages/$k"

# Back in the library, on the Reading tab it was opened from. The Series
# tab, its first cover (the folder book), and Shift+Delete there: the
# dialog says how many pages the folder has.
xdotool mousemove 43 100 click 1; sleep 1.5
key l
key shift+Delete; sleep 3
shot 06_library_dialog
key Tab; key Return; sleep 4
shot 07_library_after
# The next cover took the selection: Shift+Delete asks about it. Esc.
key shift+Delete; sleep 3
shot 07b_next_selected
key Escape; sleep 1
check "the folder book is gone" test ! -e "$folder"
check "the folder book is in the trash" test -f "$trash/files/Folder Book/p1.png"
check "the third book is untouched" test -f "$keep"
check "and still in the index" test "$(rows files "$kk")" = 1
check "one book is left in the index" test "$(q 'select count(*) from books')" = 1
stop

# A restart: nothing comes back.
start
shot 08_after_restart
check "after a restart one book is left" test "$(q 'select count(*) from books')" = 1
check "and no sidecar reappeared" test -z "$(sidecar_beside "$doomed")"
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
