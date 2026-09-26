#!/usr/bin/env bash
# End-to-end check of Settings → Export settings and Import settings on the
# Linux build under Xvfb with Openbox: an install gets every setting away
# from its default (by keys in the reader and the library, by the Settings
# dialog and, for the rest, in its index), a keys.toml, two library folders,
# a position, a bookmark, a mark, a favourite, a collection, an edit and
# reading history, with sidecars off so none of it is on disk beside the
# comics. It is exported through the GTK save dialog, its whole HOME is
# deleted, and a fresh start imports the file through the GTK open dialog.
# Every value must come back, and show at once: the window goes fullscreen,
# the folders are scanned, and a key from the imported keys.toml works, all
# before a restart. Then a restart, and files that are refused (another
# app's, a newer format, not JSON) leave everything as it was.
#
#   tool/e2e_settings_backup.sh
#
# Makes its own two small books, so it needs no corpus. E2E_SKIP_BUILD=1
# reuses the release build already in build/.
# Needs: Xvfb, openbox, xdotool, xprop (x11-utils), ImageMagick, sqlite3,
# Python 3, a C compiler, X11 headers. Output: build/e2e-settings-backup/*.png
# and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-settings-backup
rm -rf "$out" && mkdir -p "$out/Comics/Indie" "$out/Manga" "$out/Stash" "$out/home"
# The settings files live outside build/: GTK completes a typed path inline,
# and another build/e2e-* folder turns "e" into "e2e-" and garbles it.
files=$(mktemp -d /tmp/comicredr-settings-XXXXXX)
comics="$PWD/$out/Comics"
manga="$PWD/$out/Manga"
stash="$PWD/$out/Stash"
home="$PWD/$out/home"
backup="$files/comicredr-settings.json"
for i in 1 2 3 4; do
  convert -size 800x1200 xc:white -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,560' -draw 'rectangle 40,620 760,1160' \
    -fill black -stroke none -pointsize 90 -annotate +300+400 "P$i" "$out/p$i.png"
done
python3 - "$out" <<'EOF'
import sys, zipfile, pathlib
d = pathlib.Path(sys.argv[1])
for name, n in [('Comics/Indie/Test Comic 1.cbz', 4), ('Manga/Other Comic 2.cbz', 3)]:
    with zipfile.ZipFile(d / name, 'w') as z:
        for i in range(1, n + 1):
            z.write(d / f'p{i}.png', f'page{i}.png')
