#!/usr/bin/env bash
# End-to-end check that the Linux build follows its window's size: read
# into a book, resize the window the way a window manager does (including a
# fast drag through many sizes), then put it back and compare the screen
# with how it looked before. Each case saves before/during/after
# screenshots, and the script fails when a before/after pair differs or the
# app logs an error.
#
#   tool/e2e_resize.sh book.cbz
#
# Cases: a zoomed and scrolled page, narrowed and widened; guided view on a
# panel, turned to a tall "portrait" window and back; the library grid at a
# wide and a narrow width (screenshots only, for the eye).
#
# Needs: Xvfb, xdotool, ImageMagick.
# Output: build/e2e-resize/*.png and build/e2e-resize/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-resize
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
cp -r "$1" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$1")"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1600x1600x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1

HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >"$out/app.log" 2>&1 &
app=$!
sleep 6
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowmove "$win" 0 0 windowsize --sync "$win" 1280 900 windowactivate --sync "$win" 2>/dev/null || true
xdotool mousemove 640 400 click 1 2>/dev/null || true
sleep 2

key() { xdotool key "$@" 2>/dev/null; sleep 0.8; }
size() { xdotool windowsize "$win" "$1" "$2"; sleep "${3:-2}"; }
# The window's own pixels, from the top-left corner of the screen.
shot() { import -window root -crop "$(xdotool getwindowgeometry "$win" | awk '/Geometry/ {print $2}')+0+0" +repage "$out/$1.png"; }
# Compares the page area only: the status line says different things.
same() {
  local a="$out/$1_before.png" b="$out/$1_after.png" diff
  diff=$(compare -metric AE -fuzz 10% <(convert "$a" -crop 1280x780+0+0 png:-) \
    <(convert "$b" -crop 1280x780+0+0 png:-) null: 2>&1 || true)
  echo "$1: $diff pixels differ"
  [[ "${diff%% *}" -lt 4000 ]] || { echo "  the view changed across the resize"; failed=1; }
}
failed=0

# A zoomed, scrolled page: narrower, wider and back keeps zoom and place.
key 3 shift+g; sleep 1
key plus plus j j
shot normal_before
size 1100 900 0.05; size 900 900 0.05; size 700 900
shot normal_narrow
size 1280 600
shot normal_short
size 1280 900
shot normal_after
same normal

# A fast drag through forty sizes, then back: no errors, same view.
for w in $(seq 700 15 1285); do xdotool windowsize "$win" "$w" 900; sleep 0.02; done
size 1280 900
shot drag_after
cp "$out/normal_after.png" "$out/drag_before.png"
same drag

# Guided view on a panel, turned tall and back, as a phone rotates.
key v; sleep 3
key l l; sleep 1
shot guided_before
size 700 1250 3
shot guided_portrait
size 1280 900 3
shot guided_after
same guided

# The library grid reflows.
key Escape Escape; sleep 1
shot library_wide
size 560 900
shot library_narrow
size 1280 900

if grep -Ei 'exception|error' "$out/app.log" | grep -v -e libEGL -e Atk-CRITICAL; then echo "the app logged errors"; failed=1; fi
montage "$out"/{normal_before,normal_narrow,normal_short,normal_after,guided_before,guided_portrait,guided_after,library_wide,library_narrow}.png \
  -tile 3x -geometry 480x480+6+6 -background '#333' "$out/contact.png"
echo "screenshots in $out"
exit "$failed"
