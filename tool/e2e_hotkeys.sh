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
#    (That it undoes once is test/hotkeys_test.dart's: putting a favourite
#    back twice shows nothing.)
#  - The Folders tab's filter (`F`): Space picks the type that has the
#    focus, Alt+C clears it, Alt+D is Done.
#  - `gA` takes the selected library folder out; its comics stay on disk;
#    `u` puts it back and its comics are found again.
#  - The comic's details (`I`): End, then Alt+P is Redo panels: the pages
#    are analysed again, the app is still there and answers keys (`mm`
#    bookmarks the page and takes the bookmark off again, in the index;
#    Esc, the library as it was).
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
    convert -size 400x600 xc:white -fill black -pointsize 90 -annotate +60+300 "$i . $p" \
      "$out/pages/p$p.png" 2>/dev/null
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
  # window there instead of in Xvfb, where the keys go. No session bus and
  # no XDG folders of whoever runs this: the app then cannot reach their
  # keyring (the S3 secret) or their own data, whatever a key here does.
  # The bus address names a socket that is not there, rather than being
  # unset: unset, D-Bus falls back to $XDG_RUNTIME_DIR/bus, which on a
  # desktop is the real session's.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
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

# 2b. Redo panels in the comic's details: Alt+P from the end of the list,
# where its button is built, closes the details and nothing under them.
# (When the button's label and a shortcut of the view both took the key,
# the second pop took the app's own page away: a dead dark window.)
key Return
sleep 3
wait_q 'select count(*) from analysed_pages' 5 || true
check "the open comic's pages are analysed" "$(q 'select count(*) from analysed_pages')" 5
before=$(q 'select max(analysed_at) from analysed_pages')
sleep 1.5 # The index keeps whole seconds: the redo is later than $before.
shot reader
reader=$(sum "$last")
key I
differs details "$reader" "I opens the details"
key End
sleep 1
shot details_end
key alt+p
wait_q "select count(*) from analysed_pages where analysed_at <= $before" 0 || true
check "Alt+P: the panels found before are forgotten" \
  "$(q "select count(*) from analysed_pages where analysed_at <= $before")" 0
wait_q "select count(*) > 0 from analysed_pages where analysed_at > $before" 1 || true
check "and found again" "$(q "select count(*) > 0 from analysed_pages where analysed_at > $before")" 1
if kill -0 "$app" 2>/dev/null; then ok "the app is still running"; else fail "the app is gone after Alt+P"; fi
shot after_redo
# The app is alive and answers keys: mm bookmarks the page (a row in the
# index), mm again takes the bookmark off, Esc is back in the library as
# it was.
marks='select count(*) from bookmarks where deleted_at is null'
key m m
wait_q "$marks" 1 || true
check "mm bookmarks the page: the comic answers keys" "$(q "$marks")" 1
key m m
wait_q "$marks" 0 || true
check "mm again takes the bookmark off" "$(q "$marks")" 0
key Escape
same library_after_redo "$library" "Esc leaves the comic: the library as it was"

# 3. The delete question.
key g d
differs delete "$library" "gd asks before deleting"
# The question once it has faded in: the look above can be of it halfway.
sleep 1
shot delete_settled
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
if [[ ! -e "$comics/Book 01.cbz" ]]; then
  ok "the selected comic, Book 01, is the one gone"
else
  fail "Book 01.cbz is still there"
fi

# 4. The collection question: the name typed with no pause after gc, the
# letters of its buttons among them.
sleep 5 # The notice of the delete gone.
shot before_collection
before=$(sum "$last")
xdotool key g c
xdotool type --delay 40 ac
# The name is typed at once; Alt+A waits until the question is drawn. A
# key with Alt that comes before the dialog is built (the first one of a
# run can take a moment) is dropped, by design: it is no part of a name,
# and there is no button yet to press.
differs collection "$before" "gc shows the collection question"
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
# The notice offers it back, and u is its Undo: in the library again, and
# scanned, so its comics are in the index again.
key u
wait_q 'select count(*) from roots' 1 || true
check "u puts the library folder back" "$(q 'select count(*) from roots')" 1
check "the same folder" "$(q 'select path from roots')" "$comics"
wait_q 'select count(*) from files' 5 || true
check "and its comics are found again" "$(q 'select count(*) from files')" 5
check "nothing on disk changed" "$(files)" 5
shot end

if ((failed)); then
  echo "e2e hotkeys FAILED (screenshots in $out)"
  exit 1
fi
echo "e2e hotkeys passed (screenshots in $out)"
