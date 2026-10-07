#!/usr/bin/env bash
# End-to-end check of the library's cover size on the Linux build: on the
# Folders tab `+` and `-` take a column off and add one, down to a biggest
# and up to a smallest cover where nothing changes any more, `=` puts the
# usual size back, Ctrl and the wheel zoom while the wheel alone does not,
# `+` typed in the search box is typing, the Books tab shows the same
# size, two injected fingers (tool/touch_inject.c) spread and pinch the
# covers while one finger still scrolls and a tap still selects, a finger
# resting on the selected cover while another pinches opens nothing,
# Settings' Cover size buttons do the same steps, the size is there again
# after a restart, and a size that is no number put into the index (NaN)
# still starts with covers at the usual size.
#
# Every cover is plain magenta, so the covers in the first row and their
# width are counted off a screenshot; the width is compared with the
# setting `library.coverSize` in the index (sqlite3), which is what the
# app keeps.
#
#   tool/e2e_cover_zoom.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, python3 + Pillow, a C
# compiler and GTK 3 headers. Makes its own books.
# Output: build/e2e-cover-zoom/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

top=$PWD
out=build/e2e-cover-zoom
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics" "$out/pages"
home="$top/$out/home"
# No ~/Comics in this HOME, so the index is in the XDG data folder.
db="$home/.local/share/org.snonux.comicredr/comicredr.sqlite"

# 40 comics, enough to scroll at any size. The cover is all magenta, a
# colour nothing else in the app has; the second page differs per comic,
# since the same bytes twice would be one comic.
convert -size 400x600 xc:'#ff00ff' "$out/pages/p1.png"
for i in $(seq -w 1 40); do
  convert -size 400x600 xc:white -fill black -pointsize 120 -annotate +80+300 "$i" "$out/pages/p2.png"
  python3 - "$out/pages" "$out/Comics/Book $i.cbz" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for n in ('p1.png', 'p2.png'):
        z.write(f'{sys.argv[1]}/{n}', n)
EOF
done

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -shared -fPIC -o "$out/touch_inject.so" tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)

