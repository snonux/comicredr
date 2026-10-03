#!/usr/bin/env bash
# End-to-end check of marking several comics in the library and acting on
# all of them at once, on the Linux build under Xvfb, by real keys: on the
# Folders tab Shift+Right marks a run, Shift+Left takes one back,
# Shift+End runs to the last comic, Esc clears; Ctrl+A and * make every
# comic in the folder a favourite; X with two marked resets both (their
# positions go, the favourites stay); gd with three marked asks once,
# Enter cancels, then Tab and Enter delete the three for good and leave
# the rest; a restart keeps it so. Then gm moves D and E into the empty
# folder Read, picked by typing in the folder list, sidecars along and the
# index following; gc puts F in a new collection; a name taken in Read
# asks first (Enter cancels, Skip leaves F); Ctrl+N makes a folder and
# moves F into it; a restart keeps it so.
#
#   tool/e2e_multi_select.sh
#
# Makes its own books, so it needs no corpus. E2E_SKIP_BUILD=1 reuses the
# release build already in build/. Needs: Xvfb, xdotool, ImageMagick,
# sqlite3, Python 3, a C compiler, X11 headers.
# Output: build/e2e-multi-select/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-multi-select
rm -rf "$out" && mkdir -p "$out/Comics/Shelf" "$out/Comics/Read" "$out/home" "$out/pages"
comics="$PWD/$out/Comics"
shelf="$comics/Shelf"
home="$PWD/$out/home"
names=(A B C D E F)
for i in 1 2 3; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$out/pages/p$i.png"
done
python3 - "$out/pages" "$shelf" "${names[@]}" <<'EOF'
import sys, zipfile, pathlib
pages, shelf = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for name in sys.argv[3:]:
    with zipfile.ZipFile(shelf / f'Book {name}.cbz', 'w') as z:
        for f in sorted(pages.glob('*.png')):
            z.write(f, 'page' + f.name[1:])
        z.writestr('note.txt', name)  # Each book its own content key.
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
key_of() { q "select content_key from files where rel_path = 'Shelf/Book $1.cbz'"; }
favourites() { q "select count(*) from collection_books where name = 'Favourites' and removed_at is null"; }
# The Folders tab (Tab from Series, where an unread library opens), into
# Comics, into Shelf: its first comic is selected.
to_shelf() {
  key Tab; key Tab; key Tab; key Tab
  key l; key Return; key Return; sleep 1
}

start
for _ in $(seq 1 30); do [[ "$(q 'select count(*) from files')" == 6 ]] && break; sleep 1; done
check "the six books are in the index" test "$(q 'select count(*) from files')" = 6
declare -A k
for n in "${names[@]}"; do k[$n]=$(key_of "$n"); done

# A position in A and in C, for the reset to take away.
to_shelf
key Return; sleep 3; key l; key l; sleep 2; key Escape; sleep 2
key l; key l; key Return; sleep 3; key l; key l; sleep 2; key Escape; sleep 2
check "A has a position" test "$(q "select count(*) from progress where content_key = '${k[A]}'")" = 1
check "C has a position" test "$(q "select count(*) from progress where content_key = '${k[C]}'")" = 1

# Shift+Right twice from A: A, B and C.
key Home
key shift+Right; key shift+Right
shot 01_three_marked
key shift+Left
shot 02_two_marked
key shift+End
shot 03_to_the_end
key Escape
shot 04_cleared

# Ctrl+A marks the six, * makes them favourites.
key ctrl+a
shot 05_all_marked
key asterisk; sleep 3
shot 06_favourites
check "Ctrl+A and * make all six favourites" test "$(favourites)" = 6

# A to C marked, X, Reset everything: A and C lose their positions, B has
# none; the favourites stay.
key Home; key shift+Right; key shift+Right
key X; sleep 3
shot 07_reset_dialog
key Tab; key Return; sleep 4
shot 08_after_reset
check "the reset took A's position" test "$(q "select count(*) from progress where content_key = '${k[A]}'")" = 0
check "and C's" test "$(q "select count(*) from progress where content_key = '${k[C]}'")" = 0
check "the favourites stay" test "$(favourites)" = 6

