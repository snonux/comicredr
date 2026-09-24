#!/usr/bin/env bash
# Measures how much memory the app holds while reading, in a window with a
# phone screen's pixels (1080 x 2340; decode sizes follow device pixels, so
# the scale factor does not change them): page turns, zoom, then guided
# view panel by panel. The process's
# proportional set size (PSS, what Android's memory accounting uses too) is
# sampled every 0.2 s; Xvfb renders in software, so decoded pages count in
# the process, as they do in a phone's unified memory.
#
#   tool/e2e_memory.sh book.cbz [bundle] [label]
#
# bundle defaults to build/linux/x64/release/bundle. Output:
# build/e2e-memory/<label>/{samples.csv,summary.txt,shot_*.png}.
#
# Needs: Xvfb, xdotool, ImageMagick (import).
set -euo pipefail
cd "$(dirname "$0")/.."

book=$(realpath "$1")
bundle=$(realpath "${2:-build/linux/x64/release/bundle}")
label=${3:-run}
out=build/e2e-memory/$label
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics"
cp "$book" "$out/Comics/"
book="$PWD/$out/Comics/$(basename "$book")"

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1200x2400x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
HOME="$PWD/$out/home" "$bundle/comicredr" "$book" >"$out/app.log" 2>&1 &
app=$!
trap 'kill $app $xvfb $sampler 2>/dev/null || true' EXIT
sleep 4
win=$(xdotool search --name "^ComicRedr$" | tail -1)
xdotool windowsize "$win" 1080 2340 windowmove "$win" 0 0 windowactivate --sync "$win" mousemove 540 1000 click 1 2>/dev/null || true
sleep 3

phase=open
echo open >"$out/phase"
pss() { awk '/^Pss:/ {print int($2 / 1024)}' "/proc/$app/smaps_rollup"; }
(
  echo "t,phase,pss_mb" >"$out/samples.csv"
  start=$(date +%s.%N)
  while kill -0 "$app" 2>/dev/null; do
    echo "$(echo "$(date +%s.%N) - $start" | bc),$(cat "$out/phase"),$(pss)" >>"$out/samples.csv"
    sleep 0.2
  done
) &
sampler=$!

step() { echo "$1" >"$out/phase"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1.2; }
shot() { import -window root -crop 1080x2340+0+0 "$out/shot_$1.png"; }

step pages
for _ in $(seq 1 12); do key Right; done
shot 1_page
step zoom
key plus plus plus plus
shot 2_zoomed
key j j j
shot 3_zoomed_panned
key equal
step guided
key 3 shift+g
key v
sleep 2
for _ in $(seq 1 16); do key l; done
shot 4_guided_panel
step idle
sleep 3

kill "$sampler" 2>/dev/null || true
{
  echo "label: $label"
  echo "book: $(basename "$book")"
  awk -F, 'NR > 1 { if ($3 > peak[$2]) peak[$2] = $3; sum[$2] += $3; n[$2]++; if ($3 > all) all = $3 }
    END {
      split("open pages zoom guided idle", order, " ")
      for (i = 1; i <= 5; i++) { p = order[i]; if (n[p]) printf "%-7s peak %4d MB, mean %4d MB\n", p, peak[p], sum[p] / n[p] }
      printf "overall peak %d MB\n", all
    }' "$out/samples.csv"
} | tee "$out/summary.txt"
grep -iE "error|exception" "$out/app.log" | head -5 || true
