#!/usr/bin/env bash
# End-to-end check of panels drawn by a large model (tool/llm_panels.py) on
# the Linux release build under Xvfb, driven by real keys. The book is made
# here: two pages of four bordered panels in a 2x2 grid, red, green, blue
# and yellow in reading order, which classic CV finds exactly. The
# panels.json given to the tool lists page 1's panels backwards (yellow,
# blue, green, red), yellow grown into green as for a balloon that sticks
# out, and page 2 as having none, so which panel guided view frames first
# tells whose panels it uses, and that overlapping imported panels guide.
#
#   tool/e2e/e2e_llm_panels.sh
#
# Checks: `library` lists the comic with no page done; `pages` and `check`
# make their files; the app finds red first on its own; after `import` into
# the sidecar the app wrote, guided view goes yellow, blue, green, red and
# shows page 2 whole; the index holds the rows as source 'manual' and the
# record of the run (harness, model), the details (I) show it, and the
# sidecar keeps both after the app writes it again; `library` then says
# done and `pages` has nothing left to do; a restart still uses them;
# X → Redo panels drops the panels and the record, back to red first.
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, Python with Pillow and a C
# compiler with X11 headers (tool/e2e/close_window.c).
# Output: build/e2e-llm-panels/*.png and build/e2e-llm-panels/contact.png.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/e2e-llm-panels
rm -rf "$out" && mkdir -p "$out/home" "$out/books"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/e2e/close_window.c -lX11

python3 - "$out/books" <<'EOF2'
import io, json, sys, zipfile
from PIL import Image, ImageDraw
colours = [(220, 40, 40), (40, 170, 60), (40, 80, 220), (230, 200, 30)]
corners = [(30, 30), (310, 30), (30, 460), (310, 460)]
def page():
    im = Image.new('RGB', (600, 900), 'white')
    d = ImageDraw.Draw(im)
    for k, (x, y) in enumerate(corners):
        d.rectangle([x, y, x + 259, y + 409], fill=colours[k], outline='black', width=6)
        for yy in range(y + 40, y + 380, 60):  # Something inside for classic CV to see as art.
            d.line([x + 30, yy, x + 230, yy + 20], fill='black', width=3)
    b = io.BytesIO()
    im.save(b, 'PNG')
    return b.getvalue()
with zipfile.ZipFile(f'{sys.argv[1]}/Imported.cbz', 'w') as z:
    for i in range(2):
        z.writestr(f'{i + 1:02d}.png', page())
# What an agent would write: percent of the page, panels in its own order.
pct = lambda x, y: [round(x / 6, 2), round(y / 9, 2), round((x + 259) / 6, 2), round((y + 409) / 9, 2)]
panels = [pct(*corners[k]) for k in (3, 2, 1, 0)]
# Yellow grown up into green's bottom (69 px of its 409), as for a balloon hanging over the border: the
# detector's gate would refuse an overlap that big and show the page whole; imported panels may overlap.
panels[0][1] = round(370 / 9, 2)
json.dump({"pages": {"1": {"panels": panels, "balloons": [[10, 8, 30, 14]], "captions": [[55, 5, 80, 9]]},
                     "2": {"panels": []}}}, open(f'{sys.argv[1]}/panels.json', 'w'))
EOF2
book="$PWD/$out/books/Imported.cbz"
side="$out/books/.Imported.cbz.crdb"
db="$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1600x1200x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

