#!/usr/bin/env bash
# End-to-end check of the keys for buttons and dialogs (task 263) on the
# Linux build, by the keyboard alone: no click and no pointer over the
# window (it is parked below the window once, so nothing hovers; the window
# gets the keys by `xdotool windowfocus`).
#
# What it drives:
#  - Settings by `g,`: Tab to the first switch and Space (Clean up old
#    scans, kept in the index), Tab to the scrolling speed and Right; Alt+H
#    asks before clearing the reading history, where Enter is Cancel (the
#    history stays) and Alt+L clears it; Alt+C closes Settings.
#  - The delete question (`gd`): Tab moves the focus ring and Shift+Tab
#    puts it back (the screenshots differ and match again), `d` without Alt
#    deletes nothing, Enter is Cancel, Alt+C cancels, Alt+D deletes: the
#    file is gone and the index has a comic fewer.
#  - The collection question (`gc`): `ac` typed with no pause is the name
#    (the letters of Add and Cancel are letters in the field), Alt+A adds
#    it; a second name is dropped with Alt+C.
#  - `*`, `gf`, `x` and then `u`: the undo key puts the favourite back.
#  - The Folders tab's filter (`F`): Space picks the type that has the
#    focus, Alt+C clears it, Alt+D is Done.
#  - `gA` takes the selected library folder out; its comics stay on disk.
#
# Nothing is checked after a fixed wait where there is something to wait
# for: the script asks the index (sqlite3) or looks at the screen again
# until it shows what the key should give, 8 s at most, and then checks.
# Only where a key must change nothing is there a plain wait.
#
#   tool/e2e_hotkeys.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3. Makes its own books.
# Output: build/e2e-hotkeys/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-hotkeys
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics" "$out/pages"
home="$top/$out/home"
comics="$top/$out/Comics"
# No ~/Comics in this HOME, so the index is in the XDG data folder.
db="$home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Six comics of five pages; every page says which comic it is, since the
# same bytes twice would be one comic.
for i in 1 2 3 4 5 6; do
  for p in 1 2 3 4 5; do
    convert -size 400x600 xc:white -fill black -pointsize 90 -annotate +60+300 "$i . $p" "$out/pages/p$p.png" 2>/dev/null
  done
  python3 - "$out/pages" "$out/Comics/Book 0$i.cbz" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for n in range(1, 6):
        z.write(f'{sys.argv[1]}/p{n}.png', f'p{n}.png')
EOF
done

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release

