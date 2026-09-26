#!/usr/bin/env bash
# End-to-end check of the part-of-the-page keys on the Linux build: H1 H2
# (halves), B1-B3 (thirds) and Q1-Q4 (quarters) enlarge that part of a page
# guided view shows whole, and of any page outside guided view. Steps go
# through the parts in reading order, then to the whole page (held, wine
# red, in guided view), then the page turns. The same keys again or Esc
# show the whole page; Esc does not leave guided view or the book. A tap in
# the right zone steps like a key.
#
#   tool/e2e_regions.sh book.cbz [page]   # page: 1-based, default 3
#
# The page must be shown whole in guided view (reptisaurus-v2-005.cbz from
# the corpus: page 3 is a splash). The build has the detector built in;
# COMICREDR_MODEL=file.onnx tries another. tool/region_check.py tells which
# part a shot frames, against the page whole in single-page mode.
#
# Needs: Xvfb, xdotool, ImageMagick, Python with Pillow, a C compiler and
# GTK 3 and X11 headers.
# Output: build/e2e-regions/*.png and build/e2e-regions/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

page="${2:-3}"
out=build/e2e-regions
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
cp -r "$1" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$1")"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
touches="$out/touches"

start() {
  : >"$touches"
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
close_gracefully() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "the app did not quit on close"; failed=1; kill "$app"
}
step=${E2E_STEP:-1.2}
key() { xdotool key "$@" 2>/dev/null; sleep "$step"; }
shot() { import -window root "$out/$1.png"; }
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep "$step"; }
# A part key: part H 1 types H then 1.
part() { key "shift+${1,,}" "$2"; }

failed=0
# framed shot split n: the shot frames part n of split, of the page in ref_a.
framed() {
  local got; got=$(python3 tool/region_check.py "$out/ref_a.png" "$out/$1.png")
  read -r split n score <<<"$got"
  if [[ "$split $n" == "$2 $3" && "${score%.*}" -lt 20 ]]; then echo "ok    $1: $2 $3 framed (off by $score)"
  else echo "FAIL  $1: expected $2 $3 framed, best match $got"; failed=1; fi
}
# whole shot ref: the shot shows the page of ref whole.
whole() {
  local got; got=$(python3 tool/region_check.py "$out/$2.png" "$out/$1.png" whole)
  local score=${got#whole }
  if [[ "${score%.*}" -lt 8 ]]; then echo "ok    $1: whole page as $2 (off by $score)"
  else echo "FAIL  $1: expected the whole page of $2, off by $score"; failed=1; fi
}
background() { convert "$out/$1.png" -format '%[pixel:p{60,340}]' info:; }
# held shot / black shot: the background beside the page.
held() {
  local bg; bg=$(background "$1")
  if [[ "$bg" == 'srgb(58,13,22)' ]]; then echo "ok    $1: held, wine-red background"
  else echo "FAIL  $1: expected the wine-red background, got $bg"; failed=1; fi
}
black() {
  local bg; bg=$(background "$1")
  if [[ "$bg" == 'srgb(0,0,0)' ]]; then echo "ok    $1: black background"
  else echo "FAIL  $1: expected a black background, got $bg"; failed=1; fi
}

start
key "$page" shift+g; shot ref_a
key l;               shot ref_b
key "$page" shift+g

# Outside guided view: halves, then the whole page, then the next page.
part H 1;  shot u01_upper_half;   framed u01_upper_half halves 1
key l;     shot u02_lower_half;   framed u02_lower_half halves 2
key l;     shot u03_whole;        whole u03_whole ref_a
key l;     shot u04_next_page;    whole u04_next_page ref_b
key "$page" shift+g
# Thirds, and Esc back to the whole page, still in the book.
part B 1;  shot u05_third_1;      framed u05_third_1 thirds 1
key Right; shot u06_third_2;      framed u06_third_2 thirds 2
key space; shot u07_third_3;      framed u07_third_3 thirds 3
key h;     shot u08_back_2;       framed u08_back_2 thirds 2
key Escape; shot u09_esc;         whole u09_esc ref_a
# Quarters straight to one, then the same key again.
part Q 3;  shot u10_quarter_3;    framed u10_quarter_3 quarters 3
key l;     shot u11_quarter_4;    framed u11_quarter_4 quarters 4
part Q 4;  shot u12_again;        whole u12_again ref_a

# Guided view, on the page it shows whole.
key v; sleep 3
shot g00_guided;                  whole g00_guided ref_a; black g00_guided
part H 2;  shot g01_lower_half;   framed g01_lower_half halves 2; black g01_lower_half
key h;     shot g02_upper_half;   framed g02_upper_half halves 1
key h;     shot g03_held_back;    whole g03_held_back ref_a; held g03_held_back
key l;     shot g04_held_forward; whole g04_held_forward ref_b
key "$page" shift+g
part B 2;  shot g05_third_2;      framed g05_third_2 thirds 2
key l;     shot g06_third_3;      framed g06_third_3 thirds 3
key l;     shot g07_held;         whole g07_held ref_a; held g07_held
key l;     shot g08_turned;       whole g08_turned ref_b; black g08_turned
key "$page" shift+g
part Q 1;  shot g09_quarter_1;    framed g09_quarter_1 quarters 1
for n in 2 3 4; do
  key l;   shot "g1${n}_quarter_$n"; framed "g1${n}_quarter_$n" quarters "$n"
done
key Escape; shot g15_esc;         whole g15_esc ref_a
key l;     shot g16_held;         held g16_held
key l;     shot g17_turned;       whole g17_turned ref_b
# A tap in the right zone steps like a key.
key "$page" shift+g
part Q 1;  shot t01_quarter_1;    framed t01_quarter_1 quarters 1
tap 1200 340; shot t02_tap;       framed t02_tap quarters 2
tap 80 340;   shot t03_tap_back;  framed t03_tap_back quarters 1
# Esc: the whole page first, then out of guided view, still in the book.
key Escape; key Escape; shot g18_unguided; whole g18_unguided ref_a

close_gracefully
montage -label '%t' "$out"/*.png -tile 5x -geometry 384x270+4+14 "$out/contact.png"
grep -i 'detector' "$out/app.log" | sort | uniq -c || true
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
[[ $failed == 0 ]] && echo "Every part framed, stepped and left as it should; screenshots in $out/"
exit $failed