export DISPLAY=:89
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
# The kept cover width, without its quotes; empty when unset (the default).
size() { q "select value from settings where key = 'library.coverSize'" | tr -d '"'; }
touches="$top/$out/touches"
start() {
  : >"$touches"
  # GDK_BACKEND: on a desktop running Wayland GTK would otherwise open the
  # window there instead of in Xvfb, where the keys go.
  TOUCH_INJECT_FILE="$touches" LD_PRELOAD="$top/$out/touch_inject.so" HOME="$home" GDK_BACKEND=x11 \
    "$top/build/linux/x64/release/bundle/comicredr" "$@" >>"$top/$out/app.log" 2>&1 &
  app=$!
  for _ in $(seq 1 60); do xdotool search --name ComicRedr >/dev/null 2>&1 && break; sleep 0.25; done
  sleep 3
  xdotool mousemove 500 450 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root -crop 1280x720+0+0 +repage "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.25; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
# Touches in the Flutter view's logical pixels, 16 ms apart as a
# touchscreen reports them.
touch() { echo "$@" >>"$touches"; sleep 0.016; }
tap() { touch down 0 "$1" "$2"; touch up 0 "$1" "$2"; sleep 1.2; }
swipe() { # swipe x0 y0 x1 y1: one finger in 20 moves
  touch down 0 "$1" "$2"
  for i in $(seq 1 20); do touch move 0 $(($1 + ($3 - $1) * i / 20)) $(($2 + ($4 - $2) * i / 20)); done
  touch up 0 "$3" "$4"
  sleep 1.2
}
pinch() { # pinch cx y from to: two fingers from cx±from to cx±to
  touch down 0 $(($1 - $3)) "$2"; touch down 1 $(($1 + $3)) "$2"
  for i in $(seq 1 12); do
    d=$(($3 + ($4 - $3) * i / 12))
    touch move 0 $(($1 - d)) "$2"; touch move 1 $(($1 + d)) "$2"
  done
  touch up 0 $(($1 - $4)) "$2"; touch up 1 $(($1 + $4)) "$2"
  sleep 1.2
}

# measure shot [xmax]: "columns width top" of the first row of magenta
# covers left of xmax (the details pane right of the covers shows a cover
# too): how many there are, how wide the widest is (the selected one loses
# its 3 px border on each side) and where the row starts. "0 0 0" for none.
measure() {
  python3 - "$top/$out/$1.png" "${2:-1280}" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
xmax = int(sys.argv[2])
px = im.load()
magenta = lambda x, y: px[x, y][0] > 200 and px[x, y][1] < 90 and px[x, y][2] > 200
def runs(y):
    out, start = [], None
    for x in range(90, xmax):
        if magenta(x, y):
            start = x if start is None else start
        elif start is not None:
            out.append(x - start); start = None
    if start is not None: out.append(xmax - start)
    return [r for r in out if r >= 30]
# The first line with a cover on it, then a line well inside that row,
# clear of rounded corners and the selection's border.
top = next((y for y in range(50, im.height - 20) if runs(y)), None)
if top is None:
    print('0 0 0')
else:
    row = runs(min(top + 20, im.height - 1))
    print(len(row), max(row), top)
EOF
}
# Settings, scrolled to its end and then twelve wheel notches (53 px each)
# back up: where the Cover size line's smaller and bigger buttons and
# Usual size are then. Counted from the end because what is under the line
# (Sidecars, Touch, Reading history, Back up, S3 sync) is the same in every
# run here, while above it the panel detector's path wraps into more lines
# in a checkout with a longer path, which would move the line if it were
# counted from the top. (Tab does not find the buttons reliably either:
# the focus goes by where things are on screen, and the dialog scrolls as
# it moves.)
smaller_x=${SMALLER_X:-400} bigger_x=${BIGGER_X:-444} usual_x=${USUAL_X:-515} size_y=${SIZE_Y:-362}
settings() {
  # The gear wants the pointer on it before the click.
  xdotool mousemove 1251 28; sleep 0.5; xdotool click 1; sleep 1.5
  xdotool mousemove 640 400
  for _ in $(seq 1 40); do xdotool click 5; sleep 0.05; done
  sleep 0.8
  for _ in $(seq 1 12); do xdotool click 4; sleep 0.05; done
  sleep 1
}
n=0
# Where the covers end: 1280, or 895 while a cover is selected and its
# details take the right of the window.
pane=1280
# look name: a screenshot, then cols, width and top of its first row.
look() {
  n=$((n + 1))
  local name
  name=$(printf '%02d_%s' "$n" "$1")
  shot "$name"
  read -r cols width rowtop < <(measure "$name" "$pane")
}
# wait_size_change old: until the kept size is no longer [old], 5 s at most.
wait_size_change() {
  for _ in $(seq 1 25); do [[ "$(size)" != "$1" ]] && return 0; sleep 0.2; done
  return 1
}
# The kept width and the covers on screen agree, to 4 px (the selected
# cover's border, rounding).
agrees() { awk -v s="$1" -v w="$2" 'BEGIN { d = s - w; if (d < 0) d = -d; exit !(s != "" && d <= 4) }'; }
# step key what: press, wait for the kept size to change, look again.
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

# 1. The library scanned, the Books tab at the usual size to compare with,
# then into the folder on the Folders tab: its first comic is selected and
# its details take the right of the window.
start --add-root "$top/$out/Comics"
for _ in $(seq 1 120); do [[ "$(q 'select count(*) from books' 2>/dev/null)" == 40 ]] && break; sleep 0.5; done
check "the library has the comics" "$(q 'select count(*) from books')" 40
sleep 4 # Covers.
click 43 170 # Books
look books_usual
books_usual=$cols
if ((books_usual >= 4)); then ok "the Books tab at the usual size: $cols covers a row, $width px"; else fail "Books tab: $cols covers a row"; fi
click 43 380 # Folders
click 190 200 # The library folder.
pane=895
look folder_usual
usual=$cols usual_width=$width
if ((usual >= 3)); then ok "the folder at the usual size: $cols covers a row, $width px"; else fail "folder: $cols covers a row"; fi
check "nothing is kept before a zoom" "$(size)" ""

# 2. + and -, a column a press.
step plus "+" plus
check "+ takes a column off" "$cols" $((usual - 1))
if agrees "$(size)" "$width"; then ok "the kept size is the covers' width ($(size) kept, $width px on screen)"; else fail "kept $(size), $width px on screen"; fi
step minus "-" minus
check "- adds it again" "$cols" "$usual"

# 3. The biggest: + until nothing changes, then once more.
for _ in $(seq 1 10); do key plus; done
sleep 1.5
look biggest
biggest=$cols
if ((cols < usual - 1 && width <= 480 && width > usual_width * 3 / 2)); then
  ok "the biggest covers: $cols a row, $width px (480 at most)"
else
  fail "biggest: $cols a row, $width px"
fi
still plus "+ at the biggest" biggest_again
check "+ at the biggest changes nothing" "$cols" "$biggest"

# 4. The smallest: - until nothing changes, then once more.
for _ in $(seq 1 25); do key minus; done
sleep 1.5
look smallest
smallest=$cols
if ((cols > usual + 2 && width >= 72 && width < 90)); then
  ok "the smallest covers: $cols a row, $width px (72 at least)"
else
  fail "smallest: $cols a row, $width px"
fi
still minus "- at the smallest" smallest_again
check "- at the smallest changes nothing" "$cols" "$smallest"

# 5. = is the usual size, and no setting.
step equal "=" usual_again
check "= puts the usual size back" "$cols" "$usual"
check "and forgets the kept size" "$(size)" ""

# 6. Ctrl and the wheel; the wheel alone only scrolls.
xdotool mousemove 500 400
xdotool keydown ctrl; sleep 0.3; xdotool click 4; sleep 0.5; xdotool keyup ctrl
wait_size_change "" || fail "Ctrl and the wheel: nothing kept"
sleep 0.8
look ctrl_wheel
check "Ctrl and the wheel up takes a column off" "$cols" $((usual - 1))
kept=$(size)
top_before=$rowtop
xdotool click 5; sleep 0.3; xdotool click 5
sleep 1.5
check "the wheel alone does not zoom" "$(size)" "$kept"
look wheel_alone
check "the covers a row after the wheel alone" "$cols" $((usual - 1))
if ((rowtop != top_before)); then ok "it scrolls the covers (first row from $top_before to $rowtop)"; else fail "the wheel alone did not scroll"; fi
xdotool click 4; sleep 0.3; xdotool click 4; sleep 0.3; xdotool click 4; sleep 1

# 7. + in the search box is typed, not a zoom.
key slash
key plus
sleep 1.5
check "+ typed in the search box keeps the size" "$(size)" "$kept"
look search
check "and searches for it: no cover matches" "$cols" 0
key Escape
key Escape
sleep 1
# The search took the selection, and with it the details beside the covers.
pane=1280
look search_cleared
if ((cols >= usual - 1)); then ok "Esc twice brings the covers back ($cols a row)"; else fail "after the search: $cols a row"; fi

# 8. The Books tab has the size too: fewer covers a row than at first.
click 43 170
look books_zoomed
# With more room than the folder had beside the details, its covers are
# at least the kept width.
if ((cols < books_usual)) && awk -v s="$kept" -v w="$width" 'BEGIN { exit !(w >= s - 4) }'; then
  ok "the Books tab took the size: $cols a row (was $books_usual), $width px for $kept kept"
else
  fail "Books tab: $cols a row (was $books_usual), $width px, kept $kept"
fi

# 9. Two fingers. Spread: bigger; pinched together: smaller. Nothing opens.
click 43 380 # Folders, still in the folder; nothing selected.
look before_pinch
before=$cols
kept=$(size)
pinch 500 400 60 220
wait_size_change "$kept" || fail "spreading two fingers: the kept size stayed $kept"
sleep 0.8
look spread
if ((cols < before)); then ok "two fingers spread: $before to $cols covers a row"; else fail "spread: $before to $cols a row"; fi
if agrees "$(size)" "$width"; then ok "and the size is kept ($(size))"; else fail "spread: kept $(size), $width px on screen"; fi
spread=$cols
kept=$(size)
pinch 500 400 300 60
wait_size_change "$kept" || fail "pinching two fingers: the kept size stayed $kept"
sleep 0.8
look pinched
if ((cols > spread)); then ok "two fingers pinched: $spread to $cols covers a row"; else fail "pinch: $spread to $cols a row"; fi
check "a pinch opened no comic" "$(q 'select count(*) from progress')" 0
# One finger scrolls and does not zoom; a tap selects a cover (its details
# show on the right), and a second tap opens it.
kept=$(size)
top_before=$rowtop
swipe 500 600 500 330
look one_finger
check "one finger does not zoom" "$(size)" "$kept"
if ((rowtop != top_before)); then ok "it scrolls the covers (first row from $top_before to $rowtop)"; else fail "one finger did not scroll"; fi
swipe 500 330 500 650
look scrolled_back
# The first cover of the first row, 40 px into it.
tx=$((92 + 40)) ty=$((rowtop + 40))
before_tap=$(printf '%02d_scrolled_back' "$n")
tap "$tx" "$ty"
pane=895
look tapped
differ=$(python3 - "$out/$before_tap.png" "$out/$(printf '%02d_tapped' "$n").png" <<'EOF'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert('RGB') for f in sys.argv[1:3])
print(sum(1 for p in ImageChops.difference(a, b).getdata() if max(p) > 24))
EOF
)
if ((${differ:-0} > 20000)); then ok "a tap selects a cover: its details show ($differ pixels differ)"; else fail "tap: only ${differ:-0} pixels differ"; fi
check "the tap alone opens nothing" "$(q 'select count(*) from progress')" 0
# A finger resting on that selected cover, not moving and lifted within the
# half second of a long press, while a second one spreads away from it: on
# its own that finger would be the second tap, which opens the comic.
kept=$(size)
before=$cols
touch down 0 "$tx" "$ty"; touch down 1 $((tx + 90)) "$ty"
for i in 1 2 3 4 5 6; do touch move 1 $((tx + 90 + i * 40)) "$ty"; done
touch up 0 "$tx" "$ty"; touch up 1 $((tx + 330)) "$ty"
wait_size_change "$kept" || fail "a pinch with one finger resting: the kept size stayed $kept"
sleep 1.5
look resting_finger
if ((cols < before)); then ok "one finger resting, one spreading: $before to $cols covers a row"; else fail "resting pinch: $before to $cols a row"; fi
check "the resting finger opened no comic" "$(q 'select count(*) from progress')" 0
tap "$tx" "$ty"
for _ in $(seq 1 20); do [[ "$(q 'select count(*) from progress')" == 1 ]] && break; sleep 0.3; done
check "a second tap opens the comic" "$(q 'select count(*) from progress')" 1
key Escape
sleep 1.5