export DISPLAY=:93
# -noreset: without it Xvfb starts over when its last client goes.
Xvfb "$DISPLAY" -noreset -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# Xvfb takes a moment to listen, and with GDK_BACKEND=x11 the app dies on
# a display that is not there yet.
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failed=1; }
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else fail "$1: $2, expected $3"; fi
}
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
# A kept setting without its quotes; empty when unset (the default).
setting() { q "select value from settings where key = '$1'" | tr -d '"'; }
start() {
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys go.
  HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  local win=
  for _ in $(seq 1 60); do
    win=$(xdotool search --onlyvisible --name ComicRedr 2>/dev/null | head -1) && [[ -n "$win" ]] && break
    sleep 0.25
  done
  sleep 3
  # The pointer below the window (which is 720 high), so that nothing in
  # it is hovered, and the keys to the window without a click.
  xdotool mousemove 1279 899
  xdotool windowfocus "$win"
  sleep 0.5
}
key() { xdotool key "$@" 2>/dev/null; sleep 0.3; }
n=0
last=
# grab: the window into the file $last.
grab() { import -window root -crop 1280x720+0+0 +repage "$last"; }
# shot name: a screenshot of the window under the next number; its file
# is $last.
shot() {
  n=$((n + 1))
  last="$top/$out/$(printf '%02d_%s' "$n" "$1").png"
  grab
}
# The pixels of a screenshot as a checksum (a PNG's bytes also hold when
# it was written).
sum() { convert "$1" rgb:- 2>/dev/null | md5sum | cut -d' ' -f1; }
# differs name old what: looks again and again, 8 s at most, until the
# screen is no longer what [old] is the checksum of. The last look stands
# as the screenshot [name] either way.
differs() {
  shot "$1"
  for _ in $(seq 1 40); do
    if [[ "$(sum "$last")" != "$2" ]]; then ok "$3"; return 0; fi
    sleep 0.2
    grab
  done
  fail "$3: the screen did not change (see $last)"
}
# same name old what: until the screen is again what [old] is the checksum
# of, 12 s at most (a notice along the bottom takes four to go).
same() {
  shot "$1"
  for _ in $(seq 1 60); do
    if [[ "$(sum "$last")" == "$2" ]]; then ok "$3"; return 0; fi
    sleep 0.2
    grab
  done
  fail "$3: the screen is not as it was (see $last)"
}
# wait_q sql value: until the index answers [value], 8 s at most.
wait_q() {
  for _ in $(seq 1 40); do [[ "$(q "$1" 2>/dev/null)" == "$2" ]] && return 0; sleep 0.2; done
  return 1
}
# wait_setting key value / wait_setting_not key value.
wait_setting() {
  for _ in $(seq 1 40); do [[ "$(setting "$1")" == "$2" ]] && return 0; sleep 0.2; done
  return 1
}
wait_setting_not() {
  for _ in $(seq 1 40); do [[ "$(setting "$1")" != "$2" ]] && return 0; sleep 0.2; done
  return 1
}
files() { find "$comics" -name '*.cbz' | wc -l; }
in_collection() { q "select count(*) from collection_books where name = '$1' and removed_at is null"; }

# 1. The library scanned; a sitting with the first comic for the history.
start --add-root "$comics"
wait_q 'select count(*) from books' 6 || true
check "the library has the comics" "$(q 'select count(*) from books')" 6
sleep 3 # Covers.
key Tab # Series -> Books.
key l
key Return
sleep 3
key Next; key Next; key Next
sleep 4
key Escape
wait_q 'select count(*) > 0 from read_log' 1 || true
check "a sitting is in the reading history" "$(q 'select count(*) > 0 from read_log')" 1
sleep 5 # The library's notice gone, the cover's progress drawn.
shot library
library=$(sum "$last")

# 2. Settings, by keys alone.
check "Clean up old scans is not set before" "$(setting reader.cleanUp)" ""
key g comma
differs settings "$library" "g, opens Settings"
key Tab
key space
wait_setting_not reader.cleanUp "" || true
if [[ -n "$(setting reader.cleanUp)" ]]; then
  ok "Tab and Space switch Clean up old scans on: $(setting reader.cleanUp)"
else
  fail "Tab and Space left Clean up old scans unset"
fi
speed=$(setting reader.scrollSpeed)
key Tab
key Right
wait_setting_not reader.scrollSpeed "$speed" || true
if [[ "$(setting reader.scrollSpeed)" != "$speed" ]]; then
  ok "Tab and Right move the scrolling speed: '$speed' -> '$(setting reader.scrollSpeed)'"
else
  fail "Tab and Right left the scrolling speed at '$speed'"
fi
shot settings_changed
settings=$(sum "$last")
log=$(q 'select count(*) from read_log')
key alt+h
differs clear_history "$settings" "Alt+H asks before clearing the history"
key Return
same clear_history_cancelled "$settings" "Enter there is Cancel: back in Settings"
check "and the history is still there" "$(q 'select count(*) from read_log')" "$log"
key alt+h
differs clear_history_again "$settings" "Alt+H asks again"
key alt+l
wait_q 'select count(*) from read_log' 0 || true
check "Alt+L clears the history" "$(q 'select count(*) from read_log')" 0
key alt+c
same settings_closed "$library" "Alt+C closes Settings: the library as it was"