# Classic CV finds the made pages' borders exactly, so the app's own order
# is known: red, green, blue, yellow.
export COMICREDR_MODEL="${COMICREDR_MODEL:-none}"
failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$1" "$2"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1.2; }
start() {
  # As in e2e_reset.sh: X11, no session bus and no XDG folders of the caller.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus GDK_BACKEND=x11 \
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
# The status line of shot $1 as tesseract reads it, on one line: the bottom
# 60 px of the window, blown up three times so its small letters read.
# The status line's own colour, read in its left padding: the tertiary
# colour on a page with drawn panels, the usual surface on others.
line_colour() { convert "$out/$1.png" -crop 1x1+4+795 +repage -format '%[pixel:p{0,0}]' info:; }

status_of() {
  convert "$out/$1.png" -crop 1280x60+0+740 +repage -resize 300% "$out/$1_status.png"
  tesseract "$out/$1_status.png" - 2>/dev/null | tr -s ' \n' ' '
}

# Each colour's centre and size on screen (the top 740 px, above the status
# line), as "name cx cy w h" lines.
boxes() {
  python3 - "$out/$1.png" <<'EOF2'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB').crop((0, 0, 1280, 740))
w, h = im.size
px = im.load()
cols = {'red': (220, 40, 40), 'green': (40, 170, 60), 'blue': (40, 80, 220), 'yellow': (230, 200, 30)}
found = {k: [w, h, -1, -1] for k in cols}
for y in range(0, h, 2):
    for x in range(0, w, 2):
        p = px[x, y]
        for k, c in cols.items():
            if abs(p[0] - c[0]) + abs(p[1] - c[1]) + abs(p[2] - c[2]) < 60:
                b = found[k]
                b[0] = min(b[0], x); b[1] = min(b[1], y); b[2] = max(b[2], x); b[3] = max(b[3], y)
for k, (x0, y0, x1, y1) in found.items():
    print(k, (x0 + x1) // 2, (y0 + y1) // 2, max(0, x1 - x0), max(0, y1 - y0))
EOF2
}
size() { boxes "$2" | awk -v c="$1" '$1 == c {print $4 > $5 ? $4 : $5}'; }
# The colour framed in shot $1: the one far bigger than a quarter of a page
# shown whole (a grown panel framed shows some 560 px tall), or "whole" when
# all four show at about the same size (some 350 px).
framed_in() {
  boxes "$1" | awk '{s[$1] = ($4 > $5 ? $4 : $5); n++}
    END {best = ""; for (k in s) if (s[k] > 480 && (best == "" || s[k] > s[best])) best = k
         if (best == "" && s["red"] > 100 && s["yellow"] > 100) best = "whole"; print best}'
}
# Steps with l until a panel is framed, at most 3 steps (whole-page steps
# come first), into shot $1; prints the colour.
first_framed() {
  local n f
  for n in 0 1 2 3; do
    [[ $n -gt 0 ]] && key l
    shot "$1"
    cp "$out/$1.png" "$out/$1_step$n.png"
    f=$(framed_in "$1")
    [[ $f != whole && -n $f ]] && { echo "$f"; return 0; }
  done
  echo "$f"
}
expect() { [[ $2 == "$3" ]] && ok "$1 ($2)" || fail "$1: got '$2', want '$3'"; }

echo "== the tool's library, pages and check"
work="$out/work"
listed=$(python3 tool/llm_panels.py library "$out/books" --index /nonexistent)
grep -q '0/2  .*Imported.cbz' <<<"$listed" && ok "library lists the comic, no page done" \
  || fail "library: $listed"
python3 tool/llm_panels.py pages "$book" "$work" --batch 1 >/dev/null
[[ -f $work/page-001.jpg && ! -f $work/page-002.jpg ]] && grep -q 'pages to do are 1\.' "$work/PROMPT.md" \
  && ok "pages --batch 1 wrote page 1 alone" || fail "pages --batch 1 did not write page 1 alone"
python3 tool/llm_panels.py pages "$book" "$work" >/dev/null
[[ -f $work/page-001.jpg && -f $work/page-002.jpg && -f $work/PROMPT.md ]] \
  && ok "pages wrote page-001.jpg, page-002.jpg and PROMPT.md" || fail "pages did not write its files"
grep -q "llm_panels.py check" "$work/PROMPT.md" && ok "the prompt names the check command" \
  || fail "the prompt does not name the check command"
cp "$out/books/panels.json" "$work/"
python3 tool/llm_panels.py check "$book" "$work" >/dev/null
[[ -f $work/check/page-001.jpg ]] && ok "check drew page-001.jpg" || fail "check drew nothing"

echo "== the app's own panels"
start "$book"
key v
sleep 2
expect "guided view, own panels: red first" "$(first_framed 01_own_first)" red
for _ in $(seq 1 30); do [[ -f $side ]] && break; sleep 1; done
[[ -f $side ]] && ok "the app wrote the sidecar" || fail "no sidecar beside the book"
stop

echo "== imported into the sidecar the app wrote"
# Exercise upgrading a sidecar written before model attribution.
sqlite3 "$side" <<'SQL'
ALTER TABLE analysed_pages DROP COLUMN model_name;
ALTER TABLE analysed_pages DROP COLUMN model_effort;
ALTER TABLE panels DROP COLUMN model_name;
ALTER TABLE panels DROP COLUMN model_effort;
UPDATE meta SET schema_version = 3;
SQL
python3 tool/llm_panels.py import "$book" "$out/books/panels.json" \
  --harness "Claude Code" --model claude-opus-5-5 --effort medium
listed=$(python3 tool/llm_panels.py library "$out/books" --todo --index /nonexistent)
grep -q 'Imported.cbz' <<<"$listed" && fail "library --todo still lists the comic: $listed" \
  || ok "library --todo leaves the comic out"
python3 tool/llm_panels.py pages "$book" "$work" | grep -q 'done already' && ok "pages has nothing left to do" \
  || fail "pages would draw done pages again"
n=$(q "$side" "select count(*) from panels where source = 'manual' and kind = 'frame'")
expect "the sidecar holds the 4 imported panels" "$n" 4
expect "the sidecar was upgraded" "$(q "$side" 'select schema_version from meta')" 4
start "$book"
sleep 2
expect "guided view: yellow first, as imported" "$(first_framed 02_imported_first)" yellow
key l; shot 03_blue
expect "l: blue" "$(framed_in 03_blue)" blue
st=$(status_of 03_blue)
[[ $st == *'guided (drawn)'* ]] && ok "the status line says the panels are drawn ($st)" \
  || fail "the status line does not say drawn: '$st'"
own=$(line_colour 01_own_first); drawn=$(line_colour 03_blue)
[[ $own != "$drawn" ]] && ok "the status line takes another colour on the drawn page ($own, then $drawn)" \
  || fail "the status line keeps its colour on the drawn page ($drawn)"
key l; shot 04_green
expect "l: green" "$(framed_in 04_green)" green
key l; shot 05_red
expect "l: red" "$(framed_in 05_red)" red
# Then page 1 whole again, page 2 whole on arrival, and page 2 has no stops.
seen=
for i in 1 2 3 4; do
  key l
  shot "06_onward_$i"
  [[ $(q "$db" "select page from progress") == 1 ]] && { seen=$(framed_in "06_onward_$i"); break; }
done
expect "page 2 (no panels imported) is shown whole" "$seen" whole
rows=$(q "$db" "select count(*) from analysed_pages where source = 'manual'")
expect "the index holds both pages as source manual" "$rows" 2
for table in analysed_pages panels; do
  n=$(q "$db" "select count(*) from $table where source='manual'
    and model_name='claude-opus-5-5' and model_effort='medium'")
  want=6
  [[ $table == analysed_pages ]] && want=2
  expect "the index keeps model and effort on $table" "$n" "$want"
done
caps=$(q "$db" "select count(*) from panels where source = 'manual' and kind = 'caption'")
expect "and the caption" "$caps" 1
rec=$(q "$db" "select value from overrides where field = 'panelImport'")
[[ $rec == *'Claude Code'*'claude-opus-5-5'* ]] && ok "the index holds the record of the run" \
  || fail "no record in the index: $rec"
key I; sleep 3
shot 06_details
key End; sleep 1
shot 06_details_end
key Escape; sleep 1
sleep 4 # The sidecar is written two seconds after the last change.
stop
n=$(q "$side" "select count(*) from panels where source = 'manual'")
expect "the sidecar still holds the 6 imported rows after the app wrote it" "$n" 6
for table in analysed_pages panels; do
  n=$(q "$side" "select count(*) from $table where source='manual'
    and model_name='claude-opus-5-5' and model_effort='medium'")
  want=6
  [[ $table == analysed_pages ]] && want=2
  expect "the sidecar keeps model and effort on $table" "$n" "$want"
done
rec=$(q "$side" "select count(*) from overrides where field = 'panelImport'")
expect "and the record" "$rec" 1

echo "== a restart"
start "$book"
key g g
sleep 1
expect "after a restart: yellow first still" "$(first_framed 07_restart_first)" yellow
n=$(q "$db" "select count(*) from analysed_pages where source='manual'
  and model_name='claude-opus-5-5' and model_effort='medium'")
expect "a restart keeps attribution on both pages" "$n" 2

echo "== X, Redo panels"
key shift+x; sleep 3
key Return; sleep 6
rows=$(q "$db" "select count(*) from analysed_pages where source = 'manual'")
expect "Redo panels dropped the imported rows from the index" "$rows" 0
rec=$(q "$db" "select count(*) from overrides where field = 'panelImport'")
expect "and the record" "$rec" 0
key g g
sleep 1
expect "and guided view is back on the app's own: red first" "$(first_framed 08_redo_first)" red
st=$(status_of 08_redo_first)
[[ $st == *guided* && $st != *drawn* ]] && ok "the status line no longer says drawn ($st)" \
  || fail "after Redo panels the status line reads: '$st'"
expect "and its colour is the usual one again" "$(line_colour 08_redo_first)" "$own"
sleep 4
stop
n=$(q "$side" "select count(*) from panels where source = 'manual'")
expect "and from the sidecar" "$n" 0
rec=$(q "$side" "select count(*) from overrides where field = 'panelImport'")
expect "the record too" "$rec" 0

montage -label '%t' "$out"/0*.png -tile 4x -geometry 400x250+6+6 -background '#222' -fill white \
  "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out/app.log" | grep -viE 'libEGL|MESA-EGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
