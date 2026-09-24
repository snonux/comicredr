#!/usr/bin/env bash
# End-to-end check of guided view's whole-page steps on the Linux build:
# each page is shown whole on arrival and again after its last panel, with
# keys and with touches, forwards and backwards across page boundaries; `w`
# turns that off and the choice survives a restart; a restart on a
# whole-page step comes back to it.
#
#   tool/e2e_whole_page.sh book.cbz [page]   # page: 1-based, default 4
#
# How it checks: a whole-page step must look like the same page outside
# guided view, and a panel step must not. Reference shots of the page and
# the next one are taken in single-page mode first; the status line is
# cropped off before comparing. Both pages need panels guided view steps
# through, so pick pages that pass the confidence gate (not a splash; in
# reptisaurus-v2-005.cbz from the corpus, pages 4 and 5 do) and set
# COMICREDR_MODEL to the trained .onnx file as in e2e_linux.sh.
#
# Needs: Xvfb, xdotool, ImageMagick, a C compiler and GTK 3 and X11 headers.
# Output: build/e2e-whole-page/*.png and build/e2e-whole-page/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

book="$1"
page="${2:-4}"
out=build/e2e-whole-page
rm -rf "$out" && mkdir -p "$out/home"
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

next=$(( page + 1 ))
start
# References: both pages whole in single-page mode.
key $page shift+g;   shot ref_a
key l;               shot ref_b

# On, the default. Keys forwards and backwards across the page boundary.
key $page shift+g; key v; sleep 3
shot k01_enter;      whole k01_enter ref_a
key l;               shot k02_first_panel;  zoomed k02_first_panel ref_a
key ctrl+f;          shot k03_next_page;    whole k03_next_page ref_b
key h;               shot k04_back_whole;   whole k04_back_whole ref_a
key h;               shot k05_last_panel;   zoomed k05_last_panel ref_a
key l;               shot k06_whole_again;  whole k06_whole_again ref_a
key l;               shot k07_next_whole;   whole k07_next_whole ref_b
key l;               shot k08_next_panel;   zoomed k08_next_panel ref_b
key h;               shot k09_back_whole;   whole k09_back_whole ref_b

# Touch: the same steps from taps and swipes.
key h; key h;        shot t01_last_panel;   zoomed t01_last_panel ref_a
tap 1200 340;        shot t02_tap_whole;    whole t02_tap_whole ref_a
swipe 900 340 400;   shot t03_swipe_next;   whole t03_swipe_next ref_b
swipe 400 340 900;   shot t04_swipe_back;   whole t04_swipe_back ref_a
tap 80 340;          shot t05_tap_back;     zoomed t05_tap_back ref_a

# A restart on the whole page after the panels comes back to it.
key l;               shot r_before;         whole r_before ref_a
close_gracefully
start;               shot r_after;          whole r_after ref_a
key l;               shot r_next;           whole r_next ref_b

# Off: straight from panel to panel across pages, both ways.
key w
key l;               shot o01_first_panel;  zoomed o01_first_panel ref_b
key h;               shot o02_prev_last;    zoomed o02_prev_last ref_a
key l;               shot o03_next_first;   zoomed o03_next_first ref_b
key ctrl+b;          shot o04_page_back;    zoomed o04_page_back ref_a

# The choice survives a restart.
close_gracefully
start
key $page shift+g;   shot o06_restarted;    zoomed o06_restarted ref_a
key ctrl+f;          shot o07_next_page;    zoomed o07_next_page ref_b
key w; key ctrl+b;   shot o08_on_again;     whole o08_on_again ref_a

close_gracefully
montage -label '%t' "$out"/*.png -tile 5x -geometry 384x270+4+14 "$out/contact.png"
grep -i 'detector' "$out/app.log" | sort | uniq -c || true
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
[[ $failed == 0 ]] && echo "Whole-page steps held in every case; screenshots in $out/"
exit $failed
