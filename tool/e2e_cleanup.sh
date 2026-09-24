#!/usr/bin/env bash
# End-to-end check of scan clean-up (`c`) in the Linux release build under a
# virtual X display, on two golden-age scans from the corpus: a low-res one
# (about 1000 px wide, so it is also enlarged and sharpened) and a big one
# (levels only). Screenshots before and after each toggle, zoomed in and in
# guided view, and after a restart, which must keep clean-up on.
#
#   tool/e2e_cleanup.sh [low-res.cbz] [big.cbz]
#
# Defaults: test/corpus/golden-age/all-top-comics-6.cbz and
# weird-comics-004.cbz (python3 spike/fetch_corpus.py fetches them).
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick (import, montage), sqlite3.
# Output: build/e2e-cleanup/shot_*.png, contact.png, and the per-page
# clean-up times from the app's log.
set -euo pipefail
cd "$(dirname "$0")/.."

small=${1:-test/corpus/golden-age/all-top-comics-6.cbz}
big=${2:-test/corpus/golden-age/weird-comics-004.cbz}
out=build/e2e-cleanup
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home"
cp "$small" "$big" "$out/Comics/"
small="$PWD/$out/Comics/$(basename "$small")"
big="$PWD/$out/Comics/$(basename "$big")"
home="$PWD/$out/home"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
launch() {
  HOME="$home" build/linux/x64/release/bundle/comicredr "$1" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
quit() { kill "$app"; wait "$app" 2>/dev/null || true; }
trap 'kill ${app:-} $xvfb 2>/dev/null || true' EXIT
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The low-res scan: page 6, a yellowed page of line art.
launch "$small"
key 6 shift+g;                     shot 01_lowres_as_scanned
key c; sleep 3;                    shot 02_lowres_cleaned
grep -q 'Clean-up: page 1035x' "$out/app.log" || fail "the low-res page was not enlarged"
key plus plus plus;                shot 03_lowres_zoomed_cleaned
key c; sleep 2;                    shot 04_lowres_zoomed_as_scanned
key c; sleep 2
key equal
key v; sleep 4; key l; sleep 1;    shot 05_guided_cleaned
key c; sleep 2;                    shot 06_guided_as_scanned
key c; sleep 2
key Escape
quit

# A restart keeps clean-up on; the big scan is not enlarged.
launch "$big"
key 1 4 shift+g; sleep 2;          shot 07_bigscan_cleaned_after_restart
key c; sleep 2;                    shot 08_bigscan_as_scanned
key c; sleep 2
quit
db=$(find "$home" -name '*.sqlite' | head -1)
[[ $(sqlite3 "$db" "select value from settings where key = 'reader.cleanUp'") == true ]] ||
  fail "clean-up was not kept on"
if grep -q 'Clean-up: page 2610x' "$out/app.log"; then fail "the big scan was enlarged"; fi

montage "$out"/shot_*.png -tile 2x -geometry 640x450+4+4 -title 'scan clean-up (c)' "$out/contact.png"
echo "Clean-up times:"
grep 'Clean-up: page' "$out/app.log" | sort | uniq -c | sort -rn | head -20
echo "OK: screenshots in $out"
