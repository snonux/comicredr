#!/usr/bin/env bash
# End-to-end check of gc and * on the open comic, on the Linux build with a
# fresh HOME whose ~/Comics holds two comics. In the reader: gc with a
# name typed and Esc changes nothing, the dialog seen on the screen and the
# comic still open after (l and h turn its pages); gc with a name typed
# straight after it, no pause, adds the comic to a new collection with
# every letter and turns no page. Over the page grid (p): * adds it to the
# Favourites and * again takes it out, gc adds it to a second collection,
# and l Enter still picks a page, so the keys went back to the grid. Over
# the bookmark list (M): gc with a collection it is in already leaves its
# row as it was (added_at and removed_at compared, seconds later: the row's
# key is name and comic, so a count could never tell), * adds the
# favourite. The other comic is never touched. After a restart the app
# knows all that: * takes the favourite out, gc with a collection it is in
# leaves that row as it was too. Then a comic outside the library
# folders, opened by its path: gc puts it in a collection, in the index
# and its sidecar, and that collection is offered to a library comic (Tab
# and Space on its chip). Last, in the library: gc on a cover with a name
# beginning gd X typed straight after it adds that name and deletes or
# resets nothing; gc on it again with that name leaves the row and the
# sidecar as they were. Checks the index and the sidecars with sqlite3,
# the dialog by comparing screenshots, and keeps the screenshots.
#
#   tool/e2e_open_comic_collections.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-open-comic-collections/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-open-comic-collections
rm -rf "$out" && mkdir -p "$out/pages" "$out/home/Comics" "$out/home/Elsewhere"
home="$top/$out/home"
# Alpha and Bravo in the library, Loose in a folder that is no library folder.
for name in Alpha Bravo Loose; do
  for i in 1 2 3 4; do
    convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
      -fill black -stroke none -pointsize 80 -annotate +120+400 "$name $i" "$out/pages/p$i.png"
  done
  folder=Comics
  [[ $name == Loose ]] && folder=Elsewhere
  python3 - "$out/pages" "$home/$folder/$name 1.cbz" <<'EOF'
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
# a display that is not there yet ("cannot open display").
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# The index lives in ~/Comics/.comicredr when ~/Comics exists.
sql() { sqlite3 -batch -noheader "$home/Comics/.comicredr/comicredr.sqlite" "$1"; }
collections() { # collections book.cbz: the collections it is in, by name
  sql "select coalesce(group_concat(name, ', '), '') from (select c.name from collection_books c
       join files f on f.content_key = c.content_key
       where f.rel_path = '$1' and c.removed_at is null order by c.name)"
}
outside() { # the collections of comics the library has no file for
  sql "select coalesce(group_concat(name, ', '), '') from (select name from collection_books
       where removed_at is null and content_key not in (select content_key from files) order by name)"
}
rows() { sql "select count(*) from collection_books"; }
row() { # row book.cbz name: when it was put in that collection and taken out, as stored
  sql "select c.added_at || '|' || coalesce(c.removed_at, 'in') from collection_books c
       join files f on f.content_key = c.content_key where f.rel_path = '$1' and c.name = '$2'"
}
page() { # page book.cbz: the page the index has it on, from 0
  sql "select p.page from progress p join files f on f.content_key = p.content_key where f.rel_path = '$1'"
}
sidecar() { # sidecar folder book.cbz: the collections its sidecar has it in
  sqlite3 -batch -noheader "$home/$1/.$2.crdb" \
    "select coalesce(group_concat(name, ', '), '') from (select name from collections where removed_at is null order by name)"
}
start() { # start [comic]: the app, on the library or with a comic to open
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys go.
  HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
say() { xdotool type --delay 40 "$1" 2>/dev/null; sleep 0.5; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
wait_files() { for _ in $(seq 1 40); do [[ "$(sql 'select count(*) from files' 2>/dev/null)" == "$1" ]] && break; sleep 0.5; done; }

# The dialog and the dimming around it change the screen by far more than
# a status-line notice does: it is up when the screen differs from the
# picture taken before gc by more than 0.5% of full white on average (it
# makes 2.4% over the nearly black bookmark list, 8% and more elsewhere; a
# notice 0.04%), and gone when the screen is back to that picture.
before="$top/$out/before.png"
dimmed() { # whether the screen now differs that much from $before
  local n
  import -window root "$top/$out/now.png"
  n=$(convert "$before" "$top/$out/now.png" -compose difference -composite -colorspace Gray \
    -format '%[fx:int(mean*10000)]' info: 2>/dev/null) || true
  ((${n:-0} > 50))
}
wait_dialog() {
  for _ in $(seq 1 50); do
    if dimmed; then echo up; return; fi
    sleep 0.2
  done
  echo "not up"
}
wait_gone() {
  for _ in $(seq 1 50); do
    if ! dimmed; then echo gone; return; fi
    sleep 0.2
  done
  echo "still up"
}
# gc, both keys in one go, well inside the resolver's time-out. gc_now
# returns at once, for typing with the dialog still on its way; gc waits
# until the dialog shows.
gc_now() {
  import -window root "$before"
  xdotool key g c 2>/dev/null
}
gc() {
  gc_now
  check "the dialog shows" "$(wait_dialog)" up
}

start
wait_files 2
sleep 2
# Under Xvfb, with no window manager, the first click only brings the
# window forward.
click 640 450

# 1. In the reader: open Alpha. gc, a name typed and Esc writes nothing,
# and the comic is still open: l and h turn its pages.
key l; key Return
sleep 2
gc
say "Not this one"
shot 01_reader_gc_dialog
key Escape
check "Esc closes the dialog" "$(wait_gone)" gone
check "gc, a name, then Esc in the reader" "$(rows)" 0
key l
check "the comic is still open: l turns the page" "$(page 'Alpha 1.cbz')" 1
key h
check "and h turns it back" "$(page 'Alpha 1.cbz')" 0
# The name typed straight after gc, with the dialog not up yet: as
# commands T would show the time, o open the file picker, e the edit
# dialog, and the rest would turn pages.
gc_now
xdotool type --delay 25 "To read next" 2>/dev/null
check "the dialog shows" "$(wait_dialog)" up
shot 02_reader_typed_ahead
key Return
check "Enter closes the dialog" "$(wait_gone)" gone
shot 03_reader_added
check "gc and the name with no pause" "$(collections 'Alpha 1.cbz')" "To read next"
check "which turned no page" "$(page 'Alpha 1.cbz')" 0

# 2. Over the page grid: * in and out, gc, and the grid still has the keys.
key p
key asterisk
shot 04_grid_star
check "* over the page grid" "$(collections 'Alpha 1.cbz')" "Favourites, To read next"
key asterisk
check "* again over the page grid" "$(collections 'Alpha 1.cbz')" "To read next"
gc
shot 05_grid_gc_dialog
say "Grid picks"
key Return
shot 06_grid_added
check "gc over the page grid" "$(collections 'Alpha 1.cbz')" "Grid picks, To read next"
key l; key Return
sleep 1.5
shot 07_grid_picked_page
check "l Enter in the grid after gc goes to page 2" "$(page 'Alpha 1.cbz')" 1

# 3. Over the bookmark list: a collection it is in already is left as it
# is; * makes it a favourite. The table's key is (name, comic) and adding
# is an upsert, so the number of rows says nothing: the row itself must
# be untouched. added_at is whole seconds, and the wait makes sure a row
# written again would carry a later one.
key M
was=$(row 'Alpha 1.cbz' 'Grid picks')
check "Grid picks has a row for Alpha" "${was#*|}" in
sleep 2
gc
shot 07b_list_gc_dialog
say "Grid picks"
key Return
check "Enter closes the dialog" "$(wait_gone)" gone
shot 08_list_already
check "gc with a collection it is in leaves its row as it was" "$(row 'Alpha 1.cbz' 'Grid picks')" "$was"
key asterisk
shot 09_list_star
check "* over the bookmark list" "$(collections 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"
check "the other comic is untouched" "$(collections 'Bravo 1.cbz')" ""
key Escape
key Escape
sleep 1
stop
check "Alpha's sidecar" "$(sidecar Comics 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"

# 4. After a restart the index says the same, and the app goes by it: C
# opens Alpha again, * takes the favourite it finds out rather than adding
# one, and gc with a collection it is in leaves that row as it was (the
# row compared, not counted, as above).
start --add-root "$home/Comics" # In the library, not the comic read last.
click 640 450
check "after a restart" "$(collections 'Alpha 1.cbz')" "Favourites, Grid picks, To read next"
key C
sleep 2
key asterisk
shot 10_restart_star
check "* after the restart takes the favourite out" "$(collections 'Alpha 1.cbz')" "Grid picks, To read next"
was=$(row 'Alpha 1.cbz' 'To read next')
check "To read next has a row for Alpha" "${was#*|}" in
sleep 2
gc
shot 11_restart_gc_dialog
say "To read next"
key Return
check "Enter closes the dialog" "$(wait_gone)" gone
check "gc after the restart with a collection it is in leaves its row as it was" \
  "$(row 'Alpha 1.cbz' 'To read next')" "$was"
stop

# 5. A comic outside the library folders, opened by its path: gc works
# for it too, and a library comic is then offered its collection, the
# first chip in name order.
start "$home/Elsewhere/Loose 1.cbz"
click 640 300
check "files the library has for the comic outside" "$(sql "select count(*) from files where rel_path like '%Loose%'")" 0
gc
say "Aaa outside"
shot 12_outside_gc_dialog
key Return
check "gc on a comic outside the library" "$(outside)" "Aaa outside"
# Closing the comic writes its sidecar now rather than in a while.
key Escape
sleep 1
stop
check "its sidecar, beside it" "$(sidecar Elsewhere 'Loose 1.cbz')" "Aaa outside"
start "$home/Comics/Bravo 1.cbz"
click 640 300
gc
shot 13_offered_outside
key Tab
key space
check "the chip of the collection from outside puts Bravo in it" "$(collections 'Bravo 1.cbz')" "Aaa outside"
stop

# 6. In the library, gc on a cover asks through the same question: a name
# typed straight after it, no pause, is the name. As library commands gd
# would ask to delete the comic and X to reset it (and its collections
# with it).
start --add-root "$home/Comics"
click 640 450
key l
gc_now
xdotool type --delay 25 "gd Xtra" 2>/dev/null
check "the dialog shows" "$(wait_dialog)" up
shot 14_library_typed_ahead
key Return
check "Enter closes the dialog" "$(wait_gone)" gone
shot 15_library_added
# Which of the two covers comes first on the Reading tab depends on what
# was saved of the last sitting, so either may be the one: exactly one of
# them is in the new collection, and both keep what they were in (a reset
# would have taken that away).
check "gc and the name with no pause on a cover puts that one comic in it" \
  "$(sql "select count(*) from collection_books c join files f on f.content_key = c.content_key
          where c.name = 'gd Xtra' and c.removed_at is null")" 1
others() { collections "$1" | sed 's/\(, \)\?gd Xtra//'; }
check "Alpha keeps its collections" "$(others 'Alpha 1.cbz')" "Grid picks, To read next"
check "Bravo keeps its collection" "$(others 'Bravo 1.cbz')" "Aaa outside"
check "nothing was deleted" "$(ls "$home/Comics" | tr '\n' ' ')" "Alpha 1.cbz Bravo 1.cbz "
# gc on that cover again with the collection it is now in: as in the
# reader, the row is left as it was (compared seconds later, as above) and
# so is the comic's sidecar, which the add before it wrote.
cover=$(sql "select f.rel_path from collection_books c join files f on f.content_key = c.content_key
             where c.name = 'gd Xtra' and c.removed_at is null")
was=$(row "$cover" 'gd Xtra')
check "gd Xtra has a row for the cover" "${was#*|}" in
check "the cover's sidecar has it" "$(sidecar Comics "$cover" | grep -c 'gd Xtra')" 1
written=$(stat -c %y "$home/Comics/.$cover.crdb")
sleep 2
gc
say "gd Xtra"
shot 16_library_already
key Return
# The notice ("Already in gd Xtra") is up for four seconds, and wait_gone
# only answers once it has gone too: the picture of it comes first.
shot 17_library_already_said
check "Enter closes the dialog" "$(wait_gone)" gone
check "gc on a cover with a collection it is in leaves its row as it was" "$(row "$cover" 'gd Xtra')" "$was"
check "and its sidecar unwritten" "$(stat -c %y "$home/Comics/.$cover.crdb")" "$written"
stop

rm -f "$out/now.png" "$before"
montage -label '%t' "$out"/[01]*.png -tile 3x -geometry 480x338+4+14 "$out/contact.png"
grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR' && { echo "FAIL  errors in the log"; failed=1; }
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
