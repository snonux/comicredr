#!/usr/bin/env bash
# End-to-end check of turning the comic (`>`, `<`, `gr`) on the Linux
# release build under Xvfb, driven by real keys. The book is made here:
# portrait pages with four bordered panels in a 2x2 grid, each its own
# colour (red, green, blue, yellow in reading order), so where the page went
# and which panel guided view frames are pixel counts.
#
#   tool/e2e_rotate.sh
#
# Checks: `>` puts the red panel top right and the page on its side; `<`
# twice turns it counter-clockwise past upright; `2>` is a half turn; guided
# view frames each panel turned and centred, across onto the next page;
# zoom and `j` stay on the turned page; a restart opens the book turned
# (the index and the sidecar hold it); another book opens upright; `gr`
# puts it back.
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, Python with Pillow and a C
# compiler with X11 headers (tool/close_window.c).
# Output: build/e2e-rotate/*.png and build/e2e-rotate/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-rotate
rm -rf "$out" && mkdir -p "$out/home" "$out/books"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11

python3 - "$out/books" <<'EOF2'
import io, sys, zipfile
from PIL import Image, ImageDraw
colours = [(220, 40, 40), (40, 170, 60), (40, 80, 220), (230, 200, 30)]
def page(cols, textured):
    im = Image.new('RGB', (600, 900), 'white')
    d = ImageDraw.Draw(im)
    for k, (x, y) in enumerate([(30, 30), (310, 30), (30, 460), (310, 460)]):
        d.rectangle([x, y, x + 259, y + 409], fill=cols[k], outline='black', width=6)
        if textured:  # Something inside for classic CV to see as art.
            for yy in range(y + 40, y + 380, 60):
                d.line([x + 30, yy, x + 230, yy + 20], fill='black', width=3)
    b = io.BytesIO()
    im.save(b, 'PNG')
    return b.getvalue()
with zipfile.ZipFile(f'{sys.argv[1]}/Rotate.cbz', 'w') as z:
    for i in range(3):
        z.writestr(f'{i + 1:02d}.png', page(colours, True))
with zipfile.ZipFile(f'{sys.argv[1]}/Other.cbz', 'w') as z:
    for i in range(2):
        z.writestr(f'{i + 1:02d}.png', page(colours[::-1], True))
EOF2
book="$PWD/$out/books/Rotate.cbz"
other="$PWD/$out/books/Other.cbz"

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1600x1200x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1

# The made pages are flat colour, which the built-in model does not see as
# panels; classic CV finds their borders exactly. This checks the turn, not
# the detector, so classic CV unless COMICREDR_MODEL says otherwise.
export COMICREDR_MODEL="${COMICREDR_MODEL:-none}"
failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1.2; }
start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowmove "$win" 0 0 windowsize --sync "$win" 1280 800 windowactivate --sync "$win" 2>/dev/null || true
  xdotool mousemove 640 400 click 1 2>/dev/null || true
  sleep 2
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 20); do kill -0 "$app" 2>/dev/null || { app=; return 0; }; sleep 0.25; done
  kill "$app"
  app=
}
shot() { import -window root -crop 1280x800+0+0 +repage "$out/$1.png"; }

# Each colour's box and share of the page area (the top 740 px, above the
# status line), as "name x0 y0 x1 y1 share" lines.
boxes() {
  python3 - "$out/$1.png" <<'EOF2'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB').crop((0, 0, 1280, 740))
w, h = im.size
px = im.load()
cols = {'red': (220, 40, 40), 'green': (40, 170, 60), 'blue': (40, 80, 220), 'yellow': (230, 200, 30)}
found = {k: [w, h, -1, -1, 0] for k in cols}
for y in range(0, h, 2):
    for x in range(0, w, 2):
        p = px[x, y]
        for k, c in cols.items():
            if abs(p[0] - c[0]) + abs(p[1] - c[1]) + abs(p[2] - c[2]) < 60:
                b = found[k]
                b[0] = min(b[0], x); b[1] = min(b[1], y); b[2] = max(b[2], x); b[3] = max(b[3], y); b[4] += 1
for k, (x0, y0, x1, y1, n) in found.items():
    print(k, x0, y0, x1, y1, round(n * 4 / (w * h), 3))
EOF2
}
# Field $2 (1 x0, 2 y0, 3 x1, 4 y1, 5 share) of colour $1 in shot $3.
field() { boxes "$3" | awk -v c="$1" -v f="$2" '$1 == c {print $(f + 1)}'; }
centre() { boxes "$2" | awk -v c="$1" '$1 == c {printf "%d %d %d %d\n", ($2 + $4) / 2, ($3 + $5) / 2, $4 - $2, $5 - $3}'; }
# Asserts a python expression over cx cy w h of colour $1 in shot $2.
check() {
  local c="$1" s="$2" expr="$3" what="$4"
  read -r cx cy bw bh < <(centre "$c" "$s")
  if python3 -c "cx, cy, w, h = $cx, $cy, $bw, $bh; import sys; sys.exit(0 if ($expr) else 1)"; then
    ok "$what ($c at $cx,$cy, ${bw}x$bh)"
  else
    fail "$what ($c at $cx,$cy, ${bw}x$bh)"
  fi
}

