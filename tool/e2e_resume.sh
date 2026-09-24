#!/usr/bin/env bash
# End-to-end check of resume across a restart on the Linux build: read into
# a book, close the window the way a window manager's close button does (or
# kill the app outright), start it again on the same book, and compare the
# screen before and after. Each case saves a before/after pair of
# screenshots, and the script fails when a pair differs.
#
#   tool/e2e_resume.sh book.cbz
#
# Cases: guided view mid-page on a panel; balloon mode on a balloon; a
# zoomed and scrolled spread; guided view again, killed with SIGKILL a
# second after the last key instead of closed. COMICREDR_MODEL naming the
# trained .onnx file makes guided view use the model, as in e2e_linux.sh.
#
# Needs: Xvfb, xdotool, ImageMagick, a C compiler and the X11 headers.
# Output: build/e2e-resume/*.png and build/e2e-resume/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-resume
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
# A copy, so a sidecar left beside the book by an earlier run never
# changes where it opens, and the original is never written to.
cp -r "$1" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$1")"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

export DISPLAY=:98
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

start() {
  # A fixed HOME keeps one index across restarts.
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6 # Opening, then detection of the page on screen.
  win=$(xdotool search --name ComicRedr | tail -1) # The toplevel, not GDK's leader.
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
# A PDF page renders for a second or more at guided view's width while
# detection shares the CPU, and the old page stays up until it is ready,
# so PDFs get longer between steps. E2E_STEP overrides.
case "$book" in *.pdf|*.PDF) step=${E2E_STEP:-3} ;; *) step=${E2E_STEP:-0.8} ;; esac
key() { xdotool key "$@" 2>/dev/null; sleep "$step"; }
shot() { import -window root "$out/$1.png"; }
# The status line says "Resumed at …" after a restart; crop it off, so the
# pair compares only the page. The fuzz absorbs resampling: a book reopened
# straight into guided view decodes its page at a higher resolution than
# one that entered guided view from the page.
same() {
  local a="$out/$1_before.png" b="$out/$1_after.png" diff
  diff=$(compare -metric AE -fuzz 10% <(convert "$a" -crop 1280x680+0+0 png:-) \
    <(convert "$b" -crop 1280x680+0+0 png:-) null: 2>&1 || true)
  echo "$1: $diff pixels differ"
  [[ "${diff%% *}" -lt 2000 ]] || { echo "  resume did not restore the view"; failed=1; }
}
close_gracefully() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "the app did not quit on close"; failed=1; kill "$app"
}
failed=0

# Guided view on page 3, a few panels in, then closed a moment after the
# last step, before the debounced save: only the save on exit keeps it.
start
key 3 shift+g; key v; sleep 3
key l l;             shot guided_before
key h; sleep 1; xdotool key l; sleep 0.2
close_gracefully
start;               shot guided_after
same guided

# Balloon mode on a balloon, from where the last run left off.
key b; sleep 1; key l l
shot balloon_before
close_gracefully
start;               shot balloon_after
same balloon

# A zoomed, scrolled spread outside guided view.
key v; key d; key 5 shift+g; key plus plus; key j j
shot spread_before
close_gracefully
start;               shot spread_after
same spread

# Killed without warning, a second after the last key: the debounced save
# has landed by then.
key v; key b; sleep 3; key l; sleep 2 # b: balloons off again.
shot killed_before
sleep 1; kill -9 "$app"; wait "$app" 2>/dev/null || true
start;               shot killed_after
same killed

close_gracefully
montage -label '%t' "$out"/*_before.png "$out"/*_after.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
grep -i 'resumed\|detector' "$out/app.log" | sort | uniq -c || true
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
[[ $failed == 0 ]] && echo "Resume held in every case; screenshots in $out/"
exit $failed