# 10. Settings' Cover size buttons, for a phone without a pinch: the same
# steps, on the covers behind the dialog. From the usual size on the Books
# tab (no details beside the covers).
click 43 170
pane=1280
step equal "= before Settings" before_settings
check "the Books tab at the usual size again" "$cols" "$books_usual"
settings
shot settings_cover_size
click "$bigger_x" "$size_y"
wait_size_change "" || fail "Settings, bigger: nothing kept"
kept=$(size)
click "$smaller_x" "$size_y"
wait_size_change "$kept" || fail "Settings, smaller: the kept size stayed $kept"
check "Settings: bigger then smaller is the usual columns, kept as a size" "$(size | grep -c .)" 1
kept=$(size)
click "$smaller_x" "$size_y"
wait_size_change "$kept" || fail "Settings, smaller again: the kept size stayed $kept"
key Escape
sleep 1
look settings_smaller
check "Settings' smaller button twice, bigger once: a column more" "$cols" $((books_usual + 1))
if agrees "$(size)" "$width"; then ok "and the size is kept ($(size))"; else fail "Settings: kept $(size), $width px on screen"; fi
kept=$(size)
settings
click "$usual_x" "$size_y"
wait_size_change "$kept" || fail "Settings, Usual size: still kept"
check "Settings' Usual size forgets the kept size" "$(size)" ""
click "$bigger_x" "$size_y"
wait_size_change "" || fail "Settings, bigger again: nothing kept"
key Escape
sleep 1
look settings_bigger
check "Settings' bigger button takes a column off" "$cols" $((books_usual - 1))

# 11. A restart keeps the size.
look before_restart
want=$cols
kept=$(size)
stop
start
click 43 170
look after_restart
check "the kept size after a restart" "$(size)" "$kept"
check "and the covers a row" "$cols" "$want"
stop

# 12. A size that is no size, as a settings file edited by hand could have
# left it: the covers show, at the usual size, and + works from there.
for bad in NaN -12 Infinity; do
  q "insert or replace into settings (key, value) values ('library.coverSize', '\"$bad\"')"
  start
  click 43 170
  look "bad_size_$bad"
  check "a kept size of $bad: the covers a row are the usual" "$cols" "$books_usual"
  step plus "+ after a kept size of $bad" "bad_size_${bad}_plus"
  check "+ after a kept size of $bad takes a column off" "$cols" $((books_usual - 1))
  stop
done

echo
if ((failed)); then echo "FAILED; screenshots in $out/"; exit 1; fi
echo "All cover size checks passed; screenshots in $out/"