echo "== turning the page"
start "$book"
shot 01_upright
check red 01_upright "cx < 640 and cy < 370 and h > w" "upright: red top left, standing"
check blue 01_upright "cx < 640 and cy > 370" "upright: blue bottom left"

key greater
shot 02_clockwise
check red 02_clockwise "cx > 640 and cy < 370 and w > h" "> : red went top right, lying on its side"
check blue 02_clockwise "cx < 640 and cy < 370" "> : blue went top left"
check yellow 02_clockwise "cx < 640 and cy > 370" "> : yellow went bottom left"

key less less
shot 03_counter
check red 03_counter "cx < 640 and cy > 370 and w > h" "< twice: red bottom left, a quarter counter-clockwise"

key greater
shot 04_upright
check red 04_upright "cx < 640 and cy < 370 and h > w" "> : upright again"
key 2 greater
shot 05_half
check red 05_half "cx > 640 and cy > 370 and h > w" "2> : upside down, red bottom right"

key less
shot 05_quarter
check red 05_quarter "cx > 640 and cy < 370 and w > h" "< : a quarter clockwise again"

echo "== guided view, turned"
# Steps with l until colour $1 is framed (bigger than the whole page shows
# it), at most $3 steps, into shot $2. Whole-page steps come in between.
framed() {
  local n
  for n in $(seq 0 "$3"); do
    [[ $n -gt 0 ]] && key l
    shot "$2"
    read -r cx cy bw bh < <(centre "$1" "$2")
    [[ $bw -gt 700 || $bh -gt 600 ]] && return 0
  done
  return 0
}
key v
sleep 1
framed red 06_guided_red 3
check red 06_guided_red "abs(cx - 640) < 40 and abs(cy - 370) < 40 and w > h and (w > 900 or h > 600)" \
  "guided view: the first panel framed, turned and centred"
key l
shot 07_guided_green
check green 07_guided_green "abs(cx - 640) < 40 and abs(cy - 370) < 40 and w > h" "l: the second panel"
key l l
shot 08_guided_yellow
check yellow 08_guided_yellow "abs(cx - 640) < 40 and abs(cy - 370) < 40 and w > h" "l l: the fourth panel"
framed red 09_next 5
check red 09_next "abs(cx - 640) < 40 and abs(cy - 370) < 40 and w > h" "on the next page: its first panel, still turned"
st=$(sqlite3 "$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite" "select page from progress" 2>/dev/null || true)
[[ $st == 1 ]] && ok "guided view stepped onto page 2" || fail "guided view is on page index $st, not 1"
key v
sleep 1
shot 10_page2
check red 10_page2 "cx > 640 and cy < 370 and w > h" "v: out of guided view, page 2 still turned"

echo "== zoom and pan on the turned page"
key plus plus
shot 11_zoomed
key j j
shot 12_panned
# The red panel's lower edge, on screen at this zoom.
before=$(field red 4 11_zoomed)
after=$(field red 4 12_panned)
[[ $after -lt $((before - 100)) ]] && ok "j moved the page up the screen (red's lower edge $before -> $after)" \
  || fail "j did not move the page up the screen (red's lower edge $before -> $after)"
key equal
stop

echo "== a restart keeps the turn"
db="$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
view=$(sqlite3 "$db" "select view_json from progress" 2>/dev/null || true)
[[ $view == *'"rotation":1'* ]] && ok "the index holds the turn: $view" || fail "no turn in the index: $view"
side=$(sqlite3 "$out/books/.Rotate.cbz.crdb" "select view_json from progress" 2>/dev/null || true)
[[ $side == *'"rotation":1'* ]] && ok "the sidecar holds the turn" || fail "no turn in the sidecar: $side"
start "$book"
shot 13_restarted
check red 13_restarted "cx > 640 and cy < 370 and w > h" "reopened after a restart: still turned"
stop

echo "== another book opens upright"
start "$other"
shot 14_other
check yellow 14_other "cx < 640 and cy < 370 and h > w" "Other.cbz: upright, its first panel (yellow) top left"
stop

start "$book"
key g r
shot 15_gr
check red 15_gr "cx < 640 and cy < 370 and h > w" "gr: back upright"
stop

montage -label '%t' "$out"/[01]*.png -tile 4x -geometry 400x250+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