EOF

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
openbox >/dev/null 2>&1 &
wm=$!
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true; cp -r "$files" "$out/files"; rm -rf "$files"' EXIT
sleep 1

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
db="$home/.local/share/org.snonux.comicredr/comicredr.sqlite"
keys="$home/.config/comicredr/keys.toml"
q() { sqlite3 -batch -noheader "$db" "$1"; }
setting() { q "select value from settings where key = '$1'"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
start() { # start [folders...]
  local add=()
  for f in "$@"; do add+=(--add-root "$f"); done
  HOME="$home" build/linux/x64/release/bundle/comicredr "${add[@]}" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name "^ComicRedr$" | tail -1)
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
fullscreen() { xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN; }
# Where the window's content is on screen: Openbox's frame moves it, and
# fullscreen takes it away.
origin() {
  local info
  info=$(xwininfo -id "$win")
  ox=$(awk '/Absolute upper-left X/ {print $NF}' <<<"$info")
  oy=$(awk '/Absolute upper-left Y/ {print $NF}' <<<"$info")
  w=$(awk '/Width:/ {print $NF}' <<<"$info")
  h=$(awk '/Height:/ {print $NF}' <<<"$info")
}
# Clicks at x,y inside the window.
at() { origin; click $((ox + $1)) $((oy + $2)); }
# The gear, then the bottom of the Settings dialog, where Back up is: its
# two buttons sit near the bottom of the dialog.
settings_bottom() {
  origin
  click $((ox + w - 30)) $((oy + 28))
  xdotool mousemove $((ox + w / 2)) $((oy + h / 2)) click --repeat 20 --delay 50 5; sleep 1
}
# Export settings… and Import settings…: the dialog is centred and, scrolled
# to its end, the Back up buttons are a fixed way up from the bottom.
backup_button() { # backup_button export|import
  origin
  local dx=-166
  [[ $1 == import ]] && dx=30
  click $((ox + w / 2 + dx)) $((oy + h - 152))
}
# Types PATH into the GTK open dialog: Home first, out of Recent, which
# takes no path; Ctrl+L then takes one.
open_path() {
  local dlg info dx dy
  dlg=
  for _ in $(seq 1 20); do dlg=$(xdotool search --name '^Open File$' | tail -1) && [[ -n $dlg ]] && break; sleep 0.25; done
  [[ -n $dlg ]] || { echo "FAIL no open dialog"; failed=1; return; }
  info=$(xwininfo -id "$dlg")
  dx=$(awk '/Absolute upper-left X/ {print $NF}' <<<"$info")
  dy=$(awk '/Absolute upper-left Y/ {print $NF}' <<<"$info")
  click $((dx + 57)) $((dy + 60))
  key ctrl+l
  xdotool type --delay 40 "$1" 2>/dev/null; sleep 0.5
  key Return
}
# Every table an export carries, as text, in a fixed order.
dump() {
  # ~/Comics taken out is this device's own business: never exported.
  q "select key, value from settings where key not like 'device.%' and key != 'library.defaultFolderRemoved' order by key"
  echo ---; q "select path from roots order by path"
  echo ---; q "select content_key, page, panel, percent, finished, updated_at, view_json from progress order by 1"
  echo ---; q "select id, content_key, page, panel, mark, note, created_at, deleted_at from bookmarks order by 1"
  echo ---; q "select name, content_key, added_at, removed_at from collection_books order by 1, 2"
  echo ---; q "select content_key, field, value from overrides order by 1, 2"
  echo ---; q "select content_key, started_at, ended_at, pages from read_log order by 1, 2"
}

# 1. The install to back up: two library folders, sidecars off (so nothing
# of it is beside the comics), kept in one folder when they come back on,
# and ~/Comics taken out of the library, set in its index while it is shut.
start "$comics" "$manga"
stop
q "insert or replace into settings (key, value) values ('sidecars.write', 'false'), ('sidecars.dir', '\"$stash\"'),
   ('library.defaultFolderRemoved', 'true')"
mkdir -p "$(dirname "$keys")"
cat >"$keys" <<'EOF'
[keys]
toggleFavourite = ["*", "F2"]

[touch]
swipeUp = "showTime"
EOF

start
at 43 100 # Series
at 390 200 # Test Comic #1
key Return; sleep 2
key Next Next # page 3
key m m # a bookmark
key m q # mark q
key asterisk # Favourites
key greater # turned a quarter
key i # night filter
key t # auto-trim
key c # clean-up
key w # no whole-page steps
key shift+w # pages shown whole turn at once
key g w # the zoom cue
key p; key plus plus; key Escape # bigger page thumbnails
shot 01_reading
key Escape; sleep 2
at 43 380 # Folders
key shift+s # shuffle
settings_bottom
shot 02_settings
# Touch: One thumb, the right-hand segment above the reading history.
origin
click $((ox + w / 2 + 36)) $((oy + h - 568))
shot 03_touch
key Escape
key f # fullscreen, last
sleep 2
check "fullscreen before export" fullscreen
stop
# What the keys and the dialog cannot reach in a few steps: an edit and a
# collection made in the details.
key_of_test=$(q "select content_key from files where rel_path like 'Indie/%'")
key_of_other=$(q "select content_key from files where rel_path like 'Other%'")
q "insert into overrides (content_key, field, value) values ('$key_of_test', 'series', '{\"value\":\"Swamp Thing\",\"at\":1790000000000}')"
q "insert into collection_books (name, content_key, added_at) values ('Moore', '$key_of_other', 1790000000)"

want_changed() { # every setting away from its default
  test "$(setting guided.wholePageSteps)" = false -a "$(setting guided.pauseWhole)" = false \
    -a "$(setting guided.pauseCue)" = '"zoom"' -a "$(setting reader.night)" = true \
    -a "$(setting reader.autoTrim)" = true -a "$(setting reader.fullscreen)" = true \
    -a "$(setting reader.cleanUp)" = true -a "$(setting sidecars.write)" = false \
    -a "$(setting sidecars.dir)" = "\"$stash\"" -a -n "$(setting grid.zoom)" \
    -a "$(setting library.shuffle)" = true -a "$(setting library.defaultFolderRemoved)" = true \
    -a "$(setting touch.preset)" = '"oneThumb"'
}
check "every setting is changed before the export" want_changed
check "a position on page 3, turned" test "$(q "select page || ' ' || (view_json like '%\"rotation\":1%') from progress where content_key = '$key_of_test'")" = "2 1"
check "a bookmark and a mark" test "$(q "select count(*) from bookmarks where deleted_at is null")" = 2
check "a favourite and a collection" test "$(q "select count(*) from collection_books")" = 2
check "reading history" test "$(q "select count(*) from read_log")" -ge 1
check "no sidecar anywhere" test -z "$(find "$comics" "$manga" "$stash" -name '*.crdb')"
dump >"$out/before.txt"
cp "$keys" "$out/keys.before.toml"

# 2. Export, through the save dialog, in fullscreen as it was left.
start
check "the restart comes back fullscreen" fullscreen
settings_bottom
shot 04_back_up
backup_button export
sleep 1.5
shot 05_save_dialog
key ctrl+a
xdotool type --delay 40 "$backup" 2>/dev/null; sleep 0.5
key Return
sleep 1.5
shot 06_exported
stop
check "the file is written" test -s "$backup"
check "it says it is ComicRedr's settings, format 1" python3 -c "
import json, sys
j = json.load(open(sys.argv[1]))
assert j['app'] == 'org.snonux.comicredr' and j['kind'] == 'settings' and j['format'] == 1, j
assert len(j['settings']) == 12 and 'device.id' not in j['settings'], j['settings']
assert 'library.defaultFolderRemoved' not in j['settings'], j['settings']
assert j['keysToml'] == open(sys.argv[2]).read()
" "$backup" "$keys"

# 3. Wipe everything the app had: a fresh HOME.
rm -rf "$home" && mkdir -p "$home"
start
check "a fresh start has an empty library" test "$(q "select count(*) from roots")" = 0
check "a fresh start is not fullscreen" bash -c "! xprop -id $win _NET_WM_STATE | grep -q FULLSCREEN"
shot 07_fresh

# 4. Import, through the open dialog: it asks first, then takes it all up.
# The empty library has its Settings button in the middle.
origin
click $((ox + w / 2 + 175)) $((oy + h / 2 + 14))
xdotool mousemove $((ox + w / 2)) $((oy + h / 2)) click --repeat 20 --delay 50 5; sleep 1
backup_button import
sleep 1.5
open_path "$backup"
sleep 1.5
shot 08_confirm
key Return # Import is focused
sleep 3
shot 09_imported
check "the window went fullscreen at once" fullscreen
for _ in $(seq 1 20); do [[ "$(q "select count(*) from files")" == 2 ]] && break; sleep 0.5; done
check "the library folders are scanned at once" test "$(q "select count(*) from files")" = 2
dump >"$out/after.txt"
check "every setting and row came back" diff "$out/before.txt" "$out/after.txt"
check "keys.toml came back" cmp "$out/keys.before.toml" "$keys"
check "nothing but the settings file was needed: still no sidecars" \
  test -z "$(find "$comics" "$manga" "$stash" -name '*.crdb')"
settings_bottom
shot 10_settings_after
key Escape
# The imported keys.toml is live: F2 takes the selected comic out of the
# Favourites, with no restart.
origin
click $((ox + 43)) $((oy + 100)) # Series
click $((ox + 390)) $((oy + 200)) # Test Comic #1, the favourite
fav() { q "select removed_at is null from collection_books where name = 'Favourites'"; }
before_fav=$(fav)
key F2
sleep 1
check "a key from the imported keys.toml works at once" test "$before_fav" = 1 -a "$(fav)" = 0
key F2
sleep 1
check "and puts it back" test "$(fav)" = 1
stop

# 5. A restart keeps it all, and the comic opens where it was left.
start
check "fullscreen after a restart" fullscreen
origin
click $((ox + 43)) $((oy + 100))
click $((ox + 390)) $((oy + 200))
key Return; sleep 2.5
shot 11_resumed
key Escape; sleep 2
check "the position is still page 3" test "$(q "select page from progress where content_key = '$key_of_test'")" = 2
dump >"$out/after_restart.txt"

# 6. Files that are not ComicRedr's settings are refused and change nothing.
printf '{"app": "org.example.gallery", "kind": "settings", "format": 1, "settings": {"reader.night": false}}\n' >"$files/other.json"
printf '{"app": "org.snonux.comicredr", "kind": "settings", "format": 99, "settings": {"reader.night": false}}\n' >"$files/newer.json"
printf '[keys]\nnextStep = ["n"]\n' >"$files/keys.json"
n=12
for bad in other newer keys; do
  at 43 100 # Series, with nothing selected: the gear is at the right again
  settings_bottom
  backup_button import
  sleep 1.5
  open_path "$files/$bad.json"
  sleep 1.5
  shot "$n"_refused_"$bad"
  n=$((n + 1))
  sleep 8 # The notice goes.
done
dump >"$out/after_refused.txt"
check "refused files change nothing" diff "$out/after_restart.txt" "$out/after_refused.txt"

# 7. Another device's file: its own sidecars beside its comics and written
# (the defaults, so not in the file), its ~/Comics taken out, one folder
# not on this device. Nothing of this device's library or sidecar place
# may change; the other settings become the file's.
printf '{"app": "org.snonux.comicredr", "kind": "settings", "format": 1,
  "settings": {"reader.night": true, "library.defaultFolderRemoved": true},
  "libraryFolders": ["/nowhere/Comics"]}\n' >"$files/laptop.json"
roots_before=$(q "select path from roots order by path")
at 43 100
settings_bottom
backup_button import
sleep 1.5
open_path "$files/laptop.json"
sleep 1.5
shot 15_laptop_confirm
key Return
sleep 2
shot 16_laptop_imported
check "another device's file takes no library folder out" test "$(q "select path from roots order by path")" = "$roots_before"
check "nor moves this device's sidecars" test "$(setting sidecars.dir)" = "\"$stash\"" -a "$(setting sidecars.write)" = false
check "its other settings are the file's" test "$(setting reader.night)" = true -a -z "$(setting reader.cleanUp)"
check "and it does not carry ~/Comics being taken out" test -z "$(setting library.defaultFolderRemoved)"
stop

montage "$out"/[01]*.png -tile 4x -geometry 480x338+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
