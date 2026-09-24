#!/usr/bin/env bash
# End-to-end check of the pause on whole pages in guided view, on the Linux
# build: on a page guided view shows whole (no panels that pass the gate),
# the first step onward stays on the page and turns the background wine red
# until the page is left, with a hint on the status line; the next step
# turns. Mirrored going back, the same from taps, not on pages with panels,
# skipped by a count. `gw` switches to the zoom cue (the page zooms out and
# back) and `W` turns it off, which survives a restart.
#
#   tool/e2e_pause_whole.sh book.cbz [page]   # page: 1-based, default 3
#
# The page must be shown whole in guided view and the next one must have
# panels: in reptisaurus-v2-005.cbz from the corpus, page 3 is a splash and
# page 4 has panels. Set COMICREDR_MODEL to the trained .onnx file, or build
# with it (make model). Checks work like e2e_whole_page.sh: shots against
# reference shots of both pages taken in single-page mode.
#
# Needs: Xvfb, xdotool, ImageMagick, a C compiler and GTK 3 and X11 headers.
# Output: build/e2e-pause-whole/*.png and build/e2e-pause-whole/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

page="${2:-3}"
out=build/e2e-pause-whole
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
# A copy, so a sidecar left beside the book by an earlier run never
# changes where it opens, and the original is never written to.
cp -r "$1" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$1")"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
touches="$out/touches"

start() {
  : >"$touches"
  # A fixed HOME keeps one index across restarts.
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$PWD/$out/touch_inject.so" \
    HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1) # The toplevel, not GDK's leader.
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
close_gracefully() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "the app did not quit on close"; failed=1; kill "$app"
}
# A PDF page renders for a second or more at guided view's width while
# detection shares the CPU, and the old page stays up until it is ready,
# so PDFs get longer between steps. E2E_STEP overrides.
case "$book" in *.pdf|*.PDF) step=${E2E_STEP:-3} ;; *) step=${E2E_STEP:-1.2} ;; esac
key() { xdotool key "$@" 2>/dev/null; sleep "$step"; }
shot() { import -window root "$out/$1.png"; }
# Touch in the Flutter view's logical pixels, as in e2e_linux.sh.
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep "$step"; }
swipe() {
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 $(( $1 + ($3 - $1) * i / 20 )) "$2"; done
  touch up 0 "$3" "$2"
  sleep "$step"
}

# Pixels that differ between a shot and a reference, status line cropped
# off. The fuzz absorbs resampling: guided view may decode the page at
# another resolution than single-page mode.
differ() {
  compare -metric AE -fuzz 10% <(convert "$out/$1.png" -crop 1280x680+0+0 png:-) \
    <(convert "$out/$2.png" -crop 1280x680+0+0 png:-) null: 2>&1 | cut -d' ' -f1 || true
}
failed=0
# whole shot ref: the shot shows the whole page, like ref.
whole() {
  local d; d=$(differ "$1" "$2")
  if [[ "${d%.*}" -lt 4000 ]]; then echo "ok    $1: whole page ($d px off $2)"
  else echo "FAIL  $1: expected the whole page, $d px off $2"; failed=1; fi
}
# zoomed shot ref: the shot frames a panel, not the whole page.
zoomed() {
  local d; d=$(differ "$1" "$2")
  if [[ "${d%.*}" -ge 4000 ]]; then echo "ok    $1: a panel ($d px off $2)"
  else echo "FAIL  $1: expected a panel, only $d px off $2"; failed=1; fi
}


