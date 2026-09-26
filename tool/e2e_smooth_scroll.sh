#!/usr/bin/env bash
# End-to-end check that the arrow keys glide a zoomed page instead of
# jumping it. Records the screen at 60 frames a second while keys are
# pressed and held, measures how far the page moved in every frame (phase
# correlation against the frame before the key), and fails when a press
# jumps, a held key stutters, Left or Right turn the page before its edge,
# or a fresh press at the edge doesn't.
#
#   tool/e2e_smooth_scroll.sh
#
# Makes its own book: two pages of textured blocks, the first tinted blue,
# the second green, so the page on screen is told by its colour.
#
# Needs: Xvfb, xdotool, ffmpeg, Python with Pillow and numpy.
# Output: build/e2e-smooth/*.png, the recorded frames and offsets.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-smooth
rm -rf "$out" && mkdir -p "$out/home" "$out/books"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release

python3 - "$out/books" <<'EOF2'
import io, random, sys, zipfile
from PIL import Image, ImageDraw
def page(tint, seed):
    rnd = random.Random(seed)
    im = Image.new('RGB', (1200, 1800), 'white')
    d = ImageDraw.Draw(im)
    for y in range(0, 1800, 24):
        for x in range(0, 1200, 24):
            v = rnd.randrange(40, 230)
            d.rectangle([x, y, x + 23, y + 23], fill=tuple(int(v * t) for t in tint))
    b = io.BytesIO()
    im.save(b, 'JPEG', quality=92)
    return b.getvalue()
with zipfile.ZipFile(f'{sys.argv[1]}/Glide.cbz', 'w') as z:
    z.writestr('01.jpg', page((0.5, 0.6, 1.0), 1))
    z.writestr('02.jpg', page((0.5, 1.0, 0.5), 2))
EOF2
book="$PWD/$out/books/Glide.cbz"

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1
xset r on 2>/dev/null || true
# The glide is about looks, not panels: classic CV keeps detection cheap.
export COMICREDR_MODEL="${COMICREDR_MODEL:-none}"

HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$book" >"$out/app.log" 2>&1 &
app=$!
sleep 6
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowmove "$win" 0 0 windowsize --sync "$win" 1280 800 windowactivate --sync "$win" 2>/dev/null || true
xdotool mousemove 640 400 click 1 2>/dev/null || true
xdotool mousemove 5 700 2>/dev/null || true
sleep 2

failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }

# Records the page area at 60 fps for $2 seconds into $out/$1/ while the
# command after it runs, then prints each frame's offset from the first.
record() {
  local name="$1" secs="$2"
  shift 2
  mkdir -p "$out/$name"
  ffmpeg -loglevel error -f x11grab -framerate 60 -video_size 1280x720 -i "$DISPLAY+0,0" -t "$secs" \
    "$out/$name/%03d.png" &
  local rec=$!
  sleep 0.4
  "$@"
  wait "$rec"
  python3 - "$out/$name" <<'EOF2' >"$out/$name.txt"
import glob, sys
import numpy as np
from PIL import Image
# Frame to frame: where the middle of the last frame went, searched along
# each axis in turn, summed up. The pointer sits in the black margin.
files = sorted(glob.glob(sys.argv[1] + '/*.png'))
def gray(f):
    return np.asarray(Image.open(f).convert('L'), dtype=np.float32)
def shift(a, b):
    best = (1e9, 0, 0)
    for dy in range(-120, 121):
        d = np.abs(a[260:460, 480:800] - b[260 - dy:460 - dy, 480:800]).mean()
        best = min(best, (d, 0, dy))
    dy = best[2]
    best = (1e9, 0, 0)
    for dx in range(-120, 121):
        d = np.abs(a[260:460, 480:800] - b[260 - dy:460 - dy, 480 - dx:800 - dx]).mean()
        best = min(best, (d, dx, dy))
    return best[1], best[2]
x = y = 0
prev = gray(files[0])
for f in files:
    g = gray(f)
    dx, dy = shift(prev, g)
    x, y, prev = x + dx, y + dy, g
    im = np.asarray(Image.open(f).convert('RGB'), dtype=np.float32)[200:500, 400:900]
    tint = 'dark' if im.mean() < 20 else 'green' if im[..., 1].mean() > im[..., 2].mean() else 'blue'
    print(x, y, tint)
EOF2
}

