#!/usr/bin/env bash
# End-to-end check of the `?` help's text size on the Linux build: in the
# help `+` and `-` make the text a step bigger and smaller, up to three
# times the usual size and down to 0.7 of it, where nothing changes any
# more; `-` after `+` and `=` are the usual size with nothing kept; Ctrl and
# the wheel size the text while the wheel alone scrolls the list; `+` alone
# typed into the help's search, and `-` alone in a second search, leave the
# size as it is and change what the list shows (the search took them), and
# `+` sizes again once Enter gave the keys back; none of it sizes the covers
# behind the help, and with the help away `+` sizes the covers and not the
# help; the size is there again after a restart; and a size that is none
# put into the index (NaN, -12) starts at the usual size, one far too big
# (1000000) at the biggest.
#
# The text size is measured off screenshots: the help's title line starts
# with a capital K at the left edge of the list, and the height of that
# letter is the first run of light pixels down the columns it stands in.
# It is compared with the setting `help.textSize` in the index (sqlite3),
# which is what the app keeps: the factor on the usual size.
#
# Nothing is measured after a fixed wait where there is something to wait
# for: the script looks again until the screenshot or the index shows what
# the step should give (6 s at most), and then checks it. Only where a key
# must change nothing (`+` at the biggest size) is there a plain wait.
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
last= # The file of the last look, without .png.
# look name: a screenshot, then the top and height of the title's K.
look() {
  n=$((n + 1))
  local name
  name=$(printf '%02d_%s' "$n" "$1")
  shot "$name"
  read -r ktop kheight < <(measure "$name")
  last=$name
}
# look_until name test [args]: looks again and again until the test holds
# for what is on screen, 6 s at most. The last look stands either way: the
# checks after it say what is wrong when the wait ran out.
look_until() {
  local name
  n=$((n + 1))
  name=$(printf '%02d_%s' "$n" "$1")
  shift
  for _ in $(seq 1 30); do
    shot "$name"
    read -r ktop kheight < <(measure "$name")
    last=$name
    "$@" && return 0
    sleep 0.2
  done
  return 0
}
# Tests for look_until, over the K of the last look.
# k_is factor: the K is [factor] times its usual height, to a pixel and a
# twentieth (letters are drawn on whole pixels).
k_is() {
  awk -v h="$kheight" -v u="$usual" -v f="$1" 'BEGIN { d = h - u * f; if (d < 0) d = -d; exit !(d <= 1 + u * f * 0.05) }'
}
k_same() { [[ "$ktop $kheight" == "$1" ]]; }
k_differs() { [[ "$ktop $kheight" != "$1" ]]; }
# k_now factor old: a K of that size that is not the look of before; two
# sizes a step apart can be within k_is of each other.
k_now() { k_is "$1" && k_differs "$2"; }
# help_is factor: the help is up (not the library's left edge) at that size.
help_is() { k_differs "$closed" && k_is "$1"; }
# What the list shows under the title or the search field, as a checksum
# of that part of a screenshot (without the right edge, where a scrollbar
# fades after a scroll); list_differs old holds when the last look shows
# something else there.
listsum() { convert "$top/$out/$1.png" -crop 1200x600+0+120 +repage rgb:- 2>/dev/null | md5sum | cut -d' ' -f1; }
list_differs() { [[ "$(listsum "$last")" != "$1" ]]; }
# wait_size value: until the kept size is [value], 5 s at most.
wait_size() {
  for _ in $(seq 1 25); do [[ "$(size)" == "$1" ]] && return 0; sleep 0.2; done
  return 1
}
# wait_size_change old: until the kept size is no longer [old], 5 s at most.
wait_size_change() {
  for _ in $(seq 1 25); do [[ "$(size)" != "$1" ]] && return 0; sleep 0.2; done
  return 1
}
# step key what name factor: press, wait for the kept size to change and
# for the K to be drawn [factor] times the usual, then the look stands.
step() {
  local before was="$ktop $kheight"
  before=$(size)
  key "$1"
  wait_size_change "$before" || fail "$2: the kept size stayed '$before'"
  look_until "$3" k_now "$4" "$was"
}
# still key what name: press, and the kept size must not change. There is
# nothing to wait for when nothing is to happen, so a plain wait.
still() {
  local before
  before=$(size)
  key "$1"
  sleep 1.5
  check "$2: the kept size" "$(size)" "$before"
  look "$3"
}
# times what factor: the K of the last look is [factor] times its usual height.
times() {
  if k_is "$2"; then
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
look_until help_usual k_differs "$closed"
usual=$kheight
if [[ "$ktop $kheight" != "$closed" ]]; then ok "? opens the help"; else fail "? changed nothing at the left edge"; fi
if ((usual >= 8 && usual <= 16)); then ok "the help at the usual size: the title's K is $usual px high"; else fail "the help: K $usual px high"; fi
check "nothing is kept before a zoom" "$(size)" ""

# 2. + and -, a step a press.
step plus "+" plus 1.15
check "+ keeps the next size" "$(size)" 1.15
times "+" 1.15
step plus "+ again" plus_again 1.3
check "+ again keeps the size after it" "$(size)" 1.3
times "+ again" 1.3
step minus "-" minus 1.15
check "- goes a step back" "$(size)" 1.15
times "-" 1.15
step minus "- again" minus_again 1
check "+ + - - is the usual size again: nothing kept" "$(size)" ""
check "and the letters are as they were" "$kheight" "$usual"

# 3. The biggest: + until nothing changes, then once more. The list still
# shows keys and scrolls.
for _ in $(seq 1 12); do key plus; done
wait_size 3.0 || true
look_until biggest k_is 3
check "the biggest text is three times the usual" "$(size)" 3.0
times "the biggest" 3
still plus "+ at the biggest" biggest_again
times "+ at the biggest changes nothing" 3
before="$ktop $kheight"
xdotool mousemove 640 400
for _ in 1 2 3 4 5 6; do xdotool click 5; sleep 0.1; done
look_until biggest_scrolled k_differs "$before"
if [[ "$ktop $kheight" != "$before" ]]; then ok "the list scrolls at the biggest text"; else fail "the list did not scroll at the biggest text"; fi
for _ in $(seq 1 10); do xdotool click 4; sleep 0.1; done
look_until biggest_top k_same "$before"
check "and back to its top" "$ktop $kheight" "$before"

# 4. The smallest: - until nothing changes, then once more.
for _ in $(seq 1 14); do key minus; done
wait_size 0.7 || true
look_until smallest k_is 0.7
check "the smallest text is 0.7 of the usual" "$(size)" 0.7
times "the smallest" 0.7
still minus "- at the smallest" smallest_again
times "- at the smallest changes nothing" 0.7

# 5. = is the usual size, and no setting.
step equal "=" usual_again 1
check "= forgets the kept size" "$(size)" ""
check "= puts the usual letters back" "$kheight" "$usual"

# 6. Ctrl and the wheel; the wheel alone only scrolls.
xdotool mousemove 640 400
was="$ktop $kheight"
xdotool keydown ctrl; sleep 0.3; xdotool click 4; sleep 0.5; xdotool keyup ctrl
wait_size_change "" || fail "Ctrl and the wheel: nothing kept"
look_until ctrl_wheel k_now 1.15 "$was"
check "Ctrl and the wheel up keeps a step bigger" "$(size)" 1.15
times "Ctrl and the wheel up" 1.15
title="$ktop $kheight"
xdotool click 5; sleep 0.3; xdotool click 5
# Once the list has moved the wheel has been dealt with, so the size is final.
look_until wheel_alone k_differs "$title"
if [[ "$ktop $kheight" != "$title" ]]; then ok "the wheel alone scrolls the list"; else fail "the wheel alone did not scroll the list"; fi
check "and does not size the text" "$(size)" 1.15
xdotool click 4; sleep 0.3; xdotool click 4; sleep 0.3; xdotool click 4
look_until wheel_back k_same "$title"
check "the list is back at its top" "$ktop $kheight" "$title"

# 7. + typed into the help's search is typing: the size stays, and the
# list shows something else, since the search took the character. One key
# only: + then - would end at the same size also if both had sized the
# text. Then the same for - alone in a search of its own. After Enter,
# which keeps the filter and gives the keys back, + sizes the text again.
# typed_in_search key name: / then [key] alone, then Esc.
typed_in_search() {
  local shown
  key slash
  look_until "search_$1" k_differs "$title"
  if [[ "$ktop $kheight" != "$title" ]]; then ok "/ puts the search field in the title's place"; else fail "/ opened no search field"; fi
  shown=$(listsum "$last")
  key "$1"
  # The list changing is the key having been dealt with: the size is final.
  look_until "search_${1}_typed" list_differs "$shown"
  if list_differs "$shown"; then ok "$2 typed in the help's search is searched for: the list shows something else"; else fail "$2 typed in the help's search changed nothing in the list"; fi
  check "$2 typed in the help's search keeps the size" "$(size)" 1.15
}
typed_in_search plus +
key Escape # The search goes, the whole list and its title are back.
look_until search_plus_left k_same "$title"
check "Esc clears the search: the title is back as it was" "$ktop $kheight" "$title"
typed_in_search minus -
key Return
sleep 0.8 # The keys go back to the help; nothing on screen shows it.
key plus
wait_size_change 1.15 || fail "+ after Enter in the search: the kept size stayed 1.15"
check "+ after Enter in the search sizes the text" "$(size)" 1.3
look search_entered
key Escape # The filter goes.
look_until search_cleared k_is 1.3
times "Esc clears the search, and the title is back at the kept size" 1.3

# 8. None of that sized the covers behind the help; Esc closes it, and
# then + sizes the covers and not the help.
check "the covers behind the help were not sized" "$(setting library.coverSize)" ""
key Escape
look_until help_closed k_same "$closed"
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
look_until after_restart help_is 1.3
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
  look_until "bad_size_$bad" help_is 1
  check "a kept size of $bad: the usual letters" "$kheight" "$usual"
  step plus "+ after a kept size of $bad" "bad_size_${bad}_plus" 1.15
  times "+ after a kept size of $bad" 1.15
  check "+ after a kept size of $bad keeps the next size" "$(size)" 1.15
  stop
done
q "insert or replace into settings (key, value) values ('help.textSize', '\"1000000\"')"
start
key question
look_until huge_size help_is 3
times "a kept size of 1000000 is the biggest text" 3
stop

echo
if ((failed)); then echo "FAILED; screenshots in $out/"; exit 1; fi
echo "All help text size checks passed; screenshots in $out/"