# 3. The delete question.
key g d
differs delete "$library" "gd asks before deleting"
question=$(sum "$last")
key Tab
differs delete_tab "$question" "Tab moves the focus ring off Cancel"
key shift+Tab
same delete_back "$question" "Shift+Tab puts it back"
key d
sleep 1.5
same delete_d "$question" "d without Alt changes nothing in the question"
check "and deletes nothing" "$(files)" 6
key Return
same delete_enter "$library" "Enter is Cancel: the question is gone"
check "Enter deleted nothing" "$(files)" 6
key g d
differs delete_again "$library" "gd asks again"
key alt+c
same delete_cancelled "$library" "Alt+C cancels"
check "Alt+C deleted nothing" "$(files)" 6
key g d
differs delete_third "$library" "gd asks a third time"
key alt+d
wait_q 'select count(*) from books' 5 || true
check "Alt+D deletes: comics on disk" "$(files)" 5
check "Alt+D deletes: comics in the index" "$(q 'select count(*) from books')" 5
if [[ ! -e "$comics/Book 01.cbz" ]]; then ok "the selected comic, Book 01, is the one gone"; else fail "Book 01.cbz is still there"; fi

# 4. The collection question: the name typed with no pause after gc, the
# letters of its buttons among them.
sleep 5 # The notice of the delete gone.
xdotool key g c
xdotool type --delay 40 ac
key alt+a
wait_q "select count(*) from collection_books where name = 'ac' and removed_at is null" 1 || true
check "gc, ac typed at once, Alt+A: a comic in the collection ac" "$(in_collection ac)" 1
check "and no collection named a or c or empty" \
  "$(q "select count(*) from collection_books where name in ('a', 'c', '')")" 0
sleep 1
xdotool key g c
xdotool type --delay 40 zz
key alt+c
sleep 1.5
check "Alt+C drops the name typed" "$(q "select count(*) from collection_books where name like '%zz%'")" 0

# 5. A favourite taken out, and u for the notice's Undo.
key asterisk
wait_q "select count(*) from collection_books where name = 'Favourites' and removed_at is null" 1 || true
check "* makes the selected comic a favourite" "$(in_collection Favourites)" 1
key g f
sleep 1.5
key x
wait_q "select count(*) from collection_books where name = 'Favourites' and removed_at is null" 0 || true
check "gf, then x takes it out" "$(in_collection Favourites)" 0
key u
wait_q "select count(*) from collection_books where name = 'Favourites' and removed_at is null" 1 || true
check "u undoes that: a favourite again" "$(in_collection Favourites)" 1
key u
sleep 1.5
check "u again changes nothing" "$(in_collection Favourites)" 1
key Escape

# 6. The Folders tab's filter. gf left the library on Collections.
key Tab # History.
key Tab # Folders.
sleep 6 # The notice of the undo gone.
shot folders
folders=$(sum "$last")
check "no filter before" "$(setting library.folderFilter)" ""
key F
differs filter "$folders" "F opens the filter"
key space
wait_setting_not library.folderFilter "" || true
if [[ -n "$(setting library.folderFilter)" ]]; then
  ok "Space picks the type that has the focus: $(setting library.folderFilter)"
else
  fail "Space picked no type"
fi
key alt+c
wait_setting library.folderFilter "" || true
check "Alt+C clears the filter" "$(setting library.folderFilter)" ""
key alt+d
same filter_done "$folders" "Alt+D is Done: the Folders tab as it was"

# 7. The library folder taken out by gA; the comics stay.
check "one library folder" "$(q 'select count(*) from roots')" 1
key l
key g A
wait_q 'select count(*) from roots' 0 || true
check "gA takes the selected library folder out" "$(q 'select count(*) from roots')" 0
check "its comics stay on disk" "$(files)" 5
shot end

if ((failed)); then
  echo "e2e hotkeys FAILED (screenshots in $out)"
  exit 1
fi
echo "e2e hotkeys passed (screenshots in $out)"
