#!/usr/bin/env bash
# Measures how quick the Linux release build is, under Openbox in Xvfb,
# from the timings it prints with COMICREDR_TIMING=1 (lib/src/timing.dart):
#
#   1. a first start over a library of 120 made-up comics and the fetched
#      corpus: time to the first frame and to the end of the first scan;
#   2. a second start: first frame and the rescan that only compares;
#   3. the Folders tab scrolled through with the keys: frame times;
#   4. a CBZ and a PDF opened from the command line: each step of opening,
#      the first page decoded and shown, the first pages detected, then ten
#      page turns and twelve guided-view steps with their frame times.
#
#   tool/e2e_perf.sh [label]
#
# Run it before and after a change with two labels and compare
# build/e2e-perf/<label>/summary.txt. Needs test/corpus and
# test/corpus-modern (spike/fetch_corpus.py), Xvfb, openbox, xdotool and
# Python with Pillow. Xvfb draws in software, so raster times are the CPU's,
# not a GPU's; build (UI thread) times and the timings are what to compare.
set -euo pipefail
cd "$(dirname "$0")/.."

label=${1:-run}
out=build/e2e-perf/$label
bundle=build/linux/x64/release/bundle
rm -rf "$out" && mkdir -p "$out/home/Comics/made"
[[ -x $bundle/comicredr ]] || flutter build linux --release
cbz=test/corpus/silver-age/reptisaurus-v2-005.cbz
pdf=test/corpus-modern/modern-digital/first-woman-001.pdf
[[ -f $cbz && -f $pdf ]] || { echo "Fetch the corpus first (spike/fetch_corpus.py)"; exit 1; }

comics="$PWD/$out/home/Comics"
cp -r test/corpus "$comics/corpus"
cp -r test/corpus-modern "$comics/modern"
# 120 comics of four 1600x2400 JPEG pages, each cover its own, so the
# covers grid has real work.
python3 - "$comics/made" <<'EOF'
import io, random, sys, zipfile
from PIL import Image, ImageDraw
random.seed(7)
for n in range(120):
    with zipfile.ZipFile(f'{sys.argv[1]}/Made {n + 1:03d}.cbz', 'w') as z:
        for p in range(4):
            im = Image.new('RGB', (1600, 2400), (240, 236, 220))
            d = ImageDraw.Draw(im)
            for _ in range(60):
                x, y = random.randrange(1600), random.randrange(2400)
                c = tuple(random.randrange(256) for _ in range(3))
                d.ellipse((x, y, x + random.randrange(40, 400), y + random.randrange(40, 400)), fill=c)
            b = io.BytesIO()
            im.save(b, 'JPEG', quality=85)
            z.writestr(f'{p + 1:02d}.jpg', b.getvalue())
EOF

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
wm=
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 50); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.2; done
openbox >/dev/null 2>&1 &
wm=$!
sleep 1

# Starts the app with timings on, logging to $out/$1.log.
start() {
  local log=$1
  shift
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$PWD/$out/home" COMICREDR_TIMING=1 \
    GDK_BACKEND=x11 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent "$bundle/comicredr" "$@" >"$out/$log.log" 2>&1 &
  app=$!
  for _ in $(seq 100); do grep -q 'start: first frame' "$out/$log.log" 2>/dev/null && break; sleep 0.2; done
  win=$(xdotool search --sync --name '^ComicRedr$' | tail -1)
  xdotool windowsize "$win" 1280 800 windowmove "$win" 0 0 windowactivate --sync "$win" 2>/dev/null || true
}
stop() {
  kill "$app" 2>/dev/null || true
  wait "$app" 2>/dev/null || true
}
waitfor() { # pattern log [seconds]
  for _ in $(seq $((${3:-60} * 5))); do grep -q "$1" "$out/$2.log" && return 0; sleep 0.2; done
  echo "Timed out waiting for '$1' in $2.log"
}
key() { xdotool key --delay 0 "$@"; }

start first --add-root "$comics"
waitfor 'timing: scan' first 300
sleep 2
stop

start second
waitfor 'timing: scan' second 60
sleep 3
xdotool mousemove 640 400 click 1
sleep 1
# The covers, a screen at a time and back.
for _ in $(seq 8); do key Page_Down; sleep 0.4; done
for _ in $(seq 8); do key Page_Up; sleep 0.4; done
for _ in $(seq 30); do key Down; sleep 0.1; done
sleep 2.5
stop

for book in "$comics/corpus/${cbz#test/corpus/}" "$comics/modern/${pdf#test/corpus-modern/}"; do
  name=$(basename "$book")
  start "open-$name" "$book"
  waitfor 'page: .* shown' "open-$name" 60
  waitfor 'detect: page 3 ' "open-$name" 120
  sleep 2.5
  for _ in $(seq 10); do key Right; sleep 0.8; done
  sleep 2.5
  key v
  sleep 2
  for _ in $(seq 12); do key l; sleep 0.8; done
  sleep 2.5
  stop
done

{
  echo "label: $label  ($(git rev-parse --short HEAD))"
  for log in "$out"/*.log; do
    echo
    echo "== $(basename "$log" .log)"
    grep -E '^timing: ' "$log" | sed 's/^timing: //'
  done
} >"$out/summary.txt"
cat "$out/summary.txt"