# A to C marked again, gd: one dialog; Enter is Cancel.
key Home; key shift+Right; key shift+Right
key g d; sleep 4
shot 09_delete_dialog
key Return; sleep 2
for n in A B C; do check "Enter keeps Book $n" test -f "$shelf/Book $n.cbz"; done
# gd, Tab to Delete 3 for good, Enter.
key g d; sleep 3
key Tab; key Return; sleep 5
shot 10_after_delete
for n in A B C; do check "Book $n is deleted" test ! -e "$shelf/Book $n.cbz"; done
for n in D E F; do check "Book $n stays" test -f "$shelf/Book $n.cbz"; done
check "no sidecar of the deleted is left" test -z "$(find "$shelf" -name '.Book [ABC].cbz.crdb')"
check "the index holds three books" test "$(q 'select count(*) from files')" = 3
check "and three favourites" test "$(favourites)" = 3
stop

start
shot 11_after_restart
check "after a restart three books" test "$(q 'select count(*) from files')" = 3
check "and three favourites" test "$(favourites)" = 3
stop

# gm with D and E marked: the folder list, "read" typed, Enter.
start
to_shelf
key Home; key shift+Right
key g m; sleep 2
xdotool type --delay 80 read; sleep 1
shot 12_move_picker
key Return; sleep 4
shot 13_after_move
for n in D E; do
  check "Book $n moved to Read" test -f "$comics/Read/Book $n.cbz" -a ! -e "$shelf/Book $n.cbz"
  check "its sidecar went along" test -f "$comics/Read/.Book $n.cbz.crdb" -a ! -e "$shelf/.Book $n.cbz.crdb"
  check "the index has Book $n in Read" test "$(q "select rel_path from files where content_key = '${k[$n]}'")" = "Read/Book $n.cbz"
done
check "D and E are still favourites" test "$(favourites)" = 3
check "the index holds three books" test "$(q 'select count(*) from files')" = 3

# gc on F, the one left in Shelf: a new collection.
key Home
key g c; sleep 2
xdotool type --delay 80 Summer; sleep 0.5; key Return; sleep 3
check "gc put F in Summer" test "$(q "select content_key from collection_books where name = 'Summer' and removed_at is null")" = "${k[F]}"

# A Book F.cbz of its own in Read: moving F there asks; Enter is Cancel.
python3 - "$out/pages" "$comics/Read" <<'EOF2'
import sys, zipfile, pathlib
pages, to = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(to / 'Book F.cbz', 'w') as z:
    for f in sorted(pages.glob('*.png')):
        z.write(f, 'page' + f.name[1:])
    z.writestr('note.txt', 'another F')
EOF2
sleep 4
other_f=$(md5sum <"$comics/Read/Book F.cbz")
key Home
key g m; sleep 2; xdotool type --delay 80 read; sleep 1; key Return; sleep 2
shot 14_name_taken
key Return; sleep 2
check "Enter keeps F in Shelf" test -f "$shelf/Book F.cbz"
check "and the other F in Read" test "$(md5sum <"$comics/Read/Book F.cbz")" = "$other_f"
# Again, Tab to Skip it.
key g m; sleep 2; xdotool type --delay 80 read; sleep 1; key Return; sleep 2
key Tab; key Return; sleep 3
check "Skip leaves F in Shelf" test -f "$shelf/Book F.cbz"
check "and the other F as it was" test "$(md5sum <"$comics/Read/Book F.cbz")" = "$other_f"

# Ctrl+N in the picker: a new folder in Shelf, F moved into it.
key Home
key g m; sleep 2
key ctrl+n; sleep 1.5
xdotool type --delay 80 Later; sleep 0.5
shot 15_new_folder
key Return; sleep 4
check "F moved into the new folder Shelf/Later" test -f "$shelf/Later/Book F.cbz" -a ! -e "$shelf/Book F.cbz"
check "the index has F there" test "$(q "select rel_path from files where content_key = '${k[F]}'")" = "Shelf/Later/Book F.cbz"
check "F is still in Summer" test "$(q "select count(*) from collection_books where name = 'Summer' and removed_at is null")" = 1
stop

start
check "after a restart D in Read" test "$(q "select rel_path from files where content_key = '${k[D]}'")" = "Read/Book D.cbz"
check "and F in Shelf/Later" test "$(q "select rel_path from files where content_key = '${k[F]}'")" = "Shelf/Later/Book F.cbz"
check "and four books" test "$(q 'select count(*) from files')" = 4
check "and three favourites" test "$(favourites)" = 3
stop

montage "$out"/[01]*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
