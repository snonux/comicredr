#!/usr/bin/env bash
# End-to-end check that what only keys reached before has a way by touch,
# with no key or mouse at all: the library header's ⋮ opens the menu and
# its Shuffle line turns shuffle on; a comic opened by taps; ⋮ on the
# status line and its lines (Favourite, Last page, Turn clockwise), a swipe
# up on the page opening the same menu, the touch tutorial from the menu
# paged through to Done, and the menu's Back to the library. Touches come
# from tool/e2e/touch_inject.c; results are read back from the index with
# sqlite3 and from screenshots.
#
#   tool/e2e/e2e_touch_menu.sh
#
# The menu's lines are tapped where they are in a 1280x720 window: the
# list scrolled to its top, or by two swipes to its end. A line added to
# the reader's menu moves the ones under it; tool/e2e/e2e_touch_menu.sh then
# fails on the line it missed, and its screenshots show where it went.
#
# Needs: Xvfb, xdotool, ImageMagick, tesseract, sqlite3, python3, a C compiler and
# GTK 3 headers.
# Output: build/e2e-touch-menu/*.png and contact.png.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/e2e-touch-menu
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
python3 detector/make_synthetic.py --out "$out/src" --per-kind 2 >/dev/null
python3 - "$out" <<'EOF'
import glob, sys, zipfile
out = sys.argv[1]
pages = sorted(glob.glob(f"{out}/src/*.jpg"))
for name, first in (("Menu 01.cbz", 0), ("Menu 02.cbz", 4)):
    with zipfile.ZipFile(f"{out}/Comics/{name}", "w", zipfile.ZIP_STORED) as z:
        for i in range(8):
            z.write(pages[(first + i) % len(pages)], f"page{i + 1:02}.jpg")
EOF
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
read -r -a gtk_flags <<<"$(pkg-config --cflags --libs gtk+-3.0)"
cc -shared -fPIC -o "$out/touch_inject.so" tool/e2e/touch_inject.c "${gtk_flags[@]}"

export DISPLAY=:92
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
touches="$out/touches"
: >"$touches"
# No session bus and no XDG folders of whoever runs it, as the newer
# scripts do (AGENTS.md).
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent GDK_BACKEND=x11 \
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$PWD/$out/home" \
  build/linux/x64/release/bundle/comicredr --add-root "$PWD/$out/Comics" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# Xvfb has no window manager to focus the view for injected touches.
win=''
for _ in $(seq 1 120); do
  win=$(xdotool search --onlyvisible --name '^ComicRedr$' 2>/dev/null |
    tail -1 || true)
  [[ -n "$win" ]] && break
  sleep 0.5
done
[[ -n "$win" ]] || { echo "ComicRedr did not open a window; see $out/app.log"; exit 1; }
xdotool windowfocus "$win"

db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
shot() { import -window root -crop 1280x720+0+0 "$out/$1.png"; }
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep "${3:-3}"; }
# swipe x0 y0 x1 y1: one finger in 20 moves, quick enough for a flick.
swipe() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 $(( $1 + ($3 - $1) * i / 20 )) $(( $2 + ($4 - $2) * i / 20 )); done
  touch up 0 "$3" "$4"
  sleep 1.5
}
differ() { tool/e2e/differ_px.sh 5% "$out/$1.png" "$out/$2.png"; }

failed=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
expect() { if [[ "$1" == "$2" ]]; then ok "$3: $1"; else fail "$3: $1, expected $2"; fi; }
changed() {
  local d
  d=$(differ "$1" "$2")
  if (( d > $3 )); then ok "$4 ($d pixels differ)"; else fail "$4: only $d pixels differ"; fi
}
same() {
  local d
  d=$(differ "$1" "$2")
  if (( d < $3 )); then ok "$4 ($d pixels differ)"; else fail "$4: $d pixels differ"; fi
}
setting() { q "select value from settings where key = '$1'"; }
view() { q "select page + 1, json_extract(view_json, '$.rotation') from progress order by updated_at desc limit 1"; }
favourites() {
  q "select count(*) from collection_books where name = 'Favourites' and removed_at is null"
}
# The status line's ⋮, and the menu's list scrolled to its end.
menu() { tap 1248 693; }
menu_end() { menu; swipe 640 550 640 100; swipe 640 550 640 100; }

# Wait for the first scan before locating a header action or a cover.
for _ in $(seq 1 120); do
  [[ $(q 'select count(*) from books' 2>/dev/null) == 2 ]] &&
    [[ $(q 'select count(*) from roots where scanned_at is not null' 2>/dev/null) == 1 ]] && break
  sleep 0.5
