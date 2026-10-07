#!/usr/bin/env bash
# End-to-end check of the `?` help's text size on the Linux build: in the
# help `+` and `-` make the text a step bigger and smaller, up to three
# times the usual size and down to 0.7 of it, where nothing changes any
# more; `-` after `+` and `=` are the usual size with nothing kept; Ctrl and
# the wheel size the text while the wheel alone scrolls the list; `+` typed
# into the help's search is typing, and sizes again once Enter gave the
# keys back; none of it sizes the covers behind the help, and with the help
# away `+` sizes the covers and not the help; the size is there again after
# a restart; and a size that is none put into the index (NaN, -12) starts
# at the usual size, one far too big (1000000) at the biggest.
#
# The text size is measured off screenshots: the help's title line starts
# with a capital K at the left edge of the list, and the height of that
# letter is the first run of light pixels down the columns it stands in.
# It is compared with the setting `help.textSize` in the index (sqlite3),
# which is what the app keeps: the factor on the usual size.
#
#   tool/e2e_help_zoom.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3 + Pillow. Makes its
# own books.
# Output: build/e2e-help-zoom/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-help-zoom
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics" "$out/pages"
home="$top/$out/home"
# No ~/Comics in this HOME, so the index is in the XDG data folder.
db="$home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# Twelve comics for the library behind the help; the second page differs
# per comic, since the same bytes twice would be one comic.
convert -size 400x600 xc:'#ff00ff' "$out/pages/p1.png"
for i in $(seq -w 1 12); do
  convert -size 400x600 xc:white -fill black -pointsize 120 -annotate +80+300 "$i" "$out/pages/p2.png"
  python3 - "$out/pages" "$out/Comics/Book $i.cbz" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for n in ('p1.png', 'p2.png'):
        z.write(f'{sys.argv[1]}/{n}', n)
EOF
done

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release