# moving shot ref: caught mid-cue, the page is smaller than ref.
moving() {
  local d; d=$(differ "$1" "$2")
  if [[ "${d%.*}" -ge 4000 ]]; then echo "ok    $1: mid-cue ($d px off $2)"
  else echo "FAIL  $1: expected the page mid-cue, only $d px off $2"; failed=1; fi
}
# background shot: the colour of the screen beside the page.
background() { convert "$out/$1.png" -format '%[pixel:p{60,340}]' info:; }
wine='srgb(58,13,22)'
# held shot ref: still the page of ref, on a wine-red background.
held() {
  local d bg; bg=$(background "$1")
  d=$(compare -metric AE -fuzz 10% <(convert "$out/$1.png" -crop 300x500+490+100 png:-) \
    <(convert "$out/$2.png" -crop 300x500+490+100 png:-) null: 2>&1 | cut -d' ' -f1 || true)
  if [[ "${d%.*}" -lt 2000 && "$bg" == "$wine" ]]; then echo "ok    $1: held on the page, background $bg ($d px off $2)"
  else echo "FAIL  $1: expected the page held on $wine, background $bg, $d px off $2"; failed=1; fi
}
# black shot: the background is black again.
black() {
  local bg; bg=$(background "$1")
  if [[ "$bg" == 'srgb(0,0,0)' ]]; then echo "ok    $1: black background"
  else echo "FAIL  $1: expected a black background, got $bg"; failed=1; fi
}
# hint shot before: the status line changed (the hint is up).
hint() {
  local d
  d=$(compare -metric AE <(convert "$out/$1.png" -crop 1280x220+0+680 png:-) \
    <(convert "$out/$2.png" -crop 1280x220+0+680 png:-) null: 2>&1 | cut -d' ' -f1 || true)
  if [[ "${d%.*}" -ge 200 ]]; then echo "ok    $1: hint on the status line ($d px)"
  else echo "FAIL  $1: no hint on the status line ($d px)"; failed=1; fi
}

next=$(( page + 1 ))
prev=$(( page - 1 ))
start
# References: the page, the next and the previous one whole in single-page
# mode.
key $prev shift+g;   shot ref_prev
key $page shift+g;   shot ref_a
key l;               shot ref_b

# On, the default, with the colour cue. Right holds once, then turns.
key $page shift+g; key v; sleep 4
shot k01_enter;      whole k01_enter ref_a; black k01_enter
key Right;           shot k03_held;         held k03_held ref_a;  hint k03_held k01_enter
sleep 2;             shot k03b_still_held;  held k03b_still_held ref_a
key Right;           shot k04_turned;       whole k04_turned ref_b; black k04_turned
key Right;           shot k05_panel;        zoomed k05_panel ref_b

# Back: onto the page from ahead, held once, then the page before.
key Left;            shot k06_back_next;    whole k06_back_next ref_b
key Left;            shot k07_back_on;      whole k07_back_on ref_a
key Left;            shot k08_back_held;    held k08_back_held ref_a
key Left;            shot k09_back_turned;  whole k09_back_turned ref_prev
# Arrived from behind: back leaves at once, then from ahead forward does.
key $page shift+g;   shot k10_jump;         whole k10_jump ref_a
key Left;            shot k11_back_at_once; whole k11_back_at_once ref_prev
key $page shift+g; key Right; key Right; key Left
shot k12_from_ahead; whole k12_from_ahead ref_a
key Right;           shot k13_fwd_at_once;  whole k13_fwd_at_once ref_b

# A count does not hold.
key $page shift+g; key 2 l
shot k14_count;      zoomed k14_count ref_b

# Touch: the right tap zone holds the same way.
key $page shift+g
tap 1200 340;        shot t01_tap_held;     held t01_tap_held ref_a
tap 1200 340;        shot t02_tap_turned;   whole t02_tap_turned ref_b
swipe 400 340 900;   shot t03_swipe_back;   whole t03_swipe_back ref_a
swipe 400 340 900;   shot t04_swipe_held;   held t04_swipe_held ref_a

# gw: the zoom cue instead; the background stays black.
key $page shift+g; key g w
xdotool key Right; sleep 0.15
shot z01_cue;        moving z01_cue ref_a
sleep "$step"
shot z02_held;       whole z02_held ref_a;  black z02_held
key Right;           shot z03_turned;       whole z03_turned ref_b
key g w

# Off (W): the page turns at once, and stays off after a restart.
key $page shift+g; key shift+w
key Right;           shot o01_at_once;      whole o01_at_once ref_b
close_gracefully
start
key $page shift+g;   shot o02_restarted;    whole o02_restarted ref_a
key Right;           shot o03_still_off;    whole o03_still_off ref_b
key $page shift+g; key shift+w
key Right;           shot o04_on_again;     held o04_on_again ref_a

close_gracefully
montage -label '%t' "$out"/*.png -tile 5x -geometry 384x270+4+14 "$out/contact.png"
grep -i 'detector' "$out/app.log" | sort | uniq -c || true
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
[[ $failed == 0 ]] && echo "Whole pages held once in every case; screenshots in $out/"
exit $failed