done
sleep 1

# 1. The library header's ⋮: the menu, Close, then its Shuffle line.
shot 01_library
tap 1212 28 5; shot 02_library_menu
changed 01_library 02_library_menu 50000 "the library's ⋮ opens the menu"
tap 820 642; shot 03_closed
same 01_library 03_closed 3000 "Close leaves the menu with nothing done"
tap 1212 28 5; tap 560 548
expect "$(setting library.shuffle)" true "the menu's Shuffle line"
tap 1212 28 5; tap 560 548
expect "$(setting library.shuffle)" false "and again: shuffle off"

# 2. A comic, opened by taps on the Books tab.
tap 43 160; tap 190 200; tap 190 200 3; shot 04_comic
expect "$(view | cut -d'|' -f1)" 1 "two taps on a cover open the comic"

# 3. ⋮ on the status line: Favourite.
menu; shot 05_reader_menu
changed 04_comic 05_reader_menu 50000 "the status line's ⋮ opens the menu"
tap 560 151
expect "$(favourites)" 1 "the menu's Favourite line: the comic is a favourite"

# Started can be set and removed entirely by touch.
menu; tap 560 199
expect "$(q "select json_extract(value, '$.value') from overrides where field='readingStarted'")" 1 "the menu marks reading started"
menu; tap 560 199
expect "$(q "select json_extract(value, '$.value') from overrides where field='readingStarted'")" 0 "the menu marks not started"

# 4. A swipe up on the page opens it too: Last page.
shot 06_before_swipe
swipe 640 520 640 160; shot 07_swiped_up
changed 06_before_swipe 07_swiped_up 50000 "a swipe up on the page opens the menu"
tap 560 589
expect "$(view | cut -d'|' -f1)" 8 "the menu's Last page line"

# 5. Turn clockwise, at the end of the list.
menu_end; shot 08_menu_end
# Crop to the dialog and invert its dark theme: whole-screen OCR often
# finds only the brighter comic underneath and misses the menu entirely.
menu_labels=$(convert "$out/08_menu_end.png" -crop 440x620+420+50 \
  -resize 200% -colorspace Gray -negate pgm:- |
  tesseract stdin stdout --psm 6 2>/dev/null)
if [[ "$menu_labels" == *"Touch zones and gestures"* &&
      "$menu_labels" == *"Keyboard shortcuts"* &&
      "$menu_labels" != *"Show the touch zones"* &&
      "$menu_labels" != *"Keys and gestures"* ]]; then
  ok "one touch-zones-and-gestures tutorial, keyboard help named separately"
else
  fail "the menu's help labels: $menu_labels"
fi
tap 560 145 2.5
expect "$(view | cut -d'|' -f2)" 1 "the menu's Turn clockwise line"

# 6. One tutorial from the menu: live tap zones and all gestures,
# including double-tap; twelve pages, Next to Done.
expect "$(setting touch.guideSeen)" "" "the tutorial did not show by itself on Linux"
shot 09_before_tutorial
menu_end; tap 560 517 2.5; shot 10_tutorial
changed 09_before_tutorial 10_tutorial 50000 "the menu's Touch zones and gestures line opens the tutorial"
tap 831 648 2; shot 11_tutorial_zones
changed 10_tutorial 11_tutorial_zones 5000 "Next turns its page"
zone_labels=$(convert "$out/11_tutorial_zones.png" -crop 480x630+400+40 \
  -resize 200% -colorspace Gray -negate pgm:- |
  tesseract stdin stdout --psm 6 2>/dev/null)
if [[ "$zone_labels" == *"Tap to turn"* &&
      "$zone_labels" == *"Next"* && "$zone_labels" == *"Back"* ]]; then
  ok "the same tutorial draws the live tap zones"
else
  fail "the tutorial's tap-zone page: $zone_labels"
fi
for _ in $(seq 1 10); do tap 831 648 2; done
shot 12_tutorial_last
tap 831 648 2; shot 13_tutorial_done
same 09_before_tutorial 13_tutorial_done 5000 "Done on the last page closes it"
expect "$(setting touch.guideSeen)" true "seen, so Android would not show it again"

# 7. Back to the library from the menu.
menu_end; tap 560 397 2; shot 14_library_again
changed 13_tutorial_done 14_library_again 100000 "the menu's Back to the library line"

montage -label '%t' "$out"/*.png -tile 4x -geometry 480x270+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit "$failed"