export DISPLAY=:91
# -noreset: without it Xvfb starts over when its last client goes, which
# the app is when it is stopped for a restart, and the next start could
# find the display closed for that moment ("cannot open display").
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
size() { setting help.textSize; }
start() {
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys go.
  HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  for _ in $(seq 1 60); do xdotool search --name ComicRedr >/dev/null 2>&1 && break; sleep 0.25; done
  sleep 3
  xdotool mousemove 640 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root -crop 1280x720+0+0 +repage "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.25; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }

# measure shot: "top height" of the first thing written at the left edge
# of the help, the title's K: the first run of lines down the screenshot
# that have a pixel much lighter or darker than the margin beside them in
# the columns 24 to 34, where the K stands at every size. "0 0" for none.
measure() {
  python3 - "$top/$out/$1.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('L')
px = im.load()
ink = lambda y: any(abs(px[x, y] - px[8, y]) > 70 for x in range(24, 35))
top = next((y for y in range(2, im.height) if ink(y)), None)
if top is None:
    print('0 0')
else:
    end = next((y for y in range(top, im.height) if not ink(y)), im.height)
    print(top, end - top)
EOF
}
n=0
# look name: a screenshot, then the top and height of the title's K.
look() {
  n=$((n + 1))
  local name
  name=$(printf '%02d_%s' "$n" "$1")
  shot "$name"
  read -r ktop kheight < <(measure "$name")
}
# wait_size_change old: until the kept size is no longer [old], 5 s at most.
wait_size_change() {
  for _ in $(seq 1 25); do [[ "$(size)" != "$1" ]] && return 0; sleep 0.2; done
  return 1
}
# step key what name: press, wait for the kept size to change, look again.
step() {
  local before
  before=$(size)
  key "$1"
  if wait_size_change "$before"; then sleep 0.8; else fail "$2: the kept size stayed '$before'"; fi
  look "$3"
}
# still key what name: press, and the kept size must not change.
still() {
  local before
  before=$(size)
  key "$1"
  sleep 1.5
  check "$2: the kept size" "$(size)" "$before"
  look "$3"
}
# times what factor: the K is [factor] times its usual height, to a pixel
# and a twentieth (letters are drawn on whole pixels).
times() {
  if awk -v h="$kheight" -v u="$usual" -v f="$2" 'BEGIN { d = h - u * f; if (d < 0) d = -d; exit !(d <= 1 + u * f * 0.05) }'; then
    ok "$1: the title's K is $kheight px high, $2 times the usual $usual"
  else
    fail "$1: the title's K is $kheight px high, expected $2 times the usual $usual"
  fi
}

# 1. The library scanned, the help opened: the usual size, nothing kept.
start --add-root "$top/$out/Comics"
for _ in $(seq 1 120); do [[ "$(q 'select count(*) from books' 2>/dev/null)" == 12 ]] && break; sleep 0.5; done
check "the library has the comics" "$(q 'select count(*) from books')" 12
sleep 3 # Covers.
# Without the help the first thing down those columns is the library's
# rail; that is how the help being closed is told later.
look library
closed="$ktop $kheight"
key question
sleep 1
look help_usual
usual=$kheight
if [[ "$ktop $kheight" != "$closed" ]]; then ok "? opens the help"; else fail "? changed nothing at the left edge"; fi
if ((usual >= 8 && usual <= 16)); then ok "the help at the usual size: the title's K is $usual px high"; else fail "the help: K $usual px high"; fi
check "nothing is kept before a zoom" "$(size)" ""

# 2. + and -, a step a press.
step plus "+" plus
check "+ keeps the next size" "$(size)" 1.15
times "+" 1.15
step plus "+ again" plus_again
check "+ again keeps the size after it" "$(size)" 1.3
times "+ again" 1.3
step minus "-" minus
check "- goes a step back" "$(size)" 1.15
step minus "- again" minus_again
check "+ + - - is the usual size again: nothing kept" "$(size)" ""
check "and the letters are as they were" "$kheight" "$usual"

# 3. The biggest: + until nothing changes, then once more. The list still
# shows keys and scrolls.
for _ in $(seq 1 12); do key plus; done
sleep 1.5
look biggest
check "the biggest text is three times the usual" "$(size)" 3.0
times "the biggest" 3
still plus "+ at the biggest" biggest_again
times "+ at the biggest changes nothing" 3
before="$ktop $kheight"
xdotool mousemove 640 400
for _ in 1 2 3 4 5 6; do xdotool click 5; sleep 0.1; done
sleep 1
look biggest_scrolled
if [[ "$ktop $kheight" != "$before" ]]; then ok "the list scrolls at the biggest text"; else fail "the list did not scroll at the biggest text"; fi
for _ in $(seq 1 10); do xdotool click 4; sleep 0.1; done
sleep 1

# 4. The smallest: - until nothing changes, then once more.
for _ in $(seq 1 14); do key minus; done
sleep 1.5
look smallest
check "the smallest text is 0.7 of the usual" "$(size)" 0.7
times "the smallest" 0.7
still minus "- at the smallest" smallest_again
times "- at the smallest changes nothing" 0.7

# 5. = is the usual size, and no setting.
step equal "=" usual_again
check "= forgets the kept size" "$(size)" ""
check "= puts the usual letters back" "$kheight" "$usual"

# 6. Ctrl and the wheel; the wheel alone only scrolls.
xdotool mousemove 640 400
xdotool keydown ctrl; sleep 0.3; xdotool click 4; sleep 0.5; xdotool keyup ctrl
wait_size_change "" || fail "Ctrl and the wheel: nothing kept"
sleep 0.8
look ctrl_wheel
check "Ctrl and the wheel up keeps a step bigger" "$(size)" 1.15
times "Ctrl and the wheel up" 1.15
before="$ktop $kheight"
xdotool click 5; sleep 0.3; xdotool click 5
sleep 1.5
check "the wheel alone does not size the text" "$(size)" 1.15
look wheel_alone
if [[ "$ktop $kheight" != "$before" ]]; then ok "it scrolls the list"; else fail "the wheel alone did not scroll the list"; fi
xdotool click 4; sleep 0.3; xdotool click 4; sleep 0.3; xdotool click 4; sleep 1

# 7. + and - typed into the help's search are typing; after Enter, which
# keeps the filter and gives the keys back, + sizes the text again.
key slash
sleep 0.8
key plus
key minus
sleep 1.5
check "+ and - typed in the help's search keep the size" "$(size)" 1.15
before="$ktop $kheight"
look search_typed
if [[ "$ktop $kheight" != "$before" ]]; then ok "the search field took the title's place"; else fail "/ opened no search field"; fi
key Return
sleep 0.8
key plus
wait_size_change 1.15 || fail "+ after Enter in the search: the kept size stayed 1.15"
check "+ after Enter in the search sizes the text" "$(size)" 1.3
look search_entered
key Escape # The filter goes.
sleep 0.8
look search_cleared
times "Esc clears the search, and the title is back at the kept size" 1.3

# 8. None of that sized the covers behind the help; Esc closes it, and
# then + sizes the covers and not the help.
check "the covers behind the help were not sized" "$(setting library.coverSize)" ""
key Escape
sleep 1
look help_closed
check "Esc closes the help: the library's left edge again" "$ktop $kheight" "$closed"
click 43 170 # Books
key plus
for _ in $(seq 1 25); do [[ -n "$(setting library.coverSize)" ]] && break; sleep 0.2; done
if [[ -n "$(setting library.coverSize)" ]]; then ok "+ with the help away sizes the covers ($(setting library.coverSize))"; else fail "+ in the library kept no cover size"; fi
check "and leaves the help's size" "$(size)" 1.3

# 9. A restart keeps the size, also the first time the help opens.
stop
start
key question
sleep 1
look after_restart
check "the kept size after a restart" "$(size)" 1.3
times "the help after a restart" 1.3
stop

# 10. A size that is no size, as a settings file edited by hand could have
# left it: the help shows at the usual size and + works from there. One far
# beyond the steps is the biggest text, not a blank screen.
for bad in NaN -12; do
  q "insert or replace into settings (key, value) values ('help.textSize', '\"$bad\"')"
  start
  key question
  sleep 1
  look "bad_size_$bad"
  check "a kept size of $bad: the usual letters" "$kheight" "$usual"
  step plus "+ after a kept size of $bad" "bad_size_${bad}_plus"
  check "+ after a kept size of $bad keeps the next size" "$(size)" 1.15
  stop
done
q "insert or replace into settings (key, value) values ('help.textSize', '\"1000000\"')"
start
key question
sleep 1
look huge_size
times "a kept size of 1000000 is the biggest text" 3
stop

echo
if ((failed)); then echo "FAILED; screenshots in $out/"; exit 1; fi
echo "All help text size checks passed; screenshots in $out/"