# Offsets along one axis ($2: 1 x, 2 y) of a recording: distinct values.
moves() { awk -v f="$2" '{print ($f < 0 ? -$f : $f)}' "$out/$1.txt"; }
check_glide() {
  local name="$1" axis="$2" lo="$3" hi="$4"
  python3 - "$out/$name.txt" "$axis" "$lo" "$hi" <<'EOF2'
import sys
rows = [l.split() for l in open(sys.argv[1])]
a = int(sys.argv[2]) - 1
v = [abs(int(r[a])) for r in rows]
lo, hi = float(sys.argv[3]), float(sys.argv[4])
end = v[-1]
between = sorted({x for x in v if 0.05 * end < x < 0.95 * end})
steps = [b - a for a, b in zip(v, v[1:])]
back = min(steps)
print(f'  moved {end} px; {len(between)} frames on the way ({between}); biggest frame step {max(steps)} px')
ok = lo <= end <= hi and len(between) >= 3 and back >= -2
sys.exit(0 if ok else 1)
EOF2
}

echo "== zoomed in, one press of Down glides a step"
key plus plus plus
record down 1.2 xdotool key Down
if check_glide down 2 80 140; then ok "Down glides a step"; else fail "Down jumped or went the wrong distance"; fi

echo "== zoomed in all the way, Down held glides on"
key plus plus plus plus plus plus plus
record down_held 2.0 bash -c 'xdotool keydown Down; sleep 1.2; xdotool keyup Down'
python3 - "$out/down_held.txt" <<'EOF3' && ok "held Down scrolls on smoothly" || fail "held Down stuttered or did not move"
import sys
v = [abs(int(l.split()[1])) for l in open(sys.argv[1])]
seen = sorted(set(v))
steps = [b - a for a, b in zip(v, v[1:])]
print(f'  moved {v[-1]} px through {len(seen)} positions; frame steps {min(steps)}..{max(steps)} px')
# Xvfb draws in software at about a dozen frames a second, so this counts
# the positions shown rather than timing them: many, never backwards.
sys.exit(0 if v[-1] > 400 and len(seen) >= 10 and min(steps) >= -2 else 1)
EOF3

echo "== Right pans the zoomed page; held, it stops at the edge"
record right 1.2 xdotool key Right
if check_glide right 1 150 200; then ok "Right glides a step sideways"; else fail "Right jumped or did not pan"; fi
[[ "$(tail -1 "$out/right.txt" | awk '{print $3}')" == blue ]] && ok "still page 1" || fail "Right turned the page"
record right_held 6.0 bash -c 'xdotool keydown Right; sleep 5; xdotool keyup Right'
[[ "$(awk '{print $3}' "$out/right_held.txt" | sort -u)" == blue ]] && ok "held Right stayed on page 1, never in the dark margin" \
  || fail "held Right ran on into page 2 or off the page"
[[ "$(tail -60 "$out/right_held.txt" | awk '{print $1}' | sort -u | wc -l)" == 1 ]] && ok "held Right stopped at the page's edge" \
  || fail "held Right was still moving at the end"
sleep 1
key Right; sleep 1
record page2 0.3 true
[[ "$(tail -1 "$out/page2.txt" | awk '{print $3}')" == green ]] && ok "Right pressed again at the edge: page 2" \
  || fail "Right at the edge did not turn the page"

echo "== not zoomed, Left and Right step as before"
key equal; sleep 1
key Left; sleep 1
record page1 0.3 true
[[ "$(tail -1 "$out/page1.txt" | awk '{print $3}')" == blue ]] && ok "Left unzoomed: back on page 1" \
  || fail "Left unzoomed did not go back"

echo "== zoomed in a little, a page narrower than the window turns on Right"
key plus plus plus; sleep 1
key Right; sleep 1
record narrow 0.3 true
[[ "$(tail -1 "$out/narrow.txt" | awk '{print $3}')" == green ]] && ok "Right on a page that fits sideways: page 2" \
  || fail "Right on a page that fits sideways did not turn"

if grep -iE "exception|error" "$out/app.log" | grep -vE "libEGL|Atk-CRITICAL|GLib-GIO|dbus|Gdk-WARNING" >/dev/null; then
  fail "the app logged errors (see $out/app.log)"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
